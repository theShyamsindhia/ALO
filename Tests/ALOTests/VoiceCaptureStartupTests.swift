import Testing
@testable import ALO

@MainActor
struct VoiceCaptureStartupTests {
    @Test func remoteEventsCannotRestartFailedOrDormantCapture() {
        var state = VoiceCaptureLifecycle()
        #expect(state.remoteEventDecision(activeID: nil, requested: ["selected"], ownsRestart: false) == .ignore)
        state.begin("failed", recipients: ["selected"])
        state.end("failed")
        #expect(state.remoteEventDecision(activeID: nil, requested: ["selected"], ownsRestart: false) == .ignore)
    }

    @Test func repeatedDeparturesPreserveOnlyOwnedContinuation() {
        var state = VoiceCaptureLifecycle()
        state.begin("live", recipients: ["a", "b", "c"])
        let ready = state.ready("live")
        #expect(ready)
        #expect(state.remoteEventDecision(activeID: "live", requested: ["a", "b"], ownsRestart: false) == .restart)
        state.end("live")
        // Capture is stopped while its explicit continuation waits; a second
        // departure must schedule the remaining audience, not lose the call.
        #expect(state.remoteEventDecision(activeID: nil, requested: ["a"], ownsRestart: true) == .restart)
        #expect(state.remoteEventDecision(activeID: nil, requested: [], ownsRestart: true) == .stop)
        #expect(state.remoteEventDecision(activeID: nil, requested: ["a"], ownsRestart: false) == .ignore)
    }
    @Test func pendingAudienceCannotBeReusedAndOldReadinessCannotActivateReplacement() {
        var state = VoiceCaptureLifecycle()
        state.begin("old", recipients: ["a", "b"])
        #expect(state.decision(activeID: "old", requested: ["a", "b"]) == .wait)
        #expect(state.decision(activeID: "old", requested: ["a"]) == .restart)
        state.begin("new", recipients: ["a"])
        let oldReady = state.ready("old")
        #expect(!oldReady && state.phase == .connecting)
        state.end("old")
        #expect(state.sessionID == "new")
        let currentReady = state.ready("new")
        #expect(currentReady && state.decision(activeID: "new", requested: ["a"]) == .reuse)
        #expect(state.decision(activeID: "new", requested: []) == .stop)
    }
    @Test func beganMustPrecedeFirstCaptureCallback() async throws {
        var events: [String] = []
        try await VoiceCaptureStartup.perform(start: {
            // A real tap can invoke its handler before async start returns.
            events.append("capture")
        }, validate: {}, publishBegan: { events.append("began") }, awaitReadiness: {})
        #expect(events == ["began", "capture"],
            "Publishing began after capture allows the bridge to discard initial speech")
        // This ordering oracle does not prove authenticated sender readiness.
    }

    @Test func secureReadinessPrecedesCaptureAndRechecksIntent() async throws {
        var events: [String] = []
        try await VoiceCaptureStartup.perform(start: { events.append("capture") }, validate: {},
            publishBegan: { events.append("began") }, awaitReadiness: {
                #expect(events == ["began"])
                events.append("authorized")
            }, retireAnnounced: { events.append("ended") })
        #expect(events == ["began", "authorized", "capture"])
    }

    @Test(arguments: [0, 1, 2])
    func secureFailureRetiresAnnouncement(mode: Int) async {
        enum Failure: Error { case cancelled, timeout, capture }
        var current = true
        var began = 0, ended = 0, captures = 0
        do {
            try await VoiceCaptureStartup.perform(start: {
                captures += 1
                if mode == 2 { throw Failure.capture }
            }, validate: {
                if !current { throw Failure.cancelled }
            }, publishBegan: { began += 1 }, awaitReadiness: {
                #expect(captures == 0)
                if mode == 0 { current = false }
                if mode == 1 { throw Failure.timeout }
            }, retireAnnounced: { ended += 1 })
            Issue.record("Expected readiness/capture failure")
        } catch {
            #expect(began == 1 && ended == 1)
            #expect(captures == (mode == 2 ? 1 : 0))
        }
    }

    @Test func failedCaptureNeverPublishesBegan() async {
        enum Failure: Error { case start }
        var began = false
        do {
            try await VoiceCaptureStartup.perform(start: { throw Failure.start },
                validate: {}, publishBegan: { began = true })
            Issue.record("Expected startup error")
        } catch { #expect(!began) }
    }

    @Test func invalidatedIntentNeverPublishesBegan() async {
        enum Failure: Error { case cancelled }
        var began = false
        do {
            try await VoiceCaptureStartup.perform(start: {},
                validate: { throw Failure.cancelled }, publishBegan: { began = true })
            Issue.record("Expected intent cancellation")
        } catch { #expect(!began) }
    }
}
