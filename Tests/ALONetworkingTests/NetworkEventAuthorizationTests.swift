import Foundation
import Security
import Testing
import ALOCore
import ALOIdentity
import ALORooms
@testable import ALONetworking

@Suite("Network authorization for relayed signed events")
struct NetworkEventAuthorizationTests {
    @Test func liveMobileGrantCannotPublishDesktopOnlyEvents() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let mobile = try ProtocolOffer.current(capabilities: .mobile)
        let desktop = try ProtocolOffer.current(capabilities: .desktop)
        let peer = AuthenticatedPeer(nodeID: fixture.remoteInstallation.publicIdentity.nodeID,
            publicKeyHash: fixture.remoteInstallation.publicIdentity.publicKeyHash, incarnationID: UUID(), connectionID: UUID(),
            negotiated: try NegotiatedProtocol.negotiate(initiator: mobile, responder: desktop, policy: .secureV2),
            channelRole: .roomControl, userIdentity: fixture.remoteUser.publicIdentity)
        #expect(fixture.receiver.admit(peer, initiated: false))
        let author = peer.nodeID.uuidString
        let roomID = fixture.authorization.channelID.uuidString
        let queue = try #require(fixture.remoteSigner.sign(MeshRoomEvent(roomID: roomID,
            version: MeshVersion(counter: 1, nodeID: author), kind: .queueAdd,
            queueItem: RoomQueueItem(id: "track", title: "Forbidden queue edit", url: "alo-file://track"))))
        let broadcaster = try #require(fixture.remoteSigner.sign(MeshRoomEvent(roomID: roomID,
            version: MeshVersion(counter: 2, nodeID: author), kind: .broadcaster, broadcasterID: author)))
        #expect(fixture.receiver.allowsDurableStorage(queue))
        #expect(!fixture.receiver.accepts(queue))
        #expect(!fixture.receiver.accepts(broadcaster))
        #expect(!fixture.receiver.rememberAccepted([queue]))
        #expect(fixture.receiver.accepts(try fixture.remoteEvent(counter: 3, text: "Mobile chat is allowed")))
        let fresh = SecureRoomEventPolicy(roomID: roomID, identity: fixture.localInstallation,
            capabilities: .desktop, networkAuthorization: fixture.authorization)
        #expect(fresh.accepts(queue)) // Offline durable history has no live negotiated grant.
        #expect(!fresh.accepts(broadcaster)) // Transient authority always needs live admission.
    }

    @Test func fullSignedHistorySurvivesOfflineAuthorRevocationLateJoinAndContinuedEdits() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let roomID = fixture.authorization.channelID.uuidString
        var history = [MeshRoomEvent]()
        for counter in 1...AutomergeRoomStateSync.maximumChatEvents {
            let text = "Offline listening session message \(counter): chat and queue state must survive reconnects."
            history.append(try counter.isMultiple(of: 2)
                ? fixture.localEvent(counter: UInt64(counter), text: text)
                : fixture.remoteEvent(counter: UInt64(counter), text: text))
        }
        let ownerID = fixture.localInstallation.publicIdentity.nodeID.uuidString
        let offlineAuthorID = fixture.remoteInstallation.publicIdentity.nodeID.uuidString
        let ownerTrack = RoomQueueItem(id: "owner-track", title: "Shared local track", url: "alo-file://owner-track")
        let offlineTrack = RoomQueueItem(id: "offline-track", title: "Offline author's track", url: "alo-file://offline-track")
        history.append(try #require(fixture.receiver.sign(MeshRoomEvent(roomID: roomID,
            version: MeshVersion(counter: 501, nodeID: ownerID), kind: .queueAdd, queueItem: ownerTrack))))
        history.append(try #require(fixture.remoteSigner.sign(MeshRoomEvent(roomID: roomID,
            version: MeshVersion(counter: 502, nodeID: offlineAuthorID), kind: .queueAdd, queueItem: offlineTrack))))
        let existing = try AutomergeRoomStateSync(roomID: roomID,
            eventValidator: { fixture.receiver.allowsDurableStorage($0) },
            eventProjector: { fixture.receiver.accepts($0) })
        let initialCommit = try existing.ingest(history)
        #expect(fixture.receiver.rememberAccepted(initialCommit, retainingHistory: try existing.snapshot().retainedEvents))
        let established = try existing.snapshot()
        #expect(established.chatEvents.count == 500)
        #expect(Set(established.queue.map(\.id)) == Set([ownerTrack.id, offlineTrack.id]))

        // Only stored, portable proofs are relayed. The original author never
        // connects to the third installation, and now has a stale policy copy.
        try fixture.revokeRemote()
        #expect(try existing.snapshot() == established)
        let lateInstallation = try InstallationIdentity.ephemeral()
        let lateBinding = try DeviceIdentityBinding(user: fixture.owner, deviceName: "Late joining owner device", generation: 1,
            installationPublicKeyHash: lateInstallation.publicIdentity.publicKeyHash)
        let lateAuthorization = try NetworkChannelAuthorization(policy: fixture.center, channelID: fixture.authorization.channelID,
            localDevice: lateBinding)
        let latePolicy = SecureRoomEventPolicy(roomID: roomID, identity: lateInstallation, capabilities: .desktop,
            networkAuthorization: lateAuthorization)
        let late = try AutomergeRoomStateSync(roomID: roomID,
            eventValidator: { latePolicy.allowsDurableStorage($0) }, eventProjector: { latePolicy.accepts($0) })
        #expect(!latePolicy.permits(author: ownerID, capability: .chat))
        #expect(!latePolicy.permits(author: offlineAuthorID, capability: .chat))
        try converge(existing, late, policy: latePolicy, sourcePolicy: fixture.receiver)
        let initialLate = try late.snapshot()
        #expect(initialLate.retainedEvents.count == 502)
        #expect(initialLate.chatEvents.count == 250)
        #expect(initialLate.chatEvents.allSatisfy { $0.version.nodeID == ownerID })
        #expect(initialLate.queue == [ownerTrack])
        #expect(try existing.snapshot() == established)

        let revokedChat = try fixture.remoteEvent(counter: 1_000_000, text: "Revoked author cannot advance live state")
        let revokedRemove = try #require(fixture.remoteSigner.sign(MeshRoomEvent(roomID: roomID,
            version: MeshVersion(counter: 1_000_001, nodeID: offlineAuthorID), kind: .queueRemove, queueItemID: ownerTrack.id)))
        let inertCommit = try existing.ingest([revokedChat, revokedRemove])
        #expect(fixture.receiver.rememberAccepted(inertCommit.filter { fixture.receiver.accepts($0) },
                                                retainingHistory: try existing.snapshot().retainedEvents))
        try converge(existing, late, policy: latePolicy, sourcePolicy: fixture.receiver)
        let afterInert = try late.snapshot()
        #expect(afterInert.events == initialLate.events)
        #expect(afterInert.queue == [ownerTrack])
        #expect(MeshRoomReplica(events: afterInert.events).logicalClock == 501)
        #expect(!latePolicy.accepts(revokedChat))
        #expect(!latePolicy.accepts(revokedRemove))

        let lateID = lateInstallation.publicIdentity.nodeID.uuidString
        let lateChat = try #require(latePolicy.sign(MeshRoomEvent(roomID: roomID,
            version: MeshVersion(counter: 503, nodeID: lateID), kind: .chat, senderID: lateID, text: "Third device still edits")))
        let lateCommit = try late.ingest([lateChat])
        #expect(latePolicy.rememberAccepted(lateCommit, retainingHistory: try late.snapshot().retainedEvents))
        do { try converge(late, existing, policy: fixture.receiver, sourcePolicy: latePolicy) }
        catch {
            Issue.record("First continued edit failed after the mixed-author retention boundary: \(error)")
            return
        }
        let ownerChat = try fixture.localEvent(counter: 504, text: "Established actor continues after retention boundary")
        let ownerCommit = try existing.ingest([ownerChat])
        #expect(fixture.receiver.rememberAccepted(ownerCommit, retainingHistory: try existing.snapshot().retainedEvents))
        do { try converge(existing, late, policy: latePolicy, sourcePolicy: fixture.receiver) }
        catch {
            Issue.record("Second continued edit failed after the mixed-author retention boundary: \(error)")
            return
        }

        let finalExisting = try existing.snapshot()
        let finalLate = try late.snapshot()
        #expect(finalExisting.chatEvents.count == 500)
        #expect(finalLate.chatEvents.count == 252)
        #expect(finalExisting.events.contains(lateChat) && finalExisting.events.contains(ownerChat))
        #expect(finalLate.events.contains(lateChat) && finalLate.events.contains(ownerChat))
        #expect(Set(initialLate.chatEvents.map(\.id)).isSubset(of: Set(finalLate.chatEvents.map(\.id))))
        #expect(Set(finalExisting.queue.map(\.id)) == Set([ownerTrack.id, offlineTrack.id]))
        #expect(finalLate.queue == [ownerTrack])
        #expect(finalLate.chatEvents.allSatisfy { $0.version.nodeID != offlineAuthorID })
        #expect(MeshRoomReplica(events: finalLate.events).logicalClock == 504)
        #expect(existing.save().count < AutomergeRoomStateSync.maximumDocumentBytes)
        #expect(late.save().count < AutomergeRoomStateSync.maximumDocumentBytes)
    }

    @Test func freshDeviceVerifiesOfflineCurrentAuthorWithoutPriorTLSGrant() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let freshReceiver = SecureRoomEventPolicy(roomID: fixture.authorization.channelID.uuidString,
            identity: fixture.localInstallation, capabilities: .desktop, networkAuthorization: fixture.authorization)
        let historical = try fixture.remoteEvent(counter: 1, text: "Author is offline but remains a member")
        #expect(!freshReceiver.permits(author: historical.version.nodeID, capability: .chat))
        #expect(freshReceiver.allowsDurableStorage(historical))
        #expect(freshReceiver.accepts(historical))
        let source = try AutomergeRoomStateSync(roomID: historical.roomID)
        let receiver = try AutomergeRoomStateSync(roomID: historical.roomID,
            eventValidator: { freshReceiver.allowsDurableStorage($0) }, eventProjector: { freshReceiver.accepts($0) })
        try source.ingest([historical])
        try converge(source, receiver, policy: freshReceiver)
        #expect(try receiver.snapshot().events == [historical])
    }

    @Test func relayedNewEventFromPreviouslyAdmittedRevokedUserIsDenied() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let first = try fixture.remoteEvent(counter: 1, text: "Before removal")
        #expect(fixture.receiver.accepts(first))
        try fixture.revokeRemote()
        let newlySigned = try fixture.remoteEvent(counter: 2, text: "Signed after removal; relayed by an allowed peer")
        #expect(SecureRoomEventPolicy.hasValidSignature(newlySigned))
        #expect(!fixture.receiver.accepts(newlySigned))
        #expect(!fixture.receiver.permits(author: fixture.remoteInstallation.publicIdentity.nodeID.uuidString, capability: .chat))
        #expect(!fixture.receiver.accepts(first)) // Predicate evaluation alone is not a committed-history receipt.
    }

    @Test func unseenRevokedHistoryAndPostRevocationEventsRemainInertAcrossSyncAndArchive() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let history = try fixture.remoteEvent(counter: 1, text: "Unseen authentic old history")
        try fixture.revokeRemote()
        let novel = try fixture.remoteEvent(counter: 2, text: "Signed by the offline device after removal")
        let roomID = fixture.authorization.channelID.uuidString
        let fresh = SecureRoomEventPolicy(roomID: roomID, identity: fixture.localInstallation,
            capabilities: .desktop, networkAuthorization: fixture.authorization)
        let source = try AutomergeRoomStateSync(roomID: roomID)
        let receiver = try AutomergeRoomStateSync(roomID: roomID,
            eventValidator: { fresh.allowsDurableStorage($0) }, eventProjector: { fresh.accepts($0) })
        try source.ingest([history, novel])
        try converge(source, receiver, policy: fresh)
        #expect(try receiver.snapshot().events.isEmpty)
        #expect(Set(try receiver.snapshot().retainedEvents.map(\.id)) == Set([history.id, novel.id]))
        #expect(!fresh.rememberAccepted([history, novel])) // A raw committed document is not authorization.

        let current = try fixture.localEvent(counter: 3, text: "Current author still synchronizes")
        try source.ingest([current])
        try converge(source, receiver, policy: fresh)
        #expect(try receiver.snapshot().events == [current])
        #expect(!fresh.accepts(history))
        #expect(!fresh.accepts(novel))

        let archive = try fresh.archive(document: receiver.save(), retainedEvents: receiver.snapshot().retainedEvents)
        let restored = SecureRoomEventPolicy(roomID: roomID, identity: fixture.localInstallation,
            capabilities: .desktop, networkAuthorization: fixture.authorization)
        let document = try #require(restored.restoreArchive(archive))
        let loaded = try AutomergeRoomStateSync(roomID: roomID, savedDocument: document,
            eventValidator: { restored.allowsDurableStorage($0) }, eventProjector: { restored.accepts($0) })
        #expect(try loaded.snapshot().events == [current])
        #expect(!restored.accepts(history))
        #expect(!restored.accepts(novel))
    }

    @Test func legacyForgedBindingAndWrongAuthorityCannotEnterNewGenerationDocument() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let original = try fixture.remoteEvent(counter: 1, text: "Bound provenance")
        let proof = try JSONDecoder().decode(EventProofFixture.self, from: #require(original.authorization))
        let legacy = SecureRoomEventPolicy(roomID: original.roomID, identity: fixture.remoteInstallation, capabilities: .desktop)
        let legacyEvent = try #require(legacy.sign(original))
        #expect(SecureRoomEventPolicy.hasValidSignature(legacyEvent))
        #expect(!fixture.receiver.allowsDurableStorage(legacyEvent))

        var wrongBinding = proof
        wrongBinding.context.device = fixture.authorization.localDevice
        let transplanted = try wrongBinding.resign(original, with: fixture.remoteInstallation)
        #expect(!SecureRoomEventPolicy.hasValidSignature(transplanted))
        #expect(!fixture.receiver.allowsDurableStorage(transplanted))
        var wrongChannel = proof
        wrongChannel.context.authority.channelID = UUID()
        let crossChannel = try wrongChannel.resign(original, with: fixture.remoteInstallation)
        #expect(!SecureRoomEventPolicy.hasValidSignature(crossChannel))
        #expect(!fixture.receiver.allowsDurableStorage(crossChannel))

        var wrongGeneration = proof
        wrongGeneration.context.authority.generation = UUID()
        var wrongNetwork = proof
        wrongNetwork.context.authority.networkID = UUID()
        var wrongOwner = proof
        wrongOwner.context.authority.owner = UserIdentity.ephemeral().publicIdentity
        for otherContext in [wrongGeneration, wrongNetwork, wrongOwner] {
            let other = try otherContext.resign(original, with: fixture.remoteInstallation)
            #expect(SecureRoomEventPolicy.hasValidSignature(other))
            #expect(!fixture.receiver.accepts(other))
            #expect(!fixture.receiver.allowsDurableStorage(other))
            let source = try AutomergeRoomStateSync(roomID: original.roomID)
            let receiver = try AutomergeRoomStateSync(roomID: original.roomID,
                eventValidator: { fixture.receiver.allowsDurableStorage($0) },
                eventProjector: { fixture.receiver.accepts($0) })
            let good = try fixture.localEvent(counter: 2, text: "Must not partially commit")
            try source.ingest([good, other])
            #expect(throws: RoomStateSyncError.invalidDocument) { try converge(source, receiver, policy: fixture.receiver) }
            #expect(try receiver.snapshot().retainedEvents.isEmpty)
        }
        // Changing a signed context without a new installation signature is also rejected.
        let tampered = original.authorized(with: try JSONEncoder().encode(wrongNetwork))
        #expect(!SecureRoomEventPolicy.hasValidSignature(tampered))
        #expect(!fixture.receiver.allowsDurableStorage(tampered))
    }

    @Test func retiredDurableReceiptsArePrunedWithoutDroppingPendingReplicaReceipts() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let retired = try fixture.remoteEvent(counter: 1, text: "Retired durable snapshot")
        let pending = try fixture.remoteEvent(counter: 2, text: "Replica accepted, worker ingestion pending")
        #expect(fixture.receiver.rememberAccepted([retired], retainingHistory: [retired]))
        #expect(fixture.receiver.rememberAccepted([pending]))
        #expect(fixture.receiver.rememberAccepted([], retainingHistory: []))
        try fixture.revokeRemote()
        #expect(!fixture.receiver.accepts(retired))
        #expect(fixture.receiver.accepts(pending))
        #expect(fixture.receiver.rememberAccepted([pending], retainingHistory: [pending]))
        #expect(fixture.receiver.rememberAccepted([], retainingHistory: []))
        #expect(!fixture.receiver.accepts(pending))
    }

    @Test func transientEventsNeverAcquireDurableHistoryReceipts() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let author = fixture.remoteInstallation.publicIdentity.nodeID.uuidString
        let transient = try #require(fixture.remoteSigner.sign(MeshRoomEvent(roomID: fixture.authorization.channelID.uuidString,
            version: MeshVersion(counter: 1, nodeID: author), kind: .broadcaster, broadcasterID: author)))
        #expect(fixture.receiver.accepts(transient))
        #expect(!fixture.receiver.allowsDurableStorage(transient))
        #expect(fixture.receiver.rememberAccepted([transient]))
        try fixture.revokeRemote()
        #expect(!fixture.receiver.accepts(transient))
    }

    @Test func committedHistoricalEventsDoNotPoisonFutureAutomergeSyncAfterRevocation() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let roomID = fixture.authorization.channelID.uuidString
        let source = try AutomergeRoomStateSync(roomID: roomID)
        let receiver = try AutomergeRoomStateSync(roomID: roomID,
            eventValidator: { fixture.receiver.allowsDurableStorage($0) }, eventProjector: { fixture.receiver.accepts($0) })
        let history = try fixture.remoteEvent(counter: 1, text: "Accepted while member")
        try source.ingest([history])
        try converge(source, receiver, policy: fixture.receiver)
        #expect(try receiver.snapshot().events == [history])
        try fixture.revokeRemote()
        #expect(fixture.receiver.accepts(history))

        let ownerEvent = try fixture.localEvent(counter: 2, text: "Owner still has access")
        try source.ingest([ownerEvent])
        try converge(source, receiver, policy: fixture.receiver)
        #expect(Set(try receiver.snapshot().events.map(\.id)) == Set([history.id, ownerEvent.id]))

        let revokedEvent = try fixture.remoteEvent(counter: 3, text: "New relayed event after removal")
        try source.ingest([revokedEvent])
        try converge(source, receiver, policy: fixture.receiver)
        #expect(Set(try receiver.snapshot().events.map(\.id)) == Set([history.id, ownerEvent.id]))
        #expect(Set(try receiver.snapshot().retainedEvents.map(\.id)) == Set([history.id, ownerEvent.id, revokedEvent.id]))
        #expect(!fixture.receiver.accepts(revokedEvent))
    }

    @Test func failedSyncCandidateCannotPartiallyCreateAcceptedHistory() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let roomID = fixture.authorization.channelID.uuidString
        let source = try AutomergeRoomStateSync(roomID: roomID)
        let receiver = try AutomergeRoomStateSync(roomID: roomID,
            eventValidator: { fixture.receiver.allowsDurableStorage($0) }, eventProjector: { fixture.receiver.accepts($0) })
        let candidate = try fixture.remoteEvent(counter: 1, text: "Valid, but transaction never commits")
        let unknownInstallation = try InstallationIdentity.ephemeral()
        let unknownPolicy = SecureRoomEventPolicy(roomID: roomID, identity: unknownInstallation, capabilities: .desktop)
        let unknown = try #require(unknownPolicy.sign(MeshRoomEvent(roomID: roomID,
            version: MeshVersion(counter: 2, nodeID: unknownInstallation.publicIdentity.nodeID.uuidString),
            kind: .chat, text: "Unknown author rejects entire candidate")))
        try source.ingest([candidate, unknown])
        #expect(throws: RoomStateSyncError.invalidDocument) { try converge(source, receiver, policy: fixture.receiver) }
        #expect(try receiver.snapshot().events.isEmpty)
        try fixture.revokeRemote()
        #expect(!fixture.receiver.accepts(candidate))

        let cleanSource = try AutomergeRoomStateSync(roomID: roomID)
        let good = try fixture.localEvent(counter: 3, text: "Clean subsequent sync")
        try cleanSource.ingest([good])
        try converge(cleanSource, receiver, policy: fixture.receiver)
        #expect(try receiver.snapshot().events == [good])
    }

    @Test func historicalReceiptCoversExactSignedBytesAndSurvivesAuthenticatedArchive() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let roomID = fixture.authorization.channelID.uuidString
        let durable = try AutomergeRoomStateSync(roomID: roomID,
            eventValidator: { fixture.receiver.allowsDurableStorage($0) }, eventProjector: { fixture.receiver.accepts($0) })
        let history = try fixture.remoteEvent(counter: 1, text: "Committed history")
        let inserted = try durable.ingest([history])
        #expect(fixture.receiver.rememberAccepted(inserted, retainingHistory: try durable.snapshot().retainedEvents))
        try fixture.revokeRemote()
        #expect(fixture.receiver.accepts(history))
        let altered = try #require(fixture.remoteSigner.sign(MeshRoomEvent(id: history.id, roomID: history.roomID,
            version: history.version, kind: .chat, senderID: history.senderID, text: "Same ID, changed signed body")))
        #expect(SecureRoomEventPolicy.hasValidSignature(altered))
        #expect(!fixture.receiver.accepts(altered))
        let archived = try fixture.receiver.archive(document: durable.save(), retainedEvents: durable.snapshot().retainedEvents)
        let restored = SecureRoomEventPolicy(roomID: roomID, identity: fixture.localInstallation,
            capabilities: .desktop, networkAuthorization: fixture.authorization)
        let restoredData = try #require(restored.restoreArchive(archived))
        #expect(restored.accepts(history))
        #expect(!restored.accepts(altered))
        let loaded = try AutomergeRoomStateSync(roomID: roomID, savedDocument: restoredData,
            eventValidator: { restored.allowsDurableStorage($0) }, eventProjector: { restored.accepts($0) })
        #expect(try loaded.snapshot().events == [history])
        #expect(!restored.permits(author: history.version.nodeID, capability: .chat))
    }

    @Test func missingUserMappingAndInstallationUserRebindingAreDenied() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let offer = try ProtocolOffer.current(capabilities: .desktop)
        let negotiated = try NegotiatedProtocol.negotiate(initiator: offer, responder: offer, policy: .secureV2)
        let unknown = try InstallationIdentity.ephemeral()
        let noUser = AuthenticatedPeer(nodeID: unknown.publicIdentity.nodeID, publicKeyHash: unknown.publicIdentity.publicKeyHash,
            incarnationID: UUID(), connectionID: UUID(), negotiated: negotiated, channelRole: .roomControl)
        #expect(!fixture.receiver.admit(noUser, initiated: false))
        let changedUser = AuthenticatedPeer(nodeID: fixture.remoteInstallation.publicIdentity.nodeID,
            publicKeyHash: fixture.remoteInstallation.publicIdentity.publicKeyHash, incarnationID: UUID(), connectionID: UUID(),
            negotiated: negotiated, channelRole: .roomControl, userIdentity: fixture.owner.publicIdentity)
        #expect(!fixture.receiver.admit(changedUser, initiated: false))
        let legacyPolicy = SecureRoomEventPolicy(roomID: fixture.authorization.channelID.uuidString,
            identity: fixture.localInstallation, capabilities: .desktop)
        let legacyArchive = try legacyPolicy.archive(document: Data())
        let newGenerationReceiver = SecureRoomEventPolicy(roomID: fixture.authorization.channelID.uuidString,
            identity: fixture.localInstallation, capabilities: .desktop, networkAuthorization: fixture.authorization)
        #expect(newGenerationReceiver.restoreArchive(legacyArchive) == nil)
    }

    @Test func invalidOrOversizedReceiptBatchCannotPartiallyAuthorizeHistory() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let candidate = try fixture.remoteEvent(counter: 1, text: "Must never become history")
        let forged = MeshRoomEvent(roomID: candidate.roomID, version: candidate.version,
            kind: .chat, text: "Tampered body").authorized(with: candidate.authorization!)
        #expect(!fixture.receiver.rememberAccepted([candidate, forged]))
        #expect(!fixture.receiver.rememberAccepted(Array(repeating: candidate,
                                                        count: SecureRoomEventPolicy.maximumAcceptedHistory + 1)))
        try fixture.revokeRemote()
        #expect(!fixture.receiver.accepts(candidate))
    }

    @Test func removingPrivateChannelAllowlistDeniesNovelEventsWithoutRemovingMembership() throws {
        let fixture = try NetworkEventFixture(privateChannel: true)
        defer { fixture.cleanup() }
        let before = try fixture.remoteEvent(counter: 1, text: "Private channel member")
        #expect(fixture.receiver.accepts(before))
        let originalChannel = try #require(fixture.manifest.channels.first(where: { $0.id == fixture.authorization.channelID }))
        let ownerOnly = try ALORooms.NetworkChannel(id: originalChannel.id, name: originalChannel.name, visibility: .privateMembers)
        let updated = try fixture.repository.updateChannel(ownerOnly, in: fixture.manifest.id, owner: fixture.owner)
        try fixture.center.receive(updated)
        #expect(updated.isMember(fixture.remoteUser.publicIdentity))
        let denied = try fixture.remoteEvent(counter: 2, text: "No longer allowlisted")
        #expect(!fixture.receiver.accepts(denied))
        #expect(!fixture.receiver.permits(author: fixture.remoteInstallation.publicIdentity.nodeID.uuidString, capability: .voice))
    }

    @Test func localRevocationDeniesSigningAndReadingEvenPreviouslyAcceptedHistory() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let binding = try DeviceIdentityBinding(user: fixture.remoteUser, deviceName: "Locally revoked device", generation: 1,
            installationPublicKeyHash: fixture.remoteInstallation.publicIdentity.publicKeyHash)
        let context = try NetworkChannelAuthorization(policy: fixture.center, channelID: fixture.authorization.channelID, localDevice: binding)
        let localPolicy = SecureRoomEventPolicy(roomID: fixture.authorization.channelID.uuidString,
            identity: fixture.remoteInstallation, capabilities: .desktop, networkAuthorization: context)
        let event = try fixture.remoteEvent(counter: 1, text: "Previously committed locally")
        #expect(localPolicy.accepts(event))
        #expect(localPolicy.rememberAccepted([event]))
        try fixture.revokeRemote()
        #expect(!localPolicy.accepts(event))
        #expect(!localPolicy.allowsDurableStorage(event))
        #expect(localPolicy.sign(event) == nil)
        #expect(!localPolicy.permits(author: event.version.nodeID, capability: .chat))
    }

    @Test func signedArchiveCannotBeReplayedAcrossNetworksSharingAChannelIdentifier() throws {
        let fixture = try NetworkEventFixture()
        defer { fixture.cleanup() }
        let history = try fixture.remoteEvent(counter: 1, text: "First network history")
        #expect(fixture.receiver.accepts(history))
        #expect(fixture.receiver.rememberAccepted([history]))
        let archived = try fixture.receiver.archive(document: Data("first network only".utf8), retainedEvents: [history])
        let other = try fixture.repository.create(name: "Different network", owner: fixture.owner)
        let sameChannelID = try ALORooms.NetworkChannel(id: fixture.authorization.channelID, name: "Same UUID in different network")
        let otherWithChannel = try other.addingChannel(sameChannelID, signedBy: fixture.owner)
        try fixture.repository.accept(otherWithChannel, for: fixture.owner.publicIdentity)
        let otherCenter = try NetworkPolicyCenter(repository: fixture.repository, networkID: other.id)
        let otherContext = try NetworkChannelAuthorization(policy: otherCenter,
            channelID: sameChannelID.id, localDevice: fixture.authorization.localDevice)
        let otherPolicy = SecureRoomEventPolicy(roomID: sameChannelID.id.uuidString,
            identity: fixture.localInstallation, capabilities: .desktop, networkAuthorization: otherContext)
        #expect(otherPolicy.restoreArchive(archived) == nil)
    }

    private func converge(_ source: AutomergeRoomStateSync, _ receiver: AutomergeRoomStateSync,
                          policy: SecureRoomEventPolicy, sourcePolicy: SecureRoomEventPolicy? = nil) throws {
        let sourceSession = source.makeSession()
        let receiverSession = receiver.makeSession()
        for _ in 0..<100 {
            var progressed = false
            if let message = source.generateSyncMessage(for: sourceSession) {
                let committed = try receiver.receiveSyncMessage(message, from: receiverSession)
                #expect(policy.rememberAccepted(committed.filter { policy.accepts($0) },
                                                retainingHistory: try receiver.snapshot().retainedEvents))
                progressed = true
            }
            if let message = receiver.generateSyncMessage(for: receiverSession) {
                let committed = try source.receiveSyncMessage(message, from: sourceSession)
                if let sourcePolicy {
                    #expect(sourcePolicy.rememberAccepted(committed.filter { sourcePolicy.accepts($0) },
                                                          retainingHistory: try source.snapshot().retainedEvents))
                }
                progressed = true
            }
            if !progressed { return }
        }
        Issue.record("Event policy Automerge sync did not converge in 100 rounds")
    }
}

