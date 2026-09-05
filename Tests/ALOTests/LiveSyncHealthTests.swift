import Foundation
import Testing
@testable import ALO

@Suite("Live sync status")
struct LiveSyncHealthTests {
    @Test("Unavailable diagnostic reads cannot evict a genuine warning and recovery")
    func unavailableReadsDoNotManufactureTransitions() {
        var health = LiveSyncHealth()
        let warning = DiagnosticCheckResult(outcome: .warning, detail: "150 ms drift", checkedAt: nil)
        let recovered = DiagnosticCheckResult(outcome: .passed, detail: "recovered", checkedAt: nil)
        health.observe(warning, at: 0)
        #expect(health.hasCurrentSample)
        health.observe(recovered, at: 1)
        for index in 2..<22 {
            health.invalidateCurrentSample()
            #expect(!health.hasCurrentSample)
            health.observe(recovered, at: UInt64(index))
        }
        #expect(health.recentTransitions.map(\.outcome) == [.warning, .passed])
        health.observe(warning, at: 22)
        #expect(health.recentTransitions.map(\.outcome) == [.warning, .passed, .warning])
    }

    @Test("Rendering alone is not a sync verdict; fresh drift warnings replace healthy status")
    func liveStatusTracksDiagnosticsAndRejectsStaleResults() {
        var health = LiveSyncHealth()
        #expect(health.playbackLabel(isHost: false, now: 0) == "Checking sync…")
        health.observe(.init(outcome: .passed, detail: "fresh audio timing", checkedAt: nil), at: 1_000_000_000)
        #expect(health.playbackLabel(isHost: false, now: 1_100_000_000) == "Synced")
        health.observe(.init(outcome: .warning, detail: "150 ms screen handoff miss", checkedAt: nil), at: 2_000_000_000)
        #expect(health.playbackLabel(isHost: false, now: 2_100_000_000) == "Check sync")
        #expect(health.playbackLabel(isHost: true, now: 2_100_000_000) == "Broadcasting · check sync")
        health.observe(.init(outcome: .passed, detail: "recovered", checkedAt: nil), at: 3_000_000_000)
        #expect(health.playbackLabel(isHost: false, now: 3_100_000_000) == "Synced")
        #expect(health.playbackLabel(isHost: false, now: 6_000_000_000) == "Checking sync…")
        #expect(health.playbackLabel(isHost: false, now: 2_000_000_000) == "Checking sync…")
        health = LiveSyncHealth()
        #expect(health.playbackLabel(isHost: false, now: 6_000_000_000) == "Checking sync…")
    }

    @Test("Recovered sync keeps bounded incident evidence without recording every timer tick")
    func retainsTransitionsNotEverySample() {
        var health = LiveSyncHealth()
        for index in 0..<40 {
            let result = DiagnosticCheckResult(outcome: index.isMultiple(of: 2) ? .warning : .passed,
                detail: "sample \(index)", checkedAt: nil)
            health.observe(result, at: UInt64(index))
            health.observe(result, at: UInt64(index))
        }
        #expect(health.recentTransitions.count == 16)
        #expect(health.recentTransitions.first?.detail == "sample 24")
        #expect(health.recentTransitions.last?.outcome == .passed)
        #expect(health.recentTransitions.contains { $0.outcome == .warning })
        health.invalidateCurrentSample()
        #expect(health.result == nil)
        #expect(health.recentTransitions.count == 16)
        #expect(health.playbackLabel(isHost: false, now: 40) == "Checking sync…")
    }
}
