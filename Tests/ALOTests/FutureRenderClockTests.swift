import ALOCore
import Testing
@testable import ALO

struct FutureRenderClockTests {
    @Test func rejectedLatencyCannotRetainNewFutureAllowance() {
        #expect(AudioOutputRenderBudget.futureLeadAfterLatencyRefresh(proposed: 25_000_000, latencyAccepted: false) == nil)
        #expect(AudioOutputRenderBudget.futureLeadAfterLatencyRefresh(proposed: 25_000_000, latencyAccepted: true) == 25_000_000)
        #expect(AudioOutputRenderBudget.futureLeadAfterLatencyRefresh(proposed: nil, latencyAccepted: true) == nil)
    }

    @Test func invalidExplicitWindowFailsClosedEvenForPastSamples() {
        #expect(!RenderDriftEstimate.clockIsWithinWindow(nowNanos: 100, renderLocalNanos: 99,
            permittedFutureLeadNanos: RenderDriftEstimate.maximumFutureLeadNanos + 1))
    }
    private func estimate(now: UInt64 = 10_000_000_000, render: UInt64 = 10_020_000_000,
                          budget: UInt64 = 25_000_000, sample: Int64 = 48_000,
                          rate: Double = 48_000, captureOffset: Double = 0) -> RenderDriftEstimate? {
        RenderDriftEstimate(nowNanos: now, renderLocalNanos: render, renderHostNanos: render,
            outputLatencyNanos: 0, captureAnchorNanos: 8_750_000_000,
            playoutDelayNanos: 250_000_000, sampleTime: sample, sampleRate: rate,
            captureOffsetNanos: captureOffset, permittedFutureLeadNanos: budget)
    }

    @Test func futurePhaseIsPreservedWhileFreshnessAndHoldoverStayNonfuture() throws {
        let value = try #require(estimate())
        #expect(abs(value.errorSeconds - 0.020) < 0.000_001,
                "Clamping the phase timestamp would falsely report zero drift")
        #expect(value.freshnessNanos == 10_000_000_000)
        var controller = PlaybackRateController()
        let rate = controller.updateFresh(errorSeconds: value.errorSeconds, sampledAtNanos: value.freshnessNanos)
        #expect(rate > 1)
        let briefMissing = controller.handleMissing(at: 10_001_000_000)
        #expect(!briefMissing)
        #expect(controller.rate > 1)
        let beforeExpiry = controller.handleMissing(at: 10_499_999_999)
        #expect(!beforeExpiry)
        let expired = controller.handleMissing(at: 10_500_000_000)
        #expect(expired)
        #expect(controller.rate == 1)
    }

    @Test func pastAndRepeatedSamplesDoNotBecomeFreshOnEveryPoll() throws {
        let past = try #require(estimate(now: 10_200_000_000, render: 10_000_000_000))
        #expect(past.freshnessNanos == 10_000_000_000)
        let repeated = try #require(estimate(now: 10_250_000_000, render: 10_000_000_000))
        #expect(repeated.freshnessNanos == past.freshnessNanos)
        #expect(estimate(now: 10_250_000_001, render: 10_000_000_000) == nil)
        #expect(try #require(estimate(now: 10_010_000_000)).freshnessNanos == 10_010_000_000)
        #expect(try #require(estimate(now: 10_030_000_000)).freshnessNanos == 10_020_000_000)
    }

    @Test func explicitWindowHasInclusiveBoundaryAndStrictDefault() {
        #expect(estimate(render: 10_025_000_000) != nil)
        #expect(estimate(render: 10_025_000_001) == nil)
        #expect(estimate(budget: 0) == nil)
        #expect(estimate(budget: RenderDriftEstimate.maximumFutureLeadNanos + 1) == nil)
        #expect(RenderObservationSample.clockGate(pollNanos: 10_000_000_000,
            renderNanos: 10_020_000_000, permittedFutureLeadNanos: 25_000_000) == nil)
        #expect(RenderObservationSample.clockGate(pollNanos: 10_000_000_000,
            renderNanos: 10_025_000_001, permittedFutureLeadNanos: 25_000_000) == .renderAheadOfPoll)
    }

    @Test func routeBudgetUsesMeasuredGeometryAndSupportsLargeValidBuffers() throws {
        #expect(AudioOutputRenderBudget.permittedFutureLeadNanos(bufferFrames: 512,
            safetyOffsetFrames: 48, sampleRate: 48_000) == 24_333_334)
        let large = try #require(AudioOutputRenderBudget.permittedFutureLeadNanos(bufferFrames: 4096,
            safetyOffsetFrames: 48, sampleRate: 44_100))
        #expect(large > 185_000_000 && large < 190_000_000)
        #expect(AudioOutputRenderBudget.permittedFutureLeadNanos(bufferFrames: 8192,
            safetyOffsetFrames: 48, sampleRate: 44_100) == nil)
        #expect(AudioOutputRenderBudget.permittedFutureLeadNanos(bufferFrames: 512,
            safetyOffsetFrames: 0, sampleRate: 48_000) != nil)
        for rate in [Double.nan, .infinity, 0, -1, Double.leastNonzeroMagnitude] {
            #expect(AudioOutputRenderBudget.permittedFutureLeadNanos(bufferFrames: 512,
                safetyOffsetFrames: 48, sampleRate: rate) == nil)
        }
        #expect(AudioOutputRenderBudget.permittedFutureLeadNanos(bufferFrames: nil, safetyOffsetFrames: 48, sampleRate: 48_000) == nil)
        #expect(AudioOutputRenderBudget.permittedFutureLeadNanos(bufferFrames: 0, safetyOffsetFrames: 48, sampleRate: 48_000) == nil)
        #expect(AudioOutputRenderBudget.permittedFutureLeadNanos(bufferFrames: 512, safetyOffsetFrames: nil, sampleRate: 48_000) == nil)
        #expect(AudioOutputRenderBudget.permittedFutureLeadNanos(bufferFrames: 512, safetyOffsetFrames: 48, sampleRate: nil) == nil)
        #expect(AudioOutputRenderBudget.permittedFutureLeadNanos(bufferFrames: .max, safetyOffsetFrames: .max, sampleRate: 48_000) == nil)
    }

    @Test func futureAllowanceDoesNotBypassOtherEstimateGuards() {
        #expect(estimate(sample: -1) == nil)
        #expect(estimate(rate: 0) == nil)
        #expect(estimate(rate: .nan) == nil)
        #expect(estimate(captureOffset: .infinity) == nil)
        #expect(RenderDriftEstimate(nowNanos: 100, renderLocalNanos: 101, renderHostNanos: .max,
            outputLatencyNanos: 1, captureAnchorNanos: 0, playoutDelayNanos: 0,
            sampleTime: 0, sampleRate: 48_000, permittedFutureLeadNanos: 10) == nil)
        #expect(RenderDriftEstimate(nowNanos: 100, renderLocalNanos: 101, renderHostNanos: 101,
            outputLatencyNanos: 0, captureAnchorNanos: .max, playoutDelayNanos: 1,
            sampleTime: 0, sampleRate: 48_000, permittedFutureLeadNanos: 10) == nil)
    }
}
