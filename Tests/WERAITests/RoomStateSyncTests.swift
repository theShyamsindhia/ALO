import Foundation
import Network
import Testing
import Automerge
@testable import WERAI
@testable import WERAICore

struct RoomStateSyncTests {
    @Test("Automerge sync repairs non-contiguous Lamport histories")
    func repairsVersionVectorGap() throws {
        let roomID = "room-gap"
        let fourth = chat(roomID: roomID, id: "four", counter: 4, text: "four")
        let fifth = chat(roomID: roomID, id: "five", counter: 5, text: "five")
        let source = try AutomergeRoomStateSync(roomID: roomID, legacyEvents: [fourth, fifth])
        let receiver = try AutomergeRoomStateSync(roomID: roomID, legacyEvents: [fifth])

        try converge(source, receiver)

        #expect(try receiver.snapshot().chatEvents.map(\.id) == ["four", "five"])
    }

    @Test("Concurrent chat and queue edits converge")
    func concurrentEditsConverge() throws {
        let roomID = "room-concurrent"
        let left = try AutomergeRoomStateSync(roomID: roomID)
        let right = try AutomergeRoomStateSync(roomID: roomID)
        let item = RoomQueueItem(id: "track", title: "Track", url: "file:///track")

        _ = try left.ingest([
            chat(roomID: roomID, id: "left-chat", counter: 1, nodeID: "left", text: "left"),
            MeshRoomEvent(
                id: "add", roomID: roomID,
                version: MeshVersion(counter: 2, nodeID: "left"),
                kind: .queueAdd, queueItem: item
            ),
        ])
        _ = try right.ingest([
            chat(roomID: roomID, id: "right-chat", counter: 1, nodeID: "right", text: "right"),
            MeshRoomEvent(
                id: "remove", roomID: roomID,
                version: MeshVersion(counter: 2, nodeID: "right"),
                kind: .queueRemove, queueItemID: item.id
            ),
        ])

        try converge(left, right)

        #expect(try left.snapshot() == right.snapshot())
        #expect(try left.snapshot().chatEvents.count == 2)
        #expect(try left.snapshot().queue.isEmpty)
    }

    @Test("Routine one-sided sync acknowledgements remain healthy")
    func oneSidedAcknowledgementsRemainHealthy() throws {
        let roomID = "room-one-sided-acks"
        let source = try AutomergeRoomStateSync(roomID: roomID)
        let receiver = try AutomergeRoomStateSync(roomID: roomID)
        let sourceSession = source.makeSession()
        let receiverSession = receiver.makeSession()

        for counter in 1...200 {
            _ = try source.ingest([
                chat(
                    roomID: roomID, id: "chat-\(counter)",
                    counter: UInt64(counter), text: String(repeating: "x", count: 2_000)
                ),
            ])
            for _ in 0..<10 {
                var progressed = false
                if let message = source.generateSyncMessage(for: sourceSession) {
                    _ = try receiver.receiveSyncMessage(message, from: receiverSession)
                    progressed = true
                }
                if let message = receiver.generateSyncMessage(for: receiverSession) {
                    _ = try source.receiveSyncMessage(message, from: sourceSession)
                    progressed = true
                }
                if !progressed { break }
            }
        }

        #expect(try receiver.snapshot() == source.snapshot())
    }

    @Test("Sync is not capped at two thousand durable events")
    func syncsLargeHistory() throws {
        let roomID = "room-large"
        let source = try AutomergeRoomStateSync(roomID: roomID)
        let receiver = try AutomergeRoomStateSync(roomID: roomID)
        let events = (1...2_105).map {
            queueAdd(roomID: roomID, id: "event-\($0)", counter: UInt64($0))
        }
        _ = try source.ingest(events)

        try converge(source, receiver)

        #expect(try receiver.snapshot().queue.count == events.count)
    }

    @Test("Saved Automerge documents restore durable state")
    func restoresSavedDocument() throws {
        let roomID = "room-save"
        let original = try AutomergeRoomStateSync(roomID: roomID)
        _ = try original.ingest([chat(roomID: roomID, id: "saved", counter: 1, text: "saved")])

        let restored = try AutomergeRoomStateSync(roomID: roomID, savedDocument: original.save())

        #expect(try restored.snapshot().chatEvents.map(\.id) == ["saved"])
    }

    @Test("Realtime room events never enter durable Automerge state")
    func excludesRealtimeEvents() throws {
        let roomID = "room-realtime-boundary"
        let sync = try AutomergeRoomStateSync(roomID: roomID)
        let events = [MeshRoomEventKind.broadcaster, .playback, .video].enumerated().map { index, kind in
            MeshRoomEvent(
                id: "realtime-\(index)",
                roomID: roomID,
                version: MeshVersion(counter: UInt64(index + 1), nodeID: "node"),
                kind: kind
            )
        }

        #expect(try sync.ingest(events).isEmpty)
        #expect(try sync.snapshot().events.isEmpty)
    }

    @Test("Durable chat keeps the most recent five hundred messages")
    func boundsChatRetention() throws {
        let roomID = "room-retention"
        let sync = try AutomergeRoomStateSync(roomID: roomID)
        let events = (1...510).map {
            chat(roomID: roomID, id: "chat-\($0)", counter: UInt64($0), text: "message \($0)")
        }

        _ = try sync.ingest(events)
        let snapshot = try sync.snapshot()

        #expect(snapshot.chatEvents.count == AutomergeRoomStateSync.maximumChatEvents)
        #expect(snapshot.chatEvents.first?.id == "chat-11")
        #expect(snapshot.chatEvents.last?.id == "chat-510")
    }

