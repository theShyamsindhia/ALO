#if os(macOS)
import Foundation
import Darwin

/// Owner-local bounded request/reply transport. It never enables a network,
/// approves a task, discovers private IPC, or executes a command.
public enum MacOwnerSocket {
    public enum Failure: Error, Equatable {
        case unsafePath, occupied, unauthorized, capacity, timeout, closed, system(Int32)
    }
    private static let timeoutNanos: UInt64 = 5_000_000_000
    private static let socketName = "ingress.sock"

    public final class Server: @unchecked Sendable {
        private let owner = DispatchQueue(label: "alo.owner-ingress")
        private let ownerKey = DispatchSpecificKey<Bool>()
        private let workers = DispatchQueue(label: "alo.owner-ingress.requests", attributes: .concurrent)
        private var source: DispatchSourceRead?
        private var listener: Int32 = -1
        private var directoryFD: Int32 = -1
        private var writerFD: Int32 = -1
        private var socketInode: ino_t = 0
        private var active: [UUID: Int32] = [:]
        private var stopped = false
        private let handler: @Sendable (LocalDeviceMessageProtocol.Request) -> LocalDeviceMessageProtocol.Response

        /// Directory must be canonical (no symlink path components). The final
        /// directory is created 0700 if absent; its existing parent is not changed.
        /// The app must choose a stable parent chain protected from other users
        /// (owner/root-managed directories, or a root-owned sticky temp parent
        /// for tests). Canonical-path checking is not an atomic ancestor walk;
        /// it does not defend a hostile local owner renaming parent directories
        /// between validation and pathname bind/connect. Do not use an arbitrary
        /// shared writable parent. Same-UID software remains locally trusted.
        /// Handler must perform bounded local state work only: never await user
        /// input, hash executables, wait for a process, perform network I/O, or
        /// re-enter the server. It is serialized with stop on the owner queue.
        public convenience init(directory: URL,
                    handler: @escaping @Sendable (LocalDeviceMessageProtocol.Request) -> LocalDeviceMessageProtocol.Response) throws {
            try self.init(directory: directory, afterMissingLockForTesting: nil, handler: handler)
        }

