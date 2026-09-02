import Foundation

protocol AudioSource: AnyObject {
    typealias AudioHandler = (_ samples: [Int16], _ captureTimeNanos: UInt64) -> Void
    func start(audioHandler: @escaping AudioHandler) async throws
    func stop() async throws
}

extension SystemAudioCapture: AudioSource {}

enum AudioSourcePolicy: Equatable {
    case requireVirtualDevice
    case allowScreenCaptureFallback
}

enum ALOAudioSetupError: LocalizedError, Equatable {
    case installRequired
    case bridgeUnavailable

    var errorDescription: String? {
        switch self {
        case .installRequired:
            return "ALO Room must be installed before this Mac can broadcast. Install the audio component, then reopen ALO."
        case .bridgeUnavailable:
            return "ALO Room is installed, but its permission-free audio bridge is unavailable. Restart Core Audio or reinstall ALO; microphone capture was not opened."
        }
    }
}
