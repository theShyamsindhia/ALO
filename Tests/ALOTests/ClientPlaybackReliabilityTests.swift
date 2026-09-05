import CoreAudio
import Testing
@testable import ALO
@testable import ALOCore

struct ClientPlaybackReliabilityTests {
    @Test("Room mute never changes local source playback or voice/mixer preferences",
          arguments: [false, true], [false, true])
    func roomMuteKeepsSourcePlayback(participantMuted: Bool, voiceMuted: Bool) {
        var routing = IncomingAudioMuteRouting(
            participantMediaMuted: participantMuted,
            incomingMediaMuted: false,
            incomingVoiceMuted: voiceMuted
        )
        // The incoming receiver applies this preference separately from the
        // participant setting used for our own source's synchronized return.
        for muted in [true, false, true] {
            routing.incomingMediaMuted = muted
            #expect(routing.localMediaPlaybackMuted == (participantMuted || muted))
            #expect(routing.localBroadcastPlaybackMuted == participantMuted)
            #expect(routing.publishedParticipantMediaMuted == participantMuted)
            #expect(routing.voicePlaybackMuted == voiceMuted)
        }
    }

    @Test("Incoming media mute does not mute incoming voice or alter room participant state")
    func incomingMediaMuteIsIndependentFromVoice() {
        let routing = IncomingAudioMuteRouting(
            participantMediaMuted: false,
            incomingMediaMuted: true,
            incomingVoiceMuted: false
        )

        #expect(routing.localMediaPlaybackMuted)
        #expect(!routing.voicePlaybackMuted)
        #expect(!routing.publishedParticipantMediaMuted)
    }

    @Test("Incoming voice mute does not mute synchronized media")
    func incomingVoiceMuteIsIndependentFromMedia() {
        let routing = IncomingAudioMuteRouting(
            participantMediaMuted: false,
            incomingMediaMuted: false,
            incomingVoiceMuted: true
        )

        #expect(!routing.localMediaPlaybackMuted)
        #expect(routing.voicePlaybackMuted)
        #expect(!routing.publishedParticipantMediaMuted)
    }

    @Test("An authoritative mixer echo becomes the receiver's reconnect preference")
    func authoritativeLevelSurvivesReceiverReconnect() {
        var preference = ReceiverLevelPreference()

        preference.updateFromAuthoritativeLevel(volume: 0.27, muted: true)
        let message = preference.controlMessage(participantID: "local-device")

        #expect(message.type == "set_level")
        #expect(message.targetID == "local-device")
        #expect(message.volume == 0.27)
        #expect(message.muted == true)
    }

    @Test("Talk selection is additive and Everyone is a present-device snapshot") @MainActor
    func talkTargetSelection() {
        let initial: Set<String> = ["mac-a", "mac-b"]
        var selected = ALOViewModel.toggledTalkTargets(
            [], targetID: nil, currentlyPresent: initial
        )
        #expect(selected == initial)

        // A device that arrives later is not silently added to a live route.
        let afterJoin: Set<String> = ["mac-a", "mac-b", "mac-c"]
        #expect(selected == initial)
        selected = ALOViewModel.toggledTalkTargets(
            selected, targetID: "mac-c", currentlyPresent: afterJoin
        )
        #expect(selected == afterJoin)
        selected = ALOViewModel.toggledTalkTargets(
            selected, targetID: "mac-b", currentlyPresent: afterJoin
        )
        #expect(selected == ["mac-a", "mac-c"])

        selected = ALOViewModel.toggledTalkTargets(
            selected, targetID: nil, currentlyPresent: afterJoin
        )
        #expect(selected == afterJoin)
        selected = ALOViewModel.toggledTalkTargets(
            selected, targetID: nil, currentlyPresent: afterJoin
        )
        #expect(selected.isEmpty)
    }

