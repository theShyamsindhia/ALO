import Foundation
import Testing
@testable import ALONetworking

@Suite("Media host authorization and lifecycle")
struct MediaHostSessionTests {
    @Test func manualSyncTargetsOnlySelectedPeerAndAllSharesOneResetID() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            let first = try h.activate()
            let other = try MediaHostHarness.credentials()
            var messages: [MediaControlWireMessage] = []
            try h.host.addPeer(credentials: other.host, send: { bytes, done in
                if let message = try? MediaControlWireMessage(encoded: bytes) { messages.append(message) }
                done(.success(()))
            }, close: {})
            h.host.receive(try MediaControlWireMessage.subscribe(requestID: UUID(), broadcasterEpoch: 7,
                channels: [.audio]).encoded(), connectionID: other.host.connectionID)
            let second = try #require(messages.compactMap { if case .subscribed(_, let ticket, _) = $0 { return ticket }; return nil }.last)
            try h.validate(second, credentials: other.receiver)
            let secondAnchor = try #require(messages.compactMap { if case .anchor(let anchor) = $0 { return anchor }; return nil }.last)
            h.host.receive(try MediaControlWireMessage.anchorReady(stream: secondAnchor.stream,
                frameIndex: secondAnchor.frameIndex, captureTimeNanos: secondAnchor.captureTimeNanos,
                hostPlaybackTimeNanos: secondAnchor.hostPlaybackTimeNanos).encoded(), connectionID: other.host.connectionID)
            h.time += 250_000_000; h.host.tick()
            let firstCount = h.anchors.count, secondCount = messages.count
            h.host.refreshTimeline(participantID: UUID(), resetPlayback: true)
            #expect(h.anchors.count == firstCount && messages.count == secondCount, "Unknown target must not fall back to everyone")
            h.host.refreshTimeline(participantID: h.publisher.remotePeerID, resetPlayback: true)
            #expect(h.anchors.count == firstCount + 1 && messages.count == secondCount)
            #expect(h.anchors.last?.playbackResetID != nil && h.anchors.last?.stream.sessionID == first.sessionID)
            h.host.refreshTimeline(resetPlayback: true)
            let allFirst = try #require(h.anchors.last)
            let allSecond = try #require(messages.compactMap { if case .anchor(let anchor) = $0 { return anchor }; return nil }.last)
            #expect(allFirst.playbackResetID != nil && allFirst.playbackResetID == allSecond.playbackResetID)
            #expect(allSecond.stream.sessionID == second.sessionID && h.closed.isEmpty)
            h.ack(allFirst); h.time += 250_000_000; h.host.tick()
            h.host.refreshTimeline()
            #expect(h.anchors.last?.playbackResetID == nil, "Automatic refresh must never request a reset")
        }
    }

    @Test func manualSyncSurvivesMissingCaptureAndInFlightAnchor() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321); _ = try h.activate()
            h.time += 250_000_000; h.host.tick()
            h.captureAvailable = false
            h.host.refreshTimeline(resetPlayback: true)
            #expect(h.anchors.last?.playbackResetID == nil)
            h.captureAvailable = true; h.time += 100_000_000; h.host.tick()
            #expect(h.anchors.last?.playbackResetID != nil)
            let resetID = try #require(h.anchors.last?.playbackResetID)
            h.host.refreshTimeline()
            #expect(h.anchors.last?.playbackResetID == resetID, "Retain explicit sync until readiness ACK, including failed-preparation retries")
            h.holdNextAnchor = true; h.host.refreshTimeline()
            h.host.refreshTimeline(resetPlayback: true)
            let done = try #require(h.heldAnchorCompletion)
            h.heldAnchorCompletion = nil; done(.success(()))
            #expect(h.anchors.last?.playbackResetID != nil)
        }
    }
    @Test func futureActiveAnchorKeepsCommittedAudioUntilAcknowledgedCutover() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321); _ = try h.activate()
            h.anchorCaptureOffset = 100_000_000
            h.host.refreshTimeline()
            let proposal = try #require(h.anchors.last)
            #expect(proposal.captureTimeNanos > h.time)
            h.host.publishAudio(h.packet)
            #expect(h.datagrams.count == 1) // New output is still preparing.
            h.ack(proposal)
            h.host.publishAudio(h.packet(index: 1))
            #expect(h.datagrams.count == 2) // ACK does not immediately discard old capture.
            h.time = proposal.hostPlaybackTimeNanos
            h.host.tick()
            h.host.publishAudio(h.packet(index: 2))
            #expect(h.datagrams.count == 3 && h.closed.isEmpty)
        }
    }
    @Test func missingCaptureRetriesBoundedAnchorWithoutNewSubscription() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321); h.captureAvailable = false
            let ticket = try h.subscribe(); try h.validate(ticket)
            #expect(h.anchors.isEmpty)
            let calls = h.snapshotCalls
            for _ in 0..<100 { h.host.tick() }
            #expect(h.snapshotCalls == calls)
            h.captureAvailable = true; h.time += 100_000_000; h.host.tick()
            #expect(h.anchors.count == 1 && h.anchors.first?.stream.sessionID == ticket.sessionID)
            h.ack(try #require(h.anchors.last)); h.host.publishAudio(h.packet)
            #expect(h.datagrams.count == 1)
        }
    }

    @Test func malformedRecognizedAnnotationQuarantinesOnlyExtension() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321); _ = try h.activate()
            let bad = try JSONSerialization.data(withJSONObject: ["protocolName": AnnotationWireMessage.capability, "message": "invalid"])
            h.host.receive(bad, connectionID: h.publisher.connectionID)
            h.host.publishAudio(h.packet)
            #expect(h.closed.isEmpty && h.datagrams.count == 1)
        }
    }
    @Test func publisherQueuePressureRetriesWithoutLosingHealthyBurst() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            _ = try h.activate()
            h.rejectNextAudioEnqueues = 1
            for index in 0..<8 { h.host.publishAudio(h.packet(index: index)) }
            #expect(h.datagrams.isEmpty)
            #expect(h.audioRetries.count == 1)
            h.time += 5_000_000; h.audioRetries.removeFirst()()
            #expect(h.datagrams.count == 8)
            h.rejectNextAudioEnqueues = 1
            h.host.publishAudio(h.packet(index: 8))
            h.time += 81_000_000; h.audioRetries.removeFirst()()
            #expect(h.datagrams.count == 8)
        }
    }

    @Test func captureIngressPreservesHealthyBatchAndExpiresBlockedBatch() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            _ = try h.activate()
            h.host.submitAudio((0..<8).map { h.packet(index: $0) })
        }
        h.queue.sync {
            #expect(h.datagrams.count == 8)
            h.host.submitAudio((8..<16).map { h.packet(index: $0) })
            h.time += 81_000_000
        }
        h.queue.sync { #expect(h.datagrams.count == 8) }
    }

    @Test func annotationSendCompletesOnlyWithTransportAndCancellationIsOnce() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.holdAnnotationCompletions = true
            let bytes = try AnnotationWireMessage.hello(capabilities: [AnnotationWireMessage.capability]).encoded()
            var outcomes: [Result<Void, Error>] = []
            h.host.sendAnnotation(bytes, connectionID: h.publisher.connectionID) { outcomes.append($0) }
            #expect(outcomes.isEmpty)
            h.annotationCompletions.removeFirst()(.success(()))
            #expect(outcomes.count == 1)
            h.host.sendAnnotation(bytes, connectionID: h.publisher.connectionID) { outcomes.append($0) }
            let late = h.annotationCompletions.removeFirst()
            h.host.detach(connectionID: h.publisher.connectionID)
            #expect(outcomes.count == 2)
            if case .failure(let error) = outcomes[1] { #expect(error as? SecurePeerChannelError == .cancelled) }
            else { Issue.record("Cancellation reported successful annotation delivery") }
            late(.success(()))
            #expect(outcomes.count == 2)
        }
    }

    @Test func receiverAnnotationBudgetAllowsThirtyHzAndSendReportsActualFailure() throws {
        let h = try MediaHostHarness()
        let bytes = try AnnotationWireMessage.hello(capabilities: [AnnotationWireMessage.capability]).encoded()
        var delivered = 0
        var sendCompletion: ((Result<Void, Error>) -> Void)?
        var outcomes: [Result<Void, Error>] = []
        let receiver = try h.queue.sync {
            try MediaReceiverSession(expected: .init(roomID: NetworkFixture.room, localPeerID: h.receiver.localPeerID,
                broadcasterPeerID: NetworkFixture.sender, broadcasterEpoch: 7), credentials: h.receiver, queue: h.queue,
                callbacks: .init(prepareAnchor: { _ in }, audio: { _, _, _ in }, annotation: { _ in delivered += 1; return true }),
                nowNanos: { h.time }, sendControl: { _, done in sendCompletion = done },
                resolveEndpoint: { _, done in done(.failure(SecureTransportError.invalidState)) },
                makeSubscriber: { _, _, _, _ in throw SecureTransportError.invalidState }, closeControl: {})
        }
        h.queue.sync {
            for _ in 0..<60 { receiver.receive(bytes) }
            #expect(delivered == 60)
        }
        receiver.sendAnnotation(bytes) { outcomes.append($0) }
        try h.queue.sync {
            #expect(outcomes.isEmpty)
            let done = try #require(sendCompletion)
            done(.failure(SecurePeerChannelError.connectionFailed))
            #expect(outcomes.count == 1)
            if case .failure(let error) = outcomes[0] { #expect(error as? SecurePeerChannelError == .connectionFailed) }
            else { Issue.record("Failed transport reported successful annotation delivery") }
            done(.success(())); #expect(outcomes.count == 1)
        }
    }

    @Test func captureBurstDrainsEveryPacketAfterDelayedEnqueueCompletion() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            let ticket = try h.activate()
            h.holdAudioCompletions = true
            for index in 0..<8 { h.host.publishAudio(h.packet(index: index)) }
            #expect(h.datagrams.count == 1)
            while !h.audioCompletions.isEmpty { h.audioCompletions.removeFirst()(true) }
            let opener = try h.receiver.makeSubscriberDatagramOpener(ticket: ticket, channel: .audio)
            let frames = try h.datagrams.map { try AudioPacket(data: opener.open($0.bytes))?.frameIndex }
            #expect(frames == (0..<8).map { Optional(UInt64($0 * 240)) })
        }
    }

    @Test func queuedAudioExpiresAndLateCompletionCannotReviveRetiredEpoch() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            _ = try h.activate()
            h.holdAudioCompletions = true
            h.host.publishAudio(h.packet(index: 0)); h.host.publishAudio(h.packet(index: 1))
            h.time += 81_000_000
            h.audioCompletions.removeFirst()(true)
            #expect(h.datagrams.count == 1)
            h.host.publishAudio(h.packet(index: 2)); h.host.publishAudio(h.packet(index: 3))
            h.owner = .init(peerID: NetworkFixture.sender, epoch: 8)
            h.host.tick()
            h.audioCompletions.removeFirst()(true)
            #expect(h.datagrams.count == 2)
            #expect(h.registry.count == 0)
        }
    }

    @Test func sustainedBurstIsBoundedAndPauseDiscardsPendingAudio() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            let ticket = try h.activate()
            h.holdAudioCompletions = true
            for index in 0..<100 { h.host.publishAudio(h.packet(index: index)) }
            while !h.audioCompletions.isEmpty { h.audioCompletions.removeFirst()(true) }
            let opener = try h.receiver.makeSubscriberDatagramOpener(ticket: ticket, channel: .audio)
            let frames = try h.datagrams.map { try AudioPacket(data: opener.open($0.bytes))?.frameIndex }
            #expect(frames == ([0] + Array(84..<100)).map { Optional(UInt64($0 * 240)) })
            h.host.publishAudio(h.packet(index: 101)); h.host.publishAudio(h.packet(index: 102))
            let beforePause = h.datagrams.count
            h.anchorState = .paused; h.host.refreshTimeline()
            while !h.audioCompletions.isEmpty { h.audioCompletions.removeFirst()(true) }
            #expect(h.datagrams.count == beforePause)
        }
    }

    @Test func grantRequiresTrustedLocalOwnerAndActualPublisherPort() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 0)
            h.send(.subscribe(requestID: UUID(), broadcasterEpoch: 7, channels: [.audio]))
            #expect(h.rejections.last == .unavailable)
            #expect(h.registry.count == 0)
            h.host.publisherReady(port: 54321)
            h.owner = .init(peerID: h.receiver.localPeerID, epoch: 7)
            h.send(.subscribe(requestID: UUID(), broadcasterEpoch: 7, channels: [.audio]))
            #expect(h.rejections.last == .staleSession)
            #expect(h.registry.count == 0)
            h.owner = .init(peerID: NetworkFixture.sender, epoch: 8)
            h.send(.subscribe(requestID: UUID(), broadcasterEpoch: 7, channels: [.audio]))
            #expect(h.registry.count == 0)
            h.owner = .init(peerID: NetworkFixture.sender, epoch: 7)
            let ticket = try h.subscribe()
            #expect(ticket.senderID == NetworkFixture.sender)
            #expect(ticket.receiverID == h.receiver.localPeerID)
            #expect(h.grantedPort == 54321)
        }
    }

    @Test func validatedPathWarmsEncryptedAudioBeforeExactReadinessAcknowledgment() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            let ticket = try h.subscribe()
            h.host.refreshTimeline(); h.host.publishAudio(h.packet)
            #expect(h.anchors.isEmpty && h.datagrams.isEmpty)
            try h.validate(ticket)
            let anchor = try #require(h.anchors.last)
            #expect(h.snapshotCalls == 1)
            h.host.publishAudio(h.packet)
            #expect(h.datagrams.count == 1) // Startup data is needed before readiness ACK.
            h.send(.anchorReady(stream: anchor.stream, frameIndex: anchor.frameIndex + 1,
                                captureTimeNanos: anchor.captureTimeNanos, hostPlaybackTimeNanos: anchor.hostPlaybackTimeNanos))
            h.send(.renew(requestID: UUID(), stream: anchor.stream))
            #expect(h.rejections.last == .staleSession) // Wrong ACK did not activate the lease.
            h.ack(anchor)
            let datagram = try #require(h.datagrams.first)
            let opener = try h.receiver.makeSubscriberDatagramOpener(ticket: ticket, channel: .audio)
            #expect(datagram.bytes != h.packet.encoded())
            #expect(try opener.open(datagram.bytes) == h.packet.encoded())
            #expect(throws: SecureTransportError.replay) { try opener.open(datagram.bytes) }
            _ = try h.renew(ticket)
            #expect(h.registry.count == 2)
        }
    }

    @Test func renewalKeepsOldPathUntilExactAcknowledgmentAndFutureCutover() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            let old = try h.activate()
            let replacement = try h.renew(old)
            #expect(old.sessionID != replacement.sessionID)
            #expect(replacement.subscriptionSequence > old.subscriptionSequence)
            #expect(h.registry.count == 2)
            try h.validate(replacement)
            let anchor = try #require(h.anchors.last)
            h.host.publishAudio(h.packet)
            #expect(Set(h.datagrams.map(\.session)) == [old.sessionID, replacement.sessionID])
            #expect(h.registry.containsLiveSubscription(sessionID: old.sessionID, now: h.seconds))
            h.ack(anchor)
            h.datagrams.removeAll()
            h.host.publishAudio(h.packet)
            #expect(Set(h.datagrams.map(\.session)) == [old.sessionID, replacement.sessionID])
            h.time = anchor.hostPlaybackTimeNanos
            h.host.tick()
            #expect(!h.registry.containsLiveSubscription(sessionID: old.sessionID, now: h.seconds))
            #expect(h.registry.containsLiveSubscription(sessionID: replacement.sessionID, now: h.seconds))
            h.datagrams.removeAll(); h.host.publishAudio(h.packet)
            #expect(h.datagrams.map(\.session) == [replacement.sessionID])
        }
    }

    @Test func pendingDeadlinePreservesOldLeaseAndCannotExtendItsExpiry() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            let old = try h.activate()
            let pending = try h.renew(old)
            h.time += 10_100_000_000; h.host.tick()
            #expect(!h.registry.containsLiveSubscription(sessionID: pending.sessionID, now: h.seconds))
            #expect(h.registry.containsLiveSubscription(sessionID: old.sessionID, now: h.seconds))
            h.host.publishAudio(h.packet)
            #expect(h.datagrams.last?.session == old.sessionID)
            h.time = UInt64(old.expiresAt * 1_000_000_000); h.host.tick()
            #expect(h.registry.count == 0)
        }
    }

    @Test func lateRenewalAcknowledgmentCannotBreakTheOldPath() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            let old = try h.activate()
            let pending = try h.renew(old)
            try h.validate(pending)
            let proposal = try #require(h.anchors.last)
            h.time = proposal.hostPlaybackTimeNanos + 1
            h.ack(proposal)
            h.host.publishAudio(h.packet)
            #expect(h.datagrams.contains { $0.session == old.sessionID })
            #expect(h.registry.containsLiveSubscription(sessionID: old.sessionID, now: h.seconds))
            h.time += 10_000_000_000; h.host.tick()
            #expect(!h.registry.containsLiveSubscription(sessionID: pending.sessionID, now: h.seconds))
            #expect(h.registry.containsLiveSubscription(sessionID: old.sessionID, now: h.seconds))
        }
    }

    @Test func unmatchedCancelCannotRevokeAndEpochChangeRevokesBothLeases() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            let old = try h.activate()
            _ = try h.renew(old)
            h.send(.cancel(stream: .init(sessionID: UUID(), broadcasterEpoch: 7, generation: 1)))
            #expect(h.registry.count == 2)
            h.owner = .init(peerID: NetworkFixture.sender, epoch: 8)
            h.host.refreshTimeline()
            #expect(h.registry.count == 0)
        }
    }

    @Test func voiceAndWrongChannelRolesFailClosed() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            let wrong = try MediaHostHarness.credentials(role: .video)
            #expect(throws: SecureTransportError.invalidCredentials) {
                try h.host.addPeer(credentials: wrong.host, send: { _, done in done(.success(())) }, close: {})
            }
            let noAudio = try MediaHostHarness.credentials(initiatorCapabilities: [.receiveVideo, .voice])
            #expect(throws: SecureTransportError.invalidCredentials) {
                try h.host.addPeer(credentials: noAudio.host, send: { _, done in done(.success(())) }, close: {})
            }
            let bytes = try JSONSerialization.data(withJSONObject: [
                "protocolName": MediaControlWireMessage.protocolName, "version": 2,
                "message": ["subscribe": ["requestID": UUID().uuidString, "broadcasterEpoch": 7, "channels": [2]]]
            ])
            h.host.receive(bytes, connectionID: h.publisher.connectionID)
            #expect(h.closed == [h.publisher.connectionID])
            #expect(h.registry.count == 0)
        }
    }

    @Test func pongsUseHostClockAndAreRateLimited() throws {
        let h = try MediaHostHarness()
        h.queue.sync {
            for id in UInt64(0)..<20 { h.send(.clockPing(id: id, clientTimeNanos: 12)) }
            let pongs = h.messages.compactMap { message -> UInt64? in
                guard case let .clockPong(_, echoed, hostTime) = message else { return nil }
                #expect(echoed == 12); return hostTime
            }
            #expect(pongs.count == 8 && pongs.allSatisfy { $0 == h.time })
            #expect(h.closed.isEmpty)
        }
    }

    @Test func audioOnlyReceiverCannotRequestVideoKeyframe() throws {
        let h = try MediaHostHarness(initiatorCapabilities: [.receiveAudio])
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            let ticket = try h.activate()
            h.send(.requestKeyframe(requestID: UUID(), stream: .init(ticket: ticket), minimumCaptureTimeNanos: nil))
            #expect(h.rejections.last == .denied)
            #expect(h.keyframeRequests == 0)
            #expect(h.registry.containsLiveSubscription(sessionID: ticket.sessionID, now: h.seconds))
        }
    }

    @Test func slowReliablePeerExpiresWithoutClosingHealthyPeer() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            let slow = try MediaHostHarness.credentials()
            try h.host.addPeer(credentials: slow.host, send: { _, _ in }, close: { h.closed.append(slow.host.connectionID) })
            h.host.receive(try MediaControlWireMessage.clockPing(id: 1, clientTimeNanos: 1).encoded(), connectionID: slow.host.connectionID)
            h.time += 2_100_000_000; h.host.tick()
            h.send(.clockPing(id: 2, clientTimeNanos: 2))
            #expect(h.closed == [slow.host.connectionID])
            #expect(h.messages.contains { if case .clockPong(id: 2, clientTimeNanos: 2, hostTimeNanos: h.time) = $0 { return true }; return false })
        }
    }

    @Test func annotationDelegateIsExplicitAndBounded() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            let annotation = try AnnotationWireMessage.hello(capabilities: [AnnotationWireMessage.capability]).encoded()
            h.acceptAnnotations = true
            h.host.receive(annotation, connectionID: h.publisher.connectionID)
            #expect(h.annotationPayloads == [annotation])
            for _ in 0..<29 { h.host.receive(annotation, connectionID: h.publisher.connectionID) }
            #expect(h.annotationPayloads.count == 30 && h.closed.isEmpty)
            h.acceptAnnotations = false
            h.host.receive(annotation, connectionID: h.publisher.connectionID)
            #expect(h.closed.isEmpty)
            let before = h.annotationPayloads.count
            h.host.receive(annotation, connectionID: h.publisher.connectionID)
            #expect(h.annotationPayloads.count == before) // Optional extension quarantined.
        }
    }

    @Test func inFlightPauseCoalescesToLatestRunningTimeline() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321)
            _ = try h.activate()
            h.holdNextAnchor = true
            h.anchorState = .paused; h.host.refreshTimeline()
            #expect(h.anchors.last?.state == .paused)
            h.anchorState = .running; h.host.refreshTimeline()
            #expect(h.snapshotCalls == 2)
            let done = try #require(h.heldAnchorCompletion)
            h.heldAnchorCompletion = nil; done(.success(()))
            #expect(h.snapshotCalls == 3)
            #expect(h.anchors.last?.state == .running)
            h.host.publishAudio(h.packet)
            #expect(h.datagrams.count == 1)
        }
    }

    @Test func pausedInitialLeaseCanAcknowledgeWithoutAudioThenResume() throws {
        let h = try MediaHostHarness()
        try h.queue.sync {
            h.host.publisherReady(port: 54321); h.anchorState = .paused
            let ticket = try h.activate()
            h.host.publishAudio(h.packet)
            #expect(h.datagrams.isEmpty)
            h.anchorState = .running; h.host.refreshTimeline()
            h.host.publishAudio(h.packet)
            #expect(h.datagrams.map(\.session) == [ticket.sessionID])
            #expect(h.anchors.last?.state == .running)
        }
    }
}

