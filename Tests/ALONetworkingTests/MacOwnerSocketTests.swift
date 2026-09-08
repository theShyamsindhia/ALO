#if os(macOS)
import Foundation
import Darwin
import Testing
@testable import ALONetworking

@Suite("Owner-only local ingress", .serialized)
struct MacOwnerSocketTests {
    private func directory() throws -> URL {
        // Short canonical path respects Darwin's 104-byte sockaddr_un limit.
        let url = URL(fileURLWithPath: "/private/tmp/alo-ingress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }
    @Test func realRequestAndSingleOwner() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = UUID()
        let server = try MacOwnerSocket.Server(directory: directory) { _ in
            .init(status: .pendingApproval, registration: registration)
        }
        defer { server.stop() }
        // These checks inspect actual descriptor flags, not an exec'd child's
        // descriptor table. Child-inheritance integration remains a later gate.
        #expect(server.descriptorFlagsForTesting().count == 3)
        #expect(server.descriptorFlagsForTesting().allSatisfy { $0 & FD_CLOEXEC != 0 })
        let request = try LocalDeviceMessageProtocol.Request(operation: .register, taskID: UUID(), title: "Local")
        #expect(try MacOwnerSocket.request(request, directory: directory).registration == registration)
        #expect(throws: MacOwnerSocket.Failure.occupied) {
            try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .rejected) }
        }
        server.stop(); server.stop()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ingress.sock").path))
    }
    @Test func credentialBoundaryRejectsForeignUID() throws {
        try MacOwnerSocket.validateOwner(peerUID: 501, expectedUID: 501)
        #expect(throws: MacOwnerSocket.Failure.unauthorized) { try MacOwnerSocket.validateOwner(peerUID: 502, expectedUID: 501) }
    }
    @Test func clientRejectsNonFileURLBeforeConnecting() throws {
        let request = try LocalDeviceMessageProtocol.Request(operation: .status, registration: UUID())
        #expect(throws: MacOwnerSocket.Failure.unsafePath) {
            try MacOwnerSocket.request(request, directory: URL(string: "https://localhost/private/tmp")!)
        }
    }
    @Test func lastOwnerReleasedOnServerQueueDoesNotDeadlock() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let holder = ServerHolder(try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .rejected) })
        weak var observed = holder.server
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        defer { release.signal() }
        holder.server?.performOnOwnerForTesting {
            entered.signal()
            release.wait()
            // No request worker or local strong reference retains the server.
            // Its actual deinit therefore executes on its actual owner queue.
            holder.server = nil
            completed.signal()
        }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        release.signal()
        try #require(completed.wait(timeout: .now() + 2) == .success)
        #expect(observed == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ingress.sock").path))
    }
    @Test func unsafeDirectoryAndSocketSymlinkRejected() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(chmod(directory.path, 0o755) == 0)
        #expect(throws: MacOwnerSocket.Failure.unsafePath) {
            try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .rejected) }
        }
        #expect(chmod(directory.path, 0o700) == 0)
        let target = directory.appendingPathComponent("keep")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("ingress.sock"), withDestinationURL: target)
        #expect(throws: MacOwnerSocket.Failure.unsafePath) {
            try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .rejected) }
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }
    @Test func teardownDoesNotUnlinkReplacementInode() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .rejected) }
        let path = directory.appendingPathComponent("ingress.sock")
        try FileManager.default.removeItem(at: path)
        try Data("replacement".utf8).write(to: path)
        server.stop()
        #expect(try String(contentsOf: path, encoding: .utf8) == "replacement")
    }

    @Test func malformedFrameIsClosedWithoutCallingHandler() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let server = try MacOwnerSocket.Server(directory: directory) { _ in
            calls.increment(); return .init(status: .rejected)
        }
        defer { server.stop() }
        let fd = try connect(directory); defer { Darwin.close(fd) }
        let header: [UInt8] = [0,1,0,0]
        #expect(header.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == 4)
        try expectClosed(fd, timeoutMillis: 2000)
        #expect(calls.count == 0)
    }

    @Test func stalledFramesAreBoundedAndStopWakesReaders() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .rejected) }
        defer { server.stop() }
        var fds: [Int32] = []
        defer { for fd in fds { Darwin.close(fd) } }
        for _ in 0..<8 { fds.append(try connect(directory)) }
        let deadline = Date().addingTimeInterval(2)
        while server.activeCountForTesting() != 8, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        try #require(server.activeCountForTesting() == 8, "All eight baseline clients must be admitted before testing the ninth")
        #expect(server.descriptorFlagsForTesting().allSatisfy { $0 & FD_CLOEXEC != 0 })
        let excess = try connect(directory); defer { Darwin.close(excess) }
        try expectClosed(excess, timeoutMillis: 2000)
        #expect(server.activeCountForTesting() == 8)
        server.stop()
        for fd in fds { try expectClosed(fd, timeoutMillis: 2000) }
    }

    @Test func partialHeaderExpiresWithoutHandler() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let server = try MacOwnerSocket.Server(directory: directory) { _ in
            calls.increment(); return .init(status: .rejected)
        }
        defer { server.stop() }
        let fd = try connect(directory); defer { Darwin.close(fd) }
        var byte: UInt8 = 0
        #expect(Darwin.write(fd, &byte, 1) == 1)
        try expectClosed(fd, timeoutMillis: 8000)
        #expect(calls.count == 0)
    }

    @Test func competingFirstLockCreationReportsOccupied() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var competitor: Int32 = -1
        defer { if competitor >= 0 { Darwin.close(competitor) } }
        var staged = false
        #expect(throws: MacOwnerSocket.Failure.occupied) {
            try MacOwnerSocket.Server(directory: directory, afterMissingLockForTesting: {
                competitor = open(directory.appendingPathComponent("ingress.lock").path,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                try #require(competitor >= 0)
                try #require(flock(competitor, LOCK_EX | LOCK_NB) == 0)
                staged = true
            }) { _ in .init(status: .rejected) }
        }
        #expect(staged, "The competing process must actually acquire the newly created lock")
    }

    @Test(arguments: [0o600, 0o755])
    func liveNoncooperatingSocketIsNotUnlinked(mode: Int) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ingress.sock").path
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.utf8CString
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyBytes(from: $0) } }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(chmod(path, mode_t(mode)) == 0)
        try #require(Darwin.listen(listener, 8) == 0)
        var before = stat()
        try #require(lstat(path, &before) == 0)
        // No ingress.lock: the server must reach the real socket probe rather
        // than returning early from its cooperative writer-lock check.
        #expect(throws: MacOwnerSocket.Failure.occupied) {
            try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .rejected) }
        }
        var after = stat()
        try #require(lstat(path, &after) == 0)
        #expect(after.st_ino == before.st_ino && after.st_dev == before.st_dev)
        #expect(after.st_mode == before.st_mode)
        let connected = try connect(directory)
        Darwin.close(connected)
    }

    @Test(arguments: [0o600, 0o755])
    func verifiedStaleSocketRecoversIncludingPreChmodCrashMode(mode: Int) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ingress.sock").path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = path.utf8CString
            try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyBytes(from: $0) } }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0)
        } catch { Darwin.close(fd); throw error }
        Darwin.close(fd) // Actual bind-created stale socket, not a regular-file stand-in.
        try #require(chmod(path, mode_t(mode)) == 0)
        let server = try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .pendingApproval) }
        defer { server.stop() }
        let request = try LocalDeviceMessageProtocol.Request(operation: .status, registration: UUID())
        #expect(try MacOwnerSocket.request(request, directory: directory).status == .pendingApproval)
        var repaired = stat()
        try #require(lstat(path, &repaired) == 0)
        #expect(repaired.st_mode & 0o777 == 0o600)
    }

    @Test(arguments: [0o400, 0o000])
    func verifiedOwnerOnlyLockModeCanRecoverWithoutGlobalUmask(mode: Int) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ingress.lock").path
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        Darwin.close(fd)
        try #require(chmod(path, mode_t(mode)) == 0)
        // Same final owner-only modes produced by a stricter umask. Do not
        // mutate the process-wide umask in this concurrent test executable.
        let server = try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .rejected) }
        defer { server.stop() }
        var repaired = stat()
        try #require(lstat(path, &repaired) == 0)
        #expect(repaired.st_mode & 0o777 == 0o600)
    }

    @Test func sharedLockModeRemainsRejected() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ingress.lock").path
        try Data().write(to: URL(fileURLWithPath: path))
        try #require(chmod(path, 0o644) == 0)
        #expect(throws: MacOwnerSocket.Failure.unsafePath) {
            try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .rejected) }
        }
        var unchanged = stat()
        try #require(lstat(path, &unchanged) == 0)
        #expect(unchanged.st_mode & 0o777 == 0o644)
    }

    @Test(arguments: [0o500, 0o000])
    func verifiedOwnerOnlyFinalDirectoryCanRecover(mode: Int) throws {
        let directory = try directory()
        defer { _ = chmod(directory.path, 0o700); try? FileManager.default.removeItem(at: directory) }
        try #require(chmod(directory.path, mode_t(mode)) == 0)
        let server = try MacOwnerSocket.Server(directory: directory) { _ in .init(status: .rejected) }
        defer { server.stop() }
        var repaired = stat()
        try #require(lstat(directory.path, &repaired) == 0)
        #expect(repaired.st_mode & 0o777 == 0o700)
    }

    /// Isolated platform feasibility oracle, not the production repair path.
    /// Tests actual descriptor-relative0000/0400 repair before relying on it.
    @Test(arguments: [0, 1, 2, 3])
    func descriptorRelativeOwnerOnlyRepairIsSupported(fixture: Int) throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let isDirectory = fixture >= 2, initial: mode_t = fixture % 2 == 0 ? 0 : 0o400
        let target: mode_t = isDirectory ? 0o700 : 0o600
        let name = "fixed-owned-entry", path = parent.appendingPathComponent(name).path
        if isDirectory { try #require(mkdir(path, 0o700) == 0) }
        else {
            let created = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            try #require(created >= 0); Darwin.close(created)
        }
        defer { _ = chmod(path, target) }
        try #require(chmod(path, initial) == 0)
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(parentFD >= 0); defer { Darwin.close(parentFD) }
        var parentInfo = stat(), before = stat()
        try #require(fstat(parentFD, &parentInfo) == 0)
        try #require(parentInfo.st_uid == geteuid() && parentInfo.st_mode & 0o777 == 0o700)
        try #require(fstatat(parentFD, name, &before, AT_SYMLINK_NOFOLLOW) == 0)
        try #require(before.st_uid == geteuid())
        try #require(before.st_mode & S_IFMT == (isDirectory ? S_IFDIR : S_IFREG))
        try #require(before.st_mode & 0o7777 & ~target == 0)
        if !isDirectory { try #require(before.st_nlink == 1) }
        try #require(fchmodat(parentFD, name, target, AT_SYMLINK_NOFOLLOW) == 0,
            "Actual platform must support nofollow descriptor-relative mode recovery")
        var after = stat()
        try #require(fstatat(parentFD, name, &after, AT_SYMLINK_NOFOLLOW) == 0)
        #expect(after.st_ino == before.st_ino && after.st_dev == before.st_dev)
        #expect(after.st_mode & 0o7777 == target)
        let reopened = openat(parentFD, name, (isDirectory ? O_RDONLY | O_DIRECTORY : O_RDWR) | O_NOFOLLOW | O_CLOEXEC)
        try #require(reopened >= 0); defer { Darwin.close(reopened) }
        var opened = stat()
        try #require(fstat(reopened, &opened) == 0)
        #expect(opened.st_ino == before.st_ino && opened.st_dev == before.st_dev)
    }

    private func connect(_ directory: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MacOwnerSocket.Failure.system(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = directory.appendingPathComponent("ingress.sock").path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd); throw MacOwnerSocket.Failure.unsafePath
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in path.withUnsafeBytes { target.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { let error = errno; Darwin.close(fd); throw MacOwnerSocket.Failure.system(error) }
        return fd
    }
    private func expectClosed(_ fd: Int32, timeoutMillis: Int32) throws {
        var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = Darwin.poll(&state, 1, timeoutMillis)
        try #require(result > 0, "Server must close within the bounded observation window")
        var byte: UInt8 = 0
        #expect(Darwin.read(fd, &byte, 1) == 0)
    }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    // Ownership transfers to the queued closure before mutation; the semaphore
    // synchronizes the test's final weak-reference observation.
    private final class ServerHolder: @unchecked Sendable {
        var server: MacOwnerSocket.Server?
        init(_ server: MacOwnerSocket.Server) { self.server = server }
    }
}
#endif