    @Test("Queue history retains only the effective event per item")
    func compactsQueueHistory() throws {
        let roomID = "room-queue-retention"
        let sync = try AutomergeRoomStateSync(roomID: roomID)
        let item = RoomQueueItem(id: "track", title: "Track", url: "file:///track")
        var events = (1...20).map { counter in
            MeshRoomEvent(
                id: "add-\(counter)", roomID: roomID,
                version: MeshVersion(counter: UInt64(counter), nodeID: "node"),
                kind: .queueAdd, queueItem: item
            )
        }
        events.append(MeshRoomEvent(
            id: "remove", roomID: roomID,
            version: MeshVersion(counter: 21, nodeID: "node"),
            kind: .queueRemove, queueItemID: item.id
        ))

        _ = try sync.ingest(events)
        let snapshot = try sync.snapshot()

        #expect(snapshot.queue.isEmpty)
        #expect(snapshot.events.map(\.id) == ["remove"])
    }

    @Test("Queue events and tombstones have a bounded retention window")
    func boundsQueueRetention() throws {
        let roomID = "room-queue-bound"
        let sync = try AutomergeRoomStateSync(roomID: roomID)
        let events = (1...5_010).map { counter in
            MeshRoomEvent(
                id: "remove-\(counter)", roomID: roomID,
                version: MeshVersion(counter: UInt64(counter), nodeID: "node"),
                kind: .queueRemove, queueItemID: "track-\(counter)"
            )
        }

        _ = try sync.ingest(events)
        let beforeReplay = sync.save()
        let snapshot = try sync.snapshot()
        _ = try sync.ingest(Array(events.prefix(10)))

        #expect(snapshot.events.count == AutomergeRoomStateSync.maximumQueueEvents)
        #expect(snapshot.events.first?.id == "remove-11")
        #expect(sync.save() == beforeReplay)
    }

    @Test("A sync message cannot introduce an excessive change history")
    func rejectsExcessiveChangeHistory() throws {
        let roomID = "room-change-budget"
        let source = try AutomergeRoomStateSync(roomID: roomID)
        for counter in 1...(AutomergeRoomStateSync.maximumChangesPerSyncMessage + 1) {
            _ = try source.ingest([
                chat(
                    roomID: roomID, id: "chat-\(counter)",
                    counter: UInt64(counter), text: "message"
                ),
            ])
        }
        let receiver = try AutomergeRoomStateSync(roomID: roomID)
        let sourceSession = source.makeSession()
        let receiverSession = receiver.makeSession()
        var receivedError: RoomStateSyncError?
        for _ in 0..<10 where receivedError == nil {
            if let message = source.generateSyncMessage(for: sourceSession) {
                do { _ = try receiver.receiveSyncMessage(message, from: receiverSession) }
                catch { receivedError = error as? RoomStateSyncError }
            }
            if let message = receiver.generateSyncMessage(for: receiverSession) {
                _ = try? source.receiveSyncMessage(message, from: sourceSession)
            }
        }

        #expect(receivedError == .documentTooLarge)
        #expect(try receiver.snapshot().events.isEmpty)
    }

    @Test("Loading compacts history before a fresh peer synchronizes")
    func loadCompactsExcessiveHistory() throws {
        let roomID = "room-load-compaction"
        let original = try AutomergeRoomStateSync(roomID: roomID)
        for counter in 1...(AutomergeRoomStateSync.maximumChangesPerSyncMessage + 1) {
            _ = try original.ingest([
                chat(
                    roomID: roomID, id: "chat-\(counter)",
                    counter: UInt64(counter), text: "message"
                ),
            ])
        }

        let restored = try AutomergeRoomStateSync(
            roomID: roomID, savedDocument: original.save()
        )
        let receiver = try AutomergeRoomStateSync(roomID: roomID)
        try converge(restored, receiver)

        #expect(try receiver.snapshot() == restored.snapshot())
        #expect(restored.save().count < original.save().count)
    }

    @Test("A peer cannot rewrite an immutable event body")
    func rejectsImmutableEventRewrite() throws {
        let roomID = "room-immutable"
        let trusted = try AutomergeRoomStateSync(
            roomID: roomID,
            legacyEvents: [chat(roomID: roomID, id: "same", counter: 1, text: "trusted")]
        )
        let attacker = try AutomergeRoomStateSync(
            roomID: roomID,
            legacyEvents: [chat(roomID: roomID, id: "same", counter: 1, text: "rewritten")]
        )
        let trustedSession = trusted.makeSession()
        let attackerSession = attacker.makeSession()
        var rejected = false
        for _ in 0..<10 where !rejected {
            if let message = attacker.generateSyncMessage(for: attackerSession) {
                do { _ = try trusted.receiveSyncMessage(message, from: trustedSession) }
                catch { rejected = true }
            }
            if let message = trusted.generateSyncMessage(for: trustedSession) {
                do { _ = try attacker.receiveSyncMessage(message, from: attackerSession) }
                catch { rejected = true }
            }
        }
        #expect(rejected)
        #expect(try trusted.snapshot().chatEvents.first?.text == "trusted")
    }

