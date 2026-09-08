import Foundation
import CryptoKit
import ALOIdentity
import ALORooms

/// Channel-independent, receiver-owned admission. No socket, grant, or task selection.
/// Actual TLS hashes MUST come from the mutually authenticated connection, not wire claims.
public final class NetworkDeviceAuthorization: @unchecked Sendable {
    public static let purpose = "alo.network.codex-device-messaging.v1"
    public enum Failure: Error { case invalidClaim, expired, replay, capacity, notMember }

    public struct Challenge: Codable, Equatable, Sendable {
        public let purpose: String
        public let networkID: UUID
        public let generation: UUID
        public let owner: PublicUserIdentity
        public let receiver: DeviceIdentityBinding
        public let nonce: Data
    }

    public struct Claim: Codable, Sendable {
        public let challenge: Challenge
        public let sender: DeviceIdentityBinding
        public let senderNonce: Data
        public let signature: Data

        /// Both hashes originate in the actual local/remote TLS installations.
        public static func signed(challenge: Challenge, sender: DeviceIdentityBinding,
                                  user: UserIdentity, policy: NetworkPolicyCenter,
                                  actualSenderTLSHash: Data, actualReceiverTLSHash: Data) throws -> Self {
            try challenge.receiver.verify(expectedInstallationPublicKeyHash: actualReceiverTLSHash)
            try sender.verify(expectedInstallationPublicKeyHash: actualSenderTLSHash)
            guard challenge.purpose == NetworkDeviceAuthorization.purpose,
                  challenge.nonce.count == 32, sender.userIdentity == user.publicIdentity else {
                throw Failure.invalidClaim
            }
            return try policy.withStablePolicy {
                let manifest = try policy.snapshot()
                guard manifest.id == challenge.networkID, manifest.generation == challenge.generation,
                      manifest.owner == challenge.owner else { throw Failure.invalidClaim }
                guard manifest.isMember(sender.userIdentity), manifest.isMember(challenge.receiver.userIdentity) else {
                    throw Failure.notMember
                }
                let nonce = NetworkDeviceAuthorization.randomNonce()
                let unsigned = Self(challenge: challenge, sender: sender, senderNonce: nonce, signature: Data())
                return Self(challenge: challenge, sender: sender, senderNonce: nonce,
                            signature: try user.sign(unsigned.payload(), domain: NetworkDeviceAuthorization.purpose))
            }
        }

        private func payload() throws -> Data {
            // Explicit versioned fields, sorted-key JSON; signature is never self-included.
            struct Transcript: Encodable {
                let challenge: Challenge
                let sender: DeviceIdentityBinding
                let senderNonce: Data
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(Transcript(challenge: challenge, sender: sender, senderNonce: senderNonce))
        }

        fileprivate func verify(actualSenderTLSHash: Data) throws {
            try sender.verify(expectedInstallationPublicKeyHash: actualSenderTLSHash)
            guard senderNonce.count == 32,
                  sender.userIdentity.verify(signature: signature, payload: try payload(),
                                             domain: NetworkDeviceAuthorization.purpose) else {
                throw Failure.invalidClaim
            }
        }
    }

    public struct Context: Sendable {
        public let networkID: UUID
        public let generation: UUID
        public let owner: PublicUserIdentity
        public let sender: PublicUserIdentity
        public let receiver: PublicUserIdentity
        public let senderSPKIHash: Data
        public let receiverSPKIHash: Data
        public let purpose: String
        public let sessionValidUntilNanos: UInt64
        public let policyRevision: UInt64
        fileprivate init(challenge: Challenge, sender: DeviceIdentityBinding, expires: UInt64, revision: UInt64) {
            networkID = challenge.networkID; generation = challenge.generation; owner = challenge.owner
            self.sender = sender.userIdentity; receiver = challenge.receiver.userIdentity
            senderSPKIHash = sender.installationPublicKeyHash
            receiverSPKIHash = challenge.receiver.installationPublicKeyHash
            purpose = challenge.purpose; sessionValidUntilNanos = expires
            policyRevision = revision
        }
    }

    public struct Session: Sendable {
        fileprivate let issuer: UUID
        fileprivate let context: Context
    }

