import Foundation
import CryptoKit
import ALOIdentity
import ALORooms

/// One authority cache per joined network. Storage owns rollback/equivocation
/// protection; observers run outside the lock and marshal onto their executor.
/// No root private key or socket belongs in this object.
public final class NetworkPolicyCenter: @unchecked Sendable {
    private let repository: NetworkRepository
    private let anchor: NetworkManifest
    private let lock = NSLock()
    /// Serializes verification/persistence without holding the snapshot lock
    /// used by per-packet media authorization.
    private let updateLock = NSLock()
    private var current: NetworkManifest
    private var invalid = false
    private var observers = [UUID: () -> Void]()

    public init(repository: NetworkRepository, networkID: UUID) throws {
        self.repository = repository
        let manifest = try repository.trustedManifest(id: networkID)
        anchor = manifest
        current = manifest
    }

    public func snapshot() throws -> NetworkManifest {
        lock.lock(); defer { lock.unlock() }
        guard !invalid else { throw NetworkAuthorityError.quarantined }
        return current
    }

    /// A stale peer may learn the latest policy, but cannot replace it with an
    /// older one. Unknown owners and network generations are never admitted.
    public func receive(_ incoming: NetworkManifest) throws {
        updateLock.lock()
        var callbacks = [() -> Void]()
        let result = Result<Void, Error> {
            let prior = try snapshot()
            guard incoming.id == anchor.id, incoming.owner == anchor.owner,
                  incoming.generation == anchor.generation else { throw NetworkAuthorityError.ownerChanged }
            try incoming.validateSignature()
            if incoming.revision < prior.revision { return }
            let accepted = try repository.acceptUpdate(incoming, anchoredTo: anchor)
            let changed = try accepted.canonicalBytes() != prior.canonicalBytes()
            lock.lock()
            current = accepted
            callbacks = changed ? Array(observers.values) : []
            lock.unlock()
        }
        if case .failure(let error) = result {
            let conflict = (error as? NetworkAuthorityError) == .revisionConflict
                || (error as? NetworkAuthorityError) == .quarantined
            if conflict {
                lock.lock(); invalid = true; callbacks = Array(observers.values); lock.unlock()
            }
        }
        updateLock.unlock()
        callbacks.forEach { $0() }
        try result.get()
    }

    /// Call after a local owner mutation/import. Existing connections recheck
    /// access and publish the new signed policy without restarting media.
    public func reload() throws {
        do { try receive(repository.trustedManifest(id: anchor.id)) }
        catch {
            lock.lock(); invalid = true; let callbacks = Array(observers.values); lock.unlock()
            callbacks.forEach { $0() }
            throw error
        }
    }

    @discardableResult
    public func observe(_ callback: @escaping () -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); observers[id] = callback; return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        observers.removeValue(forKey: id)
    }
}

public struct NetworkPeerClaim: Codable, Sendable {
    public let manifest: NetworkManifest
    public let channelID: UUID
    public let device: DeviceIdentityBinding

    /// The transcript binds the complete signed policy and root-authorized TLS
    /// key, not a name, Bonjour label, truncated fingerprint, or shared password.
    func transcriptDigest() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(self)))
    }
}

/// Required by every production control/media/file/voice connection. All roles
/// share this authorization path; private channels do not have a bypass key.
public struct NetworkChannelAuthorization: Sendable {
    public let policy: NetworkPolicyCenter
    public let channelID: UUID
    public let localDevice: DeviceIdentityBinding

    public init(policy: NetworkPolicyCenter, channelID: UUID, localDevice: DeviceIdentityBinding) throws {
        self.policy = policy; self.channelID = channelID; self.localDevice = localDevice
        try localDevice.verify(expectedInstallationPublicKeyHash: localDevice.installationPublicKeyHash)
        try policy.snapshot().authorize(localDevice.userIdentity, channelID: channelID)
    }

    func claim(installationKeyHash: Data) throws -> NetworkPeerClaim {
        try localDevice.verify(expectedInstallationPublicKeyHash: installationKeyHash)
        let manifest = try policy.snapshot()
        try manifest.authorize(localDevice.userIdentity, channelID: channelID)
        return NetworkPeerClaim(manifest: manifest, channelID: channelID, device: localDevice)
    }

    @discardableResult
    func validate(_ remote: NetworkPeerClaim, installationKeyHash: Data) throws -> PublicUserIdentity {
        guard remote.channelID == channelID else { throw SecureTransportError.wrongContext }
        try remote.device.verify(expectedInstallationPublicKeyHash: installationKeyHash)
        // A signed update can revoke our access. Persist it before denying, so
        // restarting cannot resurrect authorization from an old invitation.
        try policy.receive(remote.manifest)
        try validateCurrentAccess(remote.device.userIdentity)
        return remote.device.userIdentity
    }

    func validateCurrentAccess(_ remote: PublicUserIdentity) throws {
        let manifest = try policy.snapshot()
        try manifest.authorize(localDevice.userIdentity, channelID: channelID)
        try manifest.authorize(remote, channelID: channelID)
    }
}
