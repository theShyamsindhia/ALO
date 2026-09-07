import AVFoundation
import ALOCore
import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct PlayerStopObservationTests {
    @Test(arguments: ["stop", "pause", "reset", "cutover"])
    func explicitStopsRetireSampleContinuity(action: String) throws {
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 960)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio())
        defer { player.stop(); output.engine.stop() }
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        player.clockOffsetNanos = 0
        player.accept(AudioPacket(sequence: 0, frameIndex: 0,
            captureTimeNanos: MonotonicClock.nowNanos() + 20_000_000_000,
            samples: [Int16](repeating: 0, count: 480)))
        node.stop()
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600))
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<2 { try #require(pcm.floatChannelData)[channel].initialize(repeating: 0, count: Int(pcm.frameLength)) }
        node.scheduleBuffer(pcm, completionHandler: nil)
        node.play()
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        for _ in 0..<3 {
            #expect(try output.engine.renderOffline(960, to: scratch) == .success)
            player.maintainSync()
        }
        #expect(try #require(player.renderObservation?.sampleTimeDelta) > 0)
        switch action {
        case "stop": player.stop()
        case "pause": player.setRoomPlayback(playing: false)
        case "reset": player.resetStream()
        default: player.forceResync(atOrAfterCaptureNanos: MonotonicClock.nowNanos())
        }
        #expect(player.renderObservation?.sampleTimeDelta == nil,
                "A deliberate stop is not a backwards sample-clock jump")
    }
}
