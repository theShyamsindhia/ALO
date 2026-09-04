import Foundation

protocol AudioSource: AnyObject {
    typealias AudioHandler = (_ samples: [Int16], _ captureTimeNanos: UInt64) -> Void
    func start(audioHandler: @escaping AudioHandler) async throws
    func stop() async throws
}

extension SystemAudioCapture: AudioSource {}

enum ALOAudioSetupError: LocalizedError, Equatable {
    case bridgeUnavailable

    var errorDescription: String? {
        switch self {
        case .bridgeUnavailable:
            return "The legacy ALO audio bridge is unavailable. Current ALO builds use Screen & System Audio Recording instead."
        }
    }
}
