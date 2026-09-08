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
