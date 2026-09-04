import Foundation
import Network
import Testing
@testable import WERAI
import WERAICore

struct MeshRoomTests {
    @Test("Room discovery and media allow nearby peer-to-peer paths")
    func nearbyPeerToPeerNetworking() {
        let tcp = LocalNetworkParameters.tcp()
        #expect(tcp.includePeerToPeer)
        let tcpOptions = tcp.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
        #expect(tcpOptions?.enableKeepalive == true)
        #expect(tcpOptions?.keepaliveIdle == 5)
        #expect(tcpOptions?.keepaliveInterval == 2)
        #expect(tcpOptions?.keepaliveCount == 3)
        #expect(LocalNetworkParameters.udp().includePeerToPeer)
    }

    @Test("Emoji identity and bounded profile images remain wire-compatible")
    func identityProfileWireCompatibility() throws {
        let profileImage = Data(repeating: 0x5A, count: DeviceAppearance.maximumProfileImageBytes)
        let envelope = MeshEnvelope(
            type: "hello",
            nodeID: "peer",
            deviceIcon: "🦊",
            profileImageData: profileImage
        )
        let encoded = try envelope.encodedLine()
        let decoded = try #require(MeshEnvelopeDecoder().append(encoded).first)

        #expect(decoded.deviceIcon == "🦊")
        #expect(decoded.profileImageData == profileImage)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"deviceIcon\":\"🦊\""))

        let legacy = try JSONDecoder().decode(
            MeshEnvelope.self,
            from: Data(#"{"type":"hello","deviceIcon":"🦊"}"#.utf8)
        )
        #expect(legacy.deviceIcon == "🦊")
        #expect(legacy.profileImageData == nil)

        let oversized = Data(
            repeating: 0xFF,
            count: DeviceAppearance.maximumProfileImageBytes + 1
        )
        #expect(DeviceAppearance.sanitizedProfileImageData(Data()) == nil)
        #expect(DeviceAppearance.sanitizedProfileImageData(oversized) == nil)
        #expect(MeshEnvelope(type: "hello", profileImageData: oversized).profileImageData == nil)
        #expect(DeviceAppearance(icon: "laptopcomputer", colorHex: "E45B69").icon == DeviceAppearance.icons[0])

        let oversizedBase64 = oversized.base64EncodedString()
        let oversizedWire = Data(
            ("{\"type\":\"hello\",\"profileImageData\":\"" + oversizedBase64 + "\"}\n").utf8
        )
        #expect(MeshEnvelopeDecoder().append(oversizedWire).first?.profileImageData == nil)

        let oversizedParticipant = try JSONDecoder().decode(
            RoomParticipant.self,
            from: Data((
                "{\"id\":\"peer\",\"name\":\"Peer\",\"volume\":1," +
                    "\"isMuted\":false,\"profileImageData\":\"" + oversizedBase64 + "\"}"
            ).utf8)
        )
        #expect(oversizedParticipant.profileImageData == nil)
    }

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
        #expect(a.chatSenderIDs == ["a"])
        #expect(b.chatSenderIDs == ["a"])
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
        a.resetParticipantCountHistory()
        b.resetParticipantCountHistory()
        nodeA.disconnectForTesting(peerID: "b")
        #expect(waitUntil { a.participantCount == 3 && b.participantCount == 3 && c.participantCount == 3 })
        Thread.sleep(forTimeInterval: 0.8)
        #expect(a.minimumObservedParticipantCount == 3)
        #expect(b.minimumObservedParticipantCount == 3)

        // Wait longer than the broadcaster lease. A's heartbeat still reaches B via C.
        Thread.sleep(forTimeInterval: 2.8)
        #expect(a.broadcasterID == "a")
        #expect(b.broadcasterID == "a")
        #expect(c.broadcasterID == "a")
    }

