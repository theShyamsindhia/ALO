import Foundation

/// The visible playback label consumes the same verdict as exported diagnostics.
struct LiveSyncHealth {
    private(set) var result: DiagnosticCheckResult?
    private(set) var sampledAtNanos: UInt64?
    private(set) var recentTransitions: [DiagnosticCheckResult] = []
    var hasCurrentSample: Bool { result != nil || sampledAtNanos != nil }

    mutating func observe(_ result: DiagnosticCheckResult, at now: UInt64) {
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
        if result.outcome == .passed { return isHost ? "Broadcasting" : "Synced" }
        return isHost ? "Broadcasting · check sync" : "Check sync"
    }
}
