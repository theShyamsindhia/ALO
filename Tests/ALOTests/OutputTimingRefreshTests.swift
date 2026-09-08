import AVFoundation
import ALOCore
import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct OutputTimingRefreshTests {
    @Test(arguments: [false, true])
    func rejectedLatencyClearsAllowanceInActualRefreshPath(configurationChange: Bool) throws {
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 960)
        var measured = SynchronizedPlayer.OutputTimingMeasurement(latencyNanos: 1_000_000,
            bufferFrames: 512, safetyFrames: 48, sampleRate: 48_000)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(),
            outputTimingMeasurement: { measured })
        defer { player.stop(); output.engine.stop() }
        player.clockOffsetNanos = 0
        player.accept(AudioPacket(sequence: 0, frameIndex: 0,
            captureTimeNanos: MonotonicClock.nowNanos() + 20_000_000_000,
            samples: [Int16](repeating: 0, count: 480)))
        // Offline mode needs a sample-clock start before querying player time;
        // a future host-time start alone has neither valid clock in this mode.
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        node.stop()
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600))
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<2 { try #require(pcm.floatChannelData)[channel].initialize(repeating: 0, count: Int(pcm.frameLength)) }
        node.scheduleBuffer(pcm, completionHandler: nil)
        node.play()
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        func poll() throws {
            try #require(try output.engine.renderOffline(960, to: scratch) == .success)
            player.maintainSync()
        }
        try poll()
        #expect(try #require(player.renderObservation?.sample.permittedFutureLeadMilliseconds) > 0)
        let originalHeadroom = player.renderSchedulingHeadroomForTimingNanos
        measured.latencyNanos = 0
        measured.bufferFrames = 1_024
        player.refreshOutputTimingForTesting(configurationChange: configurationChange)
        try poll()
        #expect(player.outputLatencyForTimingNanos == 1_000_000)
        #expect(player.renderObservation?.sample.permittedFutureLeadMilliseconds == nil)
        #expect(try #require(player.renderObservation?.sample.outputBufferMilliseconds) > 20)
        if !configurationChange { #expect(player.renderSchedulingHeadroomForTimingNanos == originalHeadroom) }
        measured.latencyNanos = 2_000_000
        player.refreshOutputTimingForTesting(configurationChange: configurationChange)
        try poll()
        #expect(player.outputLatencyForTimingNanos == 2_000_000)
        #expect(try #require(player.renderObservation?.sample.permittedFutureLeadMilliseconds) > 40)
        #expect(player.syncReport().resyncCount == 0)
    }
}
