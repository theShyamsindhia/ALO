import Foundation
import Testing
import ALOCore
import ALOIdentity
import ALORooms
@testable import ALONetworking

@Suite("Bounded exact-event cryptographic proof cache")
struct EventProofCacheTests {
    @Test func storageProjectionAndReceiptsReuseOnlyTheSuccessfulProofVerification() throws {
        let f = try EventProofNetworkFixture()
        defer { f.cleanup() }
        let event = try f.event(counter: 1)
        for _ in 0..<20 {
            #expect(f.receiver.allowsDurableStorage(event))
            #expect(f.receiver.accepts(event))
            #expect(f.receiver.rememberAccepted([event], retainingHistory: [event]))
        }
        #expect(f.receiver.verificationCacheState.verificationCount == 1)
        #expect(f.receiver.verificationCacheState.count == 1)
    }

    @Test func sameIDWithChangedContentOrProofCannotReuseACachedSuccess() throws {
        let f = try EventProofLegacyFixture()
        let event = try f.event(counter: 1)
        let proof = try #require(event.authorization)
        #expect(f.policy.accepts(event))
        let changedContent = MeshRoomEvent(id: event.id, roomID: event.roomID, version: event.version,
            kind: event.kind, senderID: event.senderID, text: "Altered signed content").authorized(with: proof)
        var object = try #require(JSONSerialization.jsonObject(with: proof) as? [String: Any])
        object["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        let changedProof = event.authorized(with: try JSONSerialization.data(withJSONObject: object))
        for changed in [changedContent, changedProof] {
            #expect(changed.id == event.id)
            #expect(!f.policy.accepts(changed))
            #expect(!f.policy.accepts(changed)) // Failed verifications are never retained.
        }
        #expect(f.policy.verificationCacheState.verificationCount == 5)
        #expect(f.policy.accepts(event))
        #expect(f.policy.verificationCacheState.verificationCount == 5)
        #expect(f.policy.verificationCacheState.count == 1)
        #expect(!SecureRoomEventPolicy.hasValidSignature(changedContent))
        #expect(!SecureRoomEventPolicy.hasValidSignature(changedProof))
    }

    @Test func equivalentProofEncodingStillRequiresAnExactProofMatch() throws {
        let f = try EventProofLegacyFixture()
        let event = try f.event(counter: 1)
        let proof = try #require(event.authorization)
        let object = try JSONSerialization.jsonObject(with: proof)
        let reformatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        #expect(reformatted != proof)
        let equivalent = event.authorized(with: reformatted)
        #expect(f.policy.accepts(event))
        #expect(f.policy.accepts(equivalent))
        #expect(f.policy.verificationCacheState.verificationCount == 2)
        #expect(f.policy.accepts(equivalent))
        #expect(f.policy.verificationCacheState.verificationCount == 2)
        #expect(f.policy.verificationCacheState.count == 1)
    }

    @Test func canonicallyEquivalentTextStillRequiresTheExactSignedBytes() throws {
        let f = try EventProofLegacyFixture()
        let event = try f.event(counter: 1, text: "caf\u{00E9}")
        let changed = MeshRoomEvent(id: event.id, roomID: event.roomID, version: event.version,
            kind: event.kind, senderID: event.senderID, text: "cafe\u{0301}")
            .authorized(with: try #require(event.authorization))
        #expect(event == changed) // Swift strings compare canonical Unicode equivalence.
        #expect(try event.signingBytes() != changed.signingBytes())
        #expect(f.policy.accepts(event))
        #expect(!SecureRoomEventPolicy.hasValidSignature(changed))
        #expect(!f.policy.accepts(changed))
        #expect(f.policy.verificationCacheState.verificationCount == 2)
    }

    @Test func cachedCryptoCannotOutliveCurrentMembershipOrCreateHistoricalReceipts() throws {
        let f = try EventProofNetworkFixture()
        defer { f.cleanup() }
        let committed = try f.event(counter: 1)
        let merelyInspected = try f.event(counter: 2)
        #expect(f.receiver.accepts(committed))
        #expect(f.receiver.rememberAccepted([committed], retainingHistory: [committed]))
        #expect(f.receiver.accepts(merelyInspected))
        #expect(f.receiver.verificationCacheState.verificationCount == 2)
        try f.revokeRemote()
        #expect(f.receiver.allowsDurableStorage(merelyInspected))
        #expect(!f.receiver.accepts(merelyInspected))
        #expect(!f.receiver.rememberAccepted([merelyInspected]))
        #expect(f.receiver.accepts(committed))
        #expect(f.receiver.verificationCacheState.verificationCount == 2)
    }

    @Test func countBoundEvictsOldProofsAndRetainsRecentHits() throws {
        let f = try EventProofLegacyFixture()
        let first = try f.event(counter: 0)
        var last = first
        #expect(f.policy.accepts(first))
        for counter in 1...SecureRoomEventPolicy.maximumVerifiedEvents {
            last = try f.event(counter: UInt64(counter))
            #expect(f.policy.accepts(last))
        }
        let state = f.policy.verificationCacheState
        #expect(state.count == SecureRoomEventPolicy.maximumVerifiedEvents)
        #expect(state.encodedBytes <= SecureRoomEventPolicy.maximumVerifiedEventBytes)
        #expect(f.policy.accepts(last))
        #expect(f.policy.verificationCacheState.verificationCount == state.verificationCount)
        #expect(f.policy.accepts(first))
        #expect(f.policy.verificationCacheState.verificationCount == state.verificationCount + 1)
        #expect(f.policy.verificationCacheState.count == SecureRoomEventPolicy.maximumVerifiedEvents)
    }

    @Test func encodedByteBudgetEvictsBeforeTheEntryLimitAndSkipsOversizedEvents() throws {
        let f = try EventProofLegacyFixture()
        let text = String(repeating: "x", count: 90_000)
        let first = try f.event(counter: 0, text: text)
        #expect(f.policy.accepts(first))
        for counter in 1..<60 {
            #expect(f.policy.accepts(try f.event(counter: UInt64(counter), text: text)))
            #expect(f.policy.verificationCacheState.encodedBytes <= SecureRoomEventPolicy.maximumVerifiedEventBytes)
        }
        let state = f.policy.verificationCacheState
        #expect(state.count > 0 && state.count < 60)
        #expect(f.policy.accepts(first))
        #expect(f.policy.verificationCacheState.verificationCount == state.verificationCount + 1)

        let oversized = try f.event(counter: 61,
            text: String(repeating: "x", count: SecureRoomEventPolicy.maximumVerifiedEventBytes))
        let before = f.policy.verificationCacheState
        #expect(f.policy.accepts(oversized))
        #expect(f.policy.accepts(oversized))
        let after = f.policy.verificationCacheState
        #expect(after.count == before.count && after.encodedBytes == before.encodedBytes)
        #expect(after.verificationCount == before.verificationCount + 2)
    }

    @Test func concurrentVerificationRetainsOneBoundedSuccessfulEntry() throws {
        let f = try EventProofLegacyFixture()
        let event = try f.event(counter: 1)
        let resultLock = NSLock()
        var rejected = 0
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if !f.policy.accepts(event) { resultLock.withLock { rejected += 1 } }
        }
        #expect(rejected == 0)
        let state = f.policy.verificationCacheState
        #expect(state.count == 1)
        #expect(state.verificationCount >= 1 && state.verificationCount <= 32)
        #expect(f.policy.accepts(event))
        #expect(f.policy.verificationCacheState.verificationCount == state.verificationCount)
    }
}

private struct EventProofLegacyFixture {
    let identity: InstallationIdentity
    let policy: SecureRoomEventPolicy
    init() throws {
        identity = try InstallationIdentity.ephemeral()
        policy = SecureRoomEventPolicy(roomID: "proof-cache", identity: identity, capabilities: .desktop)
    }
    func event(counter: UInt64, text: String = "An exact signed event") throws -> MeshRoomEvent {
        let author = identity.publicIdentity.nodeID.uuidString
        return try #require(policy.sign(MeshRoomEvent(roomID: "proof-cache",
            version: .init(counter: counter, nodeID: author), kind: .chat, senderID: author, text: text)))
    }
}

