import Foundation
import Network
import Testing
@testable import WERAI
import WERAICore

struct MeshRoomTests {
    @Test("Lamport ordering is not controlled by persisted wall clocks")
    func lamportOrderingPrecedesWallTime() {
        let olderCounter = MeshVersion(counter: 1, nodeID: "z", wallTimeMillis: UInt64.max)
        let newerCounter = MeshVersion(counter: 2, nodeID: "a", wallTimeMillis: 0)
        #expect(olderCounter < newerCounter)
    }

    @Test("Private authentication binds its response to a fresh challenge")
    func privateChallengeResponseIsNotReplayable() {
        let first = MeshControlPlane.makeChallengeResponse(
            roomID: "room", accessKey: "secret", nonce: "nonce-one", nodeID: "peer"
        )
        let second = MeshControlPlane.makeChallengeResponse(
            roomID: "room", accessKey: "secret", nonce: "nonce-two", nodeID: "peer"
        )
        #expect(first != second)
        #expect(first != MeshControlPlane.makeAccessProof(roomID: "room", accessKey: "secret"))
    }

    @Test("Mesh decoder rejects an unterminated oversized envelope")
    func decoderBoundsUnterminatedInput() {
        let decoder = MeshEnvelopeDecoder()
        let data = Data(repeating: 0x41, count: MeshEnvelopeDecoder.maximumLineBytes + 1)
        #expect(decoder.append(data).isEmpty)
        #expect(decoder.isOverflowed)
    }

    @Test("Simultaneous broadcaster claims converge by epoch then node ID")
    func simultaneousBroadcasterClaimsConverge() {
        let roomID = UUID().uuidString
        let claimA = broadcasterEvent(roomID: roomID, author: "a", owner: "a", epoch: 7, active: true)
        let claimB = broadcasterEvent(roomID: roomID, author: "b", owner: "b", epoch: 7, active: true)
        var left = MeshRoomReplica(events: [claimA, claimB])
        var right = MeshRoomReplica(events: [claimB, claimA])

        #expect(left.broadcaster?.nodeID == "b")
        #expect(right.broadcaster?.nodeID == "b")
        #expect(left.broadcaster == right.broadcaster)

        let newerClaim = broadcasterEvent(roomID: roomID, author: "a", owner: "a", epoch: 8, active: true)
        let staleStop = broadcasterEvent(roomID: roomID, author: "b", owner: "b", epoch: 7, active: false)
        _ = left.merge([newerClaim, staleStop])
        _ = right.merge([staleStop, newerClaim])
        #expect(left.broadcaster?.nodeID == "a")
        #expect(right.broadcaster?.nodeID == "a")
        #expect(left.broadcaster?.epoch == 8)
    }

    @Test("Video state belongs only to the current broadcaster epoch")
    func videoStateIsScopedToBroadcasterEpoch() {
        let roomID = UUID().uuidString
        let oldClaim = broadcasterEvent(roomID: roomID, author: "a", owner: "a", epoch: 1, active: true)
        let oldVideo = MeshRoomEvent(
            roomID: roomID,
            version: MeshVersion(counter: 2, nodeID: "a"),
            kind: .video,
            broadcasterID: "a",
            broadcasterEpoch: 1,
            videoEnabled: true
        )
        var replica = MeshRoomReplica(events: [oldClaim, oldVideo])
        #expect(replica.videoEnabled)

        let newClaim = broadcasterEvent(roomID: roomID, author: "b", owner: "b", epoch: 2, active: true)
        _ = replica.merge([newClaim])
        #expect(!replica.videoEnabled)

        let newVideo = MeshRoomEvent(
            roomID: roomID,
            version: MeshVersion(counter: 2, nodeID: "b"),
            kind: .video,
            broadcasterID: "b",
            broadcasterEpoch: 2,
            videoEnabled: true
        )
        let delayedOldStop = MeshRoomEvent(
            roomID: roomID,
            version: MeshVersion(counter: 99, nodeID: "a"),
            kind: .video,
            broadcasterID: "a",
            broadcasterEpoch: 1,
            videoEnabled: false
        )
        _ = replica.merge([newVideo, delayedOldStop])
        #expect(replica.videoEnabled)
    }

