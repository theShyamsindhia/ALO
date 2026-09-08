import Foundation
import ALOIdentity

/// Produced by the transport from its actual TLS peer and verified challenge,
/// not by discovery or callers. A snapshot for owner mapping, not dispatch authority.
public struct NetworkDeviceAuthenticatedRemote: Sendable {
    public let networkID: UUID
    public let generation: UUID
    public let policyRevision: UInt64
    public let root: PublicUserIdentity
    public let fullSPKIHash: Data
    public let deviceName: String

    init(challenge: NetworkDeviceAuthorization.Challenge, actualTLSHash: Data,
         localUser: PublicUserIdentity, policy: NetworkPolicyCenter) throws {
        try challenge.receiver.verify(expectedInstallationPublicKeyHash: actualTLSHash)
        guard challenge.purpose == NetworkDeviceAuthorization.purpose else { throw NetworkDeviceAuthorization.Failure.invalidClaim }
        let snapshot = try policy.withStablePolicy {
            let snapshot = try policy.snapshot()
            guard snapshot.id == challenge.networkID, snapshot.generation == challenge.generation,
                  snapshot.owner == challenge.owner, snapshot.isMember(localUser),
                  snapshot.isMember(challenge.receiver.userIdentity) else { throw NetworkDeviceAuthorization.Failure.notMember }
            return snapshot
        }
        networkID = snapshot.id; generation = snapshot.generation; policyRevision = snapshot.revision
        root = challenge.receiver.userIdentity; fullSPKIHash = actualTLSHash
        deviceName = challenge.receiver.deviceName
    }
    func isCurrent(in policy: NetworkPolicyCenter, localUser: PublicUserIdentity) throws -> Bool {
        let snapshot = try policy.snapshot()
        return snapshot.id == networkID && snapshot.generation == generation && snapshot.revision == policyRevision
            && snapshot.isMember(root) && snapshot.isMember(localUser)
    }
}
