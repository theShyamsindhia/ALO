import Foundation
import Network
import Testing
@testable import ALONetworking

@Suite("Media receiver bootstrap and replacement")
struct MediaReceiverSessionTests {
    @Test func annotationTrafficExpiresWithIndependentSnapshotAndGestureBudgets() {
        var budget = AnnotationTrafficBudget()
        let initial = budget.accept(bytes: 8 * 1_024 * 1_024, snapshot: true, now: 0)
        #expect(initial)
        for _ in 0..<2_047 {
            let gesture = budget.accept(bytes: 100, snapshot: false, now: 0)
            #expect(gesture)
        }
        let countOverflow = budget.accept(bytes: 1, snapshot: false, now: 0)
        #expect(!countOverflow)
        let afterExpiry = budget.accept(bytes: 1_048_576, snapshot: false, now: 1_000_000_000)
        #expect(afterExpiry)
        let byteOverflow = budget.accept(bytes: 1, snapshot: false, now: 1_000_000_000)
        #expect(!byteOverflow)
        let independentSnapshot = budget.accept(bytes: 1_024, snapshot: true, now: 1_000_000_000)
        #expect(independentSnapshot)
    }

    @Test func rejectedActiveRefreshPreservesCommittedPlaybackAndRetriesFreshAnchor() throws {
        let h = try MediaReceiverHarness()
        try h.queue.sync {
            try h.activate()
            let committed = try #require(h.committed.last)
            h.time += 20_000_000; h.host.refreshTimeline(); try h.pump()
            let rejected = try #require(h.preparations.last)
            #expect(rejected.id != committed.id)
            try h.publishPackets(4)
            #expect(h.audio.count == 8) // The old timeline plays during preparation.
            h.receiver.completePreparationOnQueue(id: rejected.id, ready: false)
            #expect(h.states.last == .active)
            #expect(h.committed.last?.id == committed.id)
            try h.publishPackets(4); #expect(h.audio.count == 12)
            h.time += 1_000_000_000; h.receiver.tick(); try h.pump()
            let retry = try #require(h.preparations.last)
            #expect(retry.id != rejected.id)
            h.receiver.completePreparationOnQueue(id: retry.id, ready: true)
            try h.publishPackets(4)
            #expect(h.audio.count == 16 && h.states.last == .active)
            #expect(h.committed.last?.id == retry.id)
            #expect(h.subscriptions.count == 1)
        }
    }

    @Test func startupRequiresClockOutputPreparationAndContiguousAuthenticatedWarmup() throws {
        let h = try MediaReceiverHarness()
        try h.queue.sync {
            try h.synchronize()
            let preparation = try #require(h.preparations.last)
            #expect(h.states.last == .preparing)
            #expect(h.committed.isEmpty && h.audio.isEmpty)
            try h.publishPackets(4)
            #expect(h.committed.isEmpty && h.audio.isEmpty)
            h.receiver.completePreparationOnQueue(id: UUID(), ready: true)
            #expect(h.committed.isEmpty)
            h.receiver.completePreparationOnQueue(id: preparation.id, ready: true)
            try h.pump()
            #expect(h.committed.map(\.id) == [preparation.id])
            #expect(h.audio.map(\.frameIndex) == [0, 240, 480, 720])
            #expect(h.states.last == .active)
            #expect(h.readiness.count == 1)
            #expect(h.readiness[0].acknowledges(preparation.anchor))
        }
    }

    @Test func preparedOutputStillWaitsForEnoughContiguousWarmup() throws {
        let h = try MediaReceiverHarness()
        try h.queue.sync {
            try h.synchronize()
            let preparation = try #require(h.preparations.last)
            h.receiver.completePreparationOnQueue(id: preparation.id, ready: true)
            try h.publishPackets(3)
            #expect(h.committed.isEmpty && h.audio.isEmpty)
            try h.publishPackets(1)
            #expect(h.committed.count == 1 && h.audio.count == 4)
        }
    }

