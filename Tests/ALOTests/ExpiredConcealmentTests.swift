import AVFoundation
import Foundation
import Testing
import ALOCore
@testable import ALO

/// Offline native output only. Host timestamps are invalid in this mode; the
/// oracle is rendered marker PCM, not acoustic timing or an invented host clock.
@Suite(.serialized) @MainActor
struct ExpiredConcealmentTests {
    @Test(arguments: [0, 1, 9, 10, 200], [UInt32(0), UInt32.max - 1])
    func missingPCMAlreadyRenderedAsSilenceMustNotBeBackfilledAgain(missingPackets: Int, startSequence: UInt32) async throws {
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio())
        defer { player.stop(); output.engine.stop() }
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        player.clockOffsetNanos = 0
        let capture = MonotonicClock.nowNanos()
        func packet(_ sequence: UInt32, marker: Bool = false) -> AudioPacket {
            AudioPacket(sequence: sequence, frameIndex: UInt64(sequence &- startSequence) * 240,
                captureTimeNanos: capture + UInt64(sequence &- startSequence) * 5_000_000,
                samples: [Int16](repeating: marker ? 24_000 : 0, count: 480))
        }
        player.accept(packet(startSequence))
        try #require(player.expectedSequenceForTesting == startSequence &+ 1)
        // Same offline start adaptation as ManualRenderTimingProbeTests: retain
        // the production anchor/admission state, replace only the unsupported
        // host-time native start with a real sample-time player start.
        node.stop()
        let seed = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        seed.frameLength = 240
        for channel in 0..<2 { try #require(seed.floatChannelData)[channel].initialize(repeating: 0, count: 240) }
        node.scheduleBuffer(seed, completionHandler: nil)
        node.play()
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        func render() throws {
            try #require(try output.engine.renderOffline(240, to: scratch) == .success)
        }
        try render()
        let firstRender = try #require(node.lastRenderTime)
        let firstSample = try #require(node.playerTime(forNodeTime: firstRender)).sampleTime
        try #require(firstSample == 240, "Exact adjacent source boundary is valid, not already-passed content")
        // The receiver did not service 200 missing packets. Its actual native
        // player nevertheless rendered one second of zeros with an empty queue.
        let renderedMissingPackets = missingPackets > 10 ? missingPackets : 0
        for _ in 0..<renderedMissingPackets {
            try render()
            #expect((0..<240).allSatisfy { abs(scratch.floatChannelData![0][$0]) < 0.001 })
        }
        let gapRender = try #require(node.lastRenderTime)
        let gapSample = try #require(node.playerTime(forNodeTime: gapRender)).sampleTime
        try #require(!gapRender.isHostTimeValid)
        try #require(gapSample - firstSample == Int64(renderedMissingPackets * 240))
        try #require(node.isPlaying)

        // Deliver the next real packet on time, not a stale packet that enters
        // the separate late-packet reset branch. Capture time and frame index
        // remain aligned with the original production anchor.
        let nextSequence = startSequence &+ UInt32(missingPackets + 1)
        let nextDesired = capture + UInt64(missingPackets + 1) * 5_000_000 + player.activePlayoutDelayNanos
            - player.outputLatencyForTimingNanos
        let missingDesired = capture + 5_000_000 + player.activePlayoutDelayNanos - player.outputLatencyForTimingNanos
        let wakeAt = (missingPackets > 0 && missingPackets <= 10 ? missingDesired : nextDesired) - 20_000_000
        let now = MonotonicClock.nowNanos()
        if now < wakeAt {
            // This is a deadline fixture, not background work: default sleep
            // tolerance coalesced the wake ~82ms beyond its requested instant.
            try await ContinuousClock().sleep(for: .nanoseconds(Int64(wakeAt - now)), tolerance: .zero)
        }
        let arrival = MonotonicClock.nowNanos()
        try #require(arrival <= nextDesired + 50_000_000,
                     "Fixture missed the timely-packet window; not a concealment result")
        if missingPackets > 0 && missingPackets <= 10 {
            try #require(arrival < missingDesired, "Fixture missed the first missing frame's concealment deadline")
        }
        let beforeAccept = MonotonicClock.nowNanos()
        player.accept(packet(nextSequence, marker: true))
        let afterAccept = MonotonicClock.nowNanos()
        try #require(player.expectedSequenceForTesting == nextSequence &+ 1)
        if missingPackets > 10 {
            #expect(player.syncReport().resyncCount == 1, "Expired content must retire the old clock mapping")
            #expect(player.syncReport().driftNanos == nil)
            let freshSequence = nextSequence &+ 1
            player.accept(AudioPacket(sequence: freshSequence, frameIndex: UInt64(missingPackets + 2) * 240,
                captureTimeNanos: MonotonicClock.nowNanos(), samples: [Int16](repeating: 24_000, count: 480)))
            #expect(player.expectedSequenceForTesting == freshSequence &+ 1)
            // No replacement PCM: keep the production-scheduled marker, only
            // adapt the unsupported offline host start to a native immediate start.
            node.play()
        } else {
            try #require(player.syncReport().latePacketCount == 0)
            try #require(player.syncReport().resyncCount == 0,
                         "Timely single loss must retain the original timeline")
        }
        var markerFrame: Int?
        for block in 0..<220 {
            try render()
            if markerFrame == nil,
               let index = (0..<240).first(where: { scratch.floatChannelData![0][$0] > 0.25 }) {
                markerFrame = block * 240 + index
            }
        }
        let marker = try #require(markerFrame, "The real packet marker must reach native output")
        player.maintainSync()
        let recovery = try #require(player.renderObservation?.sample.contentRecovery)
        #expect(recovery.concealment == (missingPackets > 10 ? 1 : 0))
        print("EXPIRED_CONCEALMENT missingPackets=\(missingPackets) gapSampleAdvance=\(gapSample - firstSample) markerAfterAppendFrames=\(marker) markerDelayMs=\(Double(marker) / 48) acceptMs=\(Double(afterAccept - beforeAccept) / 1_000_000) late=\(player.syncReport().latePacketCount) resync=\(player.syncReport().resyncCount)")
        #expect(marker <= 2_880,
                "Already-rendered underrun silence must not be queued again ahead of timely live PCM")
        if missingPackets > 0 && missingPackets <= 10 {
            #expect((missingPackets * 240...missingPackets * 240 + 96).contains(marker),
                    "Timely missing packets contribute exact source-frame silence plus bounded graph delay")
        }
    }
}
