import Foundation
import Testing
@testable import ALONetworking

@Suite("Admitted independent video transport")
struct MediaVideoSessionTests {
    @Test func pausedAudioStillAuthorizesIndependentScreenFrames() throws {
        let h = try MediaVideoHarness()
        try h.audio.queue.sync {
            h.audio.anchorState = .paused
            try h.start()
            h.audio.host.submitVideo(h.frame())
        }
        try h.audio.queue.sync {
            try h.pump()
            #expect(h.frames.count == 1 && h.states.last == .active)
            h.audio.host.publishAudio(h.audio.packet)
            #expect(h.audio.datagrams.isEmpty && h.audio.closed.isEmpty)
        }
    }

    @Test func idleVideoUsesAuthenticatedHeartbeatWithoutReconnectChurn() throws {
        let h = try MediaVideoHarness()
        try h.audio.queue.sync { try h.start(); h.audio.host.submitVideo(h.frame()) }
        try h.audio.queue.sync {
            try h.pump()
            for _ in 0..<4 {
                h.audio.time += 2_000_000_000
                h.audio.host.tick(); try h.pump(); h.video.tick()
            }
            #expect(h.connections.count == 1 && h.states.last == .active)
            #expect(h.frames.count == 1 && h.audio.closed.isEmpty)
            // A lost heartbeat/half-open video link still repairs independently.
            h.audio.time += 6_000_000_000; h.video.tick()
            #expect(h.states.last == .recovering)
            #expect(h.audio.closed.isEmpty)
        }
    }

    @Test func openerTimeoutRetiresLateCompletionAndRetries() throws {
        let h = try MediaVideoHarness()
        try h.audio.queue.sync {
            h.deferOpens = true; try h.start()
            #expect(h.connections.isEmpty && h.openReplies.count == 1)
            h.audio.time += MediaVideoWire.openDeadlineNanos; h.video.tick()
            #expect(h.states.last == .recovering)
            h.audio.time += 500_000_000; h.video.tick()
            #expect(h.openReplies.count == 2)
            h.openReplies.removeFirst()(.failure(SecurePeerChannelError.timedOut))
            #expect(h.states.last == .recovering)
        }
    }

    @Test func outerFrameCannotHideTrailingBytes() throws {
        let frame = VideoFrame(captureTimeNanos: 10, width: 64, height: 64, isKeyframe: true,
            parameterSet1: Data([1]), parameterSet2: Data([2]), payload: Data([9])).encoded() + Data([0])
        var assembler = MediaVideoAssembler()
        #expect(throws: SecureTransportError.self) {
            try assembler.append(MediaVideoWire.chunk(frame, sequence: 1, offset: 0), now: 0)
        }
    }
    @Test func videoBindsActualAudioLeaseAndAssemblesConfigurationBearingIDR() throws {
        let h = try MediaVideoHarness()
        try h.audio.queue.sync {
            try h.start()
            #expect(h.frames.isEmpty)
            let frame = h.frame(payloadBytes: 500_000)
            h.audio.host.submitVideo(frame)
        }
        try h.audio.queue.sync {
            try h.pump()
            #expect(h.frames.count == 1)
            #expect(h.frames[0].payload.count == 500_000)
            #expect(h.states.last == .active)
            #expect(h.audio.closed.isEmpty)
        }
    }

    @Test func wrongPeerAndUnissuedStreamFailOnlyVideo() throws {
        let h = try MediaVideoHarness()
        try h.audio.queue.sync {
            try h.start()
            let stranger = try MediaHostHarness.credentials(role: .video)
            var strangerClosed = false
            try h.audio.host.addVideoPeer(credentials: stranger.host, send: { _, done in done(.success(())) },
                                         close: { strangerClosed = true })
            h.audio.host.receiveVideoBinding(try MediaVideoWire.binding(h.stream, accepted: false),
                                            connectionID: stranger.host.connectionID)
            #expect(strangerClosed)
            let samePeer = try MediaHostHarness.credentials(role: .video, initiatorID: h.audio.receiver.localPeerID)
            var unissuedClosed = false
            try h.audio.host.addVideoPeer(credentials: samePeer.host, send: { _, done in done(.success(())) },
                                         close: { unissuedClosed = true })
            let unissued = MediaStreamIdentifier(sessionID: UUID(), broadcasterEpoch: 7, generation: 1)
            h.audio.host.receiveVideoBinding(try MediaVideoWire.binding(unissued, accepted: false),
                                            connectionID: samePeer.host.connectionID)
            #expect(unissuedClosed && h.audio.closed.isEmpty)
            h.audio.host.publishAudio(h.audio.packet)
            #expect(h.audio.datagrams.count == 1)
        }
    }

    @Test func malformedVideoRetriesIndependentlyAndStaleCallbacksAreIgnored() throws {
        let h = try MediaVideoHarness()
        try h.audio.queue.sync { try h.start(); h.audio.host.submitVideo(h.frame()) }
        try h.audio.queue.sync {
            try h.pump()
            let old = try #require(h.connections.first)
            old.payload?(Data([1, 2, 3]))
            #expect(h.states.last == .recovering)
            h.audio.host.publishAudio(h.audio.packet)
            #expect(h.audio.datagrams.count == 1 && h.audio.closed.isEmpty)
            h.audio.time += 500_000_000; h.video.tick(); try h.pump()
            #expect(h.connections.count == 2)
            old.failed?(); old.payload?(Data([1]))
            h.audio.host.submitVideo(h.frame())
        }
        try h.audio.queue.sync {
            try h.pump()
            #expect(h.frames.count == 2 && h.states.last == .active)
            h.video.stop()
            h.connections.last?.failed?()
            #expect(h.states.last == .stopped && h.audio.closed.isEmpty)
        }
    }

    @Test func partialFrameExpiryAndChunkSplicingFailClosed() throws {
        let frame = VideoFrame(captureTimeNanos: 10, width: 64, height: 64, isKeyframe: true,
            parameterSet1: Data([1]), parameterSet2: Data([2]), payload: Data(repeating: 9, count: 300_000)).encoded()
        var assembler = MediaVideoAssembler()
        #expect(try assembler.append(MediaVideoWire.chunk(frame, sequence: 1, offset: 0), now: 0) == nil)
        #expect(throws: SecureTransportError.self) {
            try assembler.append(MediaVideoWire.chunk(frame, sequence: 2, offset: MediaVideoWire.chunkBytes), now: 1)
        }
        #expect(assembler.expired(now: 5_000_000_000))
        #expect(throws: SecureTransportError.self) {
            try assembler.append(MediaVideoWire.chunk(frame, sequence: 1, offset: MediaVideoWire.chunkBytes), now: 5_000_000_000)
        }
    }

    @Test func pendingVideoSendDeadlineDoesNotRevokeAudioSubscription() throws {
        let h = try MediaVideoHarness()
        try h.audio.queue.sync { try h.start(); h.holdFrameSends = true; h.audio.host.submitVideo(h.frame()) }
        h.audio.queue.sync {
            #expect(!h.heldSends.isEmpty)
            h.audio.time += 5_100_000_000; h.audio.host.tick()
            #expect(h.audio.registry.containsLiveSubscription(sessionID: h.stream.sessionID, now: h.audio.seconds))
            #expect(h.audio.closed.isEmpty)
            h.audio.host.publishAudio(h.audio.packet)
            #expect(h.audio.datagrams.count == 1)
            for done in h.heldSends { done(.success(())) }
        }
    }
}

