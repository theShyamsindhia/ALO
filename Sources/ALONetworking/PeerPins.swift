import Foundation
import Security

public enum FirstContactPolicy: Sendable {
    case rejectUnknown
    /// The local user explicitly joined/created this room. This permits encrypted first
    /// contact, which is not verified human identity. Persist only after room admission.
    case explicitRoomJoin
}

public protocol PeerPinStore: AnyObject {
    func pin(for nodeID: UUID) throws -> Data?
    /// Atomically inserts an absent pin or verifies the same pin; never replaces a known key.
    func recordAfterAdmission(_ peer: PeerPublicIdentity) throws
}

public final class MemoryPeerPinStore: PeerPinStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [UUID: Data] = [:]
    public init() {}
    public func pin(for nodeID: UUID) -> Data? {
        lock.lock(); defer { lock.unlock() }; return pins[nodeID]
    }
    public func recordAfterAdmission(_ peer: PeerPublicIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        if let old = pins[peer.nodeID], old != peer.publicKeyHash { throw IdentityError.changedPeerKey }
        pins[peer.nodeID] = peer.publicKeyHash
    }
}

public final class KeychainPeerPinStore: PeerPinStore, @unchecked Sendable {
    private let namespace: IdentityKeychainNamespace
    private let lock = NSLock()
    public init(namespace: IdentityKeychainNamespace) { self.namespace = namespace }
    private func query(_ nodeID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: namespace.service + ".peer-pins",
         kSecAttrAccount as String: nodeID.uuidString,
         kSecUseDataProtectionKeychain as String: true]
    }
    private func read(_ nodeID: UUID) throws -> Data? {
        var parameters = query(nodeID)
        parameters[kSecReturnData as String] = true; parameters[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(parameters as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
        guard let bytes = result as? Data, bytes.count == 32 else { throw IdentityError.invalidKey }
        return bytes
    }
    public func pin(for nodeID: UUID) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; return try read(nodeID)
    }
    public func recordAfterAdmission(_ peer: PeerPublicIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        if let existing = try read(peer.nodeID) {
            guard existing == peer.publicKeyHash else { throw IdentityError.changedPeerKey }
            return
        }
        var parameters = query(peer.nodeID)
        parameters[kSecValueData as String] = peer.publicKeyHash
        parameters[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(parameters as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard try read(peer.nodeID) == peer.publicKeyHash else { throw IdentityError.changedPeerKey }
        } else if status != errSecSuccess { throw IdentityError.keychain(status) }
    }
}

public enum PeerTrustVerifier {
    /// TLS proves possession of the certificate key. This check binds the full node ID and
    /// stored SPKI pin to that key. It never writes first-contact pins during a TLS handshake.
    public static func evaluate(certificate: SecCertificate, expectedNodeID: UUID?,
                                pins: PeerPinStore, firstContact: FirstContactPolicy) throws -> PeerPublicIdentity {
        let peer = try PeerPublicIdentity.from(certificate: certificate)
        if let expectedNodeID, peer.nodeID != expectedNodeID { throw IdentityError.peerIdentityMismatch }
        if let pinned = try pins.pin(for: peer.nodeID) {
            guard pinned == peer.publicKeyHash else { throw IdentityError.changedPeerKey }
        } else {
            guard firstContact == .explicitRoomJoin else { throw IdentityError.unknownPeer }
        }
        return peer
    }
}
