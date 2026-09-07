import AVFoundation
import Foundation
import Testing
import ALOCore
@testable import ALO

/// Native offline PCM with controlled admission time, not acoustic or valid-host-clock evidence.
@Suite(.serialized) @MainActor
struct ContiguousUnderrunTests {
    @Test(arguments: [UInt64(0), 20_834, 60_000_000], [0, 1, 2, 3])
    func contiguousSourceFramesDoNotHideNativeUnderrun(gapNanos: UInt64, timingChange: Int) async throws {
        var fixtureNow = MonotonicClock.nowNanos()
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        var measurement = SynchronizedPlayer.OutputTimingMeasurement(latencyNanos: 100_000_000,
            bufferFrames: 512, safetyFrames: 48, sampleRate: 48_000)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(), outputTimingMeasurement: { measurement }, nowNanos: { fixtureNow })
        defer { player.stop(); output.engine.stop() }
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        player.clockOffsetNanos = 0
        let capture = fixtureNow
        player.accept(AudioPacket(sequence: 0, frameIndex: 0, captureTimeNanos: capture,
                                  samples: [Int16](repeating: 0, count: 480)))
        try #require(player.expectedSequenceForTesting == 1)
        // AVAudioPlayerNode ignores host scheduling offline. Keep the real
        // wrapper's anchor/sequence state, adapting only its native start as in
        // ManualRenderTimingProbeTests and ExpiredConcealmentTests.
        node.stop()
        let seed = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        seed.frameLength = 240
        for channel in 0..<2 { try #require(seed.floatChannelData)[channel].initialize(repeating: 0, count: 240) }
        node.scheduleBuffer(seed, completionHandler: nil)
        node.play()
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        func render() throws { try #require(try output.engine.renderOffline(240, to: scratch) == .success) }
        try render()
        let firstRender = try #require(node.lastRenderTime)
        let firstSample = try #require(node.playerTime(forNodeTime: firstRender)).sampleTime
        let gapFrames = Int(gapNanos * 48_000 / 1_000_000_000)
        for _ in 0..<(gapFrames / 240) {
            try render()
            #expect((0..<240).allSatisfy { abs(scratch.floatChannelData![0][$0]) < 0.001 })
        }
        if gapFrames % 240 != 0 {
            try #require(try output.engine.renderOffline(AVAudioFrameCount(gapFrames % 240), to: scratch) == .success)
        }
        let gapRender = try #require(node.lastRenderTime)
        let gapSample = try #require(node.playerTime(forNodeTime: gapRender)).sampleTime
        try #require(gapSample - firstSample == Int64(gapFrames))
        try #require(node.isPlaying && !gapRender.isHostTimeValid)

        let desired = capture + 5_000_000 + player.activePlayoutDelayNanos - player.outputLatencyForTimingNanos
        let wake = gapNanos == 0 ? desired - 20_000_000 : desired + gapNanos
        fixtureNow = wake
        let arrival = fixtureNow
        // Keep the current 100ms late-packet reset branch out of this RED.
        try #require(arrival < desired + 90_000_000,
                     "Fixture missed the under-threshold arrival window")
        switch timingChange {
        case 1: player.setTargetLatencyNanos(600_000_000)
        case 2: player.clockOffsetNanos = -300_000_000
        case 3:
            measurement.latencyNanos = 1_000_000
            player.refreshOutputTimingForTesting(configurationChange: true)
        default: break
        }
        if timingChange != 0 {
            let clockOffset = try #require(player.clockOffsetNanos)
            let revisedCapture = try #require(RoomTiming.clientTimeNanos(hostTimeNanos: capture + 5_000_000,
                clockOffsetNanos: clockOffset))
            let revised = revisedCapture + player.activePlayoutDelayNanos - player.outputLatencyForTimingNanos
            try #require(revised > fixtureNow + player.renderSchedulingHeadroomForTimingNanos,
                         "Fixture timing mutation must actually move the desired deadline beyond the near-deadline gate")
            if timingChange == 3 { try #require(player.outputLatencyForTimingNanos == 1_000_000) }
        }
        player.accept(AudioPacket(sequence: 1, frameIndex: 240, captureTimeNanos: capture + 5_000_000,
                                  samples: [Int16](repeating: 24_000, count: 480)))
        try #require(player.expectedSequenceForTesting == 2)
        if gapNanos > 0 {
            #expect(player.syncReport().resyncCount == 1)
            #expect(player.syncReport().driftNanos == nil)
            player.accept(AudioPacket(sequence: 2, frameIndex: 480, captureTimeNanos: fixtureNow,
                                      samples: [Int16](repeating: 24_000, count: 480)))
            #expect(player.expectedSequenceForTesting == 3)
            node.play() // Preserve real queued marker; adapt only offline host start.
        } else {
            #expect(player.syncReport().latePacketCount == 0 && player.syncReport().resyncCount == 0)
        }
        var absoluteMarker: Int?
        for block in 0..<20 {
            try render()
            if absoluteMarker == nil,
               let index = (0..<240).first(where: { scratch.floatChannelData![0][$0] > 0.25 }) {
                absoluteMarker = (gapNanos > 0 ? 0 : 240) + block * 240 + index
            }
        }
        let marker = try #require(absoluteMarker, "Timely fixture marker must reach actual native output")
        player.maintainSync()
        let recovery = try #require(player.renderObservation?.sample.contentRecovery)
        #expect(recovery.nativePosition == (gapNanos > 0 ? 1 : 0))
        let lateness = arrival >= desired ? Double(arrival - desired) / 1_000_000 : -Double(desired - arrival) / 1_000_000
        let expectedMarker = gapNanos > 0 ? 0 : 240
        print("CONTIGUOUS_UNDERRUN gapFrames=\(gapFrames) sampleAdvance=\(gapSample - firstSample) arrivalLateMs=\(lateness) marker=\(marker) expectedMarker=\(expectedMarker) displacementMs=\(Double(marker - expectedMarker) / 48) late=\(player.syncReport().latePacketCount) resync=\(player.syncReport().resyncCount)")
        #expect(marker <= (gapNanos > 0 ? 0 : 240) + 960,
                "Free-running native sample time must not silently replace the contiguous content-frame timeline")
    }
}