    @Test("Compact Talk chooses either the room or one person and clicking an avatar alone has no side effect") @MainActor
    func compactTalkAudienceIsExclusive() {
        let model = ALOViewModel(discoverRooms: false)
        model.currentParticipantID = "local"
        model.participants = [
            RoomParticipant(id: "local", name: "Local"),
            RoomParticipant(id: "mac-a", name: "Maya"),
            RoomParticipant(id: "mac-b", name: "Sam"),
        ]

        // Avatar presentation reads state only; transmission begins through
        // the explicit room/private action below.
        #expect(model.latchedTalkTargetIDs.isEmpty)
        #expect(model.compactPrivateTalkTargetID == nil)

        model.toggleCompactTalkTarget(nil)
        #expect(model.latchedTalkTargetIDs == ["mac-a", "mac-b"])
        #expect(model.compactRoomTalkIsSelected)

        model.toggleCompactTalkTarget("mac-a")
        #expect(model.latchedTalkTargetIDs == ["mac-a"])
        #expect(model.compactPrivateTalkTargetID == "mac-a")
        #expect(!model.compactRoomTalkIsSelected)

        model.toggleCompactTalkTarget("mac-a")
        #expect(model.latchedTalkTargetIDs.isEmpty)
        #expect(model.compactPrivateTalkTargetID == nil)
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

    @Test("Voice activity does not lower synchronized media")
    func voiceActivityPreservesMediaLevel() {
        #expect(MediaOutputGain.effectiveGain(
            participantVolume: 0.5, muted: false
        ) == 0.5)
        #expect(MediaOutputGain.effectiveGain(
            participantVolume: 0.5, muted: true
        ) == 0)
    }
    @Test @MainActor func videoControlStartsAudioAndVideoWhenNoBroadcasterVideoExists() {
        #expect(ALOViewModel.videoControlIntent(
            isLive: true,
            isHost: false,
            roomHasVideo: false,
            experience: .audio,
            mediaSwitchBusy: false
        ) == .beginAudioAndVideoBroadcast)
        #expect(ALOViewModel.videoControlIntent(
            isLive: true,
            isHost: true,
            roomHasVideo: false,
            experience: .audio,
            mediaSwitchBusy: false
        ) == .enableVideo)
        #expect(ALOViewModel.videoControlIntent(
            isLive: true,
            isHost: false,
            roomHasVideo: true,
            experience: .audio,
            mediaSwitchBusy: false
        ) == .showViewer)
        #expect(ALOViewModel.videoControlIntent(
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
        #expect(ALOViewModel.playbackCommand(
            metadataIsPlaying: true,
            audioIsRendering: false
        ) == .pause)
        #expect(ALOViewModel.playbackCommand(
            metadataIsPlaying: false,
            audioIsRendering: true
        ) == .play)
        #expect(ALOViewModel.playbackCommand(
            metadataIsPlaying: nil,
            audioIsRendering: true
        ) == .pause)
        #expect(ALOViewModel.playbackCommand(
            metadataIsPlaying: nil,
            audioIsRendering: false
        ) == .play)
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
        #expect(HostServer.playbackIntentIsCurrent(
            setAtNanos: 1_000_000_000,
            nowNanos: 2_500_000_000
        ))
        #expect(!HostServer.playbackIntentIsCurrent(
            setAtNanos: 1_000_000_000,
            nowNanos: 3_000_000_000
        ))
    }

    @Test func playbackControlRequiresLiveControllableMedia() {
        #expect(ALOViewModel.playbackControlAvailable(
            isLive: true,
            hasBroadcaster: true,
            isHost: false,
            hasMedia: true
        ))
        #expect(ALOViewModel.playbackControlAvailable(
            isLive: true,
            hasBroadcaster: false,
            isHost: true,
            hasMedia: true
        ))
        #expect(!ALOViewModel.playbackControlAvailable(
            isLive: false,
            hasBroadcaster: true,
            isHost: false,
            hasMedia: true
        ))
        #expect(!ALOViewModel.playbackControlAvailable(
            isLive: true,
            hasBroadcaster: false,
            isHost: false,
            hasMedia: true
        ))
        #expect(!ALOViewModel.playbackControlAvailable(
            isLive: true,
            hasBroadcaster: true,
            isHost: false,
            hasMedia: false
        ))
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
        #expect(!SynchronizedPlayer.shouldRecoverAfterConfigurationChange(
            engineIsRunning: true, deviceChanged: false, latencyChanged: true
        ))
        #expect(SynchronizedPlayer.shouldRecoverAfterConfigurationChange(
            engineIsRunning: true,
            deviceChanged: false,
            latencyChanged: false,
            engineRestarted: true
        ))
        #expect(!SynchronizedPlayer.latencyChanged(from: 10_000_000, to: 10_500_000))
        #expect(SynchronizedPlayer.latencyChanged(from: 10_000_000, to: 12_000_000))
        #expect(!SynchronizedPlayer.shouldAcceptOutputLatencyMeasurement(
            engineIsRunning: false,
            previousLatencyNanos: 220_000_000,
            measuredLatencyNanos: 220_000_000
        ))
        #expect(!SynchronizedPlayer.shouldAcceptOutputLatencyMeasurement(
            engineIsRunning: true,
            previousLatencyNanos: 220_000_000,
            measuredLatencyNanos: 0
        ))
        #expect(SynchronizedPlayer.shouldAcceptOutputLatencyMeasurement(
            engineIsRunning: true,
            previousLatencyNanos: 220_000_000,
            measuredLatencyNanos: 240_000_000
        ))
    }

    @Test("A rejoined receiver rejects stale and duplicate media packets")
    func staleMediaPacketsCannotPolluteTheNextResync() {
        #expect(!SynchronizedPlayer.shouldAdmitPacket(
            sequence: 99,
            expectedSequence: 100,
            isAlreadyPending: false
        ))
        #expect(!SynchronizedPlayer.shouldAdmitPacket(
            sequence: 101,
            expectedSequence: 100,
            isAlreadyPending: true
        ))
        #expect(SynchronizedPlayer.shouldAdmitPacket(
            sequence: 100,
            expectedSequence: 100,
            isAlreadyPending: false
        ))
        #expect(SynchronizedPlayer.shouldAdmitPacket(
            sequence: 0,
            expectedSequence: UInt32.max,
            isAlreadyPending: false
        ))
        #expect(!SynchronizedPlayer.shouldAdmitPacket(
            sequence: UInt32.max,
            expectedSequence: 0,
            isAlreadyPending: false
        ))
    }

    @Test("A receiver accepts a restarted broadcaster's reset sequence")
    func broadcasterRestartResetsReceiverStreamIdentity() throws {
        let player = try SynchronizedPlayer()
        defer { player.stop() }
        let samples = [Int16](
            repeating: 0,
            count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
        )

        player.accept(AudioPacket(
            sequence: 90_000,
            frameIndex: 0,
            captureTimeNanos: MonotonicClock.nowNanos(),
            samples: samples
        ))
        #expect(player.expectedSequenceForTesting == 90_000)

        player.resetStream()
        #expect(player.expectedSequenceForTesting == nil)

        player.accept(AudioPacket(
            sequence: 0,
            frameIndex: 0,
            captureTimeNanos: MonotonicClock.nowNanos(),
            samples: samples
        ))
        #expect(player.expectedSequenceForTesting == 0)
    }

    @Test("A stopped receiver ignores a delivery already queued by its old transport")
    func stoppedPlayerRejectsLateTransportPacket() throws {
        let player = try SynchronizedPlayer()
        player.clockOffsetNanos = 0
        player.stop()

        player.accept(AudioPacket(
            sequence: 1,
            frameIndex: 0,
            captureTimeNanos: MonotonicClock.nowNanos(),
            samples: [Int16](
                repeating: 0,
                count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
            )
        ))

        #expect(player.expectedSequenceForTesting == nil)
        #expect(player.clockOffsetNanos == nil)
    }

    @Test("A cancelled transport cannot deliver into the next receiver epoch")
    func staleTransportCallbackIsRejectedAfterReconnect() {
        var epoch = ReceiverTransportEpoch()
        let oldConnectionEpoch = epoch.token

        epoch.advance()

        #expect(!epoch.accepts(oldConnectionEpoch))
        #expect(epoch.accepts(epoch.token))
    }

    @Test("Moderate Bluetooth clock jitter never cuts playback")
    func moderateOutputJitterUsesContinuousCorrection() {
        var recovery = PlaybackDriftRecovery()
        let jitterPattern: [UInt64] = [
            24_000_000, 27_000_000, 21_000_000, 31_000_000, 23_000_000,
        ]
        for index in 0..<21 {
            let lateness = jitterPattern[index % jitterPattern.count]
            let shouldResynchronize = recovery.shouldResynchronize(latenessNanos: lateness)
            #expect(!shouldResynchronize)
        }
    }

    @Test("Bluetooth IO lead expands render scheduling headroom")
    func bluetoothRenderHeadroom() {
        #expect(AudioOutputRenderBudget.schedulingHeadroomNanos(
            bufferFrames: 128,
            safetyOffsetFrames: 32,
            sampleRate: 48_000
        ) == RoomTiming.renderSchedulingHeadroomNanos)
        let bluetoothHeadroom = AudioOutputRenderBudget.schedulingHeadroomNanos(
            bufferFrames: 512,
            safetyOffsetFrames: 4_096,
            sampleRate: 48_000
        )
        #expect(bluetoothHeadroom > 100_000_000)
        #expect(RoomTiming.outputLatencyFloor(
            220_000_000,
            roundTripNanos: 4_000_000,
            renderSchedulingHeadroomNanos: bluetoothHeadroom
        ) == 450_000_000)
    }

    @Test("An AirPods format switch rebuilds a still-running output engine")
    func airPodsFormatChangeRestartsOutputEngine() {
        let highQuality = AudioOutputHardwareFormat(sampleRate: 48_000, channelCount: 2)
        let handsFree = AudioOutputHardwareFormat(sampleRate: 24_000, channelCount: 1)
        #expect(AudioOutputHardwareFormat.changed(from: highQuality, to: handsFree))
        #expect(SynchronizedPlayer.shouldRecoverAfterConfigurationChange(
            engineIsRunning: true,
            deviceChanged: false,
            latencyChanged: false,
            outputFormatChanged: true
        ))
    }

    @Test("A final Bluetooth route notification survives an in-flight recovery")
    func routeChangeDuringRecoveryRemainsPending() {
        var gate = AudioConfigurationRecoveryGate()
        gate.markChanged()
        let initialPending = gate.takePendingChange()
        let beganRecovery = gate.beginRecovery()
        #expect(initialPending)
        #expect(beganRecovery)
        gate.markChanged()
        gate.endRecovery()
        let finalPending = gate.takePendingChange()
        #expect(finalPending)
        #expect(!gate.changePending)
    }

    @Test @MainActor func unrelatedStatusTextDoesNotClearRenderingState() {
        #expect(ALOViewModel.renderingState(for: "This Mac is playing in sync") == true)
        #expect(ALOViewModel.renderingState(for: "Connecting to the room broadcaster") == false)
        #expect(ALOViewModel.renderingState(for: "Sharing system audio") == nil)
    }

    @Test @MainActor func broadcasterMetadataIsAuthoritativeOverRenderedAudio() {
        #expect(!ALOViewModel.effectivePlaybackState(
            metadataIsPlaying: false,
            audioIsRendering: true,
            hasMedia: true
        ))
        #expect(!ALOViewModel.effectivePlaybackState(
            metadataIsPlaying: false,
            audioIsRendering: false,
            hasMedia: true
        ))
        #expect(!ALOViewModel.effectivePlaybackState(
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

        let merged = ALOViewModel.mergingParticipants(refreshed, preserving: prior)

        #expect(merged.first?.name == "New name")
        #expect(merged.first?.icon == "sparkles")
        #expect(merged.first?.colorHex == "7C6FF2")
        #expect(merged.first?.volume == 0.35)
        #expect(merged.first?.isMuted == true)
    }
}
