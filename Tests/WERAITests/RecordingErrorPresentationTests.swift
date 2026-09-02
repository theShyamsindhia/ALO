import Foundation
import ScreenCaptureKit
import Testing
@testable import WERAI

@Suite("Recording error presentation")
struct RecordingErrorPresentationTests {
    @Test func recognizesExplicitScreenCaptureDenial() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )

        #expect(RecordingErrorPresentation.isPermissionFailure(error, screenCaptureAccess: true))
    }

    @Test func recognizesOpaqueAudioStartFailureWhenTCCPreflightFails() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.failedToStartAudioCapture.rawValue
        )

        #expect(RecordingErrorPresentation.isPermissionFailure(error, screenCaptureAccess: false))
        #expect(!RecordingErrorPresentation.isPermissionFailure(error, screenCaptureAccess: true))
    }

    @Test func doesNotTreatEveryCaptureFailureAsPermissionRelated() {
        let error = NSError(
            domain: "WERAITests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "No display is available for system-audio capture."]
        )

        #expect(!RecordingErrorPresentation.isPermissionFailure(error, screenCaptureAccess: false))
        #expect(RecordingErrorPresentation.message(for: error, screenCaptureAccess: false) == error.localizedDescription)
    }

    @Test func recognizesPermissionFailureWrappedByAnotherError() {
        let denied = NSError(
            domain: NSCocoaErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
        )
        let wrapper = NSError(
            domain: "WERAI",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "System audio could not start.",
                NSUnderlyingErrorKey: denied
            ]
        )

        #expect(RecordingErrorPresentation.isPermissionFailure(wrapper, screenCaptureAccess: true))
        #expect(RecordingErrorPresentation.message(for: wrapper, screenCaptureAccess: true).contains("old entry"))
    }
}
