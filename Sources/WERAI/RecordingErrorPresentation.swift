import CoreGraphics
import Foundation
import ScreenCaptureKit

enum RecordingErrorPresentation {
    enum AccessStep: Equatable {
        case proceed
        case requestSystemAccess
        case restartRequired
        case showSettings
    }

    static func accessStep(preflightGranted: Bool, requestedThisLaunch: Bool) -> AccessStep {
        if preflightGranted { return requestedThisLaunch ? .restartRequired : .proceed }
        return requestedThisLaunch ? .showSettings : .requestSystemAccess
    }

    private static let opaqueScreenCaptureStartCodes: Set<Int> = [
        SCStreamError.Code.failedToStart.rawValue,
        SCStreamError.Code.internalError.rawValue
    ]

    private static let permissionPhrases = [
        "permission denied",
        "permission was denied",
        "not authorized",
        "user declined",
        "operation not permitted"
    ]

    static func isPermissionFailure(
        _ error: Error,
        screenCaptureAccess: Bool = CGPreflightScreenCaptureAccess()
    ) -> Bool {
        for error in errorChain(startingAt: error) {
            if error.domain == SCStreamErrorDomain {
                if error.code == SCStreamError.Code.userDeclined.rawValue {
                    return true
                }
                if error.code == SCStreamError.Code.failedToStartAudioCapture.rawValue,
                   !screenCaptureAccess {
                    return true
                }
                if opaqueScreenCaptureStartCodes.contains(error.code) {
                    // ScreenCaptureKit can return only a generic stream-start failure when TCC
                    // rejects a newly installed copy whose signing identity no longer matches the
                    // permission entry shown in System Settings.
                    if !screenCaptureAccess { return true }
                }
            }

            let message = error.localizedDescription.lowercased()
            if !screenCaptureAccess,
               permissionPhrases.contains(where: message.contains) {
                return true
            }
        }
        return false
    }

    static func message(
        for error: Error,
        screenCaptureAccess: Bool = CGPreflightScreenCaptureAccess()
    ) -> String {
        guard isPermissionFailure(error, screenCaptureAccess: screenCaptureAccess) else {
            return error.localizedDescription
        }
        return "macOS denied recording access to ALO. Enable ALO under Screen & System Audio Recording, then restart ALO before broadcasting again."
    }

    private static func errorChain(startingAt error: Error) -> [NSError] {
        var result = [NSError]()
        var current: NSError? = error as NSError
        var visited = Set<ObjectIdentifier>()

        while let error = current, visited.insert(ObjectIdentifier(error)).inserted {
            result.append(error)
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
}
