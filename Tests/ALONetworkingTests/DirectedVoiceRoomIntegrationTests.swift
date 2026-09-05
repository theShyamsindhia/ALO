import Foundation
import Network
import Testing
@testable import ALONetworking

/// Two isolated secure nodes, real TLS + return-path authenticated UDP, synthetic
/// PCM only. No microphone, speaker, Bluetooth or acoustic accuracy claim.
@Suite("Real secure directed voice alongside media", .serialized)
struct DirectedVoiceRoomIntegrationTests {
    @Test func fixedRecipientVoiceJoinDoesNotInterruptExistingMedia() async throws {
        let room = RoomConfiguration.secure(name: "Directed voice coexistence")
        let hostBox = LiveMediaBox<MediaHostSession?>(nil)
        let voiceBox = LiveMediaBox<DirectedVoiceSession?>(nil)
        let source = try LiveMediaNode(room: room, incoming: { channel, peer in
            if peer.channelRole == .voiceControl { voiceBox.read { $0 }?.attach(channel: channel) }
            else {
                channel.withAuthenticatedCredentials { result in
                    do {
                        guard let host = hostBox.read({ $0 }) else { channel.cancel(); return }
                        try host.attach(channel: channel, credentials: result.get())
                    } catch { channel.cancel() }
                }
            }
        })
        let listener = try LiveMediaNode(room: room)
        defer { hostBox.read { $0 }?.stop(); voiceBox.read { $0 }?.stop(); source.stop(); listener.stop() }
        try source.start(); try listener.start()
        source.mesh.publishBroadcaster(active: true, mediaServiceName: "Synthetic media")
        try await liveMediaEventually { source.epoch != nil }
        let epoch = try #require(source.epoch)
        let timeline = CapturedMediaTimeline()
        let host: MediaHostSession = try await withCheckedThrowingContinuation { done in
            source.mesh.makeMediaHost(callbacks: .init(currentBroadcaster: { .init(peerID: source.id, epoch: epoch) },
                currentAnchor: { _, stream, now in timeline.anchor(for: stream, issuedAtHostNanos: now) })) {
                done.resume(with: $0)
            }
        }
        hostBox.update { $0 = host }
        let capture = LiveMediaCapture(host: host, timeline: timeline); capture.start()
        defer { capture.stop() }
        let transmitter: DirectedVoiceSession = try await withCheckedThrowingContinuation { done in
            source.mesh.makeVoiceSession(callbacks: .init(pcm: { _, _, _, _, _, _ in Issue.record("No reverse voice was authorized") })) {
                if case .success(let session) = $0 { voiceBox.update { $0 = session } }
                done.resume(with: $0)
            }
        }
        let voice = LiveMediaBox<[UInt64]>([])
        let receivedVoice: DirectedVoiceSession = try await withCheckedThrowingContinuation { done in
            listener.mesh.makeVoiceSession(callbacks: .init(pcm: { peer, _, sequence, frame, bytes, _ in
                #expect(peer == source.id && frame == sequence * 480 && bytes.count == 960)
                voice.update { $0.append(sequence) }
            })) { done.resume(with: $0) }
        }
        defer { receivedVoice.stop() }
        let excluded = VoiceSessionIdentifier(sessionID: UUID())
        transmitter.beginTransmitting(session: excluded, recipients: [UUID()])
        // The transmitter already exists, but this later room join is not in its
        // fixed recipient set and cannot gain access simply by subscribing.
        listener.connect(port: try await source.port(), source: source.id)
        try await liveMediaEventually { listener.hasPeer(source.id) }
        receivedVoice.beginReceiving(from: source.id, session: excluded)
        let sink = LiveMediaSink(); sink.open(node: listener, room: room, source: source.id, epoch: epoch)
        defer { sink.stop() }
        try await liveMediaEventually { sink.count >= 30 }
        for _ in 0..<25 {
            transmitter.submitPCM16Mono(Data(repeating: 1, count: 960), captureTimeNanos: MonotonicClock.nowNanos(), session: excluded)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(voice.read { $0.isEmpty })
        let authorized = VoiceSessionIdentifier(sessionID: UUID())
        transmitter.beginTransmitting(session: authorized, recipients: [listener.id])
        receivedVoice.beginReceiving(from: source.id, session: authorized)
        let before = sink.count
        // Capture starts before the voice join/proof finishes and continues for
        // a bounded real network window, rather than requiring a second press.
        for _ in 0..<100 {
            transmitter.submitPCM16Mono(Data(repeating: 2, count: 960), captureTimeNanos: MonotonicClock.nowNanos(), session: authorized)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await liveMediaEventually { voice.read { $0.count >= 20 } }
        #expect(voice.read { Set($0).count == $0.count })
        #expect(sink.count > before + 30 && sink.commits == 1 && sink.errors.isEmpty)
        transmitter.endTransmitting(session: authorized)
        // Drain packets already in flight before asserting the stopped boundary.
        try await Task.sleep(for: .milliseconds(150))
        let finalVoiceCount = voice.read { $0.count }
        for _ in 0..<20 {
            transmitter.submitPCM16Mono(Data(repeating: 3, count: 960), captureTimeNanos: MonotonicClock.nowNanos(), session: authorized)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(voice.read { $0.count } == finalVoiceCount)
        #expect(sink.errors.isEmpty && sink.commits == 1)
    }
}
