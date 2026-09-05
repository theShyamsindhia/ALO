import Testing
@testable import ALOAppleMedia

struct BackgroundAudioEligibilityTests {
    @Test func onlyCurrentRealScheduledMediaPermitsBackgroundListening() {
        func allows(connected: Bool = true, running: Bool = true, scheduled: Bool = true,
                    mic: Bool = false, last: UInt64? = 1_000, now: UInt64 = 2_000) -> Bool {
            BackgroundAudioEligibility.allows(connected: connected, running: running,
                hasScheduledAudio: scheduled, microphoneActive: mic, lastPacketNanos: last, nowNanos: now)
        }
        #expect(allows())
        #expect(!allows(connected: false))
        #expect(!allows(running: false))
        #expect(!allows(scheduled: false))
        #expect(!allows(mic: true))
        #expect(!allows(last: nil))
        #expect(!allows(now: 999))
        #expect(!allows(now: 2_000_001_001))
    }
}
