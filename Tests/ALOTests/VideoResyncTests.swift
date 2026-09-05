import Testing
@testable import ALO
@testable import ALOAppleMedia

struct VideoResyncTests {
    @Test("A transport reconnect clears the previous host's video clock")
    func transportReconnectRequiresAFreshVideoClock() {
        let decoder = VideoDecoder { _ in }
        decoder.updateClockOffsetNanos(9_000_000_000)
        #expect(decoder.clockOffsetNanosForTesting == 9_000_000_000)

        decoder.resetTiming()

        #expect(decoder.clockOffsetNanosForTesting == nil)
        decoder.stop()
    }

    @Test("A video resync drops frames before the shared audio cutover")
    func dropsFramesBeforeCutover() {
        let gate = VideoPresentationResyncGate()
        let stalePresentation = gate.admission(forCaptureTimeNanos: 90)!

        gate.reset(atOrAfterCaptureNanos: 100)

        #expect(!gate.isCurrent(stalePresentation))
        #expect(gate.admission(forCaptureTimeNanos: 99) == nil)
        #expect(gate.admission(forCaptureTimeNanos: 100) != nil)
        #expect(gate.admission(forCaptureTimeNanos: 101) != nil)
    }

    @Test("A later video resync invalidates presentations scheduled by the prior generation")
    func invalidatesScheduledPresentations() {
        let gate = VideoPresentationResyncGate()
        gate.reset(atOrAfterCaptureNanos: 100)
        let firstGeneration = gate.admission(forCaptureTimeNanos: 100)!

        gate.reset(atOrAfterCaptureNanos: 200)

        #expect(!gate.isCurrent(firstGeneration))
        #expect(gate.admission(forCaptureTimeNanos: 199) == nil)
        let secondGeneration = gate.admission(forCaptureTimeNanos: 200)!
        #expect(gate.isCurrent(secondGeneration))
    }

    @Test("A legacy resync without a cutover still clears scheduled video")
    func legacyResyncInvalidatesWithoutFilteringFutureFrames() {
        let gate = VideoPresentationResyncGate()
        let stalePresentation = gate.admission(forCaptureTimeNanos: 50)!

        gate.reset(atOrAfterCaptureNanos: nil)

        #expect(!gate.isCurrent(stalePresentation))
        #expect(gate.admission(forCaptureTimeNanos: 1) != nil)
    }
}
@testable import ALOAppleMedia