    @Test("Duplicate peer links do not create a reconnect storm")
    func duplicatePeerLinksStayBounded() throws {
        #expect(!MeshControlPlane.shouldReconnectAfterRemoval(
            initiated: true,
            localID: "a",
            remoteID: "b",
            canonicalPeerExists: true
        ))
        #expect(MeshControlPlane.shouldReconnectAfterRemoval(
            initiated: true,
            localID: "a",
            remoteID: "b",
            canonicalPeerExists: false
        ))

        let room = RoomConfiguration(name: "Duplicate link test", creatorPeerID: "a")
        let a = MeshProbe()
        let b = MeshProbe()
        let ready = PortProbe()
        let attempts = CountProbe()
        let nodeA = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            replicaHandler: { a.update(replica: $0) },
            participantsHandler: { a.update(participants: $0) },
            connectionAttemptHandler: { attempts.increment() }
        )
        let nodeB = makeNode(room: room, id: "b", probe: b, ports: ready)
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop() }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        nodeA.connectForTesting(to: endpoint)
        #expect(waitUntil { a.participantCount == 2 && b.participantCount == 2 })
        nodeA.connectForTesting(to: endpoint)

        Thread.sleep(forTimeInterval: 1.2)
        #expect(attempts.count == 2)
    }

    @Test("A large room history crosses the mesh in bounded sync envelopes")
    func largeInitialSyncIsChunked() throws {
        let room = RoomConfiguration(name: "Large sync test", creatorPeerID: "a")
        let artwork = Data(repeating: 0xA5, count: 20_000)
        let events = (1...16).map { counter in
            MeshRoomEvent(
                id: "playback-\(counter)",
                roomID: room.id,
                version: MeshVersion(
                    counter: UInt64(counter),
                    nodeID: "a",
                    wallTimeMillis: UInt64(counter)
                ),
                kind: .playback,
                nowPlaying: NowPlayingMedia(
                    title: "Track \(counter)",
                    artworkData: artwork,
                    isPlaying: true
                )
            )
        }
        let unsafeEnvelope = try MeshEnvelope(type: "sync", events: events).encodedLine()
        #expect(unsafeEnvelope.count > MeshEnvelopeDecoder.maximumLineBytes)
        let chunks = MeshControlPlane.synchronizationEnvelopes(
            events: events,
            versionVector: ["a": 16]
        )
        #expect(chunks.count > 2)
        #expect(try chunks.allSatisfy {
            try $0.encodedLine().count <= MeshEnvelopeDecoder.maximumLineBytes
        })
        #expect(chunks.compactMap(\.events).flatMap { $0 }.count == events.count)
        #expect(chunks.last?.versionVector == ["a": 16])

        let a = MeshProbe()
        let b = MeshProbe()
        let ready = PortProbe()
        let nodeA = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            initialEvents: events,
            replicaHandler: { a.update(replica: $0) },
            participantsHandler: { a.update(participants: $0) }
        )
        let nodeB = makeNode(room: room, id: "b", probe: b, ports: ready)
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop() }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))

        #expect(waitUntil(timeout: 4) { b.eventCount == events.count })
    }

    @Test("A relaunched peer recovers the room's active broadcaster")
    func compactedReplicaRecoversLiveBroadcaster() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("werai-live-state-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let room = RoomConfiguration(name: "Relaunch sync test", creatorPeerID: "a")
        let claim = MeshRoomEvent(
            id: "active-claim",
            roomID: room.id,
            version: MeshVersion(counter: 1, nodeID: "b", wallTimeMillis: 1),
            kind: .broadcaster,
            broadcasterID: "b",
            broadcasterEpoch: 1,
            mediaServiceName: "active-media",
            isBroadcasting: true
        )
        let playback = MeshRoomEvent(
            id: "active-playback",
            roomID: room.id,
            version: MeshVersion(counter: 2, nodeID: "b", wallTimeMillis: 2),
            kind: .playback,
            nowPlaying: NowPlayingMedia(title: "Still playing", isPlaying: true)
        )
        let store = RoomStore(fileURL: directory.appendingPathComponent("rooms.json"))
        store.saveEvents([claim, playback], roomID: room.id)
        let compacted = store.loadEvents(roomID: room.id)
        #expect(MeshRoomReplica(events: compacted).broadcaster == nil)
        #expect(MeshRoomReplica(events: compacted).versionVector == ["b": 2])

        let a = MeshProbe()
        let relaunched = MeshProbe()
        let ready = PortProbe()
        let nodeA = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            initialEvents: [claim, playback],
            replicaHandler: { a.update(replica: $0) },
            participantsHandler: { a.update(participants: $0) }
        )
        let nodeC = MeshControlPlane(
            room: room,
            nodeID: "c",
            displayName: "C",
            initialEvents: compacted,
            listenerReadyHandler: { ready.set($0) },
            replicaHandler: { relaunched.update(replica: $0) },
            participantsHandler: { relaunched.update(participants: $0) }
        )
        try nodeA.start(advertise: false)
        try nodeC.start(advertise: false)
        defer { nodeA.stop(); nodeC.stop() }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))

        #expect(waitUntil { relaunched.broadcasterID == "b" })
    }

    @Test("Artwork accepted by the producer survives mesh validation")
    func producerSizedArtworkCrossesMesh() throws {
        let room = RoomConfiguration(name: "Artwork boundary test", creatorPeerID: "a")
        let artwork = Data(repeating: 0xA5, count: 180_000)
        let event = MeshRoomEvent(
            id: "large-artwork",
            roomID: room.id,
            version: MeshVersion(counter: 1, nodeID: "a", wallTimeMillis: 1),
            kind: .playback,
            nowPlaying: NowPlayingMedia(
                title: "Detailed artwork",
                artworkData: artwork,
                isPlaying: true
            )
        )
        let encoded = try MeshEnvelope(type: "sync", events: [event]).encodedLine()
        #expect(encoded.count <= MeshEnvelopeDecoder.maximumLineBytes)

        let a = MeshProbe()
        let b = MeshProbe()
        let ready = PortProbe()
        let nodeA = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            initialEvents: [event],
            replicaHandler: { a.update(replica: $0) },
            participantsHandler: { a.update(participants: $0) }
        )
        let nodeB = makeNode(room: room, id: "b", probe: b, ports: ready)
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop() }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))

        #expect(waitUntil { b.artworkByteCount == artwork.count })
    }

    @Test("Chunked sync never exposes a broadcaster whose stop is still in flight")
    func chunkedSyncAppliesBroadcasterLifecycleAtomically() throws {
        let room = RoomConfiguration(name: "Atomic sync test", creatorPeerID: "a")
        let claim = MeshRoomEvent(
            id: "old-claim",
            roomID: room.id,
            version: MeshVersion(counter: 1, nodeID: "b", wallTimeMillis: 1),
            kind: .broadcaster,
            broadcasterID: "b",
            broadcasterEpoch: 1,
            mediaServiceName: "dead-media",
            isBroadcasting: true
        )
        let artwork = Data(repeating: 0xA5, count: 20_000)
        let playback = (2...17).map { counter in
            MeshRoomEvent(
                id: "playback-\(counter)",
                roomID: room.id,
                version: MeshVersion(
                    counter: UInt64(counter),
                    nodeID: "b",
                    wallTimeMillis: UInt64(counter)
                ),
                kind: .playback,
                nowPlaying: NowPlayingMedia(
                    title: "Track \(counter)",
                    artworkData: artwork,
                    isPlaying: false
                )
            )
        }
        let stop = MeshRoomEvent(
            id: "old-stop",
            roomID: room.id,
            version: MeshVersion(counter: 18, nodeID: "b", wallTimeMillis: 18),
            kind: .broadcaster,
            broadcasterID: "b",
            broadcasterEpoch: 1,
            isBroadcasting: false
        )
        let chunks = MeshControlPlane.synchronizationEnvelopes(
            events: [claim] + playback + [stop],
            versionVector: ["b": 18]
        )
        #expect(chunks.count > 2)

        var replica = MeshRoomReplica()
        var observedBroadcasters = [String]()
        for envelope in chunks {
            _ = replica.merge(envelope.events ?? [])
            if let broadcaster = replica.broadcaster?.nodeID {
                observedBroadcasters.append(broadcaster)
            }
        }
        #expect(observedBroadcasters.isEmpty)
    }

    @Test("An expected peer identity mismatch does not reconnect forever")
    func expectedPeerIdentityMismatchStopsRetrying() throws {
        let room = RoomConfiguration(name: "Stale discovery test", creatorPeerID: "a")
        let a = MeshProbe()
        let b = MeshProbe()
        let ready = PortProbe()
        let attempts = CountProbe()
        let nodeA = MeshControlPlane(
            room: room,
            nodeID: "a",
            displayName: "A",
            replicaHandler: { a.update(replica: $0) },
            participantsHandler: { a.update(participants: $0) },
            connectionAttemptHandler: { attempts.increment() }
        )
        let nodeB = makeNode(room: room, id: "b", probe: b, ports: ready)
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop() }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        nodeA.connectForTesting(
            to: .hostPort(host: "127.0.0.1", port: port),
            expectedNodeID: "c"
        )

        Thread.sleep(forTimeInterval: 0.7)
        #expect(attempts.count == 1)
        #expect(a.participantCount == 1)
    }

    @Test("Identity mismatch is rejected before canonical direction validation")
    func inverseExpectedPeerIdentityMismatchStopsRetrying() throws {
        let room = RoomConfiguration(name: "Inverse stale discovery test", creatorPeerID: "b")
        let local = MeshProbe()
        let actual = MeshProbe()
        let ready = PortProbe()
        let attempts = CountProbe()
        let localNode = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            replicaHandler: { local.update(replica: $0) },
            participantsHandler: { local.update(participants: $0) },
            connectionAttemptHandler: { attempts.increment() }
        )
        let actualNode = makeNode(room: room, id: "a", probe: actual, ports: ready)
        try localNode.start(advertise: false)
        try actualNode.start(advertise: false)
        defer { localNode.stop(); actualNode.stop() }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        localNode.connectForTesting(
            to: .hostPort(host: "127.0.0.1", port: port),
            expectedNodeID: "c"
        )

        Thread.sleep(forTimeInterval: 0.7)
        #expect(attempts.count == 1)
        #expect(local.participantCount == 1)
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

    @Test("Authenticated room peers advertise their app version")
    func peerVersionDiscovery() throws {
        let room = RoomConfiguration(name: "Version test", creatorPeerID: "a")
        let ready = PortProbe()
        let versions = VersionProbe()
        let nodeA = MeshControlPlane(
            room: room, nodeID: "a", displayName: "A", appVersion: "0.12.0",
            replicaHandler: { _ in }, participantsHandler: { _ in },
            peerVersionHandler: { versions.add($0) }
        )
        let nodeB = MeshControlPlane(
            room: room, nodeID: "b", displayName: "B", appVersion: "0.12.1",
            listenerReadyHandler: { ready.set($0) },
            replicaHandler: { _ in }, participantsHandler: { _ in }
        )
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop() }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil { versions.contains("0.12.1") })
    }

    @Test("Any mesh participant can send playback control to the current broadcaster")
    func meshPlaybackControlReachesBroadcaster() throws {
        let room = RoomConfiguration(name: "Playback command test", creatorPeerID: "a")
        let ready = PortProbe()
        let a = MeshProbe()
        let b = MeshProbe()
        let commands = MediaCommandProbe()
        let nodeA = makeNode(room: room, id: "a", probe: a, ports: PortProbe())
        let nodeB = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: { ready.set($0) },
            replicaHandler: { b.update(replica: $0) },
            participantsHandler: { b.update(participants: $0) },
            mediaCommandHandler: { command, broadcasterID, epoch in
                commands.add(command, broadcasterID: broadcasterID, epoch: epoch)
                return true
            }
        )
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop() }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil { a.participantCount == 2 && b.participantCount == 2 })

        nodeB.publishBroadcaster(active: true, mediaServiceName: "test-media")
        #expect(waitUntil { a.broadcasterID == "b" && b.broadcasterID == "b" })
        let epoch = try #require(a.broadcasterEpoch)
        nodeA.publishMediaCommand(.pause, broadcasterID: "b", broadcasterEpoch: epoch)

        #expect(waitUntil { commands.values == [.pause] })
        #expect(commands.targetIDs == ["b"])
        #expect(commands.epochs == [epoch])
    }

    @Test("Stopping does not block behind an in-flight room command")
    func stoppingDoesNotDeadlockWithCommandHandler() throws {
        let room = RoomConfiguration(name: "Nonblocking stop test", creatorPeerID: "a")
        let ready = PortProbe()
        let a = MeshProbe()
        let b = MeshProbe()
        let blocker = BlockingCommandProbe()
        let nodeA = makeNode(room: room, id: "a", probe: a, ports: PortProbe())
        let nodeB = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: { ready.set($0) },
            replicaHandler: { b.update(replica: $0) },
            participantsHandler: { b.update(participants: $0) },
            mediaCommandHandler: { _, _, _ in blocker.handle() }
        )
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        defer {
            blocker.release()
            nodeA.stop()
            nodeB.stop()
        }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil { a.participantCount == 2 && b.participantCount == 2 })
        nodeB.publishBroadcaster(active: true, mediaServiceName: "test-media")
        #expect(waitUntil { a.broadcasterID == "b" })
        let epoch = try #require(a.broadcasterEpoch)
        nodeA.publishMediaCommand(.pause, broadcasterID: "b", broadcasterEpoch: epoch)
        #expect(blocker.waitUntilEntered())

        let started = Date()
        nodeB.stop()
        #expect(Date().timeIntervalSince(started) < 0.2)
    }

    @Test("Walkie-talkie targets one peer or every connected peer")
    func walkieTalkieRoutingAndIdentity() throws {
        let room = RoomConfiguration(name: "Walkie test", creatorPeerID: "a")
        let aProbe = MeshProbe()
        let bProbe = MeshProbe()
        let cProbe = MeshProbe()
        let bReady = PortProbe()
        let cReady = PortProbe()
        let bWalkie = WalkieProbe()
        let cWalkie = WalkieProbe()
        let initialProfileImage = Data([0x01, 0x02, 0x03])
        let nodeA = makeNode(room: room, id: "a", probe: aProbe, ports: PortProbe())
        let nodeB = MeshControlPlane(
            room: room, nodeID: "b", displayName: "B",
            profileImageData: initialProfileImage,
            listenerReadyHandler: { bReady.set($0) },
            replicaHandler: { bProbe.update(replica: $0) },
            participantsHandler: { bProbe.update(participants: $0) },
            walkieTalkieHandler: { bWalkie.add($0) }
        )
        let nodeC = MeshControlPlane(
            room: room, nodeID: "c", displayName: "C",
            listenerReadyHandler: { cReady.set($0) },
            replicaHandler: { cProbe.update(replica: $0) },
            participantsHandler: { cProbe.update(participants: $0) },
            walkieTalkieHandler: { cWalkie.add($0) }
        )
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        try nodeC.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop(); nodeC.stop() }
        guard let portB = bReady.wait(), let portC = cReady.wait() else {
            Issue.record("Walkie peers did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portB))
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portC))
        #expect(waitUntil { aProbe.participantCount == 3 })
        #expect(aProbe.participant(id: "b")?.profileImageData == initialProfileImage)

        nodeA.publishWalkieTalkie(.init(
            kind: .audio, senderID: "a", senderName: "A", targetID: "b",
            sessionID: "targeted", sequence: 1, pcm16Mono: Data([0, 0])
        ))
        #expect(waitUntil { bWalkie.count == 1 })
        #expect(cWalkie.count == 0)

        nodeA.publishWalkieTalkie(.init(
            kind: .began, senderID: "a", senderName: "A", targetID: nil,
            sessionID: "all"
        ))
        #expect(waitUntil { bWalkie.count == 2 && cWalkie.count == 1 })

        let profileImage = Data([0x89, 0x50, 0x4E, 0x47])
        nodeB.updateIdentity(
            name: "Studio Mac",
            icon: "🦊",
            colorHex: "E45B69",
            profileImageData: profileImage
        )
        #expect(waitUntil { aProbe.participant(id: "b")?.name == "Studio Mac" })
        #expect(aProbe.participant(id: "b")?.icon == "🦊")
        #expect(aProbe.participant(id: "b")?.colorHex == "E45B69")
        #expect(aProbe.participant(id: "b")?.profileImageData == profileImage)
        #expect(MeshControlPlane.identityEnvelopeType == "display_name")

        nodeB.updateIdentity(
            name: "Studio Mac",
            icon: "🦊",
            colorHex: "E45B69",
            profileImageData: nil
        )
        #expect(waitUntil { aProbe.participant(id: "b")?.profileImageData == nil })
    }

    @Test("Peer-provided appearance values are sanitized")
    func invalidPeerAppearanceIsSanitized() throws {
        let room = RoomConfiguration(name: "Appearance test", creatorPeerID: "a")
        let a = MeshProbe()
        let b = MeshProbe()
        let ready = PortProbe()
        let nodeA = makeNode(room: room, id: "a", probe: a, ports: PortProbe())
        let nodeB = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            deviceIcon: "not-an-sf-symbol-we-allow",
            deviceColorHex: "NOTHEX",
            profileImageData: Data(
                repeating: 0xFF,
                count: DeviceAppearance.maximumProfileImageBytes + 1
            ),
            listenerReadyHandler: { ready.set($0) },
            replicaHandler: { b.update(replica: $0) },
            participantsHandler: { b.update(participants: $0) }
        )
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop() }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil { a.participantCount == 2 })
        #expect(a.participant(id: "b")?.icon == DeviceAppearance.icons[0])
        #expect(a.participant(id: "b")?.colorHex == DeviceAppearance.colors[0])
        #expect(a.participant(id: "b")?.profileImageData == nil)
    }

    @Test("Playback and Sync All survive a relayed mesh path")
    func roomActionsReachBroadcasterThroughRelay() throws {
        let room = RoomConfiguration(name: "Relayed control test", creatorPeerID: "a")
        let a = MeshProbe()
        let b = MeshProbe()
        let c = MeshProbe()
        let bReady = PortProbe()
        let cReady = PortProbe()
        let commands = MediaCommandProbe()
        let resyncs = ResyncRequestProbe()
        let nodeA = makeNode(room: room, id: "a", probe: a, ports: PortProbe())
        let nodeB = makeNode(room: room, id: "b", probe: b, ports: bReady)
        let nodeC = MeshControlPlane(
            room: room,
            nodeID: "c",
            displayName: "C",
            listenerReadyHandler: { cReady.set($0) },
            replicaHandler: { c.update(replica: $0) },
            participantsHandler: { c.update(participants: $0) },
            mediaCommandHandler: { command, broadcasterID, epoch in
                commands.add(command, broadcasterID: broadcasterID, epoch: epoch)
                return true
            },
            resyncRequestHandler: { targetID, broadcasterID, epoch in
                resyncs.add(targetID: targetID, broadcasterID: broadcasterID, epoch: epoch)
                return true
            }
        )
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        try nodeC.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop(); nodeC.stop() }
        guard let portB = bReady.wait(), let portC = cReady.wait() else {
            Issue.record("Mesh listeners did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portB))
        nodeB.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portC))
        #expect(waitUntil { a.participantCount == 2 && b.participantCount == 3 && c.participantCount == 2 })

        nodeC.publishBroadcaster(active: true, mediaServiceName: "relayed-media")
        #expect(waitUntil { a.broadcasterID == "c" && b.broadcasterID == "c" })
        let epoch = try #require(a.broadcasterEpoch)
        #expect(nodeA.publishMediaCommand(.pause, broadcasterID: "c", broadcasterEpoch: epoch))
        #expect(nodeA.publishResyncRequest(targetID: nil, broadcasterID: "c", broadcasterEpoch: epoch))

        #expect(waitUntil { commands.values == [.pause] })
        #expect(waitUntil { resyncs.count == 1 })
        #expect(resyncs.targetIDs == [nil])
        Thread.sleep(forTimeInterval: 1.4)
        #expect(commands.values == [.pause])
        #expect(resyncs.count == 1)
    }

    @Test("Open-line and targeted voice audio cross a relayed mesh path")
    func walkieTalkieAudioCrossesRelay() throws {
        let room = RoomConfiguration(name: "Relayed voice test", creatorPeerID: "a")
        let a = MeshProbe()
        let b = MeshProbe()
        let c = MeshProbe()
        let bReady = PortProbe()
        let cReady = PortProbe()
        let bWalkie = WalkieProbe()
        let cWalkie = WalkieProbe()
        let bOpenLine = OpenLineProbe()
        let cOpenLine = OpenLineProbe()
        let nodeA = makeNode(room: room, id: "a", probe: a, ports: PortProbe())
        let nodeB = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: { bReady.set($0) },
            replicaHandler: { b.update(replica: $0) },
            participantsHandler: { b.update(participants: $0) },
            walkieTalkieHandler: { bWalkie.add($0) },
            openLineHandler: { bOpenLine.add($0) }
        )
        let nodeC = MeshControlPlane(
            room: room,
            nodeID: "c",
            displayName: "C",
            listenerReadyHandler: { cReady.set($0) },
            replicaHandler: { c.update(replica: $0) },
            participantsHandler: { c.update(participants: $0) },
            walkieTalkieHandler: { cWalkie.add($0) },
            openLineHandler: { cOpenLine.add($0) }
        )
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        try nodeC.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop(); nodeC.stop() }
        guard let portB = bReady.wait(), let portC = cReady.wait() else {
            Issue.record("Mesh listeners did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portB))
        nodeB.connectForTesting(to: .hostPort(host: "127.0.0.1", port: portC))
        #expect(waitUntil { a.participantCount == 2 && b.participantCount == 3 && c.participantCount == 2 })

        let broadcastPCM = Data([0x00, 0x40, 0x00, 0xC0])
        nodeA.publishWalkieTalkie(.init(
            kind: .began,
            senderID: "a",
            senderName: "A",
            targetID: nil,
            sessionID: "open-line"
        ))
        nodeA.publishWalkieTalkie(.init(
            kind: .audio,
            senderID: "a",
            senderName: "A",
            targetID: nil,
            sessionID: "open-line",
            sequence: 1,
            pcm16Mono: broadcastPCM
        ))
        #expect(waitUntil { bWalkie.audio(sessionID: "open-line") == broadcastPCM })
        #expect(waitUntil { cWalkie.audio(sessionID: "open-line") == broadcastPCM })

        let targetedPCM = Data([0x00, 0x20, 0x00, 0xE0])
        nodeA.publishWalkieTalkie(.init(
            kind: .audio,
            senderID: "a",
            senderName: "A",
            targetID: "c",
            sessionID: "targeted-relay",
            sequence: 1,
            pcm16Mono: targetedPCM
        ))
        #expect(waitUntil { cWalkie.audio(sessionID: "targeted-relay") == targetedPCM })
        #expect(bWalkie.audio(sessionID: "targeted-relay") == nil)
        #expect(WalkieTalkiePlayer.makePlaybackBuffer(fromPCM16Mono: targetedPCM) != nil)

        let groupPCM = Data([0x00, 0x10])
        nodeA.publishWalkieTalkie(.init(
            kind: .audio,
            senderID: "a",
            senderName: "A",
            targetID: nil,
            targetIDs: ["b", "c"],
            sessionID: "recipient-snapshot",
            sequence: 1,
            pcm16Mono: groupPCM
        ))
        #expect(waitUntil { bWalkie.audio(sessionID: "recipient-snapshot") == groupPCM })
        #expect(waitUntil { cWalkie.audio(sessionID: "recipient-snapshot") == groupPCM })

        nodeA.publishOpenLine(.init(
            kind: .invite,
            invitationID: "line-relay",
            senderID: "a",
            senderName: "A",
            targetID: "c"
        ))
        #expect(waitUntil { cOpenLine.count == 1 })
        #expect(bOpenLine.count == 0)
    }

    @Test("Walkie relay validates direct origins before accepting forwarded audio")
    func walkieTalkieRelayOriginValidation() {
        #expect(MeshControlPlane.isValidWalkieTalkieOrigin(
            senderID: "a", remoteID: "a", envelopeOriginID: nil, hopCount: 0
        ))
        #expect(MeshControlPlane.isValidWalkieTalkieOrigin(
            senderID: "a", remoteID: "a", envelopeOriginID: "a", hopCount: 0
        ))
        #expect(!MeshControlPlane.isValidWalkieTalkieOrigin(
            senderID: "a", remoteID: "b", envelopeOriginID: "a", hopCount: 0
        ))
        #expect(MeshControlPlane.isValidWalkieTalkieOrigin(
            senderID: "a", remoteID: "b", envelopeOriginID: "a", hopCount: 1
        ))
        #expect(!MeshControlPlane.isValidWalkieTalkieOrigin(
            senderID: "a", remoteID: "b", envelopeOriginID: "b", hopCount: 1
        ))

        let fullMesh = MeshControlPlane.walkieTalkieRoutePlan(
            recipientIDs: ["b", "c", "d", "e"],
            directlyConnectedIDs: ["b", "c", "d", "e"]
        )
        #expect(fullMesh.destinationIDs == ["b", "c", "d", "e"])
        #expect(fullMesh.unresolvedIDs.isEmpty)

        let sparseMesh = MeshControlPlane.walkieTalkieRoutePlan(
            recipientIDs: ["e"],
            directlyConnectedIDs: ["b", "c"]
        )
        #expect(sparseMesh.destinationIDs == ["b", "c"])
        #expect(sparseMesh.unresolvedIDs == ["e"])
    }

    @Test("Explicit Talk recipients remain targeted for legacy clients")
    func explicitWalkieRecipientsAreLegacySafe() throws {
        let logical = WalkieTalkieMessage(
            kind: .audio,
            senderID: "a",
            senderName: "A",
            targetID: nil,
            targetIDs: ["c", "b"],
            sessionID: "private-talk",
            sequence: 7,
            pcm16Mono: Data([0, 1])
        )

        let wireMessages = MeshControlPlane.legacySafeWalkieTalkieMessages(logical)
        #expect(wireMessages.map(\.targetID) == ["b", "c"])
        #expect(wireMessages.map(\.recipientIDs) == [["b"], ["c"]])

        for message in wireMessages {
            let line = try MeshEnvelope(
                type: "walkie_talkie",
                walkieTalkie: message
            ).encodedLine()
            let legacy = try JSONDecoder().decode(LegacyWalkieEnvelope.self, from: line)
            #expect(legacy.walkieTalkie.targetID == message.targetID)
            #expect(legacy.walkieTalkie.targetID != nil)
        }

        let broadcast = WalkieTalkieMessage(
            kind: .began,
            senderID: "a",
            senderName: "A",
            targetID: nil,
            sessionID: "everyone"
        )
        #expect(MeshControlPlane.legacySafeWalkieTalkieMessages(broadcast) == [broadcast])
    }

    @Test("Full-band voice downgrades safely for older peers")
    func fullBandVoiceCompatibilityAndBackpressure() throws {
        #expect(!MeshControlPlane.supportsFullBandVoice(appVersion: nil))
        #expect(!MeshControlPlane.supportsFullBandVoice(appVersion: "0.13.29"))
        #expect(!MeshControlPlane.supportsFullBandVoice(appVersion: "0.13.30"))
        #expect(MeshControlPlane.supportsFullBandVoice(appVersion: "0.13.31"))

        let fullBandPCM = Data(repeating: 0x24, count: 960 * MemoryLayout<Int16>.size)
        let fullBand = WalkieTalkieMessage(
            kind: .audio,
            senderID: "a",
            senderName: "A",
            targetID: "b",
            sessionID: "full-band",
            sequence: 4,
            sampleRate: 48_000,
            pcm16Mono: fullBandPCM
        )
        let legacy = MeshControlPlane.legacyCompatibleWalkieTalkieMessage(fullBand)
        #expect(legacy.resolvedSampleRate == 16_000)
        #expect(legacy.pcm16Mono?.count == 320 * MemoryLayout<Int16>.size)

        var speechDownsampler = LegacyVoiceDownsampler()
        var aliasDownsampler = LegacyVoiceDownsampler()
        let speech = legacyPCMFixture(frequency: 1_000)
        let outOfBand = legacyPCMFixture(frequency: 12_000)
        for _ in 0..<3 {
            _ = speechDownsampler.process(speech)
            _ = aliasDownsampler.process(outOfBand)
        }
        let pendingSpeechOutput = speechDownsampler.process(speech)
        let pendingAliasOutput = aliasDownsampler.process(outOfBand)
        let speechOutput = try #require(pendingSpeechOutput)
        let aliasOutput = try #require(pendingAliasOutput)
        #expect(pcmRMS(aliasOutput) < pcmRMS(speechOutput) * 0.12)

        var queue = RealtimeVoiceSendQueue(maximumPendingAudioPackets: 2)
        queue.enqueue(.init(kind: .audio, sessionID: "voice", data: Data([1])))
        queue.enqueue(.init(kind: .audio, sessionID: "voice", data: Data([2])))
        queue.enqueue(.init(kind: .audio, sessionID: "voice", data: Data([3])))
        #expect(queue.pending.map(\.data) == [Data([2]), Data([3])])
        queue.enqueue(.init(kind: .ended, sessionID: "voice", data: Data([4])))
        #expect(queue.pending.map(\.data) == [Data([4])])
    }

    private func legacyPCMFixture(frequency: Double) -> Data {
        var data = Data()
        data.reserveCapacity(960 * MemoryLayout<Int16>.size)
        for frame in 0..<960 {
            let angle = 2 * Double.pi * frequency * Double(frame) / 48_000
            let bits = UInt16(bitPattern: Int16((sin(angle) * 20_000).rounded()))
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }

    private func pcmRMS(_ data: Data) -> Double {
        var total = 0.0
        let count = data.count / MemoryLayout<Int16>.size
        data.withUnsafeBytes { bytes in
            for index in 0..<count {
                let offset = index * 2
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let sample = Double(Int16(bitPattern: bits))
                total += sample * sample
            }
        }
        return sqrt(total / Double(max(1, count)))
    }

    @Test("Room controls retry until the broadcaster media session accepts them")
    func roomActionAcknowledgementFollowsMediaAcceptance() throws {
        let room = RoomConfiguration(name: "Control retry test", creatorPeerID: "a")
        let a = MeshProbe()
        let b = MeshProbe()
        let ready = PortProbe()
        let acceptance = RetryingCommandProbe()
        let nodeA = makeNode(room: room, id: "a", probe: a, ports: PortProbe())
        let nodeB = MeshControlPlane(
            room: room,
            nodeID: "b",
            displayName: "B",
            listenerReadyHandler: { ready.set($0) },
            replicaHandler: { b.update(replica: $0) },
            participantsHandler: { b.update(participants: $0) },
            mediaCommandHandler: { command, _, _ in acceptance.handle(command) }
        )
        try nodeA.start(advertise: false)
        try nodeB.start(advertise: false)
        defer { nodeA.stop(); nodeB.stop() }
        guard let port = ready.wait() else {
            Issue.record("Mesh listener did not start")
            return
        }
        nodeA.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
        #expect(waitUntil { a.participantCount == 2 })
        nodeB.publishBroadcaster(active: true, mediaServiceName: "retry-media")
        #expect(waitUntil { a.broadcasterID == "b" })
        let epoch = try #require(a.broadcasterEpoch)

        #expect(nodeA.publishMediaCommand(.pause, broadcasterID: "b", broadcasterEpoch: epoch))
        #expect(waitUntil(timeout: 2) { acceptance.attemptCount >= 2 })
        Thread.sleep(forTimeInterval: 0.7)
        #expect(acceptance.attemptCount == 2)
        #expect(acceptance.acceptedCommands == [.pause])
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

private struct LegacyWalkieEnvelope: Decodable {
    let walkieTalkie: LegacyWalkieMessage
}

private struct LegacyWalkieMessage: Decodable {
    let targetID: String?
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

private final class CountProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class MeshProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var replica = MeshRoomReplica()
    private var participants = [RoomParticipant]()
    private var participantCountHistory = [Int]()
    var participantCount: Int { lock.withLock { participants.count } }
    var minimumObservedParticipantCount: Int? { lock.withLock { participantCountHistory.min() } }
    var chatCount: Int { lock.withLock { replica.chatEvents.count } }
    var eventCount: Int { lock.withLock { replica.events.count } }
    var artworkByteCount: Int? { lock.withLock { replica.nowPlaying.artworkData?.count } }
    var chatTexts: [String?] { lock.withLock { replica.chatEvents.map(\.text) } }
    var chatSenderIDs: [String?] { lock.withLock { replica.chatEvents.map(\.senderID) } }
    var broadcasterID: String? { lock.withLock { replica.broadcaster?.nodeID } }
    var broadcasterEpoch: UInt64? { lock.withLock { replica.broadcaster?.epoch } }
    func participant(id: String) -> RoomParticipant? {
        lock.withLock { participants.first(where: { $0.id == id }) }
    }
    func update(replica: MeshRoomReplica) { lock.withLock { self.replica = replica } }
    func update(participants: [RoomParticipant]) {
        lock.withLock {
            self.participants = participants
            participantCountHistory.append(participants.count)
        }
    }
    func resetParticipantCountHistory() {
        lock.withLock { participantCountHistory = [participants.count] }
    }
}

private final class BlockingCommandProbe: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func handle() -> Bool {
        entered.signal()
        _ = released.wait(timeout: .now() + 3)
        return true
    }

    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    func release() { released.signal() }
}

private final class WalkieProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var messages = [WalkieTalkieMessage]()
    var count: Int { lock.withLock { messages.count } }
    func add(_ message: WalkieTalkieMessage) { lock.withLock { messages.append(message) } }
    func audio(sessionID: String) -> Data? {
        lock.withLock {
            messages.first { $0.kind == .audio && $0.sessionID == sessionID }?.pcm16Mono
        }
    }
}

