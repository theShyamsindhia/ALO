import AVFoundation
import Testing
@testable import ALO

struct PlayerNodeClockValidityTests {
    @Test func invalidRawTimestampIsNotPassedToNativeConversion() {
        var raw = AudioTimeStamp()
        let neither = AVAudioTime(audioTimeStamp: &raw, sampleRate: 48_000)
        #expect(!neither.isHostTimeValid && !neither.isSampleTimeValid)
        #expect(!SynchronizedPlayer.hasUsableNodeClock(neither))
        #expect(SynchronizedPlayer.hasUsableNodeClock(AVAudioTime(sampleTime: 0, atRate: 48_000)))
        #expect(SynchronizedPlayer.hasUsableNodeClock(AVAudioTime(hostTime: 0)))
    }
}