    @Test("An observed overwrite of an immutable event is rejected")
    func rejectsObservedImmutableOverwrite() throws {
        let roomID = "room-observed-overwrite"
        let original = chat(roomID: roomID, id: "same", counter: 1, text: "trusted")
        let trusted = try AutomergeRoomStateSync(roomID: roomID, legacyEvents: [original])
        let changed = chat(roomID: roomID, id: "same", counter: 1, text: "rewritten")
        let maliciousDocument = try Document(trusted.save())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try maliciousDocument.put(
            obj: ObjId.ROOT,
            key: "event:same",
            value: .Bytes(try encoder.encode(changed))
        )
        let attacker = try AutomergeRoomStateSync(
            roomID: roomID,
            savedDocument: maliciousDocument.save()
        )
        let trustedSession = trusted.makeSession()
        let attackerSession = attacker.makeSession()
        var receivedError: RoomStateSyncError?
        for _ in 0..<10 where receivedError == nil {
            if let message = attacker.generateSyncMessage(for: attackerSession) {
                do { _ = try trusted.receiveSyncMessage(message, from: trustedSession) }
                catch { receivedError = error as? RoomStateSyncError }
            }
            if let message = trusted.generateSyncMessage(for: trustedSession) {
                _ = try? attacker.receiveSyncMessage(message, from: attackerSession)
            }
        }

        #expect(receivedError == .immutableEventChanged)
        #expect(try trusted.snapshot().chatEvents == [original])
    }

    @Test("A newer queue add cannot erase an existing remove tombstone")
    func rejectsQueueTombstoneDeletion() throws {
        let roomID = "room-tombstone"
        let item = RoomQueueItem(id: "track", title: "Track", url: "file:///track")
        let removed = MeshRoomEvent(
            id: "remove", roomID: roomID,
            version: MeshVersion(counter: 1, nodeID: "trusted"),
            kind: .queueRemove, queueItemID: item.id
        )
        let trusted = try AutomergeRoomStateSync(roomID: roomID, legacyEvents: [removed])
        let added = MeshRoomEvent(
            id: "new-add", roomID: roomID,
            version: MeshVersion(counter: 2, nodeID: "attacker"),
            kind: .queueAdd, queueItem: item
        )
        let maliciousDocument = try Document(trusted.save())
        try maliciousDocument.delete(obj: ObjId.ROOT, key: "event:\(removed.id)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try maliciousDocument.put(
            obj: ObjId.ROOT,
            key: "event:\(added.id)",
            value: .Bytes(try encoder.encode(added))
        )
        let attacker = try AutomergeRoomStateSync(
            roomID: roomID,
            savedDocument: maliciousDocument.save()
        )
        let trustedSession = trusted.makeSession()
        let attackerSession = attacker.makeSession()
        var rejected = false
        for _ in 0..<10 where !rejected {
            if let message = attacker.generateSyncMessage(for: attackerSession) {
                do { _ = try trusted.receiveSyncMessage(message, from: trustedSession) }
                catch { rejected = true }
            }
            if let message = trusted.generateSyncMessage(for: trustedSession) {
                do { _ = try attacker.receiveSyncMessage(message, from: attackerSession) }
                catch { rejected = true }
            }
        }

        #expect(rejected)
        #expect(try trusted.snapshot().queue.isEmpty)
    }

    @Test("Corrupt sidecars recover from compacted legacy events")
    func corruptSidecarRecovery() throws {
        let roomID = "room-corrupt"
        let legacy = chat(roomID: roomID, id: "legacy", counter: 1, text: "legacy")

        let recovered = AutomergeRoomStateSync.recovering(
            roomID: roomID,
            savedDocument: Data("not-an-automerge-document".utf8),
            legacyEvents: [legacy]
        )

        #expect(try recovered.snapshot().chatEvents == [legacy])
    }

