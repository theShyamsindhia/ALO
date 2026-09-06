import Foundation
import CryptoKit

/// One file per separately authenticated channel. Nothing is replicated.
public enum DirectFileWire: Codable, Sendable {
    case offer(name: String, size: Int64)
    case accept
    case decline
    case chunk(offset: Int64, bytes: Data)
    case acknowledge(offset: Int64)
    case finish(digest: Data)
    case complete

    public static let chunkBytes = 64 * 1024
    public static let maximumFileBytes: Int64 = 1024 * 1024 * 1024
    public static func safeName(_ name: String) throws -> String {
        guard !name.isEmpty, name.utf8.count <= 240,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw DirectFileError.invalidFile }
        return name
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 100 * 1024 else { throw DirectFileError.invalidFile }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public enum DirectFileError: String, Error, LocalizedError {
    case invalidFile = "This file or transfer is invalid."
    case interrupted = "The file transfer was interrupted. Try sending it again."
    case tooLarge = "Send a regular file smaller than 1 GB."
    case busy = "Too many transfers are active. Try again shortly."
    case declined = "The other device declined the file."
    public var errorDescription: String? { rawValue }
}

/// Writes only to a caller-created unique temporary destination. Count, order,
/// and SHA-256 must all agree before this file can be shown or saved.
public final class DirectFileSink {
    public private(set) var offset: Int64 = 0
    private let size: Int64
    private let handle: FileHandle
    private var hash = SHA256()
    public init(url: URL, size: Int64) throws {
        guard size >= 0, size <= DirectFileWire.maximumFileBytes else { throw DirectFileError.tooLarge }
        self.size = size
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw DirectFileError.invalidFile }
        handle = try FileHandle(forWritingTo: url)
    }
    deinit { try? handle.close() }
    public func append(offset: Int64, bytes: Data) throws {
        guard offset == self.offset, !bytes.isEmpty, bytes.count <= DirectFileWire.chunkBytes,
              Int64(bytes.count) <= size - self.offset else { throw DirectFileError.invalidFile }
        try handle.write(contentsOf: bytes)
        hash.update(data: bytes)
        self.offset += Int64(bytes.count)
    }
    public func finish(digest: Data) throws {
        guard offset == size, digest.count == 32, Data(hash.finalize()) == digest else { throw DirectFileError.invalidFile }
        try handle.synchronize()
        try handle.close()
    }
}
