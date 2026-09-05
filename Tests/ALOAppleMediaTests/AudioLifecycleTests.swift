import Testing
@testable import ALOAppleMedia

struct AudioLifecycleTests {
    @Test("Microphone permission is tied to a user request and cannot survive suspension")
    func stalePermission() throws {
        var state = AudioLifecycle()
        #expect(throws: AppleMediaError.invalidState) { try state.requestMicrophoneFromUserAction() }
        _ = state.startListening()
        let request = try state.requestMicrophoneFromUserAction()
        state.suspend()
        let stalePermission = state.completeMicrophonePermission(generation: request, granted: true)
        #expect(!stalePermission)
        _ = state.startListening()
        #expect(state.phase == .listening)
        #expect(!state.isMicrophoneActive)
    }

    @Test("A permission dialog and a denial preserve the current listening generation")
    func permissionDoesNotInterruptListening() throws {
        var state = AudioLifecycle()
        let listening = state.startListening()
        state.resynchronized(generation: listening)
        let request = try state.requestMicrophoneFromUserAction()
        #expect(state.generation == listening)
        #expect(!state.needsResynchronization)
        #expect(state.canRender)
        let deniedPermission = state.completeMicrophonePermission(generation: request, granted: false)
        #expect(!deniedPermission)
        #expect(state.generation == listening)
        #expect(state.phase == .listening)
    }

    @Test("Route changes and interruptions close the microphone and require a new audio anchor")
    func routeAndInterruption() throws {
        var state = AudioLifecycle()
        _ = state.startListening()
        let request = try state.requestMicrophoneFromUserAction()
        let grantedPermission = state.completeMicrophonePermission(generation: request, granted: true)
        #expect(grantedPermission)
        #expect(state.isMicrophoneActive)
        let old = state.generation
        state.routeChanged()
        #expect(!state.isMicrophoneActive)
        #expect(state.phase == .listening)
        state.resynchronized(generation: old)
        #expect(state.needsResynchronization)
        state.resynchronized(generation: state.generation)
        #expect(!state.needsResynchronization)
        state.interrupt()
        #expect(!state.canRender)
        _ = state.startListening()
        #expect(state.phase == .listening)
        #expect(!state.isMicrophoneActive)
        #expect(state.needsResynchronization)
    }

    @Test("Incoming voice changes neither microphone state nor default media volume")
    func explicitDuckingOnly() {
        var levels = AudioMixLevels(mediaVolume: 0.8, voiceVolume: 0.6, incomingVoiceActive: true)
        #expect(levels.effectiveMediaVolume == 0.8)
        #expect(levels.effectiveVoiceVolume == 0.6)
        levels.incomingVoicePolicy = .duckMedia(multiplier: 0.25)
        #expect(levels.effectiveMediaVolume == 0.2)
        levels.voiceMuted = true
        #expect(levels.effectiveMediaVolume == 0.8)
        #expect(levels.effectiveVoiceVolume == 0)
        levels.voiceMuted = false
        levels.voiceVolume = 0
        #expect(levels.effectiveMediaVolume == 0.8)
        levels.mediaMuted = true
        #expect(levels.effectiveMediaVolume == 0)
        levels.mediaMuted = false
        levels.mediaVolume = .nan
        #expect(levels.effectiveMediaVolume == 0)
    }
}
