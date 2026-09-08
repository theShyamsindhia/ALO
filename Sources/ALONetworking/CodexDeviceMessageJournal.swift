import Foundation
import Darwin

/// One receiver-owned journal. The service is its sole writer. Callers choose
/// a private application directory; this is never a path obtained from a peer.
public final class CodexDeviceMessageJournal {
    public static let maximumBytes = 2 * 1024 * 1024
    private let directory: Int32
    private let writerLock: Int32
    private(set) var committedWrites = 0
    public init(directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_uid == getuid(), status.st_mode & 0o077 == 0 else {
            close(fd); throw POSIXError(.EACCES)
        }
        let writer = openat(fd, "writer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard writer >= 0 else { close(fd); throw POSIXError(.EACCES) }
        var writerStatus = stat()
        guard fstat(writer, &writerStatus) == 0, writerStatus.st_mode & S_IFMT == S_IFREG,
              writerStatus.st_uid == getuid(), writerStatus.st_mode & 0o077 == 0,
              flock(writer, LOCK_EX | LOCK_NB) == 0 else {
            close(writer); close(fd); throw POSIXError(.EACCES)
        }
        directory = fd; writerLock = writer
    }
    deinit { close(writerLock); close(directory) }
    public func load() throws -> CodexDeviceMessagingPolicy.Checkpoint? {
        let fd = openat(directory, "receipts.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw POSIXError(.EIO) }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_mode & 0o077 == 0,
              status.st_size >= 0, status.st_size <= Self.maximumBytes else { throw POSIXError(.EACCES) }
        var bytes = Data(count: Int(status.st_size))
        try bytes.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        return try JSONDecoder().decode(CodexDeviceMessagingPolicy.Checkpoint.self, from: bytes)
    }
    public func save(_ checkpoint: CodexDeviceMessagingPolicy.Checkpoint) throws {
        let bytes = try JSONEncoder().encode(checkpoint)
        guard bytes.count <= Self.maximumBytes else { throw CodexDeviceMessagingError.capacity }
        let temporary = "receipt-\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, "receipts.json") == 0,
              fsync(directory) == 0 else { throw POSIXError(.EIO) }
        committedWrites += 1
    }
}
