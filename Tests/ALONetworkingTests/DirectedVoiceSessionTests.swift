import Foundation
import Network
import Testing
@testable import ALONetworking

@Suite("Directed admitted 10ms voice")
struct DirectedVoiceSessionTests {
    @Test func unexpectedPublisherFailureRevokesBeforeSingleGlobalCallback() throws {
        let h = try VoiceHarness()
        try h.queue.sync {
            try h.start()
            h.sender.publisherFailed(SecurePeerChannelError.connectionFailed)
            #expect(h.registry.count == 0 && h.publisherFailures == 1)
            h.sender.publisherFailed(SecurePeerChannelError.cancelled)
            h.sender.beginOnQueue(session: h.intent, recipients: [NetworkFixture.receiver])
            h.submit()
        }
        h.queue.sync { #expect(h.publisherFailures == 1 && h.datagrams.isEmpty) }
    }

    @Test func explicitStopDoesNotReportUnexpectedPublisherFailure() throws {
        let h = try VoiceHarness()
        h.sender.stop()
        h.queue.sync {
            h.sender.publisherFailed(SecurePeerChannelError.cancelled)
            #expect(h.publisherFailures == 0)
        }
    }
    @Test func noLocalIntentOrWrongRecipientCannotGrantVoice() throws {
        let h = try VoiceHarness()
        try h.queue.sync {
            #expect(throws: SecureTransportError.invalidCredentials) { try h.sender.addPeer(h.makeHostConnection()) }
            h.sender.beginOnQueue(session: h.intent, recipients: [UUID()])
            #expect(throws: SecureTransportError.invalidCredentials) { try h.sender.addPeer(h.makeHostConnection()) }
            h.sender.beginOnQueue(session: .init(sessionID: UUID()), recipients: [NetworkFixture.receiver])
            try h.sender.addPeer(h.makeHostConnection())
            h.hostConnection?.receive(try DirectedVoiceWire.encode(.subscribe(UUID(), h.intent)))
            #expect(h.registry.count == 0)
        }
    }

    @Test func voicePacketIsExactly480MonoFramesAndPreservesLogicalPosition() throws {
        let packet = DirectedVoiceWire.Packet(sequence: 9, frameIndex: 4_320, captureTimeNanos: 123, pcm: Data(repeating: 5, count: 960))
        let decoded = try DirectedVoiceWire.Packet.decode(packet.encoded())
        #expect(decoded.sequence == 9 && decoded.frameIndex == 4_320 && decoded.pcm.count == 960)
        #expect(packet.encoded().count <= SecureDatagram.maximumPayloadSize)
        #expect(throws: SecureTransportError.self) { try DirectedVoiceWire.Packet.decode(packet.encoded() + Data([1])) }
        let invalid = DirectedVoiceWire.Packet(sequence: 9, frameIndex: 0, captureTimeNanos: 123, pcm: packet.pcm)
        #expect(throws: SecureTransportError.self) { try DirectedVoiceWire.Packet.decode(invalid.encoded()) }
    }

    @Test func authenticatedBurstIsBoundedAndNeverUsesReliablePCM() throws {
        let h = try VoiceHarness()
        try h.queue.sync {
            try h.start(); h.holdSends = true
            for _ in 0..<8 { h.submit() }
        }
        try h.queue.sync {
            #expect(h.datagrams.count == 1 && h.sendReplies.count == 1)
            while !h.sendReplies.isEmpty { h.sendReplies.removeFirst()(true) }
            try h.pump()
            #expect(h.received.map(\.0) == Array(0..<8).map(UInt64.init))
            #expect(h.received.map(\.1) == Array(0..<8).map { UInt64($0 * 480) })
            #expect(h.received.allSatisfy { $0.2.count == 960 })
            #expect(h.tickets.count == 1 && h.tickets[0].channels == [.voice])
            #expect(throws: SecureTransportError.self) {
                try h.credentials.receiver.makeSubscriberDatagramOpener(ticket: h.tickets[0], channel: .audio)
            }
        }
    }

