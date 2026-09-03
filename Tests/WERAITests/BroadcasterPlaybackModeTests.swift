import Testing
@testable import WERAI

@Suite("Broadcaster playback mode")
struct BroadcasterPlaybackModeTests {
    @Test("Direct source remains the safe fallback while the tap is unavailable")
    func directSourceFallback() {
        let mode = BroadcasterPlaybackMode.resolve(
            sourceMuteTapActive: false,
            sourceMuteTapFeedsRoomAudio: false
        )

        #expect(mode == .directSource)
        #expect(mode.mutesSynchronizedReceiver)
    }

    @Test("A mute tap cannot replace SCK until its samples feed the room")
    func activeTapWithoutRoomFeedStaysSafe() {
        let mode = BroadcasterPlaybackMode.resolve(
            sourceMuteTapActive: true,
            sourceMuteTapFeedsRoomAudio: false
        )

        #expect(mode == .directSource)
        #expect(mode.mutesSynchronizedReceiver)
    }

    @Test("Only a tap that feeds the room may enable synchronized local return")
    func completeTapCaptureCanSynchronizeReturn() {
        let mode = BroadcasterPlaybackMode.resolve(
            sourceMuteTapActive: true,
            sourceMuteTapFeedsRoomAudio: true
        )

        #expect(mode == .synchronizedReceiver)
        #expect(!mode.mutesSynchronizedReceiver)
    }
}
