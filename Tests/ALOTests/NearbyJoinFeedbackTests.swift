import ALONetworkUI
import Testing

struct NearbyJoinFeedbackTests {
    @Test func retryClearsFailureAndOldCompletionCannotRestoreIt() {
        var feedback = ALONearbyJoinFeedback()
        let failed = feedback.begin()
        feedback.finish(failed, errorMessage: "Expired")
        #expect(feedback.errorMessage == "Expired")
        let retry = feedback.begin()
        #expect(feedback.errorMessage == nil)
        feedback.finish(failed, errorMessage: "Late old failure")
        #expect(feedback.errorMessage == nil)
        feedback.finish(retry)
        #expect(feedback.errorMessage == nil)
    }

    @Test func cancelledAttemptCannotOverwriteNewerPendingOrFailedAttempt() {
        var feedback = ALONearbyJoinFeedback()
        let old = feedback.begin()
        feedback.cancel()
        let retry = feedback.begin()
        feedback.finish(old, errorMessage: "Old connection closed")
        #expect(feedback.errorMessage == nil)
        feedback.finish(retry, errorMessage: "Current preflight unavailable")
        feedback.finish(old)
        #expect(feedback.errorMessage == "Current preflight unavailable")
        feedback.cancel()
        #expect(feedback.errorMessage == nil)
    }

    @Test func currentPreflightFailureAndDismissalAreLocalToTheScreen() {
        var firstScreen = ALONearbyJoinFeedback()
        let secondScreen = ALONearbyJoinFeedback()
        let attempt = firstScreen.begin()
        firstScreen.finish(attempt, errorMessage: "Too many active requests")
        #expect(firstScreen.errorMessage == "Too many active requests")
        #expect(secondScreen.errorMessage == nil)
        firstScreen.dismissError()
        #expect(firstScreen.errorMessage == nil)
    }
}