    @Test("Large Automerge messages stay inside mesh framing limits")
    func chunksLargeSyncMessages() throws {
        let message = Data(repeating: 0xA5, count: MeshControlPlane.roomStateSyncChunkBytes * 3 + 17)
        let envelopes = MeshControlPlane.roomStateSyncEnvelopes(message: message, messageID: "sync")

        #expect(envelopes.count == 4)
        #expect(envelopes.enumerated().allSatisfy { index, envelope in
            envelope.type == "room_state_sync" &&
                envelope.roomStateSyncID == "sync" &&
                envelope.roomStateSyncChunkIndex == UInt16(index) &&
                envelope.roomStateSyncChunkCount == UInt16(envelopes.count) &&
                (try? envelope.encodedLine().count).map { $0 <= MeshEnvelopeDecoder.maximumLineBytes } == true
        })
        #expect(envelopes.compactMap(\.roomStateSyncMessage).reduce(into: Data(), { $0.append($1) }) == message)
    }

    @Test("Room store keeps and forgets the Automerge sidecar")
    func roomStorePersistsDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-room-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomStore(fileURL: directory.appendingPathComponent("rooms.json"))
        let room = RoomConfiguration(id: "persisted", name: "Persisted")
        let document = Data([1, 2, 3, 4])

        try store.save(room)
        store.saveRoomStateDocument(document, roomID: room.id)
        #expect(store.loadRoomStateDocument(roomID: room.id) == document)

        try store.forget(roomID: room.id)
        #expect(store.loadRoomStateDocument(roomID: room.id) == nil)

        // A final session flush may arrive after the user has forgotten the
        // room; it must not recreate stale state.
        store.saveRoomStateDocument(document, roomID: room.id)
        #expect(store.loadRoomStateDocument(roomID: room.id) == nil)

        try store.save(room)
        store.saveRoomStateDocument(document, roomID: room.id)
        #expect(store.loadRoomStateDocument(roomID: room.id) == document)
    }

    @Test("Mesh transport delivers durable history beyond the legacy cap")
    func meshTransportDeliversLargeHistory() throws {
        let room = RoomConfiguration(id: "mesh-large", name: "Large")
        let events = (1...2_105).map {
            queueAdd(roomID: room.id, id: "history-\($0)", counter: UInt64($0))
        }
        let sourceState = try AutomergeRoomStateSync(roomID: room.id, legacyEvents: events)
        let receiveOnlyState = try ReceiveOnlyRoomStateSync(roomID: room.id)
        let persistedProbe = RoomStateDocumentProbe(roomID: room.id)
        let portProbe = RoomStatePortProbe()
        let source = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            initialRoomStateDocument: sourceState.save(),
            replicaHandler: { _ in },
            participantsHandler: { _ in }
        )
        let receiver = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: portProbe.set,
            replicaHandler: { _ in },
            participantsHandler: { _ in },
            roomStatePersistenceHandler: persistedProbe.update,
            roomStateSyncOverride: receiveOnlyState
        )
        try source.start(advertise: false)
        try receiver.start(advertise: false)
        defer { source.stop(); receiver.stop() }
        let port = try #require(portProbe.wait())

        source.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))

        #expect(waitUntil(timeout: 8) { persistedProbe.queueCount == events.count })
        #expect(persistedProbe.queueCount == events.count)
        #expect(receiveOnlyState.receiveAttempts > 0)
    }

    @Test("A completed merge survives its source link disappearing")
    func completedMergeSurvivesSourceDisconnect() throws {
        let room = RoomConfiguration(id: "mesh-disconnect", name: "Disconnect")
        let event = chat(roomID: room.id, id: "survives", counter: 1, text: "survives")
        let sourceState = try AutomergeRoomStateSync(roomID: room.id, legacyEvents: [event])
        let receiverDocument = RoomStateDocumentProbe(roomID: room.id)
        let relayDocument = RoomStateDocumentProbe(roomID: room.id)
        let receiverState = try ReceiveOnlyRoomStateSync(roomID: room.id)
        let relayState = try ReceiveOnlyRoomStateSync(roomID: room.id)
        let completedReceives = RoomStateCounterProbe()
        let receiverParticipants = RoomStateParticipantProbe()
        let receiverPort = RoomStatePortProbe()
        let relayPort = RoomStatePortProbe()
        weak var receiverReference: MeshControlPlane?
        let source = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            initialRoomStateDocument: sourceState.save(),
            replicaHandler: { _ in },
            participantsHandler: { _ in }
        )
        let receiver = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: receiverPort.set,
            replicaHandler: { _ in },
            participantsHandler: receiverParticipants.update,
            roomStatePersistenceHandler: receiverDocument.update,
            roomStateSyncOverride: receiverState,
            roomStateReceiveCompletedHandler: { inserted in
                if !inserted.isEmpty {
                    completedReceives.increment()
                    source.stop()
                    receiverReference?.dropPeerForTesting(peerID: "a")
                }
            }
        )
        let relay = MeshControlPlane(
            room: room,
            nodeID: "c",
            displayName: "C",
            listenerReadyHandler: relayPort.set,
            replicaHandler: { _ in },
            participantsHandler: { _ in },
            roomStatePersistenceHandler: relayDocument.update,
            roomStateSyncOverride: relayState
        )
        receiverReference = receiver
        try source.start(advertise: false)
        try receiver.start(advertise: false)
        try relay.start(advertise: false)
        defer { source.stop(); receiver.stop(); relay.stop() }
        let sourceTarget = try #require(receiverPort.wait())
        let relayTarget = try #require(relayPort.wait())

        receiver.connectForTesting(to: .hostPort(host: "127.0.0.1", port: relayTarget))
        #expect(waitUntil(timeout: 5) { receiverParticipants.count == 2 })

        source.connectForTesting(to: .hostPort(host: "127.0.0.1", port: sourceTarget))

        #expect(waitUntil(timeout: 5) { receiverDocument.chatTexts.contains("survives") })
        #expect(waitUntil(timeout: 5) { relayDocument.chatTexts.contains("survives") })
        #expect(completedReceives.value > 0)
    }

    @Test("An Automerge receive failure downgrades to legacy without reconnecting")
    func receiveFailureDowngradesWithoutReconnect() throws {
        let room = RoomConfiguration(id: "mesh-receive-failure", name: "Receive failure")
        let seed = chat(roomID: room.id, id: "seed", counter: 1, text: "seed")
        let sourceState = try AutomergeRoomStateSync(roomID: room.id, legacyEvents: [seed])
        let failingState = try ReceiveFailingRoomStateSync(roomID: room.id)
        let persistedProbe = RoomStateDocumentProbe(roomID: room.id)
        let attempts = RoomStateCounterProbe()
        let downgrade = RoomStateDowngradeProbe()
        let portProbe = RoomStatePortProbe()
        let source = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            initialRoomStateDocument: sourceState.save(),
            replicaHandler: { _ in },
            participantsHandler: { _ in },
            connectionAttemptHandler: attempts.increment
        )
        let receiver = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: portProbe.set,
            replicaHandler: { _ in },
            participantsHandler: { _ in },
            roomStatePersistenceHandler: persistedProbe.update,
            roomStateSyncOverride: failingState,
            roomStateDowngradeHandler: downgrade.update
        )
        try source.start(advertise: false)
        try receiver.start(advertise: false)
        defer { source.stop(); receiver.stop() }
        let port = try #require(portProbe.wait())

        source.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil(timeout: 5) { failingState.receiveAttempts > 0 })
        #expect(waitUntil(timeout: 5) { downgrade.contains("a") })
        #expect(waitUntil(timeout: 5) { persistedProbe.chatTexts.contains("seed") })
        source.publishChat("legacy fallback")

        #expect(waitUntil(timeout: 5) { persistedProbe.chatTexts.contains("legacy fallback") })
        Thread.sleep(forTimeInterval: 0.5)
        #expect(attempts.value == 1)
    }

    @Test("A peer-initiated downgrade backfills legacy events already in the replica")
    func peerInitiatedDowngradeBackfillsReplica() throws {
        let room = RoomConfiguration(id: "mesh-peer-backfill", name: "Peer backfill")
        let seed = chat(roomID: room.id, id: "legacy-seed", counter: 1, text: "legacy seed")
        let failingState = try ReceiveFailingRoomStateSync(roomID: room.id)
        let targetDocument = RoomStateDocumentProbe(roomID: room.id)
        let targetDowngrade = RoomStateDowngradeProbe()
        let portProbe = RoomStatePortProbe()
        let source = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            initialEvents: [seed],
            replicaHandler: { _ in },
            participantsHandler: { _ in },
            roomStateSyncOverride: failingState
        )
        let target = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: portProbe.set,
            replicaHandler: { _ in },
            participantsHandler: { _ in },
            roomStatePersistenceHandler: targetDocument.update,
            roomStateDowngradeHandler: targetDowngrade.update
        )
        try source.start(advertise: false)
        try target.start(advertise: false)
        defer { source.stop(); target.stop() }
        let port = try #require(portProbe.wait())

        source.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))

        #expect(waitUntil(timeout: 5) { failingState.receiveAttempts > 0 })
        #expect(waitUntil(timeout: 5) { targetDowngrade.contains("a") })
        #expect(waitUntil(timeout: 5) { targetDocument.chatTexts.contains("legacy seed") })
    }

    @Test("A global Automerge fallback is advertised to connected peers")
    func globalFallbackIsAdvertised() throws {
        let room = RoomConfiguration(id: "mesh-global-failure", name: "Global failure")
        let failingState = try IngestFailingRoomStateSync(roomID: room.id)
        let persistedProbe = RoomStateDocumentProbe(roomID: room.id)
        let participants = RoomStateParticipantProbe()
        let downgrade = RoomStateDowngradeProbe()
        let portProbe = RoomStatePortProbe()
        let source = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            replicaHandler: { _ in },
            participantsHandler: { _ in },
            roomStateSyncOverride: failingState
        )
        let receiver = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: portProbe.set,
            replicaHandler: { _ in },
            participantsHandler: participants.update,
            roomStatePersistenceHandler: persistedProbe.update,
            roomStateDowngradeHandler: downgrade.update
        )
        try source.start(advertise: false)
        try receiver.start(advertise: false)
        defer { source.stop(); receiver.stop() }
        let port = try #require(portProbe.wait())

        source.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil(timeout: 5) { participants.count == 2 })
        source.publishChat("trigger fallback")
        #expect(waitUntil(timeout: 5) { failingState.ingestAttempts > 0 })
        #expect(waitUntil(timeout: 5) { downgrade.contains("a") })
        source.publishChat("after global fallback")

        #expect(waitUntil(timeout: 5) {
            persistedProbe.chatTexts.contains("after global fallback")
        })
    }

    @Test("A fallback during authentication reaches the peer after the handshake")
    func fallbackDuringAuthenticationIsAdvertised() throws {
        let room = RoomConfiguration(id: "mesh-auth-fallback", name: "Auth fallback")
        let sourceDowngrade = RoomStateDowngradeProbe()
        let receiverDowngrade = RoomStateDowngradeProbe()
        let participants = RoomStateParticipantProbe()
        let portProbe = RoomStatePortProbe()
        let source = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            replicaHandler: { _ in },
            participantsHandler: { _ in },
            roomStateDowngradeHandler: sourceDowngrade.update
        )
        let receiver = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: portProbe.set,
            replicaHandler: { _ in },
            participantsHandler: participants.update,
            roomStateDowngradeHandler: receiverDowngrade.update,
            disableRoomStateSyncDuringAuthenticationForTesting: true
        )
        try source.start(advertise: false)
        try receiver.start(advertise: false)
        defer { source.stop(); receiver.stop() }
        let port = try #require(portProbe.wait())

        source.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))

        #expect(waitUntil(timeout: 5) { participants.count == 2 })
        #expect(waitUntil(timeout: 5) { receiverDowngrade.contains("a") })
        #expect(waitUntil(timeout: 5) { sourceDowngrade.contains("b") })
    }

    @Test("Malformed durable-sync framing downgrades without reconnecting")
    func malformedFramingDowngradesWithoutReconnect() throws {
        let room = RoomConfiguration(id: "mesh-malformed-sync", name: "Malformed sync")
        let participants = RoomStateParticipantProbe()
        let downgrade = RoomStateDowngradeProbe()
        let attempts = RoomStateCounterProbe()
        let portProbe = RoomStatePortProbe()
        let source = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            replicaHandler: { _ in },
            participantsHandler: { _ in },
            connectionAttemptHandler: attempts.increment
        )
        let receiver = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: portProbe.set,
            replicaHandler: { _ in },
            participantsHandler: participants.update,
            roomStateDowngradeHandler: downgrade.update
        )
        try source.start(advertise: false)
        try receiver.start(advertise: false)
        defer { source.stop(); receiver.stop() }
        let port = try #require(portProbe.wait())

        source.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil(timeout: 5) { participants.count == 2 })
        source.sendMalformedRoomStateSyncForTesting(peerID: "b")

        #expect(waitUntil(timeout: 5) { downgrade.contains("a") })
        Thread.sleep(forTimeInterval: 0.5)
        #expect(attempts.value == 1)
    }

    @Test("A busy peer can queue a bounded burst of durable-sync work")
    func healthyInboundBurstDoesNotDowngrade() throws {
        let room = RoomConfiguration(id: "mesh-sync-burst", name: "Sync burst")
        let slowState = try SlowReceivingRoomStateSync(roomID: room.id)
        let participants = RoomStateParticipantProbe()
        let downgrade = RoomStateDowngradeProbe()
        let portProbe = RoomStatePortProbe()
        let source = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            replicaHandler: { _ in },
            participantsHandler: { _ in }
        )
        let receiver = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: portProbe.set,
            replicaHandler: { _ in },
            participantsHandler: participants.update,
            roomStateSyncOverride: slowState,
            roomStateDowngradeHandler: downgrade.update
        )
        try source.start(advertise: false)
        try receiver.start(advertise: false)
        defer { source.stop(); receiver.stop() }
        let port = try #require(portProbe.wait())

        source.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil(timeout: 5) { participants.count == 2 })
        source.sendRoomStateSyncMessagesForTesting(
            (0..<8).map { Data([UInt8($0)]) },
            peerID: "b"
        )

        #expect(waitUntil(timeout: 5) { slowState.receiveAttempts >= 8 })
        #expect(!downgrade.contains("a"))
    }

    @Test("Exceeding the durable-sync work backlog downgrades the link")
    func inboundBacklogOverflowDowngrades() throws {
        let room = RoomConfiguration(id: "mesh-sync-backlog", name: "Sync backlog")
        let slowState = try SlowReceivingRoomStateSync(roomID: room.id)
        let participants = RoomStateParticipantProbe()
        let downgrade = RoomStateDowngradeProbe()
        let portProbe = RoomStatePortProbe()
        let source = MeshControlPlane(
            room: room, nodeID: "a", displayName: "A",
            replicaHandler: { _ in }, participantsHandler: { _ in }
        )
        let receiver = MeshControlPlane(
            room: room, nodeID: "b", displayName: "B",
            listenerReadyHandler: portProbe.set,
            replicaHandler: { _ in }, participantsHandler: participants.update,
            roomStateSyncOverride: slowState,
            roomStateDowngradeHandler: downgrade.update
        )
        try source.start(advertise: false)
        try receiver.start(advertise: false)
        defer { source.stop(); receiver.stop() }
        let port = try #require(portProbe.wait())

        source.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil(timeout: 5) { participants.count == 2 })
        source.sendRoomStateSyncMessagesForTesting(
            (0..<40).map { Data([UInt8($0)]) }, peerID: "b"
        )

        #expect(waitUntil(timeout: 5) { downgrade.contains("a") })
    }

    @Test("Out-of-order durable-sync chunks downgrade the link")
    func outOfOrderChunksDowngrade() throws {
        let room = RoomConfiguration(id: "mesh-sync-chunk-order", name: "Chunk order")
        let participants = RoomStateParticipantProbe()
        let downgrade = RoomStateDowngradeProbe()
        let portProbe = RoomStatePortProbe()
        let source = MeshControlPlane(
            room: room, nodeID: "a", displayName: "A",
            replicaHandler: { _ in }, participantsHandler: { _ in }
        )
        let receiver = MeshControlPlane(
            room: room, nodeID: "b", displayName: "B",
            listenerReadyHandler: portProbe.set,
            replicaHandler: { _ in }, participantsHandler: participants.update,
            roomStateDowngradeHandler: downgrade.update
        )
        try source.start(advertise: false)
        try receiver.start(advertise: false)
        defer { source.stop(); receiver.stop() }
        let port = try #require(portProbe.wait())

        source.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil(timeout: 5) { participants.count == 2 })
        source.sendRoomStateSyncEnvelopesForTesting([
            MeshEnvelope(
                type: "room_state_sync",
                roomStateSyncID: "bad-order",
                roomStateSyncChunkIndex: 1,
                roomStateSyncChunkCount: 2,
                roomStateSyncMessage: Data([1])
            ),
        ], peerID: "b")

        #expect(waitUntil(timeout: 5) { downgrade.contains("a") })
    }

    @Test("Stopping persists durable work already queued on the worker")
    func stopPersistsQueuedDurableWork() throws {
        let room = RoomConfiguration(id: "mesh-stop-save", name: "Stop save")
        let blockingState = try BlockingIngestRoomStateSync(roomID: room.id)
        let persistedProbe = RoomStateDocumentProbe(roomID: room.id)
        let control = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            replicaHandler: { _ in },
            participantsHandler: { _ in },
            roomStatePersistenceHandler: persistedProbe.update,
            roomStateSyncOverride: blockingState
        )
        try control.start(advertise: false)
        control.publishChat("last durable event")
        #expect(blockingState.waitUntilIngestStarts())

        let stopped = DispatchSemaphore(value: 0)
        control.stop { stopped.signal() }
        Thread.sleep(forTimeInterval: 0.05)
        blockingState.releaseIngest()

        #expect(stopped.wait(timeout: .now() + 5) == .success)
        #expect(persistedProbe.chatTexts.contains("last durable event"))
    }

    @Test("Compaction preserves retained state and remains syncable")
    func compactionPreservesStateAndSync() throws {
        let roomID = "room-compaction"
        let source = try AutomergeRoomStateSync(roomID: roomID)
        for batch in 0..<12 {
            _ = try source.ingest((0..<100).map { index in
                let counter = UInt64(batch * 100 + index + 1)
                return chat(
                    roomID: roomID, id: "chat-\(counter)", counter: counter,
                    text: "message \(counter)"
                )
            })
        }
        let before = try source.snapshot()
        let beforeBytes = source.save().count

        try source.compactForTesting()

        #expect(try source.snapshot() == before)
        #expect(source.save().count < beforeBytes)
        let restored = try AutomergeRoomStateSync(roomID: roomID, savedDocument: source.save())
        #expect(try restored.snapshot() == before)
        let receiver = try AutomergeRoomStateSync(roomID: roomID)
        try converge(source, receiver)
        #expect(try receiver.snapshot() == before)
    }

    private func converge(
        _ left: AutomergeRoomStateSync,
        _ right: AutomergeRoomStateSync,
        maxRounds: Int = 100
    ) throws {
        let leftState = left.makeSession()
        let rightState = right.makeSession()
        for _ in 0..<maxRounds {
            var progressed = false
            if let message = left.generateSyncMessage(for: leftState) {
                _ = try right.receiveSyncMessage(message, from: rightState)
                progressed = true
            }
            if let message = right.generateSyncMessage(for: rightState) {
                _ = try left.receiveSyncMessage(message, from: leftState)
                progressed = true
            }
            if !progressed { return }
        }
        Issue.record("Automerge peers did not converge within \(maxRounds) rounds")
    }

    private func chat(
        roomID: String,
        id: String,
        counter: UInt64,
        nodeID: String = "node",
        text: String
    ) -> MeshRoomEvent {
        MeshRoomEvent(
            id: id,
            roomID: roomID,
            version: MeshVersion(counter: counter, nodeID: nodeID),
            kind: .chat,
            senderID: nodeID,
            sender: nodeID,
            text: text
        )
    }

    private func queueAdd(roomID: String, id: String, counter: UInt64) -> MeshRoomEvent {
        MeshRoomEvent(
            id: id,
            roomID: roomID,
            version: MeshVersion(counter: counter, nodeID: "node"),
            kind: .queueAdd,
            queueItem: RoomQueueItem(id: id, title: id, url: "file:///\(id)")
        )
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }
}

