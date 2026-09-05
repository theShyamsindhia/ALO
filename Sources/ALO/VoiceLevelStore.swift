import Foundation

/// Local listening preferences keyed by the peer's persistent device ID.
/// These levels never alter the sender's microphone or another listener's mix.
struct VoiceLevelStore {
    private let defaults: UserDefaults
    private let key = "participantVoiceLevels.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var levels: [String: Double] {
        (defaults.dictionary(forKey: key) ?? [:]).reduce(into: [:]) { result, entry in
            guard !entry.key.isEmpty, let number = entry.value as? NSNumber,
                  number.doubleValue.isFinite else { return }
            result[entry.key] = Self.clamp(number.doubleValue)
        }
    }

    func set(_ volume: Double, for participantID: String) {
        guard !participantID.isEmpty, volume.isFinite else { return }
        var saved = levels
        saved[participantID] = Self.clamp(volume)
        defaults.set(saved, forKey: key)
    }

    static func clamp(_ volume: Double) -> Double { min(1, max(0, volume)) }
}