/// Deterministic adapter tests with authenticated credential fixtures and real
/// registry MAC/path/encryption checks. This is not a TLS/NWConnection integration harness.
final class MediaHostHarness {
    let queue = DispatchQueue(label: "alo.tests.media-host")
    let registry = MediaSubscriptionRegistry(limits: .init(maximumSubscriptions: 64, maximumPending: 32, maximumPerPeer: 2))
    let publisher: AuthenticatedChannelCredentials
    let receiver: AuthenticatedChannelCredentials
    var host: MediaHostSession!
    var time: UInt64 = 100_000_000_000
    var seconds: TimeInterval { TimeInterval(time) / 1_000_000_000 }
    var owner: MediaHostSession.Broadcaster? = .init(peerID: NetworkFixture.sender, epoch: 7)
    var messages: [MediaControlWireMessage] = []
    var datagrams: [(session: UUID, bytes: Data)] = []
    var flows: [UUID: UUID] = [:]
    var closed: [UUID] = []
    var snapshotCalls = 0
    var captureAvailable = true
    var anchorCaptureOffset: UInt64 = 0
    var anchorState: MediaStreamAnchor.State = .running
    var holdNextAnchor = false
    var heldAnchorCompletion: ((Result<Void, Error>) -> Void)?
    var holdAudioCompletions = false
    var audioCompletions: [(Bool) -> Void] = []
    var rejectNextAudioEnqueues = 0
    var audioRetries: [() -> Void] = []
    var holdAnnotationCompletions = false
    var annotationCompletions: [(Result<Void, Error>) -> Void] = []
    var keyframeRequests = 0
    var acceptAnnotations = false
    var annotationPayloads: [Data] = []
    var grantedPort: UInt16?
    var packet: AudioPacket { .init(sequence: 1, frameIndex: 0, captureTimeNanos: time,
                                    samples: Array(repeating: 7, count: 480)) }
    func packet(index: Int) -> AudioPacket {
        .init(sequence: UInt32(index), frameIndex: UInt64(index * 240), captureTimeNanos: time,
              samples: Array(repeating: 7, count: 480))
    }
    var anchors: [MediaStreamAnchor] { messages.compactMap { if case .anchor(let anchor) = $0 { return anchor }; return nil } }
    var rejections: [MediaControlWireMessage.Rejection] { messages.compactMap { if case .rejected(_, let reason) = $0 { return reason }; return nil } }

