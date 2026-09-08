import Foundation
import CryptoKit
import Darwin

/// One short owner-local ingress path, never a network/identity-derived socket
/// name. MacOwnerSocket still validates ownership, modes, components and inode.
public enum DeviceMessagingLocalEndpoint {
    /// Copyable POSIX shell argument, including spaces and apostrophes. This
    /// formats instructions only; it does not execute a shell or alter PATH.
    public static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    public static func applicationDirectory(bundleID: String?, owner: uid_t = geteuid()) throws -> URL {
        guard let bundleID, !bundleID.isEmpty else { throw LocalDeviceMessageProtocol.Failure.invalidRequest }
        return directory(bundleID: bundleID, development: bundleID.hasSuffix(".dev"), owner: owner)
    }
    public static func directory(bundleID: String, development: Bool, owner: uid_t = geteuid()) -> URL {
        let scope = bundleID + (development ? "\ndevelopment" : "\nproduction")
        let suffix = SHA256.hash(data: Data(scope.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/private/tmp/alo-msg-\(owner)-\(suffix)", isDirectory: true)
    }
}
