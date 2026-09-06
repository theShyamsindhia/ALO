import Foundation
import Security
import CryptoKit
import ALOCore
import ALOIdentity
import ALORooms

/// Network events prove their root user and signing installation independently of
/// the peer relaying them. Legacy fixtures retain direct TLS admission grants.
final class SecureRoomEventPolicy: @unchecked Sendable {
    private struct Proof: Codable {
        let certificate: Data
        let signature: Data
        let context: EventContext?
    }
    private struct Grant: Codable {
        let hash: Data
        let capabilities: PeerCapabilities
        let userIdentity: PublicUserIdentity?
    }
    private struct ArchiveAuthority: Codable, Equatable {
        let networkID: UUID
        let generation: UUID
        let owner: PublicUserIdentity
        let channelID: UUID
    }
    private struct EventContext: Codable {
        let version: UInt8
        let authority: ArchiveAuthority
        let device: DeviceIdentityBinding
    }
    private struct VerifiedEvent {
        let signer: PeerPublicIdentity
        let context: EventContext?
    }
    private struct VerificationCacheEntry {
        let encodedEvent: Data
        let verified: VerifiedEvent
        var encodedBytes: Int { encodedEvent.count }
    }
    static let maximumVerifiedEvents = 2_048
    static let maximumVerifiedEventBytes = 4 * 1_024 * 1_024
    private let verificationLock = NSLock()
    private var verifiedEvents = [String: VerificationCacheEntry]()
    private var verificationOrder = [String]()
    private var verificationHead = 0
    private var verifiedEventBytes = 0
    private var verificationCount: UInt64 = 0
    private let lock = NSLock()
    private var grants = [String: Grant]()
    private var acceptedHistory = Set<Data>()
    private var lastDurableSnapshot = Set<Data>()
    static let maximumAcceptedHistory = 16_384
    private let identity: InstallationIdentity?
    private let roomID: String
    private let networkAuthorization: NetworkChannelAuthorization?
    private let localBindingMatches: Bool

    init(roomID: String, identity: InstallationIdentity?, capabilities: PeerCapabilities,
         networkAuthorization: NetworkChannelAuthorization? = nil) {
        self.roomID = roomID; self.identity = identity
        self.networkAuthorization = networkAuthorization
        if let networkAuthorization, let identity,
           UUID(uuidString: roomID) == networkAuthorization.channelID {
            localBindingMatches = (try? networkAuthorization.localDevice.verify(
                expectedInstallationPublicKeyHash: identity.publicIdentity.publicKeyHash)) != nil
        } else { localBindingMatches = networkAuthorization == nil }
        if let identity {
            grants[identity.publicIdentity.nodeID.uuidString] = Grant(hash: identity.publicIdentity.publicKeyHash,
                capabilities: capabilities, userIdentity: networkAuthorization?.localDevice.userIdentity)
        }
    }

    private struct Archive: Codable { let body: Data; let signature: Data }
    private struct SavedState: Codable {
        let roomID: String
        let localPeerID: UUID
        let grants: [String: Grant]
        let document: Data
        let authority: ArchiveAuthority?
        let acceptedHistory: [Data]?
    }
    private static let archiveMagic = Data("ALOARCH2".utf8)
    private static let archiveDomain = Data("ALO/local-state-archive/v2\0".utf8)

