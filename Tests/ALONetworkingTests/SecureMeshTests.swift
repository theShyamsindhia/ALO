import Foundation
import Network
import Testing
import ALOCore
@testable import ALONetworking

@Suite("Actual secure mesh runtime", .serialized)
struct SecureMeshTests {
    @Test func largeSignedSnapshotIsPacedWithoutDisconnecting() async throws {
        let room = RoomConfiguration.secure(name: "Large signed snapshot")
        let identity = try InstallationIdentity.ephemeral()
        let signer = SecureRoomEventPolicy(roomID: room.id, identity: identity, capabilities: .desktop)
        var events = [MeshRoomEvent]()
        for index in 1...500 {
            let event = MeshRoomEvent(roomID: room.id, version: .init(counter: UInt64(index), nodeID: identity.publicIdentity.nodeID.uuidString),
                                      kind: .chat, text: String(repeating: "x", count: 4_000))
            events.append(try #require(signer.sign(event)))
        }
        #expect(try JSONEncoder().encode(events).count > 1_024 * 1_024)
        let a = SecureMeshNode(room: room, identity: identity, initialEvents: events, disableStateSync: true)
        let b = SecureMeshNode(room: room, identity: try .ephemeral(), disableStateSync: true)
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
        let restricted = SecureMeshNode(room: room, identity: try .ephemeral(), capabilities: .chat)
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
        let lower = SecureMeshNode(room: room, identity: identities[0])
        let higher = SecureMeshNode(room: room, identity: identities[1])
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
        let wrong = SecureMeshNode(room: wrongRoom, identity: b.identity)
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
        let returning = SecureMeshNode(room: room, identity: b.identity)
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

    @Test func authenticatedVideoRoleBypassesMeshDecoder() async throws {
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
            admission: .publicRoom, offer: ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .mobile),
            direction: .initiator(.video))
        let channel = SecurePeerChannel(connection: connection, identity: identity, configuration: config, pins: pins, queue: queue)
        defer { channel.cancel() }
        let payload = Data([0, 1, 2, 255])
        channel.onAuthenticated = { [weak channel] _ in channel?.send(payload: payload) }
        channel.onPayload = { bytes in routed.update { $0.payload = bytes } }
        channel.start()
        try await meshEventually { routed.read { $0.payload == payload } }
        #expect(routed.read { $0.mediaPeer?.nodeID == identity.publicIdentity.nodeID && $0.mediaPeer?.channelRole == .video })
        #expect(server.state.read { $0.participants.count == 1 })
    }

    @Test func receiverOpensMediaToAnInboundRoomPeersAdvertisedListener() async throws {
        let room = RoomConfiguration.secure(name: "Independent media connection")
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
        receiver.control.openMediaChannel(to: presenter.identity.publicIdentity.nodeID, role: .mediaControl) { result in
            do {
                let (channel, _) = try result.get()
                routed.update { $0.mediaChannels.append(channel) }
                channel.onPayload = { bytes in routed.update { $0.payload = bytes } }
                channel.send(payload: payload)
            } catch { routed.update { $0.mediaError = String(describing: error) } }
        }
        try await meshEventually { routed.read { $0.payload == payload || $0.mediaError != nil } }
        #expect(routed.read { $0.mediaError == nil && $0.payload == payload })
        #expect(routed.read { $0.mediaPeer?.channelRole == .mediaControl })
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

private final class MeshTestState: @unchecked Sendable {
    struct Value {
        var port: NWEndpoint.Port?
        var participants: [RoomParticipant] = []
        var replica = MeshRoomReplica()
        var mediaPeer: AuthenticatedPeer?
        var mediaChannels: [SecurePeerChannel] = []
        var mediaError: String?
        var payload: Data?
        var connectionAttempts = 0
    }
    private let lock = NSLock()
    private var value = Value()
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
    func read<T>(_ body: (Value) -> T) -> T { lock.withLock { body(value) } }
}

private final class SecureMeshNode {
    let identity: InstallationIdentity
    let control: MeshControlPlane
    let state = MeshTestState()
    var id: String { identity.publicIdentity.nodeID.uuidString }
    convenience init(room: RoomConfiguration, incomingMediaChannelHandler: ((SecurePeerChannel, AuthenticatedPeer) -> Void)? = nil) throws {
        self.init(room: room, identity: try .ephemeral(), incomingMediaChannelHandler: incomingMediaChannelHandler)
    }
    init(room: RoomConfiguration, identity: InstallationIdentity, capabilities: PeerCapabilities = .desktop,
         initialEvents: [MeshRoomEvent] = [], disableStateSync: Bool = false,
         incomingMediaChannelHandler: ((SecurePeerChannel, AuthenticatedPeer) -> Void)? = nil) {
        self.identity = identity
        let observation = state
        control = MeshControlPlane(room: room, nodeID: identity.publicIdentity.nodeID.uuidString, displayName: "Peer",
            initialEvents: initialEvents,
            listenerReadyHandler: { port in observation.update { $0.port = port } },
            replicaHandler: { replica in observation.update { $0.replica = replica } },
            participantsHandler: { participants in observation.update { $0.participants = participants } },
            disableRoomStateSyncDuringAuthenticationForTesting: disableStateSync,
            connectionAttemptHandler: { observation.update { $0.connectionAttempts += 1 } },
            installationIdentity: identity, peerPins: MemoryPeerPinStore(), secureCapabilities: capabilities, incomingMediaChannelHandler: incomingMediaChannelHandler)
    }
    func start() throws { try control.start(advertise: false) }
    func stop() { control.stop() }
    func readyPort() async throws -> NWEndpoint.Port {
        try await meshEventually { self.state.read { $0.port != nil } }
        return try #require(state.read { $0.port })
    }
}

private func meshEventually(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(condition(), "Secure mesh did not reach the expected state within 8 seconds")
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
