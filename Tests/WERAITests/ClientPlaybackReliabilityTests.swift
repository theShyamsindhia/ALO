import CoreAudio
import Testing
@testable import WERAI
@testable import WERAICore

struct ClientPlaybackReliabilityTests {
    @Test func explicitOutputDeviceTakesPrecedenceOverUID() {
        var resolutions = 0
        let selected = SynchronizedPlayer.selectedOutputDeviceID(
            explicitID: 42,
            uid: "physical-output",
            resolver: { _ in resolutions += 1; return 84 }
        )
        #expect(selected == AudioDeviceID(42))
        #expect(resolutions == 0)
    }

    @Test func outputUIDIsResolvedWhenNoDeviceIDIsGiven() {
        let selected = SynchronizedPlayer.selectedOutputDeviceID(
            explicitID: nil,
            uid: "physical-output",
            resolver: { $0 == "physical-output" ? 84 : nil }
        )
        #expect(selected == AudioDeviceID(84))
    }

    @Test func remoteCommandsReducePlaybackStatePredictably() {
        #expect(RoomRemoteCommandCenter.playbackState(after: .play, current: false) == true)
        #expect(RoomRemoteCommandCenter.playbackState(after: .pause, current: true) == false)
        #expect(RoomRemoteCommandCenter.playbackState(after: .togglePlayPause, current: true) == false)
        #expect(RoomRemoteCommandCenter.playbackState(after: .togglePlayPause, current: false) == true)
        #expect(RoomRemoteCommandCenter.playbackState(after: .nextTrack, current: true) == nil)
        #expect(RoomRemoteCommandCenter.playbackState(after: .previousTrack, current: false) == nil)
    }
}