private final class RoomStateReplicaProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var replica = MeshRoomReplica()
    var queueCount: Int { lock.withLock { replica.queue.count } }
    func update(_ replica: MeshRoomReplica) { lock.withLock { self.replica = replica } }
}

private final class RoomStatePortProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var port: NWEndpoint.Port?
    func set(_ port: NWEndpoint.Port) { lock.withLock { self.port = port }; ready.signal() }
    func wait() -> NWEndpoint.Port? {
        _ = ready.wait(timeout: .now() + 3)
        return lock.withLock { port }
    }
}

private final class RoomStateDocumentProbe: @unchecked Sendable {
    private let roomID: String
    private let lock = NSLock()
    private var document: Data?
    init(roomID: String) { self.roomID = roomID }
    var queueCount: Int {
        lock.withLock {
            guard let document,
                  let sync = try? AutomergeRoomStateSync(roomID: roomID, savedDocument: document)
            else { return 0 }
            return (try? sync.snapshot().queue.count) ?? 0
        }
    }
    var chatTexts: [String] {
        lock.withLock {
            guard let document,
                  let sync = try? AutomergeRoomStateSync(roomID: roomID, savedDocument: document)
            else { return [] }
            return (try? sync.snapshot().chatEvents.compactMap(\.text)) ?? []
        }
    }
    func update(_ data: Data) { lock.withLock { document = data } }
}

