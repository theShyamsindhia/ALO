import Foundation
import CryptoKit
import Network
import Testing
import ALOCore
@testable import ALONetworking

@Suite("Networking review regressions", .serialized)
struct ReviewNetworkingRegressionTests {
    @Test func privateMediaRequiresRoomKeyAndRejectsAudioReplays() async throws {
        let room = RoomConfiguration(name: "Private", isPrivate: true, accessKey: UUID().uuidString)
        let security = try #require(try RoomMediaSecurity.forRoom(room, serviceName: "source"))
        let wrongRoom = RoomConfiguration(id: room.id, name: room.name, isPrivate: true, accessKey: UUID().uuidString)
        let wrong = try #require(try RoomMediaSecurity.forRoom(wrongRoom, serviceName: "source"))
        let otherSource = try #require(try RoomMediaSecurity.forRoom(room, serviceName: "another-source"))
        let session = UUID()
        let packet = try security.audioSealer(sessionID: session).seal(Data([42]))
        let opener = try security.audioOpener(sessionID: session)
        #expect(try opener.open(packet) == Data([42]))
        #expect(throws: SecureTransportError.replay) { try opener.open(packet) }
        #expect(throws: (any Error).self) { try wrong.audioOpener(sessionID: session).open(packet) }
        #expect(throws: (any Error).self) { try otherSource.audioOpener(sessionID: session).open(packet) }
        #expect(throws: (any Error).self) { try security.audioOpener(sessionID: UUID()).open(packet) }
        for video in [false, true] {
            try await assertTLS(security: security, candidates: [security.tcp(video: video), wrong.tcp(video: video), LocalNetworkParameters.tcp()], video: video)
        }
    }