    /// Admission grants are local trust decisions. Sign them with this
    /// installation's key; a remote sync document cannot manufacture grants.
    /// Pass the exact committed durable snapshot to persist only retained history.
    /// This does not prune the live receipt cache: another queue can have committed
    /// a newer event after the caller captured that snapshot.
    func archive(document: Data, retainedEvents: [MeshRoomEvent]? = nil) throws -> Data {
        guard let identity else { throw SecureTransportError.invalidCredentials }
        let authority = try archiveAuthority()
        let retainedDigests = try retainedEvents.map { Set(try $0.map(Self.historyDigest)) }
        let state = lock.withLock {
            let history = retainedDigests.map { acceptedHistory.intersection($0) } ?? acceptedHistory
            return SavedState(roomID: roomID, localPeerID: identity.publicIdentity.nodeID, grants: grants, document: document,
                authority: authority, acceptedHistory: authority == nil ? nil : history.sorted { $0.lexicographicallyPrecedes($1) })
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let body = try encoder.encode(state)
        let signature = try identity.signRoomEvent(Self.archiveDomain + body)
        return Self.archiveMagic + (try encoder.encode(Archive(body: body, signature: signature)))
    }

    func restoreArchive(_ data: Data) -> Data? {
        guard data.count <= 8 * 1_024 * 1_024, data.starts(with: Self.archiveMagic),
              let identity, let key = SecCertificateCopyKey(identity.certificate),
              let archive = try? PropertyListDecoder().decode(Archive.self, from: data.dropFirst(Self.archiveMagic.count)),
              SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256, (Self.archiveDomain + archive.body) as CFData,
                                    archive.signature as CFData, nil),
              let saved = try? PropertyListDecoder().decode(SavedState.self, from: archive.body),
              saved.roomID == roomID, saved.localPeerID == identity.publicIdentity.nodeID,
              saved.grants.count <= 1_024 else { return nil }
        if networkAuthorization != nil {
            guard let expected = try? archiveAuthority(), saved.authority == expected,
                  let history = saved.acceptedHistory, history.count <= Self.maximumAcceptedHistory,
                  Set(history).count == history.count, history.allSatisfy({ $0.count == 32 }),
                  saved.grants.allSatisfy({ id, grant in
                      grant.userIdentity != nil && grant.hash.count == 32
                          && (try? PeerPublicIdentity(publicKeyHash: grant.hash).nodeID.uuidString) == id
                  }) else { return nil }
        } else if saved.authority != nil { return nil }
        lock.withLock {
            let localID = identity.publicIdentity.nodeID.uuidString
            let currentLocalGrant = grants[localID]
            grants = saved.grants
            grants[localID] = currentLocalGrant
            acceptedHistory = Set(saved.acceptedHistory ?? [])
            lastDurableSnapshot = acceptedHistory
        }
        return saved.document
    }

    @discardableResult
    func admit(_ peer: AuthenticatedPeer, initiated: Bool) -> Bool {
        if let networkAuthorization {
            guard let user = peer.userIdentity, let manifest = try? currentManifest(),
                  (try? manifest.authorize(user, channelID: networkAuthorization.channelID)) != nil else { return false }
        }
        return lock.withLock {
            let id = peer.nodeID.uuidString
            guard grants[id] != nil || grants.count < 1_024 else { return false }
            if networkAuthorization != nil, let existing = grants[id] {
                // A signing installation cannot be reinterpreted as another user.
                guard existing.hash == peer.publicKeyHash, existing.userIdentity == peer.userIdentity else { return false }
            }
            grants[id] = Grant(hash: peer.publicKeyHash, capabilities: initiated
                ? peer.negotiated.responderCapabilities : peer.negotiated.initiatorCapabilities, userIdentity: peer.userIdentity)
            return true
        }
    }

    static func capability(for kind: MeshRoomEventKind) -> PeerCapabilities {
        switch kind {
        case .chat: return .chat
        case .queueAdd, .queueRemove, .queueReorder: return .editQueue
        case .broadcaster, .playback, .video: return .broadcast
        }
    }

    func sign(_ event: MeshRoomEvent) -> MeshRoomEvent? {
        guard let identity, event.roomID == roomID,
              event.version.nodeID == identity.publicIdentity.nodeID.uuidString,
              permits(author: event.version.nodeID, capability: Self.capability(for: event.kind)) else { return nil }
        let context: EventContext?
        if let networkAuthorization {
            guard let authority = try? archiveAuthority() else { return nil }
            context = EventContext(version: 1, authority: authority, device: networkAuthorization.localDevice)
        } else { context = nil }
        guard let bytes = try? Self.signingBytes(event, context: context),
              let signature = try? identity.signRoomEvent(bytes),
              let proof = try? JSONEncoder().encode(Proof(certificate: SecCertificateCopyData(identity.certificate) as Data,
                                                         signature: signature, context: context)) else { return nil }
        return event.authorized(with: proof)
    }

