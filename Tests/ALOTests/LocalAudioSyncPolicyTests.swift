import Foundation
import Testing
import ALOCore

@Suite("Local automatic audio synchronization")
struct LocalAudioSyncPolicyTests {
    @Test func sustainedDriftTriggersOnceAndHonorsCooldown() {
        var policy = LocalAudioSyncPolicy()
        for tick in 0..<20 {
            let result = policy.shouldRealign(driftNanos: 45_000_000, now: UInt64(tick) * 50_000_000)
            #expect(!result)
        }
        let trigger = policy.shouldRealign(driftNanos: 45_000_000, now: 1_000_000_000)
        #expect(trigger)
        for tick in 21..<180 {
            let result = policy.shouldRealign(driftNanos: 90_000_000, now: UInt64(tick) * 50_000_000)
            #expect(!result)
        }
        for tick in 180..<200 {
            let result = policy.shouldRealign(driftNanos: 90_000_000, now: UInt64(tick) * 50_000_000)
            #expect(!result)
        }
        let again = policy.shouldRealign(driftNanos: 90_000_000, now: 10_000_000_000)
        #expect(again)
    }

    @Test func spikesUnknownAndInterruptedMeasurementsDoNotTrigger() {
        var policy = LocalAudioSyncPolicy()
        let start = policy.shouldRealign(driftNanos: 50_000_000, now: 0)
        let spike = policy.shouldRealign(driftNanos: 0, now: 50_000_000)
        let unknown = policy.shouldRealign(driftNanos: nil, now: 100_000_000)
        let resumed = policy.shouldRealign(driftNanos: 100_000_000, now: 5_000_000_000)
        #expect(!start && !spike && !unknown && !resumed)
        let gap = policy.shouldRealign(driftNanos: 100_000_000, now: 6_000_000_000)
        #expect(!gap)
    }

    @Test func optOutAndMandatoryRecoveryResetEvidence() {
        var policy = LocalAudioSyncPolicy()
        policy.setEnabled(false)
        for tick in 0..<30 {
            let result = policy.shouldRealign(driftNanos: 500_000_000, now: UInt64(tick) * 50_000_000)
            #expect(!result)
        }
        policy.didRealign(at: 2_000_000_000)
        policy.setEnabled(true)
        #expect(policy.isCoolingDown(at: 3_000_000_000))
        #expect(!policy.isCoolingDown(at: 10_000_000_000))
    }

    @Test func reportsAdvertiseReceiverOwnershipAndDecodeLegacy() throws {
        let report = PlaybackSyncReport(measuredAtNanos: 1, latenessNanos: 0,
            latePacketCount: 0, resyncCount: 0, automaticSyncEnabled: false)
        let decoded = try JSONDecoder().decode(PlaybackSyncReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.automaticSyncEnabled == false)
        let legacy = Data(#"{"measuredAtNanos":1,"latenessNanos":0,"latePacketCount":0,"resyncCount":0}"#.utf8)
        #expect(try JSONDecoder().decode(PlaybackSyncReport.self, from: legacy).automaticSyncEnabled == nil)
    }
}

@Suite("Render clock drift estimates")
struct RenderDriftEstimateTests {
    private func estimate(now: UInt64 = 2_000_000_000, render: UInt64 = 2_000_000_000,
                          sample: Int64 = 48_000, rate: Double = 48_000,
                          output: UInt64 = 0, anchor: UInt64 = 750_000_000) -> RenderDriftEstimate? {
        RenderDriftEstimate(nowNanos: now, renderLocalNanos: render, renderHostNanos: render,
                            outputLatencyNanos: output, captureAnchorNanos: anchor,
                            playoutDelayNanos: 250_000_000, sampleTime: sample, sampleRate: rate)
    }

    @Test func staleOrFutureRenderClockCannotReportFreshZero() {
        #expect(estimate(now: 2_300_000_000) == nil)
        #expect(estimate(now: 1_999_999_999) == nil)
        #expect(estimate(now: 2_250_000_000)?.magnitudeNanos == 0)
    }

    @Test func usesRenderSampleRateAndReportedOutputLatency() {
        #expect(estimate(sample: 44_100, rate: 44_100)?.magnitudeNanos == 0)
        let late = estimate(sample: 45_600)
        #expect(abs((late?.errorSeconds ?? 0) - 0.05) < 0.000001)
        #expect((late?.magnitudeNanos ?? 0) >= 49_999_999)
        #expect(estimate(output: 50_000_000)?.magnitudeNanos ?? 0 >= 49_999_999)
        #expect((estimate(sample: 50_400)?.errorSeconds ?? 0) < 0)
    }

    @Test func invalidAndNotStartedSamplesAreUnknown() {
        #expect(estimate(sample: -1) == nil)
        #expect(estimate(rate: 0) == nil)
        #expect(estimate(rate: .nan) == nil)
        #expect(estimate(rate: .infinity) == nil)
        #expect(estimate(anchor: 2_000_000_000) == nil)
        #expect(estimate(output: .max) == nil)
        #expect(estimate(anchor: .max) == nil)
    }
}


@Suite("Capture content timeline alignment")
struct CaptureTimelineAlignmentTests {
    @Test func tapGapsInvalidateOldAnchorDespiteContiguousPacketFrames() {
        for gap in [UInt64(200_000_000), 400_000_000] {
            let packetizer = AudioPacketizer()
            let first = packetizer.append(samples: [Int16](repeating: 1, count: 480),
                                          captureTimeNanos: 1_000_000_000)[0]
            packetizer.discardPendingSamples()
            let resumed = packetizer.append(samples: [Int16](repeating: 2, count: 480),
                                            captureTimeNanos: 1_005_000_000 + gap)[0]
            #expect(resumed.frameIndex == first.frameIndex + 240)
            #expect(CaptureTimelineAlignment.check(frameIndex: resumed.frameIndex,
                captureNanos: resumed.captureTimeNanos, anchorFrameIndex: first.frameIndex,
                anchorCaptureNanos: first.captureTimeNanos) == .discontinuous)
            // A freshly joined renderer, and a repaired existing renderer, now
            // agree on the post-gap anchor instead of retaining a 200–400 ms offset.
            #expect(CaptureTimelineAlignment.check(frameIndex: resumed.frameIndex + 240,
                captureNanos: resumed.captureTimeNanos + 5_000_000,
                anchorFrameIndex: resumed.frameIndex,
                anchorCaptureNanos: resumed.captureTimeNanos) == .aligned)
        }
    }

    @Test func ordinaryPacketLossAndSmallTimestampJitterDoNotReset() {
        #expect(CaptureTimelineAlignment.check(frameIndex: 48_000, captureNanos: 2_000_000_000,
            anchorFrameIndex: 0, anchorCaptureNanos: 1_000_000_000) == .aligned)
        #expect(CaptureTimelineAlignment.check(frameIndex: 48_000, captureNanos: 2_005_000_000,
            anchorFrameIndex: 0, anchorCaptureNanos: 1_000_000_000) == .aligned)
    }

    @Test func packetsBeforeAnchorAreStaleRatherThanRecoveryTriggers() {
        #expect(CaptureTimelineAlignment.check(frameIndex: 239, captureNanos: 1_005_000_000,
            anchorFrameIndex: 240, anchorCaptureNanos: 1_005_000_000) == .stale)
        #expect(CaptureTimelineAlignment.check(frameIndex: 480, captureNanos: 1_000_000_000,
            anchorFrameIndex: 240, anchorCaptureNanos: 1_005_000_000) == .stale)
    }
}
