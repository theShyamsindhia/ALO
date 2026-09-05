import Testing
import ALOCore
@testable import ALOAppleMedia

struct CapturePlayoutDelayTimelineTests {
    @Test func committedCutoverDoesNotRetimePredecessorDecodedLater() {
        var delays = CapturePlayoutDelayTimeline()
        delays.reset(delayNanos: 250_000_000)
        delays.stage(captureTimeNanos: 1_000, delayNanos: 300_000_000)
        #expect(delays.delay(forCapture: 1_001) == 300_000_000)
        #expect(delays.delay(forCapture: 999) == 250_000_000)
        delays.stage(captureTimeNanos: 2_000, delayNanos: 300_000_000)
        #expect(delays.delay(forCapture: 999) == 250_000_000)
        delays.reset()
        #expect(delays.delay(forCapture: 1_001) == RoomTiming.defaultPlayoutDelayNanos)
    }
    @Test func retiredHistoryCannotAssignNewDelayToAnAncientFrame() {
        var delays = CapturePlayoutDelayTimeline()
        for index in 1...12 {
            delays.stage(captureTimeNanos: UInt64(index * 100),
                         delayNanos: index.isMultiple(of: 2) ? 250_000_000 : 300_000_000)
        }
        #expect(delays.delay(forCapture: 1) == nil)
        #expect(delays.delay(forCapture: 1_200) == 250_000_000)
        #expect(delays.delay(forCapture: 1_199) == 300_000_000)
    }
}