    func permits(author: String, capability: PeerCapabilities) -> Bool {
        guard let grant = lock.withLock({ grants[author] }), grant.capabilities.contains(capability) else { return false }
        return currentlyAuthorizes(grant)
    }

    /// Pins authorization across a Core transaction, including destructive
    /// retention. A changed policy must discard the candidate, not merely hide
    /// its new operations after they removed previously authorized records.
    var projectionRevision: UInt64? { try? currentManifest().revision }

    func accepts(_ event: MeshRoomEvent) -> Bool {
        guard event.roomID == roomID, Self.hasValidAuthorFields(event),
              let verified = cachedVerifiedEvent(event) else { return false }
        let digest = networkAuthorization == nil ? nil : try? Self.historyDigest(event)
        let state = lock.withLock { (grants[event.version.nodeID], digest.map { acceptedHistory.contains($0) } ?? false) }
        // Historical receipts preserve exact already-committed bytes after author
        // removal. They never grant the local user access to a revoked channel.
        if let networkAuthorization {
            guard let manifest = try? currentManifest(), let context = verified.context,
                  context.authority == Self.authority(for: manifest, channelID: networkAuthorization.channelID) else { return false }
            if state.1 { return true }
            if let grant = state.0 {
                guard grant.hash == verified.signer.publicKeyHash, grant.userIdentity == context.device.userIdentity,
                      grant.capabilities.contains(Self.capability(for: event.kind)) else { return false }
            } else if !Self.isDurable(event) {
                // Offline historical proofs never confer live broadcaster or
                // playback authority without the author's negotiated grant.
                return false
            }
            return (try? manifest.authorize(context.device.userIdentity, channelID: networkAuthorization.channelID)) != nil
        }
        guard let grant = state.0, grant.hash == verified.signer.publicKeyHash,
              grant.capabilities.contains(Self.capability(for: event.kind)) else { return false }
        return currentlyAuthorizes(grant)
    }

    /// Validates immutable document provenance, not permission to affect live
    /// state. A revoked author's authentic bytes can remain inert in the bounded
    /// CRDT without making every subsequent synchronization fail. Callers MUST
    /// separately filter projection, effects, counters and semantic retention
    /// through accepts(); storage alone never creates a historical receipt.
    func allowsDurableStorage(_ event: MeshRoomEvent) -> Bool {
        guard networkAuthorization != nil else { return accepts(event) }
        guard Self.isDurable(event), event.roomID == roomID, Self.hasValidAuthorFields(event),
              let verified = cachedVerifiedEvent(event), let context = verified.context,
              let expected = try? archiveAuthority(), context.authority == expected else { return false }
        return true
    }

