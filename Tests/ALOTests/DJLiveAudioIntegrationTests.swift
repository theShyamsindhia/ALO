import AVFoundation
import Testing
import ALOCore
@testable import ALO

@Suite(.serialized)
struct DJLiveAudioIntegrationTests {
    @Test func receiverProcessesOnlyOrderedAdmittedMediaOnce() throws {
        let live = DJLiveAudio()
        live.configure(stage: .listening)
        defer { live.configure(stage: nil) }
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        // Set manual rendering before SynchronizedPlayer starts its graph. Nothing
        // reaches a hardware output, including scheduled future audio packets.
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: live)
        defer { player.stop(); output.engine.stop() }
        player.clockOffsetNanos = 0
        player.setTargetLatencyNanos(250_000_000)
        let capture = MonotonicClock.nowNanos() + 500_000_000
        func packet(_ sequence: UInt32) -> AudioPacket {
            AudioPacket(sequence: sequence, frameIndex: UInt64(sequence) * 240,
                        captureTimeNanos: capture + UInt64(sequence) * 5_000_000,
                        samples: [Int16](repeating: Int16(sequence + 1) * 100, count: 480))
        }
        player.accept(packet(0))
        #expect(abs(live.snapshot().historyDuration - 0.005) < 0.000001)
        player.accept(packet(2)) // Must wait for sequence 1 in the existing player queue.
        #expect(abs(live.snapshot().historyDuration - 0.005) < 0.000001)
        player.accept(packet(0)) // Already admitted replay.
        #expect(abs(live.snapshot().historyDuration - 0.005) < 0.000001)
        player.accept(packet(1))
        #expect(abs(live.snapshot().historyDuration - 0.015) < 0.000001)
        #expect(player.pendingPlaybackPacketCount == 0)
        player.accept(packet(2))
        #expect(abs(live.snapshot().historyDuration - 0.015) < 0.000001)
    }

    @Test func broadcasterLocalPlaybackDoesNotEnterListeningHistory() throws {
        let live = DJLiveAudio()
        live.configure(stage: .broadcast)
        defer { live.configure(stage: nil) }
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: live)
        defer { player.stop(); output.engine.stop() }
        player.clockOffsetNanos = 0
        player.setTargetLatencyNanos(250_000_000)
        player.accept(AudioPacket(sequence: 0, frameIndex: 0,
            captureTimeNanos: MonotonicClock.nowNanos() + 500_000_000,
            samples: [Int16](repeating: 1000, count: 480)))
        #expect(live.snapshot().historyDuration == 0)
    }
}