    @Test func pauseAndResumeRequireNewPreparationWithoutNewTicket() throws {
        let h = try MediaReceiverHarness()
        try h.queue.sync {
            try h.activate()
            let ticket = try #require(h.subscriptions.last)
            h.time += 20_000_000; h.anchorState = .paused
            h.host.refreshTimeline(); try h.pump()
            let pause = try #require(h.preparations.last)
            h.receiver.completePreparationOnQueue(id: pause.id, ready: true); try h.pump()
            #expect(h.states.last == .paused)
            let delivered = h.audio.count
            try h.publishPackets(4)
            #expect(h.audio.count == delivered)
            h.time += 20_000_000; h.anchorState = .running
            h.host.refreshTimeline(); try h.pump()
            let resume = try #require(h.preparations.last)
            #expect(resume.id != pause.id)
            h.receiver.completePreparationOnQueue(id: pause.id, ready: true)
            try h.publishPackets(4)
            #expect(h.audio.count == delivered)
            h.receiver.completePreparationOnQueue(id: resume.id, ready: true); try h.pump()
            #expect(h.audio.count == delivered + 4)
            #expect(h.states.last == .active)
            #expect(h.subscriptions.map(\.sessionID) == [ticket.sessionID])
            #expect(h.committed.last?.id == resume.id)
        }
    }

    @Test func stalledPathRenewalPreservesActiveUntilPreparedFutureCutover() throws {
        let h = try MediaReceiverHarness()
        try h.queue.sync {
            try h.activate()
            let old = try #require(h.subscriptions.last)
            for _ in 0..<4 { h.time += 1_000_000_000; h.receiver.tick(); try h.pump() }
            let replacement = try #require(h.subscriptions.last)
            #expect(replacement.sessionID != old.sessionID)
            let preparation = try #require(h.preparations.last)
            #expect(!h.cancelled.contains(old.sessionID))
            #expect(h.registry.containsLiveSubscription(sessionID: old.sessionID, now: h.seconds))
            h.receiver.completePreparationOnQueue(id: preparation.id, ready: true)
            try h.publishPackets(4)
            #expect(h.committed.last?.id == preparation.id)
            #expect(!h.cancelled.contains(old.sessionID))
            let delivered = h.audio.count
            #expect(Set(h.audio.map(\.frameIndex)).count == delivered)
            h.time = preparation.anchor.hostPlaybackTimeNanos + 1
            h.receiver.tick(); h.host.tick(); try h.pump()
            #expect(h.cancelled.contains(old.sessionID))
            #expect(!h.cancelled.contains(replacement.sessionID))
            #expect(!h.registry.containsLiveSubscription(sessionID: old.sessionID, now: h.seconds))
        }
    }