    /// Receipt for a SUCCESSFULLY COMMITTED replica/Automerge transaction only.
    /// accepts() deliberately has no side effects: merely examining a candidate
    /// that later fails validation must never turn its bytes into trusted history.
    /// Call this on newly committed PROJECTED events, filtered through accepts(),
    /// immediately after the whole commit succeeds. Raw inert storage and failed
    /// or partially validated candidates must never receive historical receipts.
    ///
    /// `retainingHistory`, when supplied, must be the complete committed retained
    /// raw event set, captured on the same serialized transaction executor. It lets
    /// callers prune retired events without evicting still-retained old queue data.
    /// False is fail-closed; callers must stop/repair the session rather than keep
    /// accepting new durable state without historical receipts.
    @discardableResult
    func rememberAccepted(_ events: [MeshRoomEvent], retainingHistory: [MeshRoomEvent]? = nil) -> Bool {
        guard networkAuthorization != nil else { return true }
        guard let networkAuthorization, let manifest = try? currentManifest(),
              events.count <= Self.maximumAcceptedHistory else { return false }
        let expectedAuthority = Self.authority(for: manifest, channelID: networkAuthorization.channelID)
        var receipts = [(MeshRoomEvent, EventContext, Data)]()
        for event in events where Self.isDurable(event) {
            guard event.roomID == roomID, Self.hasValidAuthorFields(event),
                  let verified = cachedVerifiedEvent(event), let context = verified.context,
                  context.authority == expectedAuthority,
                  let digest = try? Self.historyDigest(event) else { return false }
            receipts.append((event, context, digest))
        }
        let retained: Set<Data>?
        if let retainingHistory {
            guard let digests = try? retainingHistory.map(Self.historyDigest) else { return false }
            retained = Set(digests)
        } else { retained = nil }
        return lock.withLock {
            // Only a currently authorized projection or an exact prior receipt
            // may become history. Cryptographically valid inert storage is not
            // a permission grant, even after the whole raw document commits.
            guard receipts.allSatisfy({ event, context, digest in
                if acceptedHistory.contains(digest) { return true }
                if let grant = grants[event.version.nodeID] {
                    guard grant.userIdentity == context.device.userIdentity,
                          grant.capabilities.contains(Self.capability(for: event.kind)) else { return false }
                }
                return (try? manifest.authorize(context.device.userIdentity, channelID: networkAuthorization.channelID)) != nil
            }) else { return false }
            // Only retire receipts that were in the PRIOR committed durable
            // snapshot. A replica queue may have accepted a new event whose
            // ingestion is still pending; it must not be erased by this worker.
            var next = retained.map { acceptedHistory.subtracting(lastDurableSnapshot.subtracting($0)) } ?? acceptedHistory
            next.formUnion(receipts.map { $0.2 })
            guard next.count <= Self.maximumAcceptedHistory else { return false }
            acceptedHistory = next
            if let retained { lastDurableSnapshot = retained }
            return true
        }
    }

    private static func isDurable(_ event: MeshRoomEvent) -> Bool {
        switch event.kind {
        case .chat, .queueAdd, .queueRemove, .queueReorder: return true
        default: return false
        }
    }

    private func currentlyAuthorizes(_ grant: Grant) -> Bool {
        guard let networkAuthorization else { return true }
        guard let user = grant.userIdentity, let manifest = try? currentManifest() else { return false }
        return (try? manifest.authorize(user, channelID: networkAuthorization.channelID)) != nil
    }

    /// Verifies the local root's binding too, so a mismatched context cannot
    /// authorize a different installation's local signatures.
    private func currentManifest() throws -> NetworkManifest {
        guard let networkAuthorization, localBindingMatches else { throw SecureTransportError.wrongContext }
        let manifest = try networkAuthorization.policy.snapshot()
        try manifest.authorize(networkAuthorization.localDevice.userIdentity, channelID: networkAuthorization.channelID)
        return manifest
    }

    private func archiveAuthority() throws -> ArchiveAuthority? {
        guard let networkAuthorization else { return nil }
        let manifest = try currentManifest()
        return Self.authority(for: manifest, channelID: networkAuthorization.channelID)
    }

    private static func authority(for manifest: NetworkManifest, channelID: UUID) -> ArchiveAuthority {
        ArchiveAuthority(networkID: manifest.id, generation: manifest.generation, owner: manifest.owner, channelID: channelID)
    }

