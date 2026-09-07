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

}

/// Hysteresis belongs to the measured signal and participant that crossed a
/// threshold. Missing data or a video warning must not latch unrelated signals.
enum SyncParticipant: Hashable, Sendable {
    case localRenderer
    case peer(String)
}

struct SyncRecoveryState: Equatable, Sendable {
    static let localParticipant = SyncParticipant.localRenderer
    private(set) var driftParticipants: Set<SyncParticipant> = []
    private(set) var clockParticipants: Set<SyncParticipant> = []

    mutating func retainParticipants(_ participants: Set<SyncParticipant>) {
        driftParticipants.formIntersection(participants)
        clockParticipants.formIntersection(participants)
    }

    mutating func observeDrift(_ drift: Double?, age: Double?, participant: SyncParticipant) -> Bool {
        guard let drift, let age, drift.isFinite, drift >= 0,
              age.isFinite, age >= 0, age <= 500 else { return false }
        if drift >= SyncHealthTolerance.driftWarningMilliseconds { driftParticipants.insert(participant) }
        else if drift <= SyncHealthTolerance.driftRecoveryMilliseconds { driftParticipants.remove(participant) }
        return !driftParticipants.contains(participant)
    }

    mutating func observeClockRTT(_ roundTrip: Double?, participant: SyncParticipant) -> Bool {
        guard let roundTrip, roundTrip.isFinite, roundTrip >= 0 else { return false }
        if roundTrip >= SyncHealthTolerance.clockRTTWarningMilliseconds { clockParticipants.insert(participant) }
        else if roundTrip <= SyncHealthTolerance.clockRTTRecoveryMilliseconds { clockParticipants.remove(participant) }
        return !clockParticipants.contains(participant)
    }
}

enum LiveSyncEvidence: Equatable {
    case unknown, needsAttention, estimated

    var title: String {
        switch self {
        case .unknown: "No current timing"
        case .needsAttention: "Check timing"
        case .estimated: "Estimated sync"
        }
    }
}

/// The visible playback label consumes the same verdict as exported diagnostics.
struct LiveSyncHealth {
    private(set) var result: DiagnosticCheckResult?
    private(set) var sampledAtNanos: UInt64?
    private(set) var recentTransitions: [DiagnosticCheckResult] = []
    /// Preserve warning hysteresis across missing samples, pauses and reconnects
    /// within this monitoring session. A new session replaces this value.
    private(set) var recovery = SyncRecoveryState()
    var hasCurrentSample: Bool { result != nil || sampledAtNanos != nil }

    mutating func observe(_ result: DiagnosticCheckResult, at now: UInt64) {
        if let recovery = result.syncRecovery { self.recovery = recovery }
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

    func currentResult(at now: UInt64) -> DiagnosticCheckResult? {
        guard let result, let sampledAtNanos,
              now >= sampledAtNanos, now - sampledAtNanos < 2_500_000_000 else {
            return nil
        }
        return result
    }

    func evidence(at now: UInt64) -> LiveSyncEvidence {
        guard let result = currentResult(at: now) else { return .unknown }
        return result.outcome == .passed ? .estimated : .needsAttention
    }

    func playbackLabel(isHost: Bool, now: UInt64) -> String {
        guard let result = currentResult(at: now) else {
            return isHost ? "Broadcasting · checking sync" : "Checking sync…"
        }
        if result.outcome == .passed { return isHost ? "Broadcasting" : "Estimated sync" }
        return isHost ? "Broadcasting · check sync" : "Check sync"
    }
}