    @Test("Replicas converge and version vectors request only missing feed entries")
    func replicaConvergence() {
        let roomID = UUID().uuidString
        let first = MeshRoomEvent(
            roomID: roomID,
            version: MeshVersion(counter: 1, nodeID: "a", wallTimeMillis: 100),
            kind: .chat,
            sender: "A",
            text: "hello"
        )
        let second = MeshRoomEvent(
            roomID: roomID,
            version: MeshVersion(counter: 1, nodeID: "b", wallTimeMillis: 101),
            kind: .chat,
            sender: "B",
            text: "world"
        )
        var left = MeshRoomReplica(events: [first])
        var right = MeshRoomReplica(events: [second])
        #expect(left.missingEvents(comparedWith: right.versionVector) == [first])
        #expect(right.missingEvents(comparedWith: left.versionVector) == [second])
        _ = left.merge(right.events)
        _ = right.merge(left.events)
        #expect(left == right)
        #expect(left.chatEvents.map(\.text) == ["hello", "world"])
    }

    @Test("A three-peer room keeps replicating after its creator leaves")
    func creatorIndependentMesh() throws {
        let room = RoomConfiguration(name: "Mesh test", creatorPeerID: "a")
        let a = MeshProbe()
        let b = MeshProbe()
        let c = MeshProbe()
        let aReady = PortProbe()
        let bReady = PortProbe()
        let cReady = PortProbe()
        let nodeA = makeNode(room: room, id: "a", probe: a, ports: aReady)
        let nodeB = makeNode(room: room, id: "b", probe: b, ports: bReady)
        let nodeC = makeNode(room: room, id: "c", probe: c, ports: cReady)
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        try nodeC.start(advertise: false)
        defer { nodeB.stop(); nodeC.stop() }
        guard let portB = bReady.wait(), let portC = cReady.wait() else {
            Issue.record("Mesh listeners did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portB))
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portC))
        nodeB.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portC))
        #expect(waitUntil { a.participantCount == 3 && b.participantCount == 3 && c.participantCount == 3 })

        nodeA.publishChat("from creator")
        #expect(waitUntil { a.chatCount == 1 && b.chatCount == 1 && c.chatCount == 1 })
        nodeA.stop()
        #expect(waitUntil { b.participantCount == 2 && c.participantCount == 2 })

        nodeB.publishChat("after creator left")
        #expect(waitUntil { b.chatCount == 2 && c.chatCount == 2 })
        #expect(b.chatTexts == c.chatTexts)
    }

    @Test("A crashed broadcaster leaves the surviving room idle")
    func crashedBroadcasterBecomesIdle() throws {
        let room = RoomConfiguration(name: "Crash test", creatorPeerID: "a")
        let a = MeshProbe()
        let b = MeshProbe()
        let c = MeshProbe()
        let aReady = PortProbe()
        let bReady = PortProbe()
        let cReady = PortProbe()
        let nodeA = makeNode(room: room, id: "a", probe: a, ports: aReady)
        let nodeB = makeNode(room: room, id: "b", probe: b, ports: bReady)
        let nodeC = makeNode(room: room, id: "c", probe: c, ports: cReady)
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        try nodeC.start(advertise: false)
        defer { nodeB.stop(); nodeC.stop() }
        guard let portB = bReady.wait(), let portC = cReady.wait() else {
            Issue.record("Mesh listeners did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portB))
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portC))
        nodeB.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portC))
        #expect(waitUntil { a.participantCount == 3 && b.participantCount == 3 && c.participantCount == 3 })

        nodeA.publishBroadcaster(active: true, mediaServiceName: "media-a")
        #expect(waitUntil { a.broadcasterID == "a" && b.broadcasterID == "a" && c.broadcasterID == "a" })
        nodeA.stop()

        #expect(waitUntil { b.participantCount == 2 && c.participantCount == 2 })
        #expect(waitUntil { b.broadcasterID == nil && c.broadcasterID == nil })
        nodeC.publishBroadcaster(active: true, mediaServiceName: "media-c")
        #expect(waitUntil { b.broadcasterID == "c" && c.broadcasterID == "c" })
    }

    @Test("A live broadcaster survives one flapped mesh edge")
    func broadcasterSurvivesSingleEdgeFlap() throws {
        let room = RoomConfiguration(name: "Edge flap test", creatorPeerID: "a")
        let a = MeshProbe()
        let b = MeshProbe()
        let c = MeshProbe()
        let aReady = PortProbe()
        let bReady = PortProbe()
        let cReady = PortProbe()
        let nodeA = makeNode(room: room, id: "a", probe: a, ports: aReady)
        let nodeB = makeNode(room: room, id: "b", probe: b, ports: bReady)
        let nodeC = makeNode(room: room, id: "c", probe: c, ports: cReady)
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        try nodeC.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop(); nodeC.stop() }
        guard let portB = bReady.wait(), let portC = cReady.wait() else {
            Issue.record("Mesh listeners did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portB))
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portC))
        nodeB.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portC))
        #expect(waitUntil { a.participantCount == 3 && b.participantCount == 3 && c.participantCount == 3 })

        nodeA.publishBroadcaster(active: true, mediaServiceName: "media-a")
        #expect(waitUntil { a.broadcasterID == "a" && b.broadcasterID == "a" && c.broadcasterID == "a" })
        nodeA.disconnectForTesting(peerID: "b")
        #expect(waitUntil { a.participantCount == 2 && b.participantCount == 2 })
        #expect(waitUntil { a.participantCount == 3 && b.participantCount == 3 && c.participantCount == 3 })

        // Wait longer than the broadcaster lease. A's heartbeat still reaches B via C.
        Thread.sleep(forTimeInterval: 2.8)
        #expect(a.broadcasterID == "a")
        #expect(b.broadcasterID == "a")
        #expect(c.broadcasterID == "a")
    }

    @Test("A restarted peer reseeds heartbeat sequence and can broadcast after rejoining")
    func restartedPeerHeartbeatGeneration() throws {
        let room = RoomConfiguration(name: "Restart test", creatorPeerID: "a")
        let a = MeshProbe()
        let oldB = MeshProbe()
        let aNode = makeNode(room: room, id: "a", probe: a, ports: PortProbe())
        let oldReady = PortProbe()
        let oldBNode = makeNode(room: room, id: "b", probe: oldB, ports: oldReady)
        try aNode.start(advertise: false)
        try oldBNode.start(advertise: false)
        defer { aNode.stop() }
        guard let oldPort = oldReady.wait() else { Issue.record("Old peer did not start"); return }
        aNode.connectForTesting(to: .hostPort(host: "127.0.0.1", port: oldPort))
        #expect(waitUntil { a.participantCount == 2 })
        Thread.sleep(forTimeInterval: 0.5) // ensure the old heartbeat sequence is observed
        oldBNode.stop()
        #expect(waitUntil { a.participantCount == 1 })

        let newB = MeshProbe()
        let newReady = PortProbe()
        let newBNode = makeNode(room: room, id: "b", probe: newB, ports: newReady)
        try newBNode.start(advertise: false)
        defer { newBNode.stop() }
        guard let newPort = newReady.wait() else { Issue.record("Restarted peer did not start"); return }
        aNode.connectForTesting(to: .hostPort(host: "127.0.0.1", port: newPort))
        #expect(waitUntil { a.participantCount == 2 && newB.participantCount == 2 })
        newBNode.publishBroadcaster(active: true, mediaServiceName: "media-b-restarted")
        #expect(waitUntil { a.broadcasterID == "b" && newB.broadcasterID == "b" })
        Thread.sleep(forTimeInterval: 2.8)
        #expect(a.broadcasterID == "b")
        #expect(newB.broadcasterID == "b")
    }

    private func broadcasterEvent(
        roomID: String,
        author: String,
        owner: String,
        epoch: UInt64,
        active: Bool
    ) -> MeshRoomEvent {
        MeshRoomEvent(
            roomID: roomID,
            version: MeshVersion(counter: epoch, nodeID: author, wallTimeMillis: epoch),
            kind: .broadcaster,
            broadcasterID: owner,
            broadcasterEpoch: epoch,
            mediaServiceName: active ? "media-\(owner)" : nil,
            isBroadcasting: active
        )
    }

    @Test("Public rooms admit a peer without a shared secret")
    func publicRoomAdmission() throws {
        let room = RoomConfiguration(name: "Public test", creatorPeerID: "a")
        let a = MeshProbe()
        let b = MeshProbe()
        let ready = PortProbe()
        let nodeA = makeNode(room: room, id: "a", probe: a, ports: PortProbe())
        let nodeB = makeNode(room: room, id: "b", probe: b, ports: ready)
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop() }
        guard let port = ready.wait() else {
            Issue.record("Public room listener did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil { a.participantCount == 2 && b.participantCount == 2 })
    }

    @Test("Private rooms admit only peers with the same room secret")
    func privateRoomAdmission() throws {
        let roomID = UUID().uuidString
        let validRoom = RoomConfiguration(
            id: roomID,
            name: "Private test",
            creatorPeerID: "a",
            isPrivate: true,
            accessKey: "correct horse battery staple"
        )
        let invalidRoom = RoomConfiguration(
            id: roomID,
            name: "Private test",
            creatorPeerID: "a",
            isPrivate: true,
            accessKey: "wrong secret"
        )
        let a = MeshProbe()
        let b = MeshProbe()
        let c = MeshProbe()
        let bReady = PortProbe()
        let cReady = PortProbe()
        let nodeA = makeNode(room: validRoom, id: "a", probe: a, ports: PortProbe())
        let nodeB = makeNode(room: validRoom, id: "b", probe: b, ports: bReady)
        let nodeC = makeNode(room: invalidRoom, id: "c", probe: c, ports: cReady)
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        try nodeC.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop(); nodeC.stop() }
        guard let portB = bReady.wait(), let portC = cReady.wait() else {
            Issue.record("Private room listeners did not start")
            return
        }

        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portB))
        #expect(waitUntil { a.participantCount == 2 && b.participantCount == 2 })

        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portC))
        Thread.sleep(forTimeInterval: 0.15)
        #expect(a.participantCount == 2)
        #expect(c.participantCount == 1)
    }

    @Test("Queue tombstones and concurrent chat merge independent of arrival order")
    func durableStateMerging() {
        let roomID = UUID().uuidString
        let item = RoomQueueItem(id: "track", title: "A track", url: "https://example.com/track")
        let events = [
            MeshRoomEvent(
                id: "add",
                roomID: roomID,
                version: MeshVersion(counter: 1, nodeID: "a", wallTimeMillis: 100),
                kind: .queueAdd,
                queueItem: item
            ),
            MeshRoomEvent(
                id: "chat-a",
                roomID: roomID,
                version: MeshVersion(counter: 2, nodeID: "a", wallTimeMillis: 110),
                kind: .chat,
                sender: "A",
                text: "first"
            ),
            MeshRoomEvent(
                id: "chat-b",
                roomID: roomID,
                version: MeshVersion(counter: 1, nodeID: "b", wallTimeMillis: 120),
                kind: .chat,
                sender: "B",
                text: "second"
            ),
            MeshRoomEvent(
                id: "remove",
                roomID: roomID,
                version: MeshVersion(counter: 3, nodeID: "a", wallTimeMillis: 130),
                kind: .queueRemove,
                queueItemID: item.id
            ),
        ]
        let forward = MeshRoomReplica(events: events)
        let reverse = MeshRoomReplica(events: events.reversed())
        #expect(forward == reverse)
        #expect(forward.queue.isEmpty)
        #expect(forward.chatEvents.compactMap(\.text) == ["second", "first"])
    }

    @Test("Room event persistence retains durable state and recent bounded chat")
    func roomEventPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("werai-mesh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomStore(fileURL: directory.appendingPathComponent("rooms.json"))
        let roomID = UUID().uuidString
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        var events = (0..<510).map { index in
            MeshRoomEvent(
                id: "chat-\(index)",
                roomID: roomID,
                version: MeshVersion(counter: UInt64(index + 1), nodeID: "a", wallTimeMillis: now),
                kind: .chat,
                sender: "A",
                text: "message-\(index)"
            )
        }
        events.append(MeshRoomEvent(
            id: "old-chat",
            roomID: roomID,
            version: MeshVersion(counter: 700, nodeID: "a", wallTimeMillis: now - 8 * 86_400_000),
            kind: .chat,
            sender: "A",
            text: "expired"
        ))
        events.append(MeshRoomEvent(
            id: "queue-add",
            roomID: roomID,
            version: MeshVersion(counter: 1, nodeID: "b", wallTimeMillis: now),
            kind: .queueAdd,
            queueItem: RoomQueueItem(id: "saved", title: "Saved", url: "https://example.com")
        ))
        events.append(MeshRoomEvent(
            id: "ephemeral-broadcaster",
            roomID: roomID,
            version: MeshVersion(counter: 2, nodeID: "b", wallTimeMillis: now),
            kind: .broadcaster,
            broadcasterID: "b",
            mediaServiceName: "temporary",
            isBroadcasting: true
        ))
        events.append(MeshRoomEvent(
            id: "playback-old", roomID: roomID,
            version: MeshVersion(counter: 3, nodeID: "b", wallTimeMillis: now),
            kind: .playback, nowPlaying: NowPlayingMedia(title: "Old")
        ))
        events.append(MeshRoomEvent(
            id: "playback-new", roomID: roomID,
            version: MeshVersion(counter: 4, nodeID: "b", wallTimeMillis: now),
            kind: .playback, nowPlaying: NowPlayingMedia(title: "New")
        ))
        let removed = RoomQueueItem(id: "removed", title: "Removed", url: "https://example.com/removed")
        events.append(MeshRoomEvent(
            id: "removed-add", roomID: roomID,
            version: MeshVersion(counter: 5, nodeID: "b", wallTimeMillis: now),
            kind: .queueAdd, queueItem: removed
        ))
        events.append(MeshRoomEvent(
            id: "removed-tombstone", roomID: roomID,
            version: MeshVersion(counter: 6, nodeID: "b", wallTimeMillis: now),
            kind: .queueRemove, queueItemID: removed.id
        ))

        store.saveEvents(events, roomID: roomID)
        let persisted = store.loadEvents(roomID: roomID)
        let restored = MeshRoomReplica(events: persisted)
        #expect(restored.chatEvents.count == 500)
        #expect(!restored.chatEvents.contains { $0.text == "expired" })
        #expect(restored.queue.map(\.id) == ["saved"])
        #expect(restored.broadcaster == nil)
        #expect(persisted.filter { $0.kind == .playback }.map(\.id) == ["playback-new"])
        #expect(persisted.contains { $0.id == "removed-tombstone" })
        #expect(!persisted.contains { $0.id == "removed-add" })
    }

    private func makeNode(room: RoomConfiguration, id: String, probe: MeshProbe, ports: PortProbe) -> MeshControlPlane {
        MeshControlPlane(
            room: room,
            nodeID: id,
            displayName: id.uppercased(),
            listenerReadyHandler: { ports.set($0) },
            replicaHandler: { probe.update(replica: $0) },
            participantsHandler: { probe.update(participants: $0) }
        )
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }
}

private final class PortProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: NWEndpoint.Port?
    func set(_ port: NWEndpoint.Port) { lock.withLock { value = port }; semaphore.signal() }
    func wait() -> NWEndpoint.Port? {
        _ = semaphore.wait(timeout: .now() + 3)
        return lock.withLock { value }
    }
}

private final class MeshProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var replica = MeshRoomReplica()
    private var participants = [RoomParticipant]()
    var participantCount: Int { lock.withLock { participants.count } }
    var chatCount: Int { lock.withLock { replica.chatEvents.count } }
    var chatTexts: [String?] { lock.withLock { replica.chatEvents.map(\.text) } }
    var broadcasterID: String? { lock.withLock { replica.broadcaster?.nodeID } }
    func update(replica: MeshRoomReplica) { lock.withLock { self.replica = replica } }
    func update(participants: [RoomParticipant]) { lock.withLock { self.participants = participants } }
}
