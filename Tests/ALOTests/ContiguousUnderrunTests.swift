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
        try await exerciseBoundary(gapNanos: gapNanos, timingChange: timingChange, seededPackets: 1)
    }
    private func exerciseBoundary(gapNanos: UInt64, timingChange: Int, seededPackets: Int) async throws {
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
        if seededPackets == 2 {
            player.accept(AudioPacket(sequence: 1, frameIndex: 240, captureTimeNanos: capture + 5_000_000,
                                      samples: [Int16](repeating: 0, count: 480)))
        }
        try #require(player.expectedSequenceForTesting == UInt32(seededPackets))
        player.maintainSync()
        try #require(player.pendingPlaybackPacketCount == 0)
        try #require(player.outstandingPlaybackBufferCount == seededPackets)
        // AVAudioPlayerNode ignores host scheduling offline. Keep the real
        // wrapper's anchor/sequence state, adapting only its native start as in
        // ManualRenderTimingProbeTests and ExpiredConcealmentTests.
        node.stop()
        let seed = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seededPackets * 240)))
        seed.frameLength = seed.frameCapacity
        for channel in 0..<2 { try #require(seed.floatChannelData)[channel].initialize(repeating: 0, count: seededPackets * 240) }
        node.scheduleBuffer(seed, completionHandler: nil)
        node.play()
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        func render() throws { try #require(try output.engine.renderOffline(240, to: scratch) == .success) }
        try render()
        let firstRender = try #require(node.lastRenderTime)
        let firstSample = try #require(node.playerTime(forNodeTime: firstRender)).sampleTime
        try #require(firstSample == 240)
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

        let nextCapture = capture + UInt64(seededPackets) * 5_000_000
        let desired = nextCapture + player.activePlayoutDelayNanos - player.outputLatencyForTimingNanos
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
            let revisedCapture = try #require(RoomTiming.clientTimeNanos(hostTimeNanos: nextCapture,
                clockOffsetNanos: clockOffset))
            let revised = revisedCapture + player.activePlayoutDelayNanos - player.outputLatencyForTimingNanos
            try #require(revised > fixtureNow + player.renderSchedulingHeadroomForTimingNanos,
                         "Fixture timing mutation must actually move the desired deadline beyond the near-deadline gate")
            if timingChange == 3 { try #require(player.outputLatencyForTimingNanos == 1_000_000) }
        }
        player.accept(AudioPacket(sequence: UInt32(seededPackets), frameIndex: UInt64(seededPackets * 240), captureTimeNanos: nextCapture,
                                  samples: [Int16](repeating: 24_000, count: 480)))
        player.maintainSync() // Real maintenance admits the held tail before the native oracle.
        try #require(player.expectedSequenceForTesting == UInt32(seededPackets + 1))
        let needsRecovery = seededPackets == 1
        if needsRecovery {
            #expect(player.syncReport().resyncCount == 1)
            #expect(player.syncReport().driftNanos == nil)
            if player.outstandingPlaybackBufferCount == 0 {
                // A late first packet was dropped after retirement. Only this
                // branch needs a new live capture; otherwise the first packet
                // already anchors the new timeline and must be rendered intact.
                player.accept(AudioPacket(sequence: UInt32(seededPackets + 1), frameIndex: UInt64((seededPackets + 1) * 240), captureTimeNanos: fixtureNow,
                                          samples: [Int16](repeating: 24_000, count: 480)))
                #expect(player.expectedSequenceForTesting == UInt32(seededPackets + 2))
            }
            try #require(player.outstandingPlaybackBufferCount > 0)
            node.play() // Preserve real queued marker; adapt only offline host start.
        } else {
            #expect(player.syncReport().latePacketCount == 0 && player.syncReport().resyncCount == 0)
        }
        var absoluteMarker: Int?
        for block in 0..<20 {
            try render()
            if absoluteMarker == nil,
               let index = (0..<240).first(where: { scratch.floatChannelData![0][$0] > 0.25 }) {
                absoluteMarker = (needsRecovery ? 0 : 240) + block * 240 + index
            }
        }
        let marker = try #require(absoluteMarker, "Timely fixture marker must reach actual native output")
        player.maintainSync()
        let recovery = try #require(player.renderObservation?.sample.contentRecovery)
        #expect(recovery.nativePosition == (needsRecovery ? 1 : 0))
        let lateness = arrival >= desired ? Double(arrival - desired) / 1_000_000 : -Double(desired - arrival) / 1_000_000
        let expectedMarker = needsRecovery ? 0 : seededPackets * 240
        print("CONTIGUOUS_UNDERRUN gapFrames=\(gapFrames) sampleAdvance=\(gapSample - firstSample) arrivalLateMs=\(lateness) marker=\(marker) expectedMarker=\(expectedMarker) displacementMs=\(Double(marker - expectedMarker) / 48) late=\(player.syncReport().latePacketCount) resync=\(player.syncReport().resyncCount)")
        #expect(marker <= expectedMarker + 960,
                "Free-running native sample time must not silently replace the contiguous content-frame timeline")
        if !needsRecovery {
            #expect((expectedMarker...expectedMarker + 96).contains(marker),
                    "Known queued prefix preserves its exact original source-frame placement")
        }
    }
    @Test func knownQueuedPrefixPreservesPositiveNativeLead() async throws {
        try await exerciseBoundary(gapNanos: 0, timingChange: 0, seededPackets: 2)
    }
}