    private func assertTLS(security: RoomMediaSecurity, candidates: [NWParameters], video: Bool) async throws {
        let queue = DispatchQueue(label: "review.private-media.test")
        let probe = MediaProbe()
        let listener = try NWListener(using: security.tcp(video: video), on: .any)
        listener.stateUpdateHandler = { state in if case .ready = state { probe.lock.withLock { probe.port = listener.port } } }
        listener.newConnectionHandler = { connection in
            probe.lock.withLock { probe.connections.append(connection) }
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state { probe.lock.withLock { probe.failures.append("server: \(error)") } }
            }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { data, _, _, _ in
                if let data, !data.isEmpty { probe.lock.withLock { probe.received.append(data) } }
            }
        }
        listener.start(queue: queue)
        defer {
            listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
            probe.lock.withLock { probe.connections.forEach { $0.cancel() }; probe.connections.removeAll() }
        }
        for _ in 0..<200 {
            if probe.lock.withLock({ probe.port != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try #require(probe.lock.withLock { probe.port })
        for (index, parameters) in candidates.enumerated() {
            let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
            probe.lock.withLock { probe.connections.append(connection) }
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state { probe.lock.withLock { probe.failures.append("client \(index): \(error)") } }
            }
            connection.start(queue: queue)
            connection.send(content: Data([UInt8(index + 1)]), completion: .contentProcessed { _ in })
        }
        for _ in 0..<200 {
            if probe.lock.withLock({ !probe.received.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(probe.lock.withLock { probe.received } == [Data([1])], "TLS failures: \(probe.lock.withLock { probe.failures })")
    }

    @Test func moreThan64SequentialSubscriptionsDoNotResetRetiredReplayWindows() throws {
        let offer = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop)
        let transcript = try AdmissionTranscript(roomID: NetworkFixture.room, initiatorID: NetworkFixture.receiver,
            responderID: NetworkFixture.sender, connectionID: NetworkFixture.session,
            initiatorKeyHash: Data(repeating: 1, count: 32), responderKeyHash: Data(repeating: 2, count: 32),
            initiatorNonce: Data(repeating: 3, count: 32), responderNonce: Data(repeating: 4, count: 32),
            initiatorOffer: offer, responderOffer: offer, policy: .secureV2, channelRole: .mediaControl, admissionKind: .publicRoom)
        let publisher = AuthenticatedChannelCredentials(transcript: transcript, localRole: .responder, rootSecret: NetworkFixture.key)
        let subscriber = AuthenticatedChannelCredentials(transcript: transcript, localRole: .initiator, rootSecret: NetworkFixture.key)
        let registry = MediaSubscriptionRegistry()
        for index in 1...130 {
            let ticket = try registry.reserveAdmittedSubscription(credentials: publisher, broadcasterEpoch: 1, generation: 1,
                                                                  channels: [.audio], now: 0)
            #expect(ticket.subscriptionSequence == UInt64(index))
            let opener = try subscriber.makeSubscriberDatagramOpener(ticket: ticket, channel: .audio)
            #expect(try subscriber.makeSubscriberDatagramOpener(ticket: ticket, channel: .audio) === opener)
            let packet = try DatagramSealer(secret: NetworkFixture.key, context: ticket.context(for: .audio)).seal(Data([1]))
            #expect(try opener.open(packet) == Data([1]))
            subscriber.retireSubscriberTicket(ticket)
            registry.cancel(sessionID: ticket.sessionID)
            #expect(throws: SecureTransportError.wrongContext) { try subscriber.makeSubscriberDatagramOpener(ticket: ticket, channel: .audio) }
            #expect(throws: SecureTransportError.invalidCredentials) { try opener.open(packet) }
            #expect(throws: SecureTransportError.wrongContext) { try subscriber.makeReturnPathProbe(ticket: ticket) }
        }
    }

    @Test func signedEventsCannotBypassNegotiatedCapabilitiesThroughRelays() throws {
        let identity = try InstallationIdentity.ephemeral()
        let nodeID = identity.publicIdentity.nodeID.uuidString
        // Even a modified caller that signs a broadcast must obey the receiver's admission grant.
        let signer = SecureRoomEventPolicy(roomID: "r", identity: identity, capabilities: .desktop)
        let receiverIdentity = try InstallationIdentity.ephemeral()
        let receiver = SecureRoomEventPolicy(roomID: "r", identity: receiverIdentity, capabilities: [])
        let broadcast = MeshRoomEvent(roomID: "r", version: .init(counter: 1, nodeID: nodeID), kind: .broadcaster,
            broadcasterID: nodeID, broadcasterEpoch: 1, mediaServiceName: "source", isBroadcasting: true)
        let signed = try #require(signer.sign(broadcast))
        #expect(!receiver.accepts(signed)) // Unknown relayed author.
        let chat = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .chat)
        let desktop = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop)
        let negotiated = try NegotiatedProtocol.negotiate(initiator: chat, responder: desktop, policy: .secureV2)
        receiver.admit(AuthenticatedPeer(nodeID: identity.publicIdentity.nodeID, publicKeyHash: identity.publicIdentity.publicKeyHash,
            incarnationID: UUID(), connectionID: UUID(), negotiated: negotiated, channelRole: .roomControl), initiated: false)
        #expect(!receiver.accepts(signed))
        let signedChat = try #require(signer.sign(MeshRoomEvent(roomID: "r", version: .init(counter: 2, nodeID: nodeID), kind: .chat, text: "hello")))
        #expect(receiver.accepts(signedChat))
        let forged = MeshRoomEvent(roomID: "r", version: signedChat.version, kind: .chat, text: "tampered").authorized(with: signedChat.authorization!)
        #expect(!SecureRoomEventPolicy.hasValidSignature(forged))
        let durable = try AutomergeRoomStateSync(roomID: "r", eventValidator: { receiver.accepts($0) })
        let forbiddenQueue = try #require(signer.sign(MeshRoomEvent(roomID: "r", version: .init(counter: 3, nodeID: nodeID),
                                                                   kind: .queueRemove, queueItemID: "item")))
        #expect(try durable.ingest([forbiddenQueue]).isEmpty)
        #expect(try durable.ingest([forged]).isEmpty)
        #expect(try durable.ingest([signedChat]).count == 1)
        let archive = try receiver.archive(document: durable.save())
        let restored = SecureRoomEventPolicy(roomID: "r", identity: receiverIdentity, capabilities: [])
        let document = try #require(restored.restoreArchive(archive))
        #expect(restored.accepts(signedChat))
        #expect(!restored.accepts(signed))
        let loaded = try AutomergeRoomStateSync(roomID: "r", savedDocument: document, eventValidator: { restored.accepts($0) })
        #expect(try loaded.snapshot().events.count == 1)
        let wrongInstallation = SecureRoomEventPolicy(roomID: "r", identity: try .ephemeral(), capabilities: [])
        #expect(wrongInstallation.restoreArchive(archive) == nil)
        var corrupt = archive
        corrupt[corrupt.count - 8] ^= 1
        #expect(restored.restoreArchive(corrupt) == nil)
    }
}

private final class MediaProbe: @unchecked Sendable {
    let lock = NSLock()
    var port: NWEndpoint.Port?
    var connections = [NWConnection]()
    var received = [Data]()
    var failures = [String]()
}