    private static func historyDigest(_ event: MeshRoomEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: Data("alo.network.accepted-event.v1\0".utf8) + (try encoder.encode(event))))
    }

    static func hasValidSignature(_ event: MeshRoomEvent) -> Bool { verifiedEvent(event) != nil }

    /// Internal diagnostics cover crypto work and retained proof bytes only.
    var verificationCacheState: (count: Int, encodedBytes: Int, verificationCount: UInt64) {
        verificationLock.withLock { (verifiedEvents.count, verifiedEventBytes, verificationCount) }
    }

    private func cachedVerifiedEvent(_ event: MeshRoomEvent) -> VerifiedEvent? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let encodedEvent = try? encoder.encode(event) else { return nil }
        let cached: VerifiedEvent? = verificationLock.withLock {
            // ID is only an index. Compare the complete wire bytes, including
            // proof: Swift String equality alone folds distinct Unicode encodings
            // that have different signatures. No digest collisions grant hits.
            if let entry = verifiedEvents[event.id], entry.encodedEvent == encodedEvent { return entry.verified }
            verificationCount &+= 1
            return nil
        }
        if let cached { return cached }
        // Certificate parsing, root-binding verification and ECDSA must never
        // hold either the cache lock or the grants/receipt lock. Racing misses
        // may verify independently, but retain only one entry for this ID.
        guard let verified = Self.verifiedEvent(event) else { return nil }
        guard encodedEvent.count <= Self.maximumVerifiedEventBytes else { return verified }
        verificationLock.withLock {
            if let entry = verifiedEvents[event.id], entry.encodedEvent == encodedEvent { return }
            if let prior = verifiedEvents[event.id] { verifiedEventBytes -= prior.encodedBytes }
            else { verificationOrder.append(event.id) }
            verifiedEvents[event.id] = VerificationCacheEntry(encodedEvent: encodedEvent, verified: verified)
            verifiedEventBytes += encodedEvent.count
            while verifiedEvents.count > Self.maximumVerifiedEvents || verifiedEventBytes > Self.maximumVerifiedEventBytes {
                let oldest = verificationOrder[verificationHead]
                verificationHead += 1
                if let removed = verifiedEvents.removeValue(forKey: oldest) { verifiedEventBytes -= removed.encodedBytes }
            }
            if verificationHead > 128 && verificationHead * 2 >= verificationOrder.count {
                verificationOrder.removeFirst(verificationHead); verificationHead = 0
            }
        }
        // Membership, negotiated capabilities, manifest authority and historical
        // receipts are deliberately rechecked by each caller after this returns.
        return verified
    }

    private static func hasValidAuthorFields(_ event: MeshRoomEvent) -> Bool {
        if event.kind == .chat, let sender = event.senderID, sender != event.version.nodeID { return false }
        if event.kind == .broadcaster || event.kind == .video { return event.broadcasterID == event.version.nodeID }
        return true
    }

    private static func signingBytes(_ event: MeshRoomEvent, context: EventContext?) throws -> Data {
        guard let context else { return try event.signingBytes() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var wire = WireBytes()
        wire.append(Data("alo.network.signed-event.v1\0".utf8))
        wire.field(try encoder.encode(context))
        wire.field(try event.signingBytes())
        return wire.data
    }

    private static func verifiedEvent(_ event: MeshRoomEvent) -> VerifiedEvent? {
        guard let encoded = event.authorization, encoded.count <= 4_096,
              let proof = try? JSONDecoder().decode(Proof.self, from: encoded),
              let certificate = SecCertificateCreateWithData(nil, proof.certificate as CFData),
              let publicKey = SecCertificateCopyKey(certificate),
              let signer = try? PeerPublicIdentity.from(publicKey: publicKey),
              signer.nodeID.uuidString == event.version.nodeID else { return nil }
        if let context = proof.context {
            guard context.version == 1, context.authority.channelID == UUID(uuidString: event.roomID),
                  (try? context.device.verify(expectedInstallationPublicKeyHash: signer.publicKeyHash)) != nil else { return nil }
        }
        guard let bytes = try? signingBytes(event, context: proof.context),
              SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, bytes as CFData,
                                    proof.signature as CFData, nil) else { return nil }
        return VerifiedEvent(signer: signer, context: proof.context)
    }
}
