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
        var fixtureNow = MonotonicClock.nowNanos()
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(), nowNanos: { fixtureNow })
        defer { player.stop(); output.engine.stop() }
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        player.clockOffsetNanos = 0
        let capture = fixtureNow
        func packet(_ sequence: UInt32, marker: Bool = false) -> AudioPacket {
            AudioPacket(sequence: sequence, frameIndex: UInt64(sequence &- startSequence) * 240,
                captureTimeNanos: capture + UInt64(sequence &- startSequence) * 5_000_000,
                samples: [Int16](repeating: marker ? 24_000 : 0, count: 480))
        }
        // Timely loss retains one known queued packet; appending at an already
        // empty native queue has separate near-future scheduling semantics.
        // The expired case intentionally retains its original empty-queue oracle.
        let seededPackets = missingPackets > 10 ? 1 : 2
        for index in 0..<seededPackets { player.accept(packet(startSequence &+ UInt32(index))) }
        try #require(player.expectedSequenceForTesting == startSequence &+ UInt32(seededPackets))
        player.maintainSync()
        try #require(player.pendingPlaybackPacketCount == 0)
        try #require(player.outstandingPlaybackBufferCount == seededPackets)
        // Same offline start adaptation as ManualRenderTimingProbeTests: retain
        // the production anchor/admission state, replace only the unsupported
        // host-time native start with a real sample-time player start.
        node.stop()
        let seed = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seededPackets * 240)))
        seed.frameLength = seed.frameCapacity
        for channel in 0..<2 { try #require(seed.floatChannelData)[channel].initialize(repeating: 0, count: seededPackets * 240) }
        node.scheduleBuffer(seed, completionHandler: nil)
        node.play()
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        func render() throws {
            try #require(try output.engine.renderOffline(240, to: scratch) == .success)
        }
        try render()
        let firstRender = try #require(node.lastRenderTime)
        let firstSample = try #require(node.playerTime(forNodeTime: firstRender)).sampleTime
        try #require(firstSample == 240, "Exactly one seed packet must have reached the native clock")
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
        let nextSequence = startSequence &+ UInt32(missingPackets + seededPackets)
        let nextDesired = capture + UInt64(missingPackets + seededPackets) * 5_000_000 + player.activePlayoutDelayNanos
            - player.outputLatencyForTimingNanos
        let missingDesired = capture + UInt64(seededPackets) * 5_000_000 + player.activePlayoutDelayNanos - player.outputLatencyForTimingNanos
        let wakeAt = (missingPackets > 0 && missingPackets <= 10 ? missingDesired : nextDesired) - 20_000_000
        // Control admission time; native PCM/source-frame advancement remains real.
        fixtureNow = wakeAt
        let arrival = fixtureNow
        try #require(arrival <= nextDesired + 50_000_000,
                     "Fixture missed the timely-packet window; not a concealment result")
        if missingPackets > 0 && missingPackets <= 10 {
            try #require(arrival < missingDesired, "Fixture missed the first missing frame's concealment deadline")
        }
        let beforeAccept = fixtureNow
        player.accept(packet(nextSequence, marker: true))
        player.maintainSync()
        let afterAccept = fixtureNow
        try #require(player.expectedSequenceForTesting == nextSequence &+ 1)
        if missingPackets > 10 {
            #expect(player.syncReport().resyncCount == 1, "Expired content must retire the old clock mapping")
            #expect(player.syncReport().driftNanos == nil)
            let freshSequence = nextSequence &+ 1
            player.accept(AudioPacket(sequence: freshSequence, frameIndex: UInt64(missingPackets + seededPackets + 1) * 240,
                captureTimeNanos: fixtureNow, samples: [Int16](repeating: 24_000, count: 480)))
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
        #expect(recovery.concealment == 0)
        #expect(recovery.nativePosition == (missingPackets > 10 ? 1 : 0))
        print("EXPIRED_CONCEALMENT missingPackets=\(missingPackets) gapSampleAdvance=\(gapSample - firstSample) markerAfterAppendFrames=\(marker) markerDelayMs=\(Double(marker) / 48) controlledAcceptMs=\(Double(afterAccept - beforeAccept) / 1_000_000) late=\(player.syncReport().latePacketCount) resync=\(player.syncReport().resyncCount)")
        #expect(marker <= 2_880,
                "Already-rendered underrun silence must not be queued again ahead of timely live PCM")
        if missingPackets <= 10 {
            let expected = (seededPackets - 1 + missingPackets) * 240
            #expect((expected...expected + 96).contains(marker),
                    "Known remaining seed PCM plus exact missing-frame silence precedes the real marker")
        }
    }
}
