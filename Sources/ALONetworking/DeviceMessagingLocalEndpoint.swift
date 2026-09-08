import Foundation
import CryptoKit
import Darwin

/// One short owner-local ingress path, never a network/identity-derived socket
/// name. MacOwnerSocket still validates ownership, modes, components and inode.
public enum DeviceMessagingLocalEndpoint {
    public enum Failure: Error { case unsafeTemporaryDirectory }
    /// Copyable POSIX shell argument, including spaces and apostrophes. This
    /// formats instructions only; it does not execute a shell or alter PATH.
    public static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    public static func applicationDirectory(bundleID: String?, owner: uid_t = geteuid()) throws -> URL {
        guard let bundleID, !bundleID.isEmpty else { throw LocalDeviceMessageProtocol.Failure.invalidRequest }
        return try directory(bundleID: bundleID, development: bundleID.hasSuffix(".dev"), owner: owner)
    }
    public static func directory(bundleID: String, development: Bool, owner: uid_t = geteuid()) throws -> URL {
        let scope = bundleID + (development ? "\ndevelopment" : "\nproduction")
        let suffix = SHA256.hash(data: Data(scope.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        // Ask Darwin, not an inherited TMPDIR supplied by an invoking shell.
        // Another UID cannot pre-create the deterministic child in this parent.
        #if os(macOS)
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 1, count <= 4096 else { throw Failure.unsafeTemporaryDirectory }
        var buffer = [CChar](repeating: 0, count: count)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, count) == count else { throw Failure.unsafeTemporaryDirectory }
        let parent = URL(fileURLWithPath: String(cString: buffer), isDirectory: true).resolvingSymlinksInPath()
        #else
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        #endif
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw Failure.unsafeTemporaryDirectory }
        let result = parent.appendingPathComponent("alo-\(owner)-\(suffix)", isDirectory: true)
        guard result.appendingPathComponent("ingress.sock").path.utf8.count < 104 else { throw Failure.unsafeTemporaryDirectory }
        return result
    }
}