private final class RoomStateCounterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class RoomStateParticipantProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var participantCount = 0
    var count: Int { lock.withLock { participantCount } }
    func update(_ participants: [RoomParticipant]) {
        lock.withLock { participantCount = participants.count }
    }
}

private final class RoomStateDowngradeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var peerIDs = Set<String>()
    func update(_ peerID: String?) {
        guard let peerID else { return }
        lock.withLock { _ = peerIDs.insert(peerID) }
    }
    func contains(_ peerID: String) -> Bool { lock.withLock { peerIDs.contains(peerID) } }
}

private enum InjectedRoomStateSyncError: Error {
    case receive
    case ingest
}

private final class ReceiveFailingRoomStateSync: RoomStateSync, @unchecked Sendable {
    private let base: AutomergeRoomStateSync
    private let lock = NSLock()
    private var receiveCount = 0
    var receiveAttempts: Int { lock.withLock { receiveCount } }

    init(roomID: String) throws { base = try AutomergeRoomStateSync(roomID: roomID) }
    func snapshot() throws -> RoomStateSnapshot { try base.snapshot() }
    func ingest(_ events: [MeshRoomEvent]) throws -> [MeshRoomEvent] { try base.ingest(events) }
    func makeSession() -> RoomStateSyncSession { base.makeSession() }
    func generateSyncMessage(for session: RoomStateSyncSession) -> Data? {
        nil
    }
    func receiveSyncMessage(_ message: Data, from session: RoomStateSyncSession) throws -> [MeshRoomEvent] {
        lock.withLock { receiveCount += 1 }
        throw InjectedRoomStateSyncError.receive
    }
    func save() -> Data { base.save() }
}