    @Test func renewalKeepsLogicalSequenceAndDeduplicatesBothUDPPaths() throws {
        let h = try VoiceHarness()
        try h.queue.sync { try h.start(); h.submit() }
        try h.queue.sync {
            try h.pump()
            let original = try #require(h.tickets.first)
            for _ in 0..<10 { h.time += 2_000_000_000; h.sender.tick(); h.receiver.tick(); try h.pump() }
            #expect(h.tickets.count == 2)
            #expect(h.registry.containsLiveSubscription(sessionID: original.sessionID, now: h.seconds))
            h.submit()
        }
        try h.queue.sync {
            try h.pump()
            #expect(h.received.map(\.0) == [0, 1])
            #expect(h.cancelled.contains(h.tickets[0].sessionID))
            #expect(h.receiverStates.last == .active)
            h.submit()
        }
        try h.queue.sync { try h.pump(); #expect(h.received.map(\.0) == [0, 1, 2]) }
    }

    @Test func endedTransmissionRevokesTicketsAndDropsLateCapture() throws {
        let h = try VoiceHarness()
        try h.queue.sync { try h.start(); h.submit() }
        try h.queue.sync { try h.pump(); #expect(h.received.count == 1) }
        h.sender.endTransmitting(session: h.intent)
        h.queue.sync { h.submit(); #expect(h.registry.count == 0) }
        try h.queue.sync { try h.pump(); #expect(h.received.count == 1) }
    }

    @Test func delayedSenderCompletionExpiresQueuedVoice() throws {
        let h = try VoiceHarness()
        try h.queue.sync { try h.start(); h.holdSends = true; for _ in 0..<8 { h.submit() } }
        try h.queue.sync {
            h.time += 81_000_000
            h.sendReplies.removeFirst()(true); try h.pump()
            #expect(h.received.count == 1 && h.datagrams.isEmpty && h.sendReplies.isEmpty)
        }
    }

    @Test func staleCallbacksAfterStopCannotDeliverPCM() throws {
        let h = try VoiceHarness()
        try h.queue.sync { try h.start(); h.submit() }
        h.receiver.stop()
        try h.queue.sync {
            try h.pump()
            #expect(h.received.isEmpty && h.receiverStates.last == .stopped)
        }
    }
}

private final class VoiceHarness {
    struct Flow { let id: UUID; let opener: DatagramOpener; let pcm: (Data) -> Void }
    let queue = DispatchQueue(label: "alo.tests.directed-voice")
    let registry = MediaSubscriptionRegistry()
    let credentials: (host: AuthenticatedChannelCredentials, receiver: AuthenticatedChannelCredentials)
    let intent = VoiceSessionIdentifier(sessionID: UUID())
    var sender: DirectedVoiceSession!
    var receiver: DirectedVoiceSession!
    var time: UInt64 = 100_000_000_000
    var seconds: TimeInterval { Double(time) / 1_000_000_000 }
    var hostConnection: VoiceControlConnection?
    var subscriberConnection: VoiceControlConnection?
    var toHost: [Data] = [], toReceiver: [Data] = []
    var datagrams: [(UUID, Data)] = []
    var flows: [UUID: Flow] = [:]
    var tickets: [MediaSubscriptionTicket] = []
    var cancelled = Set<UUID>()
    var received: [(UInt64, UInt64, Data)] = []
    var receiverStates: [DirectedVoiceSession.State] = []
    var holdSends = false
    var sendReplies: [(Bool) -> Void] = []
    var publisherFailures = 0
    init() throws {
        credentials = try MediaHostHarness.credentials(role: .voiceControl, initiatorID: NetworkFixture.receiver)
        sender = DirectedVoiceSession(roomID: NetworkFixture.room, localPeerID: NetworkFixture.sender, queue: queue,
            callbacks: .init(pcm: { _, _, _, _, _, _ in Issue.record("Receiving unexpectedly activated transmission") },
                failed: { [weak self] _ in
                    guard let self else { return }
                    #expect(self.registry.count == 0)
                    self.publisherFailures += 1
                }),
            registry: registry, now: { [weak self] in self?.time ?? 0 },
            open: { _, reply in reply(.failure(SecureTransportError.invalidState)) },
            subscribe: { _, _, _, _, _ in throw SecureTransportError.invalidState },
            sendDatagram: { [weak self] bytes, sessionID, done in
                guard let self, let flow = self.flows[sessionID],
                      let encrypted = try? self.registry.sealMedia(bytes, sessionID: sessionID,
                        acceptedFlowID: flow.id, channel: .voice, now: self.seconds) else { done(false); return }
                self.datagrams.append((sessionID, encrypted))
                if self.holdSends { self.sendReplies.append(done) } else { done(true) }
            }, cancelDatagram: { [weak self] in self?.cancelled.insert($0) })
        receiver = DirectedVoiceSession(roomID: NetworkFixture.room, localPeerID: NetworkFixture.receiver, queue: queue,
            callbacks: .init(pcm: { [weak self] peer, session, sequence, frame, pcm, _ in
                guard let self else { return }
                #expect(peer == NetworkFixture.sender && session == self.intent)
                self.received.append((sequence, frame, pcm))
            }, state: { [weak self] _, state in self?.receiverStates.append(state) }),
            registry: .init(), now: { [weak self] in self?.time ?? 0 },
            open: { [weak self] peer, reply in
                guard let self else { return }
                #expect(peer == NetworkFixture.sender)
                do {
                    try self.sender.addPeer(self.makeHostConnection())
                    let connection = VoiceControlConnection(credentials: self.credentials.receiver,
                        send: { [weak self] bytes, done in self?.toHost.append(bytes); done(.success(())) }, close: {},
                        resolve: { port, reply in reply(.success(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))) },
                        now: { [weak self] in self?.time ?? 0 })
                    self.subscriberConnection = connection; reply(.success(connection))
                } catch { reply(.failure(error)) }
            }, subscribe: { [weak self] _, credentials, ticket, state, pcm in
                guard let self else { throw SecureTransportError.invalidState }
                self.tickets.append(ticket)
                let flow = UUID(), probe = try credentials.makeReturnPathProbe(ticket: ticket)
                let challenge = try self.registry.receiveProbe(probe, sessionID: ticket.sessionID, acceptedFlowID: flow, now: self.seconds)
                let response = try credentials.answerReturnPathChallenge(challenge, ticket: ticket)
                _ = try self.registry.confirmReturnPathResponse(response, sessionID: ticket.sessionID, acceptedFlowID: flow, now: self.seconds)
                self.flows[ticket.sessionID] = Flow(id: flow, opener: try credentials.makeSubscriberDatagramOpener(ticket: ticket, channel: .voice), pcm: pcm)
                self.sender.validated(ticket.sessionID); state(.active)
                return { [weak self] in self?.cancelled.insert(ticket.sessionID) }
            }, sendDatagram: { _, _, reply in reply(false) }, cancelDatagram: { _ in })
    }
    func makeHostConnection() -> VoiceControlConnection {
        let connection = VoiceControlConnection(credentials: credentials.host,
            send: { [weak self] bytes, done in self?.toReceiver.append(bytes); done(.success(())) }, close: {},
            resolve: { _, reply in reply(.failure(SecureTransportError.invalidState)) }, now: { [weak self] in self?.time ?? 0 })
        hostConnection = connection; return connection
    }
    func start() throws {
        sender.publisherReady(port: 54321)
        sender.beginOnQueue(session: intent, recipients: [NetworkFixture.receiver])
        receiver.receiveOnQueue(from: NetworkFixture.sender, session: intent)
        try pump()
    }
    func submit() { sender.submitPCM16Mono(Data(repeating: 7, count: 960), captureTimeNanos: time, session: intent) }
    func pump() throws {
        var count = 0
        while !toHost.isEmpty || !toReceiver.isEmpty || !datagrams.isEmpty {
            count += 1; guard count < 1_000 else { throw SecureTransportError.capacity }
            if !toHost.isEmpty { hostConnection?.receive(toHost.removeFirst()) }
            if !toReceiver.isEmpty { subscriberConnection?.receive(toReceiver.removeFirst()) }
            if !datagrams.isEmpty {
                let (session, bytes) = datagrams.removeFirst()
                if let flow = flows[session], let packet = try? flow.opener.open(bytes) { flow.pcm(packet) }
            }
        }
    }
}
