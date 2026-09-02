import CoreGraphics
import Foundation
import ScreenCaptureKit

enum RecordingErrorPresentation {
    private static let opaqueCaptureStartCodes: Set<Int> = [
        SCStreamError.Code.failedToStart.rawValue,
        SCStreamError.Code.internalError.rawValue,
        SCStreamError.Code.failedToStartAudioCapture.rawValue
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
                if opaqueCaptureStartCodes.contains(error.code) {
                    // ScreenCaptureKit can return only a generic start/audio failure when TCC
                    // rejects a newly installed copy whose signing identity no longer matches the
                    // permission entry shown in System Settings.
                    if !screenCaptureAccess { return true }
                }
            }

            let message = error.localizedDescription.lowercased()
            if permissionPhrases.contains(where: message.contains) {
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
        return "macOS denied recording access to this copy of WERAI. If WERAI already looks enabled, remove its old entry in Recording settings, add the installed app again, then restart WERAI."
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