    private let policy: NetworkPolicyCenter
    private let localDevice: DeviceIdentityBinding
    private let issuer = UUID()
    private let lock = NSLock()
    private var pending: [Data: (Challenge, UInt64)] = [:]
    private let challengeLifetime: UInt64 = 5_000_000_000
    private let sessionLifetime: UInt64 = 300_000_000_000

    public init(policy: NetworkPolicyCenter, localDevice: DeviceIdentityBinding,
                actualLocalTLSHash: Data) throws {
        try localDevice.verify(expectedInstallationPublicKeyHash: actualLocalTLSHash)
        guard try policy.snapshot().isMember(localDevice.userIdentity) else { throw Failure.notMember }
        self.policy = policy; self.localDevice = localDevice
    }

    public func challenge(nowNanos: UInt64) throws -> Challenge {
        let manifest = try policy.snapshot()
        guard manifest.isMember(localDevice.userIdentity), nowNanos <= UInt64.max - challengeLifetime else {
            throw Failure.invalidClaim
        }
        let value = Challenge(purpose: Self.purpose, networkID: manifest.id, generation: manifest.generation,
                              owner: manifest.owner, receiver: localDevice, nonce: Self.randomNonce())
        lock.lock(); defer { lock.unlock() }
        pending = pending.filter { nowNanos < $0.value.1 }
        guard pending.count < 64 else { throw Failure.capacity }
        pending[value.nonce] = (value, nowNanos + challengeLifetime)
        return value
    }
    public func cancel(_ challenge: Challenge) {
        lock.lock(); defer { lock.unlock() }
        if pending[challenge.nonce]?.0 == challenge { pending.removeValue(forKey: challenge.nonce) }
    }
    public func cancelAll() { lock.lock(); defer { lock.unlock() }; pending.removeAll() }

    /// Every attempt consumes the challenge, including invalid signatures. Reconnect creates a new one.
    public func accept(_ claim: Claim, actualSenderTLSHash: Data, nowNanos: UInt64) throws -> Session {
        try accept(claim, actualSenderTLSHash: actualSenderTLSHash, clock: { nowNanos })
    }
    func accept(_ claim: Claim, actualSenderTLSHash: Data, clock: () -> UInt64) throws -> Session {
        lock.lock(); let entry = pending.removeValue(forKey: claim.challenge.nonce); lock.unlock()
        guard let entry else { throw Failure.replay }
        guard entry.0 == claim.challenge else { throw Failure.invalidClaim }
        try claim.verify(actualSenderTLSHash: actualSenderTLSHash)
        return try policy.withStablePolicy {
            let nowNanos = clock()
            guard nowNanos < entry.1, nowNanos <= UInt64.max - sessionLifetime else { throw Failure.expired }
            let context = Context(challenge: claim.challenge, sender: claim.sender, expires: nowNanos + sessionLifetime,
                                  revision: try policy.snapshot().revision)
            try validate(context, nowNanos: nowNanos)
            return Session(issuer: issuer, context: context)
        }
    }

    /// Use at receipt AND immediately at dispatch. Do not cache Context as authorization.
    /// Body must be short, synchronous, and must not reenter this policy center or call application callbacks.
    public func withCurrentContext<T>(session: Session, nowNanos: UInt64,
                                      body: (Context) throws -> T) throws -> T {
        try withCurrentContext(session: session, clock: { nowNanos }) { context, _ in try body(context) }
    }
    func withCurrentContext<T>(session: Session, clock: () -> UInt64,
                              body: (Context, UInt64) throws -> T) throws -> T {
        guard session.issuer == issuer else { throw Failure.invalidClaim }
        return try policy.withStablePolicy {
            let nowNanos = clock()
            try validate(session.context, nowNanos: nowNanos)
            return try body(session.context, nowNanos)
        }
    }

    private func validate(_ context: Context, nowNanos: UInt64) throws {
        guard nowNanos < context.sessionValidUntilNanos else { throw Failure.expired }
        let manifest = try policy.snapshot()
        guard context.purpose == Self.purpose, manifest.id == context.networkID,
              manifest.generation == context.generation, manifest.owner == context.owner,
              manifest.revision == context.policyRevision else {
            throw Failure.invalidClaim
        }
        guard manifest.isMember(context.sender), manifest.isMember(context.receiver) else { throw Failure.notMember }
    }

    private static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