private final class MediaVideoHarness {
    let audio: MediaHostHarness
    var stream: MediaStreamIdentifier!
    var video: MediaVideoReceiver!
    var connections: [MediaVideoConnection] = []
    var fromHost: [(MediaVideoConnection, Data)] = []
    var frames: [VideoFrame] = []
    var states: [VideoReceiverState] = []
    var holdFrameSends = false
    var heldSends: [(Result<Void, Error>) -> Void] = []
    var deferOpens = false
    var openReplies: [(Result<MediaVideoConnection, Error>) -> Void] = []
    init() throws { audio = try MediaHostHarness() }
    func start() throws {
        audio.host.publisherReady(port: 54321)
        stream = .init(ticket: try audio.activate())
        audio.host.setVideoEnabled(true)
        video = MediaVideoReceiver(credentials: audio.receiver, open: { [weak self] reply in
            guard let self else { reply(.failure(SecureTransportError.invalidState)); return }
            if self.deferOpens { self.openReplies.append(reply); return }
            do {
                let peer = try MediaHostHarness.credentials(role: .video, initiatorID: self.audio.receiver.localPeerID)
                let connection = MediaVideoConnection(credentials: peer.receiver,
                    send: { [weak self] data, done in
                        self?.audio.host.receiveVideoBinding(data, connectionID: peer.host.connectionID); done(.success(()))
                    }, close: { [weak self] in self?.audio.host.removeVideoPeer(connectionID: peer.host.connectionID) })
                try self.audio.host.addVideoPeer(credentials: peer.host, send: { [weak self, weak connection] data, done in
                    guard let self, let connection else { done(.failure(SecurePeerChannelError.cancelled)); return }
                    if self.holdFrameSends, (try? MediaVideoWire.decodeBinding(data, accepted: true)) == nil {
                        self.heldSends.append(done); return
                    }
                    self.fromHost.append((connection, data)); done(.success(()))
                }, close: { [weak connection] in connection?.failed?() })
                self.connections.append(connection); reply(.success(connection))
            } catch { reply(.failure(error)) }
        }, callbacks: .init(frame: { [weak self] frame, _, _ in self?.frames.append(frame) },
                            state: { [weak self] in self?.states.append($0) }),
        authorized: { [weak self] stream in
            guard let self else { return false }
            return self.audio.registry.containsLiveSubscription(sessionID: stream.sessionID, now: self.audio.seconds)
        }, requestIDR: { _ in }, now: { [weak self] in self?.audio.time ?? 0 })
        video.select(stream: stream, captureFloor: audio.time, generation: 1)
        try pump()
    }
    func frame(payloadBytes: Int = 100) -> VideoFrame {
        .init(captureTimeNanos: audio.time, width: 1280, height: 720, isKeyframe: true,
              parameterSet1: Data([1, 2]), parameterSet2: Data([3, 4]), payload: Data(repeating: 5, count: payloadBytes))
    }
    func pump() throws {
        var count = 0
        while !fromHost.isEmpty {
            count += 1; guard count < 1_000 else { throw SecureTransportError.capacity }
            let (connection, data) = fromHost.removeFirst(); connection.payload?(data)
        }
    }
}