private struct EventProofNetworkFixture {
    let directory: URL
    let repository: NetworkRepository
    let owner: UserIdentity
    let remote: UserIdentity
    let remoteInstallation: InstallationIdentity
    let center: NetworkPolicyCenter
    let roomID: UUID
    let receiver: SecureRoomEventPolicy
    let signer: SecureRoomEventPolicy
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-proof-cache-\(UUID().uuidString)")
        repository = NetworkRepository(directoryURL: directory)
        owner = UserIdentity.ephemeral(); remote = UserIdentity.ephemeral()
        let created = try repository.create(name: "Proof cache", owner: owner)
        let manifest = try repository.addMember(remote.publicIdentity, to: created.id, owner: owner)
        center = try NetworkPolicyCenter(repository: repository, networkID: manifest.id)
        roomID = manifest.mainChannel.id
        let localInstallation = try InstallationIdentity.ephemeral()
        remoteInstallation = try InstallationIdentity.ephemeral()
        let localDevice = try DeviceIdentityBinding(user: owner, deviceName: "Receiver", generation: 1,
            installationPublicKeyHash: localInstallation.publicIdentity.publicKeyHash)
        let remoteDevice = try DeviceIdentityBinding(user: remote, deviceName: "Author", generation: 1,
            installationPublicKeyHash: remoteInstallation.publicIdentity.publicKeyHash)
        receiver = SecureRoomEventPolicy(roomID: roomID.uuidString, identity: localInstallation, capabilities: .desktop,
            networkAuthorization: try NetworkChannelAuthorization(policy: center, channelID: roomID, localDevice: localDevice))
        signer = SecureRoomEventPolicy(roomID: roomID.uuidString, identity: remoteInstallation, capabilities: .desktop,
            networkAuthorization: try NetworkChannelAuthorization(policy: center, channelID: roomID, localDevice: remoteDevice))
    }
    func event(counter: UInt64) throws -> MeshRoomEvent {
        let author = remoteInstallation.publicIdentity.nodeID.uuidString
        return try #require(signer.sign(MeshRoomEvent(roomID: roomID.uuidString,
            version: .init(counter: counter, nodeID: author), kind: .chat, senderID: author, text: "Signed by another user")))
    }
    func revokeRemote() throws {
        let id = try center.snapshot().id
        try center.receive(repository.removeMember(userID: remote.publicIdentity.userID, from: id, owner: owner))
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