/// Independent test-side wire shape permits authentic installation signatures
/// over deliberately invalid root/context claims; no production signing bypass.
private struct EventProofFixture: Codable {
    struct Authority: Codable {
        var networkID: UUID
        var generation: UUID
        var owner: PublicUserIdentity
        var channelID: UUID
    }
    struct Context: Codable {
        var version: UInt8
        var authority: Authority
        var device: DeviceIdentityBinding
    }
    var certificate: Data
    var signature: Data
    var context: Context

    func resign(_ event: MeshRoomEvent, with identity: InstallationIdentity) throws -> MeshRoomEvent {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = WireBytes()
        bytes.append(Data("alo.network.signed-event.v1\0".utf8))
        bytes.field(try encoder.encode(context))
        bytes.field(try event.signingBytes())
        var signed = self
        signed.certificate = SecCertificateCopyData(identity.certificate) as Data
        signed.signature = try identity.signRoomEvent(bytes.data)
        return event.authorized(with: try encoder.encode(signed))
    }
}

private final class NetworkEventFixture {
    let directory: URL
    let owner = UserIdentity.ephemeral()
    let remoteUser = UserIdentity.ephemeral()
    let localInstallation: InstallationIdentity
    let remoteInstallation: InstallationIdentity
    let repository: NetworkRepository
    let manifest: NetworkManifest
    let center: NetworkPolicyCenter
    let authorization: NetworkChannelAuthorization
    let remoteAuthorization: NetworkChannelAuthorization
    let receiver: SecureRoomEventPolicy
    let remoteSigner: SecureRoomEventPolicy