    @Test func stoppedReceiverRejectsLatePreparationDatagramsAndPathCallbacksAfterRejoin() throws {
        let old = try MediaReceiverHarness()
        try old.queue.sync {
            try old.synchronize()
            let preparation = try #require(old.preparations.last)
            let flow = try #require(old.flows.values.first)
            old.receiver.stopOnQueue(failed: false)
            flow.state(.active)
            flow.payload(.audio, AudioPacket(sequence: 0, frameIndex: 0, captureTimeNanos: old.time,
                samples: Array(repeating: 1, count: 480)).encoded())
            old.receiver.completePreparationOnQueue(id: preparation.id, ready: true)
            #expect(old.audio.isEmpty && old.committed.isEmpty)
            #expect(old.states.last == .stopped)
        }
        let rejoined = try MediaReceiverHarness()
        try rejoined.queue.sync { try rejoined.activate(); #expect(rejoined.audio.count == 4) }
        old.queue.sync { old.flows.values.first?.state(.failed); #expect(old.states.last == .stopped) }
        rejoined.queue.sync { #expect(rejoined.states.last == .active && rejoined.audio.count == 4) }
    }

    @Test func stoppedReceiverDoesNotCreateSubscriberFromLateEndpointResolution() throws {
        let h = try MediaReceiverHarness()
        try h.queue.sync {
            h.deferEndpoint = true
            try h.synchronize()
            let resolve = try #require(h.endpointReplies.first)
            h.receiver.stopOnQueue(failed: false)
            resolve(.success(.hostPort(host: "127.0.0.1", port: 54321)))
            #expect(h.flows.isEmpty && h.preparations.isEmpty)
            #expect(h.states.last == .stopped)
        }
    }
}

/// Real host/receiver state machines and actual admitted-ticket MAC, return-path
/// proof and AES-GCM processing, with deterministic reliable/datagram delivery.
/// This does not exercise Network.framework sockets or audio hardware.
private final class MediaReceiverHarness {
    struct Flow {
        let id: UUID
        let state: (SecureMediaTransportState) -> Void
        let payload: (DatagramChannel, Data) -> Void
        let opener: DatagramOpener
    }
    let queue = DispatchQueue(label: "alo.tests.media-receiver")
    let registry = MediaSubscriptionRegistry()
    let publisher: AuthenticatedChannelCredentials
    let subscriber: AuthenticatedChannelCredentials
    var host: MediaHostSession!
    var receiver: MediaReceiverSession!
    var time: UInt64 = 100_000_000_000
    var seconds: TimeInterval { Double(time) / 1_000_000_000 }
    var nextFrame: UInt64 = 0
    var anchorState: MediaStreamAnchor.State = .running
    var fromHost: [Data] = [], toHost: [Data] = []
    var datagrams: [(UUID, Data)] = []
    var flows: [UUID: Flow] = [:]
    var cancelled = Set<UUID>()
    var subscriptions: [MediaSubscriptionTicket] = []
    var preparations: [MediaReceiverSession.Preparation] = []
    var committed: [MediaReceiverSession.Preparation] = []
    var audio: [AudioPacket] = []
    var states: [MediaReceiverSession.State] = []
    var readiness: [MediaControlWireMessage] = []
    var deferEndpoint = false
    var endpointReplies: [(Result<NWEndpoint, Error>) -> Void] = []

    init() throws {
        let offer = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop)
        let transcript = try AdmissionTranscript(roomID: NetworkFixture.room, initiatorID: NetworkFixture.receiver,
            responderID: NetworkFixture.sender, connectionID: UUID(), initiatorKeyHash: Data(repeating: 1, count: 32),
            responderKeyHash: Data(repeating: 2, count: 32), initiatorNonce: Data(repeating: 3, count: 32),
            responderNonce: Data(repeating: 4, count: 32), initiatorOffer: offer, responderOffer: offer,
            policy: .secureV2, channelRole: .mediaControl, admissionKind: .publicRoom)
        publisher = .init(transcript: transcript, localRole: .responder, rootSecret: NetworkFixture.key)
        subscriber = .init(transcript: transcript, localRole: .initiator, rootSecret: NetworkFixture.key)
        host = MediaHostSession(roomID: NetworkFixture.room, localPeerID: NetworkFixture.sender, queue: queue,
            callbacks: .init(currentBroadcaster: { .init(peerID: NetworkFixture.sender, epoch: 7) },
                currentAnchor: { [weak self] _, stream, now in
                    guard let self else { return nil }
                    return .init(stream: stream, captureTimeNanos: now, frameIndex: self.nextFrame,
                        hostPlaybackTimeNanos: now + 200_000_000, issuedAtHostNanos: now, state: self.anchorState)
                }), registry: registry, nowNanos: { [weak self] in self?.time ?? 0 },
            sendDatagram: { [weak self] data, session, done in
                guard let self, let flow = self.flows[session],
                      let encrypted = try? self.registry.sealMedia(data, sessionID: session, acceptedFlowID: flow.id,
                        channel: .audio, now: self.seconds) else { done(false); return }
                self.datagrams.append((session, encrypted)); done(true)
            }, cancelDatagram: { [weak self] in self?.cancelled.insert($0) })
        receiver = try MediaReceiverSession(expected: .init(roomID: NetworkFixture.room,
            localPeerID: NetworkFixture.receiver, broadcasterPeerID: NetworkFixture.sender, broadcasterEpoch: 7),
            credentials: subscriber, queue: queue,
            callbacks: .init(prepareAnchor: { [weak self] in self?.preparations.append($0) },
                anchorCommitted: { [weak self] in self?.committed.append($0) },
                audio: { [weak self] packet, _, _ in self?.audio.append(packet) },
                state: { [weak self] in self?.states.append($0) }),
            nowNanos: { [weak self] in self?.time ?? 0 },
            sendControl: { [weak self] data, done in self?.toHost.append(data); done(.success(())) },
            resolveEndpoint: { [weak self] port, reply in
                if self?.deferEndpoint == true { self?.endpointReplies.append(reply) }
                else { reply(.success(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))) }
            }, makeSubscriber: { [weak self] _, ticket, state, payload in
                guard let self else { throw SecureTransportError.invalidState }
                let id = UUID()
                let probe = try self.subscriber.makeReturnPathProbe(ticket: ticket)
                let challenge = try self.registry.receiveProbe(probe, sessionID: ticket.sessionID, acceptedFlowID: id, now: self.seconds)
                let response = try self.subscriber.answerReturnPathChallenge(challenge, ticket: ticket)
                _ = try self.registry.confirmReturnPathResponse(response, sessionID: ticket.sessionID, acceptedFlowID: id, now: self.seconds)
                let opener = try self.subscriber.makeSubscriberDatagramOpener(ticket: ticket, channel: .audio)
                self.flows[ticket.sessionID] = Flow(id: id, state: state, payload: payload, opener: opener)
                state(.active); self.host.subscriptionValidated(ticket.sessionID)
                return { [weak self] in self?.cancelled.insert(ticket.sessionID) }
            }, closeControl: {})
        try queue.sync {
            try host.addPeer(credentials: publisher, send: { [weak self] data, done in
                self?.fromHost.append(data); done(.success(()))
            }, close: {})
            host.publisherReady(port: 54321)
        }
    }

    func synchronize() throws {
        for _ in 0..<4 { receiver.tick(); try pump(); time += 250_000_000 }
    }
    func activate() throws {
        try synchronize()
        let preparation = try #require(preparations.last)
        receiver.completePreparationOnQueue(id: preparation.id, ready: true)
        try publishPackets(4)
    }
    func publishPackets(_ count: Int) throws {
        for _ in 0..<count {
            host.publishAudio(.init(sequence: UInt32(nextFrame / 240), frameIndex: nextFrame,
                captureTimeNanos: time, samples: Array(repeating: 7, count: 480)))
            nextFrame += 240
        }
        try pump()
    }
    func pump() throws {
        var iterations = 0
        while !toHost.isEmpty || !fromHost.isEmpty || !datagrams.isEmpty {
            iterations += 1
            guard iterations <= 1_000 else { throw SecureTransportError.capacity }
            if !toHost.isEmpty {
                let data = toHost.removeFirst()
                if case .anchorReady = try MediaControlWireMessage(encoded: data) {
                    readiness.append(try MediaControlWireMessage(encoded: data))
                }
                host.receive(data, connectionID: publisher.connectionID)
            }
            if !fromHost.isEmpty {
                let data = fromHost.removeFirst()
                if case .subscribed(_, let ticket, _) = try MediaControlWireMessage(encoded: data) { subscriptions.append(ticket) }
                receiver.receive(data)
            }
            if !datagrams.isEmpty {
                let (session, encrypted) = datagrams.removeFirst()
                if let flow = flows[session], !cancelled.contains(session) {
                    flow.payload(.audio, try flow.opener.open(encrypted))
                }
            }
        }
    }
}
