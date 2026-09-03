import CoreAudio
import Testing
@testable import WERAI
@testable import WERAICore

struct ClientPlaybackReliabilityTests {
    @Test("Talk selection is additive and Everyone is a present-device snapshot") @MainActor
    func talkTargetSelection() {
        let initial: Set<String> = ["mac-a", "mac-b"]
        var selected = WERAIViewModel.toggledTalkTargets(
            [], targetID: nil, currentlyPresent: initial
        )
        #expect(selected == initial)

        // A device that arrives later is not silently added to a live route.
        let afterJoin: Set<String> = ["mac-a", "mac-b", "mac-c"]
        #expect(selected == initial)
        selected = WERAIViewModel.toggledTalkTargets(
            selected, targetID: "mac-c", currentlyPresent: afterJoin
        )
        #expect(selected == afterJoin)
        selected = WERAIViewModel.toggledTalkTargets(
            selected, targetID: "mac-b", currentlyPresent: afterJoin
        )
        #expect(selected == ["mac-a", "mac-c"])

        selected = WERAIViewModel.toggledTalkTargets(
            selected, targetID: nil, currentlyPresent: afterJoin
        )
        #expect(selected == afterJoin)
        selected = WERAIViewModel.toggledTalkTargets(
            selected, targetID: nil, currentlyPresent: afterJoin
        )
        #expect(selected.isEmpty)
    }

    @Test("Voice input restart preserves Talk and Open Line recipients")
    func voiceInputRestartRecipients() {
        let invitation = OpenLineInvitation(
            id: "line-1",
            callerID: "local",
            callerName: "Local",
            inviteeID: "line-peer"
        )

        #expect(MeshSession.effectiveVoiceTargets(
            talkTargetIDs: ["talk-peer", "local"],
            openLineState: .connected(invitation),
            localID: "local"
        ) == ["talk-peer", "line-peer"])
        #expect(MeshSession.effectiveVoiceTargets(
            talkTargetIDs: ["talk-peer"],
            openLineState: .invited(invitation),
            localID: "local"
        ) == ["talk-peer"])
    }

    @Test("Voice playback never changes synchronized media gain")
    func voiceDoesNotDuckMedia() {
        #expect(MediaOutputGain.effectiveGain(
            participantVolume: 0.5, muted: false
        ) == 0.5)
        #expect(MediaOutputGain.effectiveGain(
            participantVolume: 0.5, muted: true
        ) == 0)
    }
    @Test @MainActor func videoControlStartsAudioAndVideoWhenNoBroadcasterVideoExists() {
        #expect(WERAIViewModel.videoControlIntent(
            isLive: true,
            isHost: false,
            roomHasVideo: false,
            experience: .audio,
            mediaSwitchBusy: false
        ) == .beginAudioAndVideoBroadcast)
        #expect(WERAIViewModel.videoControlIntent(
            isLive: true,
            isHost: true,
            roomHasVideo: false,
            experience: .audio,
            mediaSwitchBusy: false
        ) == .enableVideo)
        #expect(WERAIViewModel.videoControlIntent(
            isLive: true,
            isHost: false,
            roomHasVideo: true,
            experience: .audio,
            mediaSwitchBusy: false
        ) == .showViewer)
        #expect(WERAIViewModel.videoControlIntent(
            isLive: true,
            isHost: false,
            roomHasVideo: true,
            experience: .video,
            mediaSwitchBusy: false
        ) == .toggleViewer)
    }

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
        #expect(RoomRemoteCommandCenter.effectivePlaybackState(
            metadataIsPlaying: false,
            streamIsActive: true
        ) == false)
        #expect(RoomRemoteCommandCenter.effectivePlaybackState(
            metadataIsPlaying: false,
            streamIsActive: false
        ) == false)
    }

    @Test func unrelatedAudioConfigurationChangesDoNotRestartAHealthyEngine() {
        #expect(!SynchronizedPlayer.shouldRecoverAfterConfigurationChange(
            engineIsRunning: true, deviceChanged: false, latencyChanged: false
        ))
        #expect(SynchronizedPlayer.shouldRecoverAfterConfigurationChange(
            engineIsRunning: false, deviceChanged: false, latencyChanged: false
        ))
        #expect(SynchronizedPlayer.shouldRecoverAfterConfigurationChange(
            engineIsRunning: true, deviceChanged: true, latencyChanged: false
        ))
        #expect(SynchronizedPlayer.shouldRecoverAfterConfigurationChange(
            engineIsRunning: true, deviceChanged: false, latencyChanged: true
        ))
        #expect(!SynchronizedPlayer.latencyChanged(from: 10_000_000, to: 10_500_000))
        #expect(SynchronizedPlayer.latencyChanged(from: 10_000_000, to: 12_000_000))
    }

    @Test @MainActor func unrelatedStatusTextDoesNotClearRenderingState() {
        #expect(WERAIViewModel.renderingState(for: "This Mac is playing in sync") == true)
        #expect(WERAIViewModel.renderingState(for: "Connecting to the room broadcaster") == false)
        #expect(WERAIViewModel.renderingState(for: "Sharing system audio") == nil)
    }

    @Test @MainActor func broadcasterMetadataIsAuthoritativeOverRenderedAudio() {
        #expect(!WERAIViewModel.effectivePlaybackState(
            metadataIsPlaying: false,
            audioIsRendering: true,
            hasMedia: true
        ))
        #expect(!WERAIViewModel.effectivePlaybackState(
            metadataIsPlaying: false,
            audioIsRendering: false,
            hasMedia: true
        ))
        #expect(!WERAIViewModel.effectivePlaybackState(
            metadataIsPlaying: true,
            audioIsRendering: false,
            hasMedia: false
        ))
    }

    @Test func identityRefreshPreservesPerDeviceMixerSettings() {
        let prior = [RoomParticipant(
            id: "peer",
            name: "Old name",
            volume: 0.35,
            isMuted: true,
            icon: "laptopcomputer",
            colorHex: "E45B69"
        )]
        let refreshed = [RoomParticipant(
            id: "peer",
            name: "New name",
            volume: 1,
            isMuted: false,
            icon: "sparkles",
            colorHex: "7C6FF2"
        )]

        let merged = WERAIViewModel.mergingParticipants(refreshed, preserving: prior)

        #expect(merged.first?.name == "New name")
        #expect(merged.first?.icon == "sparkles")
        #expect(merged.first?.colorHex == "7C6FF2")
        #expect(merged.first?.volume == 0.35)
        #expect(merged.first?.isMuted == true)
    }
}