    init(privateChannel: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-network-events-test-\(UUID().uuidString)")
        localInstallation = try InstallationIdentity.ephemeral()
        remoteInstallation = try InstallationIdentity.ephemeral()
        repository = NetworkRepository(directoryURL: directory)
        let created = try repository.create(name: "Relayed event policy", owner: owner)
        var initialPolicy = try repository.addMember(remoteUser.publicIdentity, to: created.id, owner: owner)
        if privateChannel {
            initialPolicy = try repository.createChannel(name: "Private", in: created.id, owner: owner,
                visibility: .privateMembers, allowedUserIDs: [remoteUser.publicIdentity.userID])
        }
        manifest = initialPolicy
        center = try NetworkPolicyCenter(repository: repository, networkID: manifest.id)
        let device = try DeviceIdentityBinding(user: owner, deviceName: "Receiving test device", generation: 1,
            installationPublicKeyHash: localInstallation.publicIdentity.publicKeyHash)
        let channelID = privateChannel ? manifest.channels.first(where: { $0.isPrivate })!.id : manifest.mainChannel.id
        authorization = try NetworkChannelAuthorization(policy: center, channelID: channelID, localDevice: device)
        receiver = SecureRoomEventPolicy(roomID: channelID.uuidString,
            identity: localInstallation, capabilities: .desktop, networkAuthorization: authorization)
        let remoteRepository = NetworkRepository(directoryURL: directory.appendingPathComponent("offline-author"))
        try remoteRepository.accept(manifest, for: remoteUser.publicIdentity)
        let remoteCenter = try NetworkPolicyCenter(repository: remoteRepository, networkID: manifest.id)
        let remoteDevice = try DeviceIdentityBinding(user: remoteUser, deviceName: "Offline author device", generation: 1,
            installationPublicKeyHash: remoteInstallation.publicIdentity.publicKeyHash)
        remoteAuthorization = try NetworkChannelAuthorization(policy: remoteCenter, channelID: channelID, localDevice: remoteDevice)
        remoteSigner = SecureRoomEventPolicy(roomID: channelID.uuidString,
            identity: remoteInstallation, capabilities: .desktop, networkAuthorization: remoteAuthorization)
        let offer = try ProtocolOffer.current(capabilities: .desktop)
        let negotiated = try NegotiatedProtocol.negotiate(initiator: offer, responder: offer, policy: .secureV2)
        let peer = AuthenticatedPeer(nodeID: remoteInstallation.publicIdentity.nodeID,
            publicKeyHash: remoteInstallation.publicIdentity.publicKeyHash, incarnationID: UUID(), connectionID: UUID(),
            negotiated: negotiated, channelRole: .roomControl, userIdentity: remoteUser.publicIdentity)
        #expect(receiver.admit(peer, initiated: false))
    }

    func remoteEvent(counter: UInt64, text: String) throws -> MeshRoomEvent {
        let author = remoteInstallation.publicIdentity.nodeID.uuidString
        return try #require(remoteSigner.sign(MeshRoomEvent(roomID: authorization.channelID.uuidString,
            version: MeshVersion(counter: counter, nodeID: author), kind: .chat, senderID: author, text: text)))
    }

    func localEvent(counter: UInt64, text: String) throws -> MeshRoomEvent {
        let author = localInstallation.publicIdentity.nodeID.uuidString
        return try #require(receiver.sign(MeshRoomEvent(roomID: authorization.channelID.uuidString,
            version: MeshVersion(counter: counter, nodeID: author), kind: .chat, senderID: author, text: text)))
    }

    func revokeRemote() throws {
        let revoked = try repository.removeMember(userID: remoteUser.publicIdentity.userID, from: manifest.id, owner: owner)
        try center.receive(revoked)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