        /// Test-only scheduling seam at the real first-creation race boundary.
        /// Public construction always supplies nil and performs the same I/O.
        init(directory: URL, afterMissingLockForTesting: (() throws -> Void)?,
             handler: @escaping @Sendable (LocalDeviceMessageProtocol.Request) -> LocalDeviceMessageProtocol.Response) throws {
            self.handler = handler
            owner.setSpecific(key: ownerKey, value: true)
            do {
                directoryFD = try Self.openDirectory(directory)
                var existingLock = stat()
                if fstatat(directoryFD, "ingress.lock", &existingLock, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT else { throw Failure.system(errno) }
                    try afterMissingLockForTesting?()
                    let created = openat(directoryFD, "ingress.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    if created >= 0 { Darwin.close(created) }
                    else {
                        // Another starter may create the same lock after our
                        // missing-entry check. Still validate its owner/type and
                        // acquire flock below; existence alone is not authority.
                        guard errno == EEXIST else { throw Failure.system(errno) }
                    }
                }
                writerFD = try Self.openOwnerEntry(parent: directoryFD, name: "ingress.lock", directory: false)
                guard flock(writerFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure.occupied }
                let path = directory.appendingPathComponent(socketName).path
                var previous = stat()
                if fstatat(directoryFD, socketName, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard previous.st_mode & S_IFMT == S_IFSOCK, previous.st_uid == geteuid(),
                          previous.st_nlink == 1 else { throw Failure.unsafePath }
                    // A lock-free socket is not automatically stale: never unlink
                    // a live endpoint belonging to a noncooperating local process.
                    let probe = try makeSocket()
                    defer { Darwin.close(probe) }
                    let connected = try withAddress(path) {
                        let result = Darwin.connect(probe, $0, $1)
                        return (result, errno)
                    }
                    guard connected.0 != 0, connected.1 == ECONNREFUSED else { throw Failure.occupied }
                    var current = stat()
                    guard fstatat(directoryFD, socketName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                          current.st_ino == previous.st_ino, current.st_dev == previous.st_dev else { throw Failure.unsafePath }
                    guard unlinkat(directoryFD, socketName, 0) == 0 else { throw Failure.system(errno) }
                } else if errno != ENOENT { throw Failure.system(errno) }
                listener = try makeSocket()
                let boundResult = try withAddress(path) {
                    let result = Darwin.bind(listener, $0, $1)
                    return (result, errno)
                }
                guard boundResult.0 == 0 else { throw Failure.system(boundResult.1) }
                var bound = stat()
                guard fstatat(directoryFD, socketName, &bound, AT_SYMLINK_NOFOLLOW) == 0,
                      bound.st_mode & S_IFMT == S_IFSOCK, bound.st_uid == geteuid() else { throw Failure.unsafePath }
                socketInode = bound.st_ino
                guard fchmodat(directoryFD, socketName, 0o600, AT_SYMLINK_NOFOLLOW) == 0,
                      Darwin.listen(listener, 8) == 0 else { throw Failure.system(errno) }
                let fd = listener
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: owner)
                source.setEventHandler { [weak self] in self?.acceptAvailable() }
                source.setCancelHandler { Darwin.close(fd) }
                self.source = source
                source.resume()
            } catch {
                cleanupUnstarted()
                throw error
            }
        }

        public func stop() {
            if DispatchQueue.getSpecific(key: ownerKey) == true { stopOnOwner() }
            else { owner.sync { stopOnOwner() } }
        }
        private func stopOnOwner() {
            dispatchPrecondition(condition: .onQueue(owner))
            guard !stopped else { return }
            stopped = true
            // Request workers retain their descriptors until return. Shutdown
            // wakes poll/read without racing close against descriptor reuse.
            for fd in active.values { _ = shutdown(fd, SHUT_RDWR) }
            source?.cancel(); source = nil; listener = -1
            removeOwnedSocket()
            if writerFD >= 0 { Darwin.close(writerFD); writerFD = -1 }
            if directoryFD >= 0 { Darwin.close(directoryFD); directoryFD = -1 }
        }
        deinit { stop() }

        // Read-only test observations of actual descriptors, not alternate I/O.
        func descriptorFlagsForTesting() -> [Int32] {
            owner.sync { ([listener, directoryFD, writerFD] + Array(active.values)).filter { $0 >= 0 }.map { fcntl($0, F_GETFD) } }
        }
        func activeCountForTesting() -> Int { owner.sync { active.count } }
        func performOnOwnerForTesting(_ operation: @escaping @Sendable () -> Void) { owner.async(execute: operation) }

        private func acceptAvailable() {
            guard !stopped else { return }
            // Yield to queued stop/work completions even under connection flood.
            for _ in 0..<16 {
                let fd = Darwin.accept(listener, nil, nil)
                if fd < 0 { return }
                do {
                    try configure(fd)
                    try validatePeer(fd)
                    guard active.count < 8 else { throw Failure.capacity }
                    let id = UUID(); active[id] = fd
                    workers.async { [self] in
                        defer {
                            _ = owner.sync { active.removeValue(forKey: id) }
                            Darwin.close(fd)
                        }
                        do {
                            let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
                            let payload = try readPayload(fd, deadline: deadline)
                            let request = try LocalDeviceMessageProtocol.decodeRequest(payload)
                            let response = try owner.sync {
                                guard !stopped else { throw Failure.closed }
                                return handler(request)
                            }
                            try writeAll(fd, data: LocalDeviceMessageProtocol.encode(response), deadline: deadline)
                        } catch { /* Fail closed; no unbounded exception text on wire. */ }
                    }
                } catch { Darwin.close(fd) }
            }
        }

        private static func openDirectory(_ url: URL) throws -> Int32 {
            guard url.isFileURL, url.path.hasPrefix("/"),
                  url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw Failure.unsafePath }
            let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw Failure.unsafePath }
            defer { Darwin.close(parent) }
            var info = stat()
            guard fstat(parent, &info) == 0,
                  info.st_uid == geteuid() || info.st_uid == 0,
                  info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & S_ISVTX != 0) else { throw Failure.unsafePath }
            let name = url.lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { throw Failure.unsafePath }
            if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw Failure.system(errno) }
            return try openOwnerEntry(parent: parent, name: name, directory: true)
        }

        /// Repair only the fixed final owned entry, never its ancestors or
        /// group/world permissions. Parent is already trusted/open; a hostile
        /// same-UID rename remains outside this local trust boundary. Validation
        /// and reopen pin the inode, but this is not an atomic chmod-by-inode API.
        private static func openOwnerEntry(parent: Int32, name: String, directory: Bool) throws -> Int32 {
            let mode: mode_t = directory ? 0o700 : 0o600
            let type = directory ? S_IFDIR : S_IFREG
            var before = stat()
            guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_uid == geteuid(), before.st_mode & S_IFMT == type,
                  before.st_mode & 0o7777 & ~mode == 0,
                  directory || before.st_nlink == 1 else { throw Failure.unsafePath }
            if before.st_mode & 0o7777 != mode {
                guard fchmodat(parent, name, mode, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.system(errno) }
            }
            var after = stat()
            guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  after.st_ino == before.st_ino, after.st_dev == before.st_dev,
                  after.st_uid == geteuid(), after.st_mode & S_IFMT == type,
                  after.st_mode & 0o7777 == mode,
                  directory || after.st_nlink == 1 else { throw Failure.unsafePath }
            let fd = openat(parent, name, (directory ? O_RDONLY | O_DIRECTORY : O_RDWR | O_NONBLOCK) | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.system(errno) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_ino == before.st_ino,
                  opened.st_dev == before.st_dev, opened.st_uid == geteuid(),
                  opened.st_mode & S_IFMT == type, opened.st_mode & 0o7777 == mode,
                  directory || opened.st_nlink == 1 else { Darwin.close(fd); throw Failure.unsafePath }
            return fd
        }

        private func removeOwnedSocket() {
            guard directoryFD >= 0, socketInode != 0 else { return }
            var current = stat()
            if fstatat(directoryFD, socketName, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_ino == socketInode, current.st_mode & S_IFMT == S_IFSOCK,
               current.st_uid == geteuid() { _ = unlinkat(directoryFD, socketName, 0) }
            socketInode = 0
        }
        private func cleanupUnstarted() {
            if listener >= 0 { Darwin.close(listener); listener = -1 }
            removeOwnedSocket()
            if writerFD >= 0 { Darwin.close(writerFD); writerFD = -1 }
            if directoryFD >= 0 { Darwin.close(directoryFD); directoryFD = -1 }
        }
    }

    /// One request per connection; no private task enumeration or app bootstrap.
    /// Requires the same protected, stable parent chain documented by Server.
    public static func request(_ request: LocalDeviceMessageProtocol.Request, directory: URL) throws -> LocalDeviceMessageProtocol.Response {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else { throw Failure.unsafePath }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw Failure.unsafePath }
        let path = directory.appendingPathComponent(socketName).path
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600 else { throw Failure.unsafePath }
        let fd = try makeSocket(); defer { Darwin.close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
        let connected = try withAddress(path) {
            let result = Darwin.connect(fd, $0, $1)
            return (result, errno)
        }
        if connected.0 != 0 {
            guard connected.1 == EINPROGRESS else { throw Failure.system(connected.1) }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw Failure.closed }
        }
        try validatePeer(fd)
        try writeAll(fd, data: LocalDeviceMessageProtocol.encode(request), deadline: deadline)
        return try LocalDeviceMessageProtocol.decodeResponse(readPayload(fd, deadline: deadline))
    }

    static func validateOwner(peerUID: uid_t, expectedUID: uid_t) throws {
        guard peerUID == expectedUID else { throw Failure.unauthorized }
    }
    private static func validatePeer(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { throw Failure.unauthorized }
        try validateOwner(peerUID: uid, expectedUID: geteuid())
    }
    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system(errno) }
        do { try configure(fd); return fd }
        catch { Darwin.close(fd); throw error }
    }
    private static func configure(_ fd: Int32) throws {
        // Darwin accept/socket followed by fcntl is not atomic with another
        // thread's fork/exec. These flags bound normal child inheritance, not
        // that residual creation window; callers must not claim atomic CLOEXEC.
        let flags = fcntl(fd, F_GETFL)
        var noSignal: Int32 = 1
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Failure.system(errno) }
    }
    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unsafePath }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    private static func wait(_ fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw Failure.timeout }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(5_000, max(1, (deadline - now + 999_999) / 1_000_000)))
            let result = Darwin.poll(&item, 1, milliseconds)
            if result > 0 {
                guard item.revents & events != 0 else { throw Failure.closed }
                return
            }
            if result < 0, errno != EINTR { throw Failure.system(errno) }
        }
    }
    private static func readExactly(_ fd: Int32, count: Int, deadline: UInt64) throws -> Data {
        var data = Data(count: count), offset = 0
        while offset < count {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let remaining = count - offset
            let result = data.withUnsafeMutableBytes {
                let n = Darwin.read(fd, $0.baseAddress!.advanced(by: offset), remaining)
                return (n, errno)
            }
            let n = result.0
            if n > 0 { offset += n }
            else if n == 0 { throw Failure.closed }
            else if result.1 != EAGAIN && result.1 != EINTR { throw Failure.system(result.1) }
        }
        return data
    }
    private static func readPayload(_ fd: Int32, deadline: UInt64) throws -> Data {
        let header = try readExactly(fd, count: 4, deadline: deadline)
        return try readExactly(fd, count: LocalDeviceMessageProtocol.payloadLength(header: header), deadline: deadline)
    }
    private static func writeAll(_ fd: Int32, data: Data, deadline: UInt64) throws {
        var offset = 0
        while offset < data.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let result = data.withUnsafeBytes {
                let n = Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
                return (n, errno)
            }
            let n = result.0
            if n > 0 { offset += n }
            else if n == 0 { throw Failure.closed }
            else if result.1 != EAGAIN && result.1 != EINTR { throw Failure.system(result.1) }
        }
    }
}
#endif
