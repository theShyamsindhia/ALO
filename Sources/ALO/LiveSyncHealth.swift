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
    static let continuityRecoveryNanos: UInt64 = 10_000_000_000
    static let continuityFreshnessNanos: UInt64 = 2_500_000_000
    private struct Continuity: Equatable, Sendable {
        var late: UInt64
        var resync: UInt64
        var lastFreshAt: UInt64?
        var stableSince: UInt64?
        var warning = false
    }
    static let localParticipant = SyncParticipant.localRenderer
    private(set) var driftParticipants: Set<SyncParticipant> = []
    private(set) var clockParticipants: Set<SyncParticipant> = []
    private var continuity: [SyncParticipant: Continuity] = [:]

    mutating func retainParticipants(_ participants: Set<SyncParticipant>) {
        driftParticipants.formIntersection(participants)
        clockParticipants.formIntersection(participants)
        continuity = continuity.filter { participants.contains($0.key) }
    }

    mutating func invalidateContinuityFreshness(excluding preserved: Set<SyncParticipant> = []) {
        // Keep incident/baseline state across pauses and unavailable reads, but
        // never count their elapsed time toward fresh-report recovery.
        for participant in Array(continuity.keys) where !preserved.contains(participant) {
            continuity[participant]?.lastFreshAt = nil
            continuity[participant]?.stableSince = nil
        }
    }

    func hasContinuityWarning(for participant: SyncParticipant) -> Bool {
        continuity[participant]?.warning == true
    }

    var hasPeerContinuityWarning: Bool {
        continuity.contains { participant, state in
            if case .peer = participant { return state.warning }
            return false
        }
    }

    /// Historical totals establish a baseline, not a permanent warning. Once
    /// an interruption is observed, only ten seconds of fresh counter reports
    /// without new reported interruptions clear it. Missing telemetry does not
    /// count toward recovery; this is not evidence of acoustic alignment.
    mutating func observeContinuity(late: UInt64?, resync: UInt64?, fresh: Bool,
                                   participant: SyncParticipant, at now: UInt64) -> Bool {
        guard fresh, let late, let resync else {
            if var state = continuity[participant] {
                state.lastFreshAt = nil
                state.stableSince = nil
                continuity[participant] = state
            }
            return false
        }
        guard var state = continuity[participant] else {
            continuity[participant] = Continuity(late: late, resync: resync, lastFreshAt: now)
            return true
        }
        let increased = late > state.late || resync > state.resync
        let reset = late < state.late || resync < state.resync
        let continuous = state.lastFreshAt.map {
            now >= $0 && now - $0 < Self.continuityFreshnessNanos
        } ?? false
        if increased {
            state.warning = true
            state.stableSince = now
        } else if state.warning {
            if reset || !continuous || state.stableSince == nil { state.stableSince = now }
            if let began = state.stableSince, now >= began,
               now - began >= Self.continuityRecoveryNanos { state.warning = false }
        }
        state.late = late
        state.resync = resync
        state.lastFreshAt = now
        continuity[participant] = state
        return !state.warning
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
        recovery.invalidateContinuityFreshness()
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
