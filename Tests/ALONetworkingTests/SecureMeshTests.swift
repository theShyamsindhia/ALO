import Foundation
import CryptoKit
import Network
import Testing
import ALOCore
@testable import ALONetworking

@Suite("Actual secure mesh runtime", .serialized)
struct SecureMeshTests {
    @Test func mixedSignedHistoryVerifiesDurableProofsOnlyAfterTheWorkerRuns() async throws {
        let room = RoomConfiguration.secure(name: "Durable proof queue boundary")
        let blocked = try RejectOnceRoomStateSync(roomID: room.id, blockFirstChat: true)
        let receiver = try SecureMeshNode(room: room, identity: .ephemeral(), disableStateSync: true,
            roomStateSyncOverride: blocked)
        let sender = try SecureMeshNode(room: room, identity: .ephemeral(), disableStateSync: true)
        defer { blocked.release(); receiver.stop(); sender.stop() }
        let signer = SecureRoomEventPolicy(roomID: room.id, identity: sender.identity, capabilities: .desktop,
            networkAuthorization: try sender.networkFixture.authorization(for: sender.identity))
        let durable = try #require(signer.sign(MeshRoomEvent(id: "deferred-valid", roomID: room.id,
            version: .init(counter: 10, nodeID: sender.id), kind: .chat, text: "Valid mixed history")))
        let original = try #require(signer.sign(MeshRoomEvent(id: "deferred-invalid", roomID: room.id,
            version: .init(counter: 11, nodeID: sender.id), kind: .chat, text: "Original bytes")))
        let invalid = MeshRoomEvent(id: original.id, roomID: room.id, version: original.version,
            kind: .chat, text: "Tampered bytes").authorized(with: try #require(original.authorization))
        let live = try #require(signer.sign(MeshRoomEvent(id: "immediate-live", roomID: room.id,
            version: .init(counter: 12, nodeID: sender.id), kind: .broadcaster,
            broadcasterID: sender.id, broadcasterEpoch: 1, mediaServiceName: "Live state", isBroadcasting: true)))
        try receiver.start(); try sender.start()
        let port = try await receiver.readyPort()
        sender.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: receiver.id)
        try await meshEventually {
            receiver.state.read { $0.participants.count == 2 } && sender.state.read { $0.participants.count == 2 }
        }
        receiver.control.publishChat("Hold the durable worker")
        try await meshEventually { blocked.isBlocked }
        let repeated = Array(repeating: MeshEnvelope(type: "event", event: durable), count: 32)
        sender.control.sendRoomStateSyncEnvelopesForTesting(
            [MeshEnvelope(type: "sync", events: [durable, invalid])] + repeated + [MeshEnvelope(type: "event", event: live)],
            peerID: receiver.id)
        try await meshEventually { receiver.state.read { $0.replica.broadcaster?.nodeID == sender.id } }
        // The live event proves the mixed envelope completed the media path.
        // The worker is held, so a durable cache hit proves misplaced crypto.
        #expect(blocked.isBlocked)
        #expect(receiver.control.hasVerifiedEventForTesting(live))
        #expect(!receiver.control.hasVerifiedEventForTesting(durable))
        #expect(receiver.control.acceptedEventReceiptCountForTesting == 0)
        #expect(await receiver.control.pendingDurableCommitsForTesting() == 2, "One blocked local job and one exact-deduplicated remote batch")
        #expect(receiver.state.read { $0.replica.chatEvents.isEmpty })
        blocked.release()
        try await meshEventually { receiver.state.read { $0.replica.chatEvents.contains { $0.id == durable.id } } }
        #expect(receiver.control.hasVerifiedEventForTesting(durable))
        #expect(!receiver.control.hasVerifiedEventForTesting(invalid))
        #expect(!blocked.attempts.contains { $0.id == invalid.id })
        #expect(receiver.control.acceptedEventReceiptCountForTesting == 1)
        await receiver.control.waitForDurableWorkForTesting()
        #expect(blocked.attempts.filter { $0.id == durable.id }.count == 1)
        #expect(receiver.state.read { !$0.replica.chatEvents.contains { $0.id == invalid.id } })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = Data(SHA256.hash(data: Data("alo.network.accepted-event.v1\0".utf8) + (try encoder.encode(invalid))))
        try await meshEventually { receiver.state.read { $0.savedArchive != nil } }
        #expect(try !archiveReceiptDigests(#require(receiver.state.read { $0.savedArchive })).contains(digest))
        let marker = try #require(signer.sign(MeshRoomEvent(id: "second-live", roomID: room.id,
            version: .init(counter: 13, nodeID: sender.id), kind: .broadcaster,
            broadcasterID: sender.id, broadcasterEpoch: 2, mediaServiceName: "Second live state", isBroadcasting: true)))
        sender.control.sendRoomStateSyncEnvelopesForTesting(repeated + [MeshEnvelope(type: "event", event: marker)], peerID: receiver.id)
        try await meshEventually { receiver.state.read { $0.replica.broadcaster?.epoch == 2 } }
        await receiver.control.waitForDurableWorkForTesting()
        #expect(blocked.attempts.filter { $0.id == durable.id }.count == 1, "Committed exact duplicates never reach Core again")
        let different = try #require(signer.sign(MeshRoomEvent(id: durable.id, roomID: room.id,
            version: durable.version, kind: .chat, text: "Different validly signed bytes under the same ID")))
        let finalMarker = try #require(signer.sign(MeshRoomEvent(id: "third-live", roomID: room.id,
            version: .init(counter: 14, nodeID: sender.id), kind: .broadcaster,
            broadcasterID: sender.id, broadcasterEpoch: 3, mediaServiceName: "Third live state", isBroadcasting: true)))
        sender.control.sendRoomStateSyncEnvelopesForTesting(
            [MeshEnvelope(type: "event", event: different), MeshEnvelope(type: "event", event: finalMarker)], peerID: receiver.id)
        try await meshEventually { receiver.state.read { $0.replica.broadcaster?.epoch == 3 } }
        await receiver.control.waitForDurableWorkForTesting()
        #expect(blocked.attempts.contains { $0.id == different.id && $0.text == different.text }, "Different same-ID bytes are not deduplicated as an exact success")
        #expect(receiver.state.read { $0.replica.chatEvents.first?.text == durable.text })
        #expect(receiver.control.acceptedEventReceiptCountForTesting == 1)
    }

    @Test func invalidLocalDurableEditStillReportsRejectionAndDoesNotEarnAReceipt() async throws {
        let room = RoomConfiguration.secure(name: "Invalid local durable edit")
        let node = try SecureMeshNode(room: room)
        defer { node.stop() }
        try node.start()
        // publishChat limits graphemes, while durable admission bounds UTF-8.
        let oversized = String(repeating: "👨‍👩‍👧‍👦", count: 400)
        #expect(oversized.count <= 2_000 && oversized.utf8.count > 8_192)
        node.control.publishChat(oversized)
        try await meshEventually { node.state.read { !$0.rejectedOperations.isEmpty } }
        #expect(node.state.read { $0.rejectedOperations == [.authorizationChanged] && $0.replica.chatEvents.isEmpty })
        #expect(node.control.acceptedEventReceiptCountForTesting == 0)
        node.control.publishChat("A valid edit still succeeds")
        try await meshEventually { node.state.read { $0.replica.chatEvents.count == 1 } }
        #expect(node.state.read { $0.replica.chatEvents.first?.text == "A valid edit still succeeds" })
        #expect(node.control.acceptedEventReceiptCountForTesting == 1)
    }

    @Test func remoteDurableQuotaRejectionNeverClaimsALocalEditWasNotSent() async throws {
        let room = RoomConfiguration.secure(name: "Remote quota diagnostic")
        let rejected = try RejectOnceRoomStateSync(roomID: room.id)
        let receiver = try SecureMeshNode(room: room, identity: .ephemeral(), disableStateSync: true,
            roomStateSyncOverride: rejected)
        let sender = try SecureMeshNode(room: room, identity: .ephemeral(), disableStateSync: true)
        defer { receiver.stop(); sender.stop() }
        try receiver.start(); try sender.start()
        let port = try await receiver.readyPort()
        sender.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: receiver.id)
        try await meshEventually { sender.state.read { $0.participants.count == 2 } }
        sender.control.publishChat("Remote rejected allocation")
        try await meshEventually { rejected.attempts.contains { $0.text == "Remote rejected allocation" } }
        await receiver.control.waitForDurableWorkForTesting()
        #expect(receiver.state.read { $0.operationRejectionDescriptions.isEmpty })
        #expect(receiver.control.acceptedEventReceiptCountForTesting == 0)
        sender.control.publishChat("Remote valid retry")
        try await meshEventually { receiver.state.read { $0.replica.chatEvents.contains { $0.text == "Remote valid retry" } } }
        #expect(receiver.state.read { $0.operationRejectionDescriptions.isEmpty })
    }

    @Test func relayedSignedHistoryUsesPacedBatchesWithoutFloodingTheDurableWorker() async throws {
        let room = RoomConfiguration.secure(name: "Paced three-peer durable relay")
        let blocked = try RejectOnceRoomStateSync(roomID: room.id, blockFirstChat: true)
        let source = try SecureMeshNode(room: room, identity: .ephemeral(), disableStateSync: true)
        let relay = try SecureMeshNode(room: room, identity: .ephemeral(), disableStateSync: true)
        let receiver = try SecureMeshNode(room: room, identity: .ephemeral(), disableStateSync: true, roomStateSyncOverride: blocked)
        defer { blocked.release(); source.stop(); relay.stop(); receiver.stop() }
        let signer = SecureRoomEventPolicy(roomID: room.id, identity: source.identity, capabilities: .desktop,
            networkAuthorization: try source.networkFixture.authorization(for: source.identity))
        let events = try (1...500).map { index in
            try #require(signer.sign(MeshRoomEvent(id: "relayed-\(index)", roomID: room.id,
                version: .init(counter: UInt64(index), nodeID: source.id), kind: .chat, text: "Relayed signed history \(index)")))
        }
        try source.start(); try relay.start(); try receiver.start()
        let port = try await relay.readyPort()
        source.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: relay.id)
        receiver.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: relay.id)
        try await fullMeshEventually([source, relay, receiver])
        let initialConnections = await receiver.control.secureConnectionsForTesting()
        #expect(initialConnections.count == 2)
        receiver.control.publishChat("Hold the downstream durable worker")
        try await meshEventually { blocked.isBlocked }
        // Pace the source fixture below the transport's 1 MiB queue so this
        // tests the relay's production fanout, not an oversized test injection.
        var sent = 0
        for envelope in MeshControlPlane.synchronizationEnvelopes(events: events, versionVector: nil) {
            source.control.sendRoomStateSyncEnvelopesForTesting([envelope], peerID: relay.id)
            sent += envelope.events?.count ?? 0
            try await meshEventually(reason: "Relay did not commit source page through event \(sent)") { relay.state.read { $0.replica.chatEvents.count >= sent } }
        }
        relay.control.publishBroadcaster(active: true, mediaServiceName: "Relay remains live")
        try await meshEventually(reason: "Downstream live marker was lost after the relay broadcast 500 durable events") { receiver.state.read { $0.replica.broadcaster?.nodeID == relay.id } }
        #expect(await receiver.control.secureConnectionsForTesting() == initialConnections)
        #expect(await receiver.control.pendingDurableCommitsForTesting() <= 16, "A 500-event relay must not create 500 serial full-history transactions")
        #expect(receiver.control.acceptedEventReceiptCountForTesting == 0)
        blocked.release()
        try await meshEventually(reason: "Downstream did not receive the 500 relayed events after its worker was released") { receiver.state.read { $0.replica.chatEvents.count == 500 } }
        #expect(await receiver.control.secureConnectionsForTesting() == initialConnections)
        #expect(receiver.state.read { $0.operationRejectionDescriptions.count == 1 }, "Only the deliberately rejected local blocker can produce a composer notice")
    }

    @Test func rejectedNetworkDurableOperationHasNoProjectionGossipOrReceiptAndNextEditSucceeds() async throws {
        let room = RoomConfiguration.secure(name: "Atomic local operation rejection")
        let rejecting = try RejectOnceRoomStateSync(roomID: room.id)
        let a = try SecureMeshNode(room: room, identity: .ephemeral(), roomStateSyncOverride: rejecting)
        let b = try SecureMeshNode(room: room)
        defer { a.stop(); b.stop() }
        try a.start(); try b.start()
        let port = try await a.readyPort()
        b.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: a.id)
        try await meshEventually { a.state.read { $0.participants.count == 2 } }
        a.control.publishChat("Rejected allocation")
        try await meshEventually { a.state.read { !$0.rejectedOperations.isEmpty } }
        #expect(a.state.read { $0.rejectedOperations == [RoomStateSyncError.retentionCapacity] })
        #expect(a.control.acceptedEventReceiptCountForTesting == 0, "A rejected operation cannot acquire a live historical receipt")
        #expect(!a.state.read { $0.replica.chatEvents.contains { $0.text == "Rejected allocation" } })
        #expect(!b.state.read { $0.replica.chatEvents.contains { $0.text == "Rejected allocation" } })
        await withCheckedContinuation { continuation in a.control.performMediaWork { continuation.resume() } }
        a.control.publishChat("Next operation succeeds")
        try await meshEventually {
            a.state.read { $0.replica.chatEvents.contains { $0.text == "Next operation succeeds" } }
                && b.state.read { $0.replica.chatEvents.contains { $0.text == "Next operation succeeds" } }
        }
        let rejected = try #require(rejecting.attempts.first(where: { $0.text == "Rejected allocation" }))
        let accepted = try #require(rejecting.attempts.first(where: { $0.text == "Next operation succeeds" }))
        #expect(accepted.version.counter > rejected.version.counter, "Failed reservations must not reuse a Lamport counter")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let rejectedDigest = Data(SHA256.hash(data: Data("alo.network.accepted-event.v1\0".utf8) + (try encoder.encode(rejected))))
        let acceptedDigest = Data(SHA256.hash(data: Data("alo.network.accepted-event.v1\0".utf8) + (try encoder.encode(accepted))))
        try await meshEventually {
            guard let archive = a.state.read({ $0.savedArchive }), let digests = try? archiveReceiptDigests(archive) else { return false }
            return digests.contains(acceptedDigest)
        }
        let archive = try #require(a.state.read { $0.savedArchive })
        #expect(try !archiveReceiptDigests(archive).contains(rejectedDigest))
        #expect(!a.state.read { $0.replica.chatEvents.contains { $0.id == rejected.id } })
        #expect(!b.state.read { $0.replica.chatEvents.contains { $0.id == rejected.id } })
    }

    @Test func pendingDurableWorkDoesNotBlockLiveControlOrPublishAfterStop() async throws {
        let room = RoomConfiguration.secure(name: "Pending durable edit")
        let blocked = try RejectOnceRoomStateSync(roomID: room.id, blockFirstChat: true)
        let node = try SecureMeshNode(room: room, identity: .ephemeral(), roomStateSyncOverride: blocked)
        defer { blocked.release(); node.stop() }
        try node.start()
        node.control.publishChat("Pending edit that is cancelled")
        try await meshEventually { blocked.isBlocked }
        #expect(node.control.acceptedEventReceiptCountForTesting == 0)
        #expect(node.state.read { $0.replica.chatEvents.isEmpty })
        node.control.publishBroadcaster(active: true, mediaServiceName: "Live control stays responsive")
        try await meshEventually { node.state.read { $0.replica.broadcaster?.nodeID == node.id } }
        let observation = node.state
        node.control.stop { observation.update { $0.stopCompleted = true } }
        // This work is ordered after stop's lifecycle fence, but does not wait
        // for the blocked durable worker or the final archive write.
        await withCheckedContinuation { continuation in node.control.performMediaWork { continuation.resume() } }
        blocked.release()
        try await meshEventually { node.state.read { $0.stopCompleted } }
        #expect(node.state.read { $0.replica.chatEvents.isEmpty && $0.rejectedOperations.isEmpty })
        #expect(node.control.acceptedEventReceiptCountForTesting == 0)
    }

    @Test func largeSignedSnapshotIsPacedWithoutDisconnecting() async throws {
        let room = RoomConfiguration.secure(name: "Large signed snapshot")
        let identity = try InstallationIdentity.ephemeral()
        let network = try NetworkTestRoomFixture.shared(for: room)
        let signer = SecureRoomEventPolicy(roomID: room.id, identity: identity, capabilities: .desktop,
            networkAuthorization: try network.authorization(for: identity))
        var events = [MeshRoomEvent]()
        for index in 1...500 {
            let event = MeshRoomEvent(roomID: room.id, version: .init(counter: UInt64(index), nodeID: identity.publicIdentity.nodeID.uuidString),
                                      kind: .chat, text: String(repeating: "x", count: 1_500))
            events.append(try #require(signer.sign(event)))
        }
        let encodedHistoryBytes = try JSONEncoder().encode(events).count
        #expect(encodedHistoryBytes > 1_024 * 1_024)
        #expect(encodedHistoryBytes < AutomergeRoomStateSync.maximumRetainedEventBytes)
        let a = try SecureMeshNode(room: room, identity: identity, initialEvents: events, disableStateSync: true)
        let b = try SecureMeshNode(room: room, identity: .ephemeral(), disableStateSync: true)
        defer { a.stop(); b.stop() }
        try a.start(); try b.start()
        let port = try await a.readyPort()
        b.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: a.id)
        try await meshEventually { b.state.read { $0.replica.chatEvents.count == 500 } }
        let connections = await b.control.secureConnectionsForTesting()
        #expect(connections.count == 1)
        #expect(b.state.read { $0.connectionAttempts == 1 })
    }

    @Test func restrictedPeerCanChatButCannotBroadcastOrEditQueue() async throws {
        let room = RoomConfiguration.secure(name: "Restricted peer")
        let restricted = try SecureMeshNode(room: room, identity: .ephemeral(), capabilities: .chat)
        let desktop = try SecureMeshNode(room: room)
        defer { restricted.stop(); desktop.stop() }
        try restricted.start(); try desktop.start()
        let port = try await desktop.readyPort()
        restricted.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: desktop.id)
        try await meshEventually { desktop.state.read { $0.participants.count == 2 } }
        restricted.control.publishBroadcaster(active: true, mediaServiceName: "Forbidden")
        restricted.control.publishQueueAdd(RoomQueueItem(title: "Forbidden", url: "https://example.com"))
        restricted.control.publishPlayback(NowPlayingMedia(title: "Forbidden"))
        restricted.control.publishChat("Allowed")
        try await meshEventually { desktop.state.read { $0.replica.chatEvents.contains { $0.text == "Allowed" } } }
        #expect(desktop.state.read { $0.replica.broadcaster == nil && $0.replica.queue.isEmpty && $0.replica.nowPlaying.isEmpty })
        #expect(restricted.state.read { $0.replica.broadcaster == nil && $0.replica.queue.isEmpty })
    }

    @Test func privateRoomSyncAndChatWorkWhenHigherIDInitiates() async throws {
        let room = RoomConfiguration.secure(name: "Private mesh")
        let identities = try [InstallationIdentity.ephemeral(), InstallationIdentity.ephemeral()]
            .sorted { $0.publicIdentity.nodeID.uuidString < $1.publicIdentity.nodeID.uuidString }
        let lower = try SecureMeshNode(room: room, identity: identities[0])
        let higher = try SecureMeshNode(room: room, identity: identities[1])
        defer { lower.stop(); higher.stop() }
        try lower.start(); try higher.start()
        for index in 0..<40 { lower.control.publishChat("Before join \(index)") }
        try await meshEventually { lower.state.read { $0.replica.chatEvents.count == 40 } }
        let port = try await lower.readyPort()
        higher.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: lower.id)
        try await meshEventually { higher.state.read { $0.replica.chatEvents.count == 40 && $0.participants.count == 2 } }
        higher.control.publishChat("Encrypted reply")
        try await meshEventually { lower.state.read { $0.replica.chatEvents.contains { $0.text == "Encrypted reply" } } }
        let left = await lower.control.secureConnectionsForTesting(), right = await higher.control.secureConnectionsForTesting()
        #expect(left[higher.id] == right[lower.id])
        #expect(left.count == 1 && right.count == 1)
    }

    @Test func authenticatedPeersTransferChunkedChatAttachments() async throws {
        let room = RoomConfiguration.secure(name: "File transfer")
        let sender = try SecureMeshNode(room: room), receiver = try SecureMeshNode(room: room)
        defer { sender.stop(); receiver.stop() }
        try sender.start(); try receiver.start()
        let port = try await receiver.readyPort()
        sender.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: receiver.id)
        try await meshEventually { receiver.state.read { $0.participants.count == 2 } }

        let data = Data((0..<(RoomChatAttachmentPacket.chunkBytes * 2 + 37)).map { UInt8($0 % 253) })
        let attachment = RoomChatAttachment(fileName: "sample.dat", contentType: "application/octet-stream", byteCount: data.count)
        let payload = try #require(RoomChatAttachmentPayload(attachment: attachment, data: data))
        sender.control.publishChatAttachment(payload)
        try await meshEventually {
            receiver.state.read { $0.chatAttachments[sender.id]?.attachment == attachment }
        }
        #expect(receiver.state.read { $0.chatAttachments[sender.id]?.data == data })
    }

    @Test func authenticatedPeersRequestAndReceiveLateRoomTrayFiles() async throws {
        let room = RoomConfiguration.secure(name: "Late tray download")
        let holder = try SecureMeshNode(room: room), requester = try SecureMeshNode(room: room)
        defer { holder.stop(); requester.stop() }
        try holder.start(); try requester.start()
        let port = try await holder.readyPort()
        requester.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: holder.id)
        try await meshEventually { holder.state.read { $0.participants.count == 2 } }

        let attachment = RoomChatAttachment(fileName: "late.txt", byteCount: 9)
        let payload = try #require(RoomChatAttachmentPayload(attachment: attachment, data: Data("late file".utf8)))
        let digest = try #require(RoomChatAttachmentPacket.packets(for: payload).first?.digest)
        let request = RoomTrayFileRequest(itemID: attachment.id, digest: digest)
        requester.control.publishRoomTrayFileRequest(request)
        try await meshEventually { holder.state.read { $0.roomTrayRequests[requester.id] == request } }

        holder.control.publishChatAttachment(payload, targetID: requester.id)
        try await meshEventually {
            requester.state.read { $0.chatAttachments[holder.id]?.attachment == attachment }
        }
        #expect(requester.state.read { $0.chatAttachments[holder.id]?.data == payload.data })
    }

    @Test func simultaneousPublicDialsAgreeOnOneConnection() async throws {
        let room = RoomConfiguration.secure(name: "Public mesh", isPrivate: false)
        let a = try SecureMeshNode(room: room), b = try SecureMeshNode(room: room)
        defer { a.stop(); b.stop() }
        try a.start(); try b.start()
        let aPort = try await a.readyPort(), bPort = try await b.readyPort()
        a.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: bPort), expectedNodeID: b.id)
        b.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: aPort), expectedNodeID: a.id)
        try await meshEventually { a.state.read { $0.participants.count == 2 } && b.state.read { $0.participants.count == 2 } }
        let firstA = await a.control.secureConnectionsForTesting(), firstB = await b.control.secureConnectionsForTesting()
        #expect(firstA[b.id] != nil)
        #expect(firstA[b.id] == firstB[a.id])
        // A redundant admitted candidate cannot displace a healthy agreed link.
        a.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: bPort), expectedNodeID: b.id)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await a.control.secureConnectionsForTesting() == firstA)
        #expect(await b.control.secureConnectionsForTesting() == firstB)
        a.control.publishChat("Still connected")
        try await meshEventually { b.state.read { $0.replica.chatEvents.contains { $0.text == "Still connected" } } }
    }

    @Test func wrongSecretCandidateCannotEvictHealthyPeerOrReadState() async throws {
        let room = RoomConfiguration.secure(name: "Secret room")
        let a = try SecureMeshNode(room: room), b = try SecureMeshNode(room: room)
        defer { a.stop(); b.stop() }
        try a.start(); try b.start()
        let port = try await a.readyPort()
        b.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: a.id)
        try await meshEventually { b.state.read { $0.participants.count == 2 } }
        let committed = await a.control.secureConnectionsForTesting()
        let wrongRoom = RoomConfiguration.secure(id: room.id, name: room.name)
        let wrong = try SecureMeshNode(room: wrongRoom, identity: b.identity)
        defer { wrong.stop() }
        try wrong.start()
        wrong.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: a.id)
        a.control.publishChat("Private state")
        try await meshEventually { b.state.read { $0.replica.chatEvents.contains { $0.text == "Private state" } } }
        try await Task.sleep(for: .milliseconds(600))
        #expect(await a.control.secureConnectionsForTesting() == committed)
        #expect(wrong.state.read { $0.participants.count == 1 && $0.replica.chatEvents.isEmpty })
    }

    @Test func reconnectUsesFreshStateSessionAndTimeoutDoesNotStopBroadcaster() async throws {
        let room = RoomConfiguration.secure(name: "Reconnect")
        let a = try SecureMeshNode(room: room), b = try SecureMeshNode(room: room)
        defer { a.stop(); b.stop() }
        try a.start(); try b.start()
        let port = try await a.readyPort()
        b.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: a.id)
        try await meshEventually { b.state.read { $0.participants.count == 2 } }
        b.control.publishBroadcaster(active: true, mediaServiceName: "Secure source")
        try await meshEventually { a.state.read { $0.replica.broadcaster?.nodeID == b.id } }
        b.stop()
        try await Task.sleep(for: .seconds(3))
        #expect(a.state.read { $0.replica.broadcaster?.nodeID == b.id })
        a.control.publishChat("While disconnected")
        let returning = try SecureMeshNode(room: room, identity: b.identity)
        defer { returning.stop() }
        try returning.start()
        returning.control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: a.id)
        try await meshEventually { returning.state.read { $0.replica.chatEvents.contains { $0.text == "While disconnected" } } }
    }

    @Test func migrationAndIdentityMismatchFailBeforeListening() throws {
        let room = RoomConfiguration(name: "Pending", transportPolicy: .migrationRequired)
        let pending = MeshControlPlane(room: room, nodeID: "legacy", displayName: "Pending",
                                       replicaHandler: { _ in }, participantsHandler: { _ in })
        #expect(throws: RoomSecurityPolicyError.migrationRequired) { try pending.start(advertise: false) }
        let secure = MeshControlPlane(room: .secure(name: "Secure"), nodeID: "claimed-peer", displayName: "Mismatch",
            replicaHandler: { _ in }, participantsHandler: { _ in }, installationIdentity: try .ephemeral(), peerPins: MemoryPeerPinStore())
        #expect(throws: SecureTransportError.invalidCredentials) { try secure.start(advertise: false) }
    }

    @Test(arguments: [false, true], [false, true])
    func mismatchedNetworkContextDoesNotReadOrOverwriteArchive(wrongChannel: Bool, injectState: Bool) async throws {
        let authorizedRoom = RoomConfiguration.secure(name: "Authorized archive")
        let identity = try InstallationIdentity.ephemeral()
        let network = try NetworkTestRoomFixture.shared(for: authorizedRoom)
        let authorization = try network.authorization(for: identity)
        let signer = SecureRoomEventPolicy(roomID: authorizedRoom.id, identity: identity, capabilities: .desktop,
                                          networkAuthorization: authorization)
        let event = try #require(signer.sign(MeshRoomEvent(roomID: authorizedRoom.id,
            version: .init(counter: 1, nodeID: identity.publicIdentity.nodeID.uuidString), kind: .chat, text: "Keep saved history")))
        let document = try AutomergeRoomStateSync(roomID: authorizedRoom.id, legacyEvents: [event])
        let archive = try signer.archive(document: document.save(), retainedEvents: [event])
        let source = UntouchedRoomStateSync(events: [event])
        let observation = MeshInitializationObservation(archive: archive)
        let invalidRoom = wrongChannel
            ? RoomConfiguration.secure(name: "Different channel")
            : RoomConfiguration(id: authorizedRoom.id, name: "Legacy transport", transportPolicy: .legacyOnly)
        let control = MeshControlPlane(room: invalidRoom, nodeID: identity.publicIdentity.nodeID.uuidString,
            displayName: "Invalid context", initialEvents: [event], initialRoomStateDocument: archive,
            listenerReadyHandler: { _ in observation.recordCallback() },
            replicaHandler: { _ in observation.recordCallback() },
            participantsHandler: { _ in observation.recordCallback() },
            roomStatePersistenceHandler: { observation.persist($0) },
            roomStateSyncOverride: injectState ? source : nil,
            installationIdentity: identity, peerPins: MemoryPeerPinStore(), networkAuthorization: authorization)

        #expect(throws: SecureTransportError.wrongContext) { try control.start(advertise: false) }
        await withCheckedContinuation { continuation in control.stop { continuation.resume() } }
        #expect(source.calls == 0, "Invalid configuration must be rejected before accessing saved state")
        #expect(observation.callbacks == 0, "Invalid configuration must not publish UI or listener state")
        #expect(observation.persisted.elementsEqual(archive), "Failed initialization must preserve the original archive byte-for-byte")
        #expect(observation.writes == 0)
    }

    @Test(arguments: [RoomStateSyncError.untrustedHistoryLimit, .authorizationChanged])
    func failedStateInitializationPreservesErrorAndArchive(failure: RoomStateSyncError) async throws {
        let room = RoomConfiguration.secure(name: "Unavailable saved history")
        let identity = try InstallationIdentity.ephemeral()
        let network = try NetworkTestRoomFixture.shared(for: room)
        let authorization = try network.authorization(for: identity)
        let policy = SecureRoomEventPolicy(roomID: room.id, identity: identity, capabilities: .desktop,
                                          networkAuthorization: authorization)
        let archive = try policy.archive(document: AutomergeRoomStateSync(roomID: room.id).save())
        let observation = MeshInitializationObservation(archive: archive)
        let source = UntouchedRoomStateSync(events: [], failure: failure)
        let control = MeshControlPlane(room: room, nodeID: identity.publicIdentity.nodeID.uuidString,
            displayName: "Unavailable state", initialRoomStateDocument: archive,
            listenerReadyHandler: { _ in observation.recordCallback() },
            replicaHandler: { _ in observation.recordCallback() },
            participantsHandler: { _ in observation.recordCallback() },
            roomStatePersistenceHandler: { observation.persist($0) }, roomStateSyncOverride: source,
            installationIdentity: identity, peerPins: MemoryPeerPinStore(), networkAuthorization: authorization)

        #expect(throws: failure) { try control.start(advertise: false) }
        await withCheckedContinuation { continuation in control.stop { continuation.resume() } }
        #expect(source.calls == 1, "Stop must not compact or save a failed initial state")
        #expect(observation.callbacks == 0)
        #expect(observation.writes == 0)
        #expect(observation.persisted.elementsEqual(archive))
    }

    @Test(arguments: [true, false]) func mediaAdmissionEnforcesCurrentGeneration(currentGeneration: Bool) async throws {
        let room = RoomConfiguration.secure(name: "Role routing", isPrivate: false)
        let routed = MeshTestState()
        let server = try SecureMeshNode(room: room, incomingMediaChannelHandler: { channel, peer in
            routed.update { $0.mediaPeer = peer; $0.mediaChannels.append(channel) }
            channel.onPayload = { [weak channel] data in channel?.send(payload: data) }
        })
        defer { server.stop(); routed.read { $0.mediaChannels }.forEach { $0.cancel() } }
        try server.start()
        let port = try await server.readyPort()
        let identity = try InstallationIdentity.ephemeral(), pins = MemoryPeerPinStore()
        let queue = DispatchQueue(label: "alo.tests.securemesh.video")
        let connection = NWConnection(host: "127.0.0.1", port: port, using: try SecureNetworkParameters.tcp(
            identity: identity, expectedPeerID: server.identity.publicIdentity.nodeID, pins: pins,
            firstContact: .explicitRoomJoin, verificationQueue: queue))
        let config = try SecurePeerConfiguration(roomID: try #require(UUID(uuidString: room.id)), incarnationID: UUID(),
            admission: .publicRoom, offer: currentGeneration ? ProtocolOffer.current(capabilities: .mobile) : ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .mobile),
            direction: .initiator(.video),
            networkAuthorization: currentGeneration ? server.networkFixture.authorization(for: identity) : nil)
        let channel = SecurePeerChannel(connection: connection, identity: identity, configuration: config, pins: pins, queue: queue)
        defer { channel.cancel() }
        let payload = Data([0, 1, 2, 255])
        channel.onAuthenticated = { [weak channel] _ in channel?.send(payload: payload) }
        channel.onPayload = { bytes in routed.update { $0.payload = bytes } }
        channel.onState = { state in
            if case .failed(let error) = state { routed.update { $0.mediaError = String(describing: error) } }
        }
        channel.start()
        try await meshEventually { routed.read { $0.payload == payload || $0.mediaError != nil } }
        if !currentGeneration {
            #expect(routed.read { $0.payload == nil && $0.mediaPeer == nil && $0.mediaError != nil })
            #expect(server.state.read { $0.participants.count == 1 })
            return
        }
        #expect(routed.read { $0.mediaPeer?.nodeID == identity.publicIdentity.nodeID && $0.mediaPeer?.channelRole == .video })
        #expect(server.state.read { $0.participants.count == 1 })
    }

    @Test(arguments: [ReliableChannelRole.mediaControl, .fileTransfer])
    func receiverOpensMediaToAnInboundRoomPeersAdvertisedListener(role: ReliableChannelRole) async throws {
        let room = try RoomConfiguration(name: "Migrated private room", isPrivate: true, accessKey: UUID().uuidString).upgradedToCurrentSystem()
        let routed = MeshTestState()
        let presenter = try SecureMeshNode(room: room, incomingMediaChannelHandler: { channel, peer in
            routed.update { $0.mediaPeer = peer; $0.mediaChannels.append(channel) }
            channel.onPayload = { [weak channel] data in channel?.send(payload: data) }
        })
        let receiver = try SecureMeshNode(room: room)
        defer {
            presenter.stop(); receiver.stop()
            routed.read { $0.mediaChannels }.forEach { $0.cancel() }
        }
        try presenter.start(); try receiver.start()
        let receiverPort = try await receiver.readyPort()
        _ = try await presenter.readyPort()
        presenter.control.connect(to: .hostPort(host: "127.0.0.1", port: receiverPort),
            expectedPeerID: receiver.identity.publicIdentity.nodeID)
        try await fullMeshEventually([presenter, receiver])
        let payload = Data([42, 12, 83])
        receiver.control.openPeerChannel(to: presenter.identity.publicIdentity.nodeID, role: role) { result in
            do {
                let (channel, _) = try result.get()
                routed.update { $0.mediaChannels.append(channel) }
                channel.onPayload = { bytes in routed.update { $0.payload = bytes } }
                channel.send(payload: payload)
            } catch { routed.update { $0.mediaError = String(describing: error) } }
        }
        try await meshEventually { routed.read { $0.payload == payload || $0.mediaError != nil } }
        #expect(routed.read { $0.mediaError == nil && $0.payload == payload })
        #expect(routed.read { $0.mediaPeer?.channelRole == role })
        #expect(presenter.state.read { $0.participants.count == 2 })
    }

    @Test func directoryBuildsFullMeshAndRepairsWithoutSeed() async throws {
        let room = RoomConfiguration.secure(name: "Directory mesh")
        let seed = try SecureMeshNode(room: room), b = try SecureMeshNode(room: room), c = try SecureMeshNode(room: room)
        defer { seed.stop(); b.stop(); c.stop() }
        try seed.start(); try b.start(); try c.start()
        let seedPort = try await seed.readyPort()
        b.control.connect(to: .hostPort(host: "127.0.0.1", port: seedPort), expectedPeerID: seed.identity.publicIdentity.nodeID)
        try await meshEventually { b.state.read { $0.participants.count == 2 } }
        c.control.connect(to: .hostPort(host: "127.0.0.1", port: seedPort), expectedPeerID: seed.identity.publicIdentity.nodeID)
        try await fullMeshEventually([seed, b, c])
        seed.stop()
        try await fullMeshEventually([b, c])

        // The direct non-seed edge is repaired using authenticated directory
        // hints even though every test browser/advertisement is disabled.
        let previous = await b.control.secureConnectionsForTesting()[c.id]
        b.control.dropPeerForTesting(peerID: c.id)
        for _ in 0..<400 {
            let current = await b.control.secureConnectionsForTesting()[c.id]
            if let current, current != previous { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await fullMeshEventually([b, c])
        #expect(await b.control.secureConnectionsForTesting()[c.id] != previous)

        let newcomer = try SecureMeshNode(room: room)
        defer { newcomer.stop() }
        try newcomer.start()
        let bPort = try await b.readyPort()
        newcomer.control.connect(to: .hostPort(host: "127.0.0.1", port: bPort), expectedPeerID: b.identity.publicIdentity.nodeID)
        try await fullMeshEventually([b, c, newcomer])
        newcomer.control.publishChat("The original seed is gone")
        try await meshEventually { c.state.read { $0.replica.chatEvents.contains { $0.text == "The original seed is gone" } } }
    }

    @Test func directoryHintsExpireAndCannotSubstituteDestinationIdentity() async throws {
        let room = RoomConfiguration.secure(name: "Directory bounds", isPrivate: false)
        let a = try SecureMeshNode(room: room), b = try SecureMeshNode(room: room)
        defer { a.stop(); b.stop() }
        try a.start(); try b.start()
        let aPort = try await a.readyPort(), bPort = try await b.readyPort()
        b.control.connect(to: .hostPort(host: "127.0.0.1", port: aPort), expectedPeerID: a.identity.publicIdentity.nodeID)
        try await fullMeshEventually([a, b])
        let expected = await a.control.secureConnectionsForTesting()
        let invalid = MeshPeerDirectoryHint(peerID: UUID().uuidString, incarnationID: UUID().uuidString,
                                            host: "127.0.0.1", port: bPort.rawValue, validForSeconds: 0)
        let before = a.state.read { $0.connectionAttempts }
        b.control.sendRoomStateSyncEnvelopesForTesting([MeshEnvelope(type: "mesh_peer_directory", meshPeerDirectory: [invalid])], peerID: a.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(a.state.read { $0.connectionAttempts } == before)
        let hint = MeshPeerDirectoryHint(peerID: UUID().uuidString, incarnationID: UUID().uuidString,
                                         host: "127.0.0.1", port: bPort.rawValue, validForSeconds: 1)
        b.control.sendRoomStateSyncEnvelopesForTesting([MeshEnvelope(type: "mesh_peer_directory", meshPeerDirectory: [hint])], peerID: a.id)
        try await meshEventually { a.state.read { $0.connectionAttempts > before } }
        try await Task.sleep(for: .milliseconds(1_500))
        let expiredAttempts = a.state.read { $0.connectionAttempts }
        try await Task.sleep(for: .milliseconds(800))
        #expect(a.state.read { $0.connectionAttempts } == expiredAttempts)
        #expect(await a.control.secureConnectionsForTesting() == expected)
    }
}

private final class MeshInitializationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var archive: Data
    private var callbackCount = 0
    private var writeCount = 0
    init(archive: Data) { self.archive = archive }
    var callbacks: Int { lock.withLock { callbackCount } }
    var writes: Int { lock.withLock { writeCount } }
    var persisted: Data { lock.withLock { archive } }
    func recordCallback() { lock.withLock { callbackCount += 1 } }
    func persist(_ data: Data) { lock.withLock { archive = data; writeCount += 1 } }
}

private func archiveReceiptDigests(_ archive: Data) throws -> Set<Data> {
    let outer = try #require(PropertyListSerialization.propertyList(from: archive.dropFirst(8), format: nil) as? [String: Any])
    let body = try #require(outer["body"] as? Data)
    let saved = try #require(PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any])
    return Set(try #require(saved["acceptedHistory"] as? [Data]))
}

private final class RejectOnceRoomStateSync: RoomStateSync, @unchecked Sendable {
    private let backing: AutomergeRoomStateSync
    private let lock = NSLock()
    private var rejected = false
    private var observed = [MeshRoomEvent]()
    private let blockFirstChat: Bool
    private let gate = DispatchSemaphore(value: 0)
    private var enteredGate = false
    init(roomID: String, blockFirstChat: Bool = false) throws {
        backing = try AutomergeRoomStateSync(roomID: roomID)
        self.blockFirstChat = blockFirstChat
    }
    var attempts: [MeshRoomEvent] { lock.withLock { observed } }
    var isBlocked: Bool { lock.withLock { enteredGate } }
    func release() { gate.signal() }
    func snapshot() throws -> RoomStateSnapshot { try backing.snapshot() }
    func ingest(_ events: [MeshRoomEvent]) throws -> [MeshRoomEvent] {
        let reject = lock.withLock {
            observed.append(contentsOf: events)
            guard !rejected, events.contains(where: { $0.kind == .chat }) else { return false }
            rejected = true
            return true
        }
        if reject {
            if blockFirstChat {
                lock.withLock { enteredGate = true }
                guard gate.wait(timeout: .now() + 20) == .success else { throw RoomStateSyncError.processingTimedOut }
            }
            throw RoomStateSyncError.retentionCapacity
        }
        return try backing.ingest(events)
    }
    func makeSession() -> RoomStateSyncSession { backing.makeSession() }
    func generateSyncMessage(for session: RoomStateSyncSession) -> Data? { backing.generateSyncMessage(for: session) }
    func receiveSyncMessage(_ message: Data, from session: RoomStateSyncSession) throws -> [MeshRoomEvent] {
        try backing.receiveSyncMessage(message, from: session)
    }
    func compactIfNeeded() throws -> Bool { try backing.compactIfNeeded() }
    func save() -> Data { backing.save() }
}

private final class UntouchedRoomStateSync: RoomStateSync, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let events: [MeshRoomEvent]
    private let failure: RoomStateSyncError?
    init(events: [MeshRoomEvent], failure: RoomStateSyncError? = nil) { self.events = events; self.failure = failure }
    var calls: Int { lock.withLock { callCount } }
    private func called() { lock.withLock { callCount += 1 } }
    func snapshot() throws -> RoomStateSnapshot {
        called()
        if let failure { throw failure }
        return RoomStateSnapshot(events: events)
    }
    func ingest(_ events: [MeshRoomEvent]) -> [MeshRoomEvent] { called(); return [] }
    func makeSession() -> RoomStateSyncSession { called(); return RoomStateSyncSession() }
    func generateSyncMessage(for session: RoomStateSyncSession) -> Data? { called(); return nil }
    func receiveSyncMessage(_ message: Data, from session: RoomStateSyncSession) -> [MeshRoomEvent] { called(); return [] }
    func save() -> Data { called(); return Data() }
}

private final class MeshTestState: @unchecked Sendable {
    struct Value {
        var port: NWEndpoint.Port?
        var participants: [RoomParticipant] = []
        var replica = MeshRoomReplica()
        var mediaPeer: AuthenticatedPeer?
        var mediaChannels: [SecurePeerChannel] = []
        var mediaError: String?
        var payload: Data?
        var chatAttachments = [String: RoomChatAttachmentPayload]()
        var roomTrayRequests = [String: RoomTrayFileRequest]()
        var connectionAttempts = 0
        var savedArchive: Data?
        var rejectedOperations = [RoomStateSyncError]()
        var operationRejectionDescriptions = [String]()
        var stopCompleted = false
    }
    private let lock = NSLock()
    private var value = Value()
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
    func read<T>(_ body: (Value) -> T) -> T { lock.withLock { body(value) } }
}

private final class SecureMeshNode {
    let identity: InstallationIdentity
    let networkFixture: NetworkTestRoomFixture
    let control: MeshControlPlane
    let state = MeshTestState()
    var id: String { identity.publicIdentity.nodeID.uuidString }
    convenience init(room: RoomConfiguration, incomingMediaChannelHandler: ((SecurePeerChannel, AuthenticatedPeer) -> Void)? = nil) throws {
        try self.init(room: room, identity: .ephemeral(), incomingMediaChannelHandler: incomingMediaChannelHandler)
    }
    init(room: RoomConfiguration, identity: InstallationIdentity, capabilities: PeerCapabilities = .desktop,
         initialEvents: [MeshRoomEvent] = [], disableStateSync: Bool = false,
         roomStateSyncOverride: (any RoomStateSync)? = nil,
         incomingMediaChannelHandler: ((SecurePeerChannel, AuthenticatedPeer) -> Void)? = nil) throws {
        self.identity = identity
        networkFixture = try NetworkTestRoomFixture.shared(for: room)
        let observation = state
        control = MeshControlPlane(room: room, nodeID: identity.publicIdentity.nodeID.uuidString, displayName: "Peer",
            initialEvents: initialEvents,
            listenerReadyHandler: { port in observation.update { $0.port = port } },
            replicaHandler: { replica in observation.update { $0.replica = replica } },
            participantsHandler: { participants in observation.update { $0.participants = participants } },
            chatAttachmentHandler: { sender, payload in
                observation.update { $0.chatAttachments[sender] = payload }
            },
            roomTrayFileRequestHandler: { sender, request in
                observation.update { $0.roomTrayRequests[sender] = request }
            },
            roomStatePersistenceHandler: { archive in observation.update { $0.savedArchive = archive } },
            roomStateOperationRejectedHandler: { error in
                observation.update { $0.operationRejectionDescriptions.append(error.localizedDescription) }
                let underlying = (error as? RoomStateOperationRejection)?.underlyingError ?? error
                if let underlying = underlying as? RoomStateSyncError { observation.update { $0.rejectedOperations.append(underlying) } }
            },
            roomStateSyncOverride: roomStateSyncOverride,
            disableRoomStateSyncDuringAuthenticationForTesting: disableStateSync,
            connectionAttemptHandler: { observation.update { $0.connectionAttempts += 1 } },
            installationIdentity: identity, peerPins: MemoryPeerPinStore(), secureCapabilities: capabilities,
            networkAuthorization: try networkFixture.authorization(for: identity),
            incomingMediaChannelHandler: incomingMediaChannelHandler)
    }
    func start() throws { try control.start(advertise: false) }
    func stop() { control.stop() }
    func readyPort() async throws -> NWEndpoint.Port {
        try await meshEventually { self.state.read { $0.port != nil } }
        return try #require(state.read { $0.port })
    }
}

private func meshEventually(reason: String = "Secure mesh did not reach the expected state within 8 seconds", _ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(condition(), Comment(rawValue: reason))
}

private func fullMeshEventually(_ nodes: [SecureMeshNode]) async throws {
    for _ in 0..<400 {
        var connections: [String: [String: UUID]] = [:]
        for node in nodes { connections[node.id] = await node.control.secureConnectionsForTesting() }
        let ready = nodes.allSatisfy { node in
            let expected = Set(nodes.map(\.id)).subtracting([node.id])
            guard Set(connections[node.id]?.keys.map { $0 } ?? []) == expected else { return false }
            return expected.allSatisfy { connections[node.id]?[$0] == connections[$0]?[node.id] }
        }
        if ready { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Authenticated peers did not converge to the same direct full mesh within 8 seconds")
}
