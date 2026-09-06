import Darwin
import Foundation

/// A static UTF-8 text credential, deliberately unencrypted at the user's explicit choice.
/// Render as plain text; this format has no executable HTML, links, or remote resources.
public struct IdentityRecoveryDocument {
    public static let maximumByteCount = 8_192
    public static let suggestedFileName = "ALO-identity-recovery.txt"
    public static let warning = """
    **WARNING: THIS UNENCRYPTED FILE IS YOUR ACCOUNT CREDENTIAL.**
    **Anyone with this file can impersonate you on every device.**
    **If you lose every signed-in device and this file, your identity cannot be recovered.**
    """

    private static let prefix = """
    ALO identity recovery

    \(warning)

    Keep this file somewhere private. Do not send it in chat or upload it publicly.
    No password protects this file. Import it in ALO to restore the same user on a new device.
    This restores your user root; it does not copy a device's TLS key or restore channel history.

    Format: alo-user-root-recovery-v1
    """ + "\n"

    public let publicIdentity: PublicUserIdentity
    private let privateKey: Data

    /// This is an explicit export operation; it does not read Keychain or write a file.
    public init(identity: UserIdentity) {
        publicIdentity = identity.publicIdentity
        privateKey = identity.rawPrivateKeyRepresentation
    }

    public func serializedData() -> Data {
        Data((Self.prefix + "User-ID: " + publicIdentity.userID + "\n"
            + "Public-Key-P256-X963-Base64: " + publicIdentity.publicKey.base64EncodedString() + "\n"
            + "Private-Key-P256-Raw-Base64: " + privateKey.base64EncodedString() + "\n").utf8)
    }

    /// The complete fixed grammar is required: no duplicate/unknown fields, alternate versions, or markup.
    /// Both public metadata fields must match the public key derived from the private root.
    public static func restore(from bytes: Data) throws -> UserIdentity {
        guard bytes.count <= maximumByteCount, let text = String(data: bytes, encoding: .utf8),
              text.hasPrefix(prefix) else { throw UserIdentityError.invalidRecoveryDocument }
        let fields = text.dropFirst(prefix.count).split(separator: "\n", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[3].isEmpty else { throw UserIdentityError.invalidRecoveryDocument }
        func field(_ index: Int, prefix: String) throws -> String {
            guard fields[index].hasPrefix(prefix) else { throw UserIdentityError.invalidRecoveryDocument }
            return String(fields[index].dropFirst(prefix.count))
        }
        func base64(_ value: String, byteCount: Int) throws -> Data {
            guard value.utf8.count <= 128, let data = Data(base64Encoded: value), data.count == byteCount,
                  data.base64EncodedString() == value else { throw UserIdentityError.invalidRecoveryDocument }
            return data
        }
        let userID = try field(0, prefix: "User-ID: ")
        let publicKey = try base64(field(1, prefix: "Public-Key-P256-X963-Base64: "), byteCount: 65)
        let privateKey = try base64(field(2, prefix: "Private-Key-P256-Raw-Base64: "), byteCount: 32)
        do {
            let declared = try PublicUserIdentity(userID: userID, publicKey: publicKey)
            let recovered = try UserIdentity(rawPrivateKeyRepresentation: privateKey)
            guard declared == recovered.publicIdentity else { throw UserIdentityError.invalidRecoveryDocument }
            return recovered
        } catch {
            throw UserIdentityError.invalidRecoveryDocument
        }
    }

    /// Bounds the file before and during reading. Symlink credentials are rejected.
    public static func restore(fromFile url: URL) throws -> UserIdentity {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw RecoveryExportError.invalidURL }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw RecoveryExportError.posix(errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw RecoveryExportError.posix(errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
              info.st_size <= maximumByteCount else { throw UserIdentityError.invalidRecoveryDocument }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while result.count <= maximumByteCount {
            let count = read(descriptor, &buffer, min(buffer.count, maximumByteCount + 1 - result.count))
            if count == 0 { return try restore(from: result) }
            if count < 0 {
                if errno == EINTR { continue }
                throw RecoveryExportError.posix(errno)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw UserIdentityError.invalidRecoveryDocument
    }

    /// Publishes a fully written 0600 regular file atomically without replacing any existing destination.
    /// A test can inject a temporary sibling URL; the helper never touches an installed app's keys.
    public func export(to destination: URL, temporaryURL: URL? = nil) throws {
        guard destination.isFileURL, !destination.path.utf8.contains(0) else { throw RecoveryExportError.invalidURL }
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let temporary = temporaryURL ?? parent.appendingPathComponent(".alo-identity-\(UUID().uuidString).tmp")
        guard temporary.isFileURL, !temporary.path.utf8.contains(0),
              temporary.standardizedFileURL.deletingLastPathComponent() == parent,
              temporary.standardizedFileURL != destination,
              !["", ".", ".."].contains(destination.lastPathComponent),
              !["", ".", ".."].contains(temporary.lastPathComponent) else { throw RecoveryExportError.invalidURL }

        // Hold the directory descriptor across creation and publication so a parent-path replacement
        // cannot redirect one half of the operation to a different directory.
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw RecoveryExportError.posix(errno) }
        defer { close(directory) }
        let temporaryName = temporary.lastPathComponent
        let descriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw RecoveryExportError.posix(errno) }
        defer {
            close(descriptor)
            unlinkat(directory, temporaryName, 0)
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else { throw RecoveryExportError.posix(errno) }
        let bytes = serializedData()
        try bytes.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { throw UserIdentityError.invalidRecoveryDocument }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, address.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RecoveryExportError.posix(errno)
                }
                guard count > 0 else { throw RecoveryExportError.posix(EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw RecoveryExportError.posix(errno) }
        // linkat is an atomic, exclusive publish. rename would overwrite a credential at the destination.
        guard linkat(directory, temporaryName, directory, destination.lastPathComponent, 0) == 0 else {
            if errno == EEXIST { throw RecoveryExportError.destinationExists }
            throw RecoveryExportError.posix(errno)
        }
    }
}

public enum RecoveryExportError: Error, Equatable {
    case invalidURL, destinationExists, posix(Int32)
}