private final class ReceiveOnlyRoomStateSync: RoomStateSync, @unchecked Sendable {
    private let base: AutomergeRoomStateSync
    private let lock = NSLock()
    private var receiveCount = 0
    var receiveAttempts: Int { lock.withLock { receiveCount } }

    init(roomID: String) throws { base = try AutomergeRoomStateSync(roomID: roomID) }
    func snapshot() throws -> RoomStateSnapshot { try base.snapshot() }
    func ingest(_ events: [MeshRoomEvent]) throws -> [MeshRoomEvent] { [] }
    func makeSession() -> RoomStateSyncSession { base.makeSession() }
    func generateSyncMessage(for session: RoomStateSyncSession) -> Data? {
        base.generateSyncMessage(for: session)
    }
    func receiveSyncMessage(_ message: Data, from session: RoomStateSyncSession) throws -> [MeshRoomEvent] {
        lock.withLock { receiveCount += 1 }
        return try base.receiveSyncMessage(message, from: session)
    }
    func save() -> Data { base.save() }
}

private final class IngestFailingRoomStateSync: RoomStateSync, @unchecked Sendable {
    private let base: AutomergeRoomStateSync
    private let lock = NSLock()
    private var ingestCount = 0
    var ingestAttempts: Int { lock.withLock { ingestCount } }