    init(initiatorCapabilities: PeerCapabilities = .desktop) throws {
        let credentials = try Self.credentials(initiatorCapabilities: initiatorCapabilities)
        publisher = credentials.host; receiver = credentials.receiver
        host = MediaHostSession(roomID: NetworkFixture.room, localPeerID: NetworkFixture.sender, queue: queue,
            callbacks: .init(currentBroadcaster: { [weak self] in self?.owner }, currentAnchor: { [weak self] _, stream, time in
                self?.snapshotCalls += 1
                guard self?.captureAvailable == true else { return nil }
                let capture = time + (self?.anchorCaptureOffset ?? 0)
                return MediaStreamAnchor(stream: stream, captureTimeNanos: capture, frameIndex: 0,
                    hostPlaybackTimeNanos: capture + 200_000_000, issuedAtHostNanos: time, state: self?.anchorState ?? .paused)
            }, requestKeyframe: { [weak self] _, _, _ in self?.keyframeRequests += 1 }, annotation: { [weak self] credentials, bytes in
                guard let self, credentials === self.publisher else { return false }
                self.annotationPayloads.append(bytes); return self.acceptAnnotations
            }), registry: registry, nowNanos: { [weak self] in self?.time ?? 0 },
            sendDatagram: { [weak self] bytes, session, done in
                guard let self else { done(false); return }
                if self.rejectNextAudioEnqueues > 0 { self.rejectNextAudioEnqueues -= 1; done(false); return }
                guard let flow = self.flows[session],
                      let sealed = try? self.registry.sealMedia(bytes, sessionID: session, acceptedFlowID: flow,
                                                               channel: .audio, now: self.seconds) else { done(false); return }
                self.datagrams.append((session, sealed))
                if self.holdAudioCompletions { self.audioCompletions.append(done) } else { done(true) }
            }, cancelDatagram: { [weak self] in self?.flows.removeValue(forKey: $0) },
            scheduleAudioRetry: { [weak self] in self?.audioRetries.append($0) })
        try queue.sync {
            try host.addPeer(credentials: publisher, send: { [weak self] bytes, done in
                guard let self else { return }
                if let message = try? MediaControlWireMessage(encoded: bytes) {
                    self.messages.append(message)
                    if case .subscribed(_, _, let port) = message { self.grantedPort = port }
                    if case .anchor = message, self.holdNextAnchor {
                        self.holdNextAnchor = false; self.heldAnchorCompletion = done; return
                    }
                } else if self.holdAnnotationCompletions {
                    self.annotationCompletions.append(done); return
                }
                done(.success(()))
            }, close: { [weak self] in if let self { self.closed.append(self.publisher.connectionID) } })
        }
    }
    static func credentials(role: ReliableChannelRole = .mediaControl,
                            initiatorCapabilities: PeerCapabilities = .desktop, initiatorID: UUID = UUID()) throws
        -> (host: AuthenticatedChannelCredentials, receiver: AuthenticatedChannelCredentials) {
        let initiator = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: initiatorCapabilities)
        let responder = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop)
        let transcript = try AdmissionTranscript(roomID: NetworkFixture.room, initiatorID: initiatorID,
            responderID: NetworkFixture.sender, connectionID: UUID(), initiatorKeyHash: Data(repeating: 1, count: 32),
            responderKeyHash: Data(repeating: 2, count: 32), initiatorNonce: Data(repeating: 3, count: 32),
            responderNonce: Data(repeating: 4, count: 32), initiatorOffer: initiator, responderOffer: responder,
            policy: .secureV2, channelRole: role, admissionKind: .publicRoom)
        return (.init(transcript: transcript, localRole: .responder, rootSecret: NetworkFixture.key),
                .init(transcript: transcript, localRole: .initiator, rootSecret: NetworkFixture.key))
    }
    func send(_ message: MediaControlWireMessage) {
        guard let bytes = try? message.encoded() else { Issue.record("Test constructed invalid media message"); return }
        host.receive(bytes, connectionID: publisher.connectionID)
    }
    func subscribe() throws -> MediaSubscriptionTicket {
        send(.subscribe(requestID: UUID(), broadcasterEpoch: 7, channels: [.audio]))
        return try lastTicket()
    }
    func renew(_ old: MediaSubscriptionTicket) throws -> MediaSubscriptionTicket {
        send(.renew(requestID: UUID(), stream: .init(ticket: old)))
        return try lastTicket()
    }
    func lastTicket() throws -> MediaSubscriptionTicket {
        try #require(messages.compactMap { if case .subscribed(_, let ticket, _) = $0 { return ticket }; return nil }.last)
    }
    func validate(_ ticket: MediaSubscriptionTicket, credentials: AuthenticatedChannelCredentials? = nil) throws {
        let receiver = credentials ?? self.receiver
        let flow = UUID(); flows[ticket.sessionID] = flow
        let probe = try receiver.makeReturnPathProbe(ticket: ticket)
        let challenge = try registry.receiveProbe(probe, sessionID: ticket.sessionID, acceptedFlowID: flow, now: seconds)
        let response = try receiver.answerReturnPathChallenge(challenge, ticket: ticket)
        _ = try registry.confirmReturnPathResponse(response, sessionID: ticket.sessionID, acceptedFlowID: flow, now: seconds)
        host.subscriptionValidated(ticket.sessionID)
    }
    func ack(_ anchor: MediaStreamAnchor) {
        send(.anchorReady(stream: anchor.stream, frameIndex: anchor.frameIndex, captureTimeNanos: anchor.captureTimeNanos,
                         hostPlaybackTimeNanos: anchor.hostPlaybackTimeNanos))
    }
    func activate() throws -> MediaSubscriptionTicket {
        let ticket = try subscribe(); try validate(ticket); ack(try #require(anchors.last)); return ticket
    }
}
