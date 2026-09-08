import Testing
@testable import ALO

struct VoiceCapturePresentationTests {
    private func presentation(_ phase: VoiceCaptureLifecycle.Phase, targets: Bool = true,
                              other: String? = nil) -> VoiceCapturePresentation {
        VoiceCapturePresentation.phase(phase, hasTalkTargets: targets,
                                       talkingStatus: "Talking to A", otherVoiceStatus: other)
    }

    @Test func automaticAudienceShrinkCompletesPresentation() {
        // A+B -> A causes a synchronous idle, then a new connecting/ready pair
        // without the explicit GUI start Task's success continuation.
        let idle = presentation(.idle)
        #expect(idle.status == "Talk paused")
        #expect(!idle.starting && !idle.talking)
        let connecting = presentation(.connecting)
        #expect(connecting.starting && !connecting.talking)
        let ready = presentation(.ready)
        #expect(ready.status == "Talking to A")
        #expect(ready.talking && !ready.starting)
    }

    @Test(arguments: ["B is talking to you", "Line open with B", "Waiting for B to join the line"])
    func cancellationRestoresOtherVoiceStatus(_ other: String) {
        let idle = presentation(.idle, targets: false, other: other)
        #expect(idle.status == other)
        #expect(!idle.starting && !idle.talking)
    }

    @Test func cancellationWithoutOtherVoiceIsOff() {
        #expect(presentation(.idle, targets: false).status == "Talk is off")
    }

    @Test(arguments: [VoiceCaptureLifecycle.Phase.connecting, .ready])
    func openLineStartupBeforeGUIStatePropagationDoesNotClaimTalk(_ phase: VoiceCaptureLifecycle.Phase) {
        // MeshSession invites/accepts and awaits reconcileVoiceCapture before
        // publishing openLineStateHandler. A real connecting phase therefore
        // can arrive while GUI Talk targets and Open Line state are still empty.
        // Absence of GUI Talk targets does not imply absence of a wire audience.
        let value = presentation(phase, targets: false)
        #expect(!value.starting && !value.talking)
        #expect(value.status == (phase == .connecting ? "Connecting voice…" : "Talk is off"))
    }

    @Test func localOpenLineIsSpeakingButRemotePresenceIsNotInvented() {
        #expect(VoiceCapturePresentation.isSpeaking(isLocal: true, talk: false,
            openLineMicrophone: true, incoming: false))
        #expect(!VoiceCapturePresentation.isSpeaking(isLocal: false, talk: true,
            openLineMicrophone: true, incoming: false))
        #expect(VoiceCapturePresentation.isSpeaking(isLocal: false, talk: false,
            openLineMicrophone: false, incoming: true))
    }
}
