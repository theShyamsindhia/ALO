import Foundation

/// Diagnostic tolerances, not the player's emergency reset thresholds. These
/// describe observed software timing, never a guarantee of acoustic alignment.
enum SyncHealthTolerance {
    static let driftWarningMilliseconds = 40.0
    static let driftRecoveryMilliseconds = 20.0
    // RTT/2 alone is not a complete uncertainty bound. A large RTT is enough
    // to withhold confidence; a small RTT is not proof of physical alignment.
    static let clockRTTWarningMilliseconds = 40.0
    static let clockRTTRecoveryMilliseconds = 30.0

    static func acceptsDrift(_ drift: Double?, age: Double?, recovering: Bool) -> Bool {
        guard let drift, let age, drift.isFinite, drift >= 0,
              age.isFinite, age >= 0, age <= 500 else { return false }
        return recovering ? drift <= driftRecoveryMilliseconds : drift < driftWarningMilliseconds
    }

    static func acceptsClockRTT(_ roundTrip: Double?, recovering: Bool) -> Bool {
        guard let roundTrip, roundTrip.isFinite, roundTrip >= 0 else { return false }
        return recovering ? roundTrip <= clockRTTRecoveryMilliseconds : roundTrip < clockRTTWarningMilliseconds
    }
}

/// The visible playback label consumes the same verdict as exported diagnostics.
struct LiveSyncHealth {
    private(set) var result: DiagnosticCheckResult?
    private(set) var sampledAtNanos: UInt64?
    private(set) var recentTransitions: [DiagnosticCheckResult] = []
    /// Preserve warning hysteresis across missing samples, pauses and reconnects
    /// within this monitoring session. A new session replaces this value.
    private(set) var requiresRecovery = false
    var hasCurrentSample: Bool { result != nil || sampledAtNanos != nil }

    mutating func observe(_ result: DiagnosticCheckResult, at now: UInt64) {
        requiresRecovery = result.outcome != .passed
        if recentTransitions.last?.outcome != result.outcome {
            recentTransitions.append(result)
            if recentTransitions.count > 16 { recentTransitions.removeFirst(recentTransitions.count - 16) }
        }
        self.result = result
        sampledAtNanos = now
    }

    mutating func invalidateCurrentSample() {
        result = nil
        sampledAtNanos = nil
    }

    func playbackLabel(isHost: Bool, now: UInt64) -> String {
        guard let result, let sampledAtNanos,
              now >= sampledAtNanos, now - sampledAtNanos < 2_500_000_000 else {
            return isHost ? "Broadcasting · checking sync" : "Checking sync…"
        }
        if result.outcome == .passed { return isHost ? "Broadcasting" : "Estimated sync" }
        return isHost ? "Broadcasting · check sync" : "Check sync"
    }
}