private final class OpenLineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var messages = [OpenLineMessage]()
    var count: Int { lock.withLock { messages.count } }
    func add(_ message: OpenLineMessage) { lock.withLock { messages.append(message) } }
}

private final class MediaCommandProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = [(RoomMediaCommand, String, UInt64)]()
    var values: [RoomMediaCommand] { lock.withLock { entries.map(\.0) } }
    var targetIDs: [String] { lock.withLock { entries.map(\.1) } }
    var epochs: [UInt64] { lock.withLock { entries.map(\.2) } }
    func add(_ command: RoomMediaCommand, broadcasterID: String, epoch: UInt64) {
        lock.withLock { entries.append((command, broadcasterID, epoch)) }
    }
}

private final class ResyncRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = [(String?, String, UInt64)]()
    var count: Int { lock.withLock { entries.count } }
    var targetIDs: [String?] { lock.withLock { entries.map(\.0) } }
    func add(targetID: String?, broadcasterID: String, epoch: UInt64) {
        lock.withLock { entries.append((targetID, broadcasterID, epoch)) }
    }
}

private final class RetryingCommandProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var accepted = [RoomMediaCommand]()
    var attemptCount: Int { lock.withLock { attempts } }
    var acceptedCommands: [RoomMediaCommand] { lock.withLock { accepted } }
    func handle(_ command: RoomMediaCommand) -> Bool {
        lock.withLock {
            attempts += 1
            guard attempts >= 2 else { return false }
            accepted.append(command)
            return true
        }
    }
}

private final class VersionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<String>()
    func add(_ value: String) { lock.withLock { _ = values.insert(value) } }
    func contains(_ value: String) -> Bool { lock.withLock { values.contains(value) } }
}