    init(roomID: String) throws { base = try AutomergeRoomStateSync(roomID: roomID) }
    func snapshot() throws -> RoomStateSnapshot { try base.snapshot() }
    func ingest(_ events: [MeshRoomEvent]) throws -> [MeshRoomEvent] {
        lock.withLock { ingestCount += 1 }
        throw InjectedRoomStateSyncError.ingest
    }
    func makeSession() -> RoomStateSyncSession { base.makeSession() }
    func generateSyncMessage(for session: RoomStateSyncSession) -> Data? {
        base.generateSyncMessage(for: session)
    }
    func receiveSyncMessage(_ message: Data, from session: RoomStateSyncSession) throws -> [MeshRoomEvent] {
        try base.receiveSyncMessage(message, from: session)
    }
    func save() -> Data { base.save() }
}

private final class SlowReceivingRoomStateSync: RoomStateSync, @unchecked Sendable {
    private let base: AutomergeRoomStateSync
    private let lock = NSLock()
    private var receiveCount = 0
    var receiveAttempts: Int { lock.withLock { receiveCount } }

    init(roomID: String) throws { base = try AutomergeRoomStateSync(roomID: roomID) }
    func snapshot() throws -> RoomStateSnapshot { try base.snapshot() }
    func ingest(_ events: [MeshRoomEvent]) throws -> [MeshRoomEvent] { try base.ingest(events) }
    func makeSession() -> RoomStateSyncSession { base.makeSession() }
    func generateSyncMessage(for session: RoomStateSyncSession) -> Data? { nil }
    func receiveSyncMessage(_ message: Data, from session: RoomStateSyncSession) throws -> [MeshRoomEvent] {
        lock.withLock { receiveCount += 1 }
        Thread.sleep(forTimeInterval: 0.05)
        return []
    }
    func save() -> Data { base.save() }
}

private final class BlockingIngestRoomStateSync: RoomStateSync, @unchecked Sendable {
    private let base: AutomergeRoomStateSync
    private let ingestStarted = DispatchSemaphore(value: 0)
    private let ingestRelease = DispatchSemaphore(value: 0)

    init(roomID: String) throws { base = try AutomergeRoomStateSync(roomID: roomID) }
    func snapshot() throws -> RoomStateSnapshot { try base.snapshot() }
    func ingest(_ events: [MeshRoomEvent]) throws -> [MeshRoomEvent] {
        ingestStarted.signal()
        _ = ingestRelease.wait(timeout: .now() + 5)
        return try base.ingest(events)
    }
    func makeSession() -> RoomStateSyncSession { base.makeSession() }
    func generateSyncMessage(for session: RoomStateSyncSession) -> Data? {
        base.generateSyncMessage(for: session)
    }
    func receiveSyncMessage(_ message: Data, from session: RoomStateSyncSession) throws -> [MeshRoomEvent] {
        try base.receiveSyncMessage(message, from: session)
    }
    func save() -> Data { base.save() }
    func waitUntilIngestStarts() -> Bool {
        ingestStarted.wait(timeout: .now() + 3) == .success
    }
    func releaseIngest() { ingestRelease.signal() }
}
