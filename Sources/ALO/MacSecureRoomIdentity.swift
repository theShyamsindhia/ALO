import Foundation
import ALONetworking

/// Loaded only after an explicit create/join operation. Discovery and merely
/// opening the app must not generate an identity or prompt for Keychain access.
final class MacSecureRoomIdentity {
    let identity: InstallationIdentity
    let pins: KeychainPeerPinStore

    init() throws {
        let bundleID = Bundle.main.bundleIdentifier ?? "in.werai.audio"
        let namespace = try IdentityKeychainNamespace(applicationID: bundleID,
            environment: bundleID == "in.werai.audio.dev" ? .development : .production)
        identity = try InstallationIdentity.loadOrCreate(namespace: namespace)
        pins = KeychainPeerPinStore(namespace: namespace)
    }
}

/// Admission handlers must be installed inline on the channel's serial queue,
/// not through a MainActor hop that can lose the first coalesced payload.
final class SecureMediaAdmissionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((SecurePeerChannel, AuthenticatedPeer) -> Void)?
    func update(_ handler: ((SecurePeerChannel, AuthenticatedPeer) -> Void)?) {
        lock.withLock { self.handler = handler }
    }
    func receive(_ channel: SecurePeerChannel, peer: AuthenticatedPeer) {
        let current = lock.withLock { handler }
        if let current { current(channel, peer) } else { channel.cancel() }
    }
}
