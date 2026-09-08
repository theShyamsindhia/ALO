import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite("Recent playback continuity affects live synchronization")
struct SyncContinuityTests {
    @Test func resyncWithoutDriftRecordsContinuityAtTheActualSnapshot() {
        var recovery = SyncRecoveryState()
        func sample(_ second: Int, resync: UInt64, driftAvailable: Bool = true) -> DiagnosticOutcome {
            var room = context(late: 0, resync: resync,
                drift: driftAvailable ? 0.1 : nil, age: driftAvailable ? 10 : nil)
            room.recovery = recovery
            room.observedAtNanos = UInt64(second) * 1_000_000_000
            let result = room.result
            recovery = result.syncRecovery ?? recovery
            return result.outcome
        }
        #expect(sample(1, resync: 0) == .passed)
        // hardResynchronize clears the drift measurement in the same snapshot
        // that increments this live counter. The counter is still current.
        #expect(sample(2, resync: 1, driftAvailable: false) == .warning)
        for second in 3...11 { #expect(sample(second, resync: 1) == .warning) }
        #expect(sample(12, resync: 1) == .passed,
            "Counter continuity must not start one sample late because drift was cleared")
    }

    @Test func missingHostSubsetBreaksRemoteRecoveryWindow() {
        var recovery = SyncRecoveryState()
        func sample(_ second: Int, resync: UInt64, missingHost: Bool = false) -> DiagnosticOutcome {
            let listener = HostListenerTimingDiagnostics(peerID: "remote", isTimingEligible: true,
                reportAgeMilliseconds: 10, recommendedBufferMilliseconds: 250,
                hardwareFloorMilliseconds: 20, driftMilliseconds: 0.1,
                driftSampleAgeMilliseconds: 10, playbackReportAgeMilliseconds: 10,
                resyncCount: resync)
            let host = HostTimingDiagnostics(listenerCount: 1, reportingListenerCount: 1,
                groupBufferMilliseconds: 250, maximumLatenessMilliseconds: 0,
                totalResyncCount: resync, listeners: [listener])
            let result = DiagnosticRoomContext(isActive: true, role: .broadcaster,
                participantCount: 2, remotePeerCount: 1, syncLabel: "Broadcasting",
                audioIsRendering: true, hasBroadcaster: true,
                timing: .init(receiver: context(late: 0, resync: 0).timing?.receiver,
                    host: missingHost ? nil : host), recovery: recovery,
                observedAtNanos: UInt64(second) * 1_000_000_000,
                peerPlaybackTiming: ["remote": .init(roundTripMilliseconds: 2,
                    driftMilliseconds: 0.1)]).result
            recovery = result.syncRecovery ?? recovery
            return result.outcome
        }
        #expect(sample(0, resync: 100) == .passed)
        #expect(sample(1, resync: 101) == .warning)
        for second in 2...9 { #expect(sample(second, resync: 101) == .warning) }
        #expect(sample(10, resync: 101, missingHost: true) == .warning)
        for second in 11...20 { #expect(sample(second, resync: 101) == .warning) }
        #expect(sample(21, resync: 101) == .passed)
    }

    @Test func explicitInvalidationBreaksFreshRecoveryWithoutErasingWarning() {
        var state = SyncRecoveryState()
        #expect(tick(&state, at: 0))
        #expect(!tick(&state, at: 1, resync: 1))
        for second in 2...10 { #expect(!tick(&state, at: second, resync: 1)) }
        var health = LiveSyncHealth()
        health.observe(.init(outcome: .warning, detail: "Recovering continuity", checkedAt: nil,
            syncRecovery: state), at: 10_000_000_000)
        health.invalidateCurrentSample()
        state = health.recovery
        #expect(!tick(&state, at: 11, resync: 1),
            "Explicit unavailable telemetry must restart the fresh recovery window")
        for second in 12...20 { #expect(!tick(&state, at: second, resync: 1)) }
        #expect(tick(&state, at: 21, resync: 1))
    }

    @Test func counterIncrementsOverrideHealthyDrift() {
        var health = LiveSyncHealth()
        var first = context(late: 488, resync: 57)
        first.observedAtNanos = 1_000_000_000
        first.recovery = health.recovery
        let baseline = first.result
        #expect(baseline.outcome == .passed, "Historical totals alone must not fail recovered playback")
        health.observe(baseline, at: 1_000_000_000)
        var next = context(late: 489, resync: 58)
        next.observedAtNanos = 2_000_000_000
        next.recovery = health.recovery
        let increment = next.result
        #expect(increment.outcome == .warning,
            "A new interruption must not look healthy merely because clock drift is 0.1ms")
        health.observe(increment, at: 2_000_000_000)
        #expect(health.evidence(at: 2_100_000_000) == .needsAttention)
        #expect(health.playbackLabel(isHost: false, now: 2_100_000_000) == "Check sync")
    }

    @Test func tenFreshStableSecondsRecoverButEveryIncreaseRestartsTheWindow() {
        var state = SyncRecoveryState()
        #expect(tick(&state, at: 0, late: 500, resync: 100))
        #expect(!tick(&state, at: 1, late: 501, resync: 101))
        for second in 2...10 { #expect(!tick(&state, at: second, late: 501, resync: 101)) }
        #expect(!tick(&state, at: 11, late: 501, resync: 102))
        for second in 12...20 { #expect(!tick(&state, at: second, late: 501, resync: 102)) }
        #expect(tick(&state, at: 21, late: 501, resync: 102))
    }

    @Test func staleReportsAndObservationGapsCannotCountAsRecovery() {
        var state = SyncRecoveryState()
        #expect(tick(&state, at: 0))
        #expect(!tick(&state, at: 1, resync: 1))
        for second in 2...9 { #expect(!tick(&state, at: second, resync: 1)) }
        #expect(!tick(&state, at: 10, resync: 1, fresh: false))
        #expect(!tick(&state, at: 11, resync: 1))
        for second in 12...20 { #expect(!tick(&state, at: second, resync: 1)) }
        #expect(tick(&state, at: 21, resync: 1))
        #expect(!tick(&state, at: 22, resync: 2))
        #expect(!tick(&state, at: 40, resync: 2), "Unobserved time is not stable playback")
        for second in 41...49 { #expect(!tick(&state, at: second, resync: 2)) }
        #expect(tick(&state, at: 50, resync: 2))
    }

    @Test func counterResetDoesNotEraseAnObservedInterruption() {
        var state = SyncRecoveryState()
        #expect(tick(&state, at: 0, resync: 100))
        #expect(!tick(&state, at: 1, resync: 101))
        #expect(!tick(&state, at: 2, resync: 0))
        for second in 3...11 { #expect(!tick(&state, at: second)) }
        #expect(tick(&state, at: 12))
    }

    @Test func missingCountersPreserveBaselineAndExactGapBreaksRecovery() {
        var state = SyncRecoveryState()
        #expect(tick(&state, at: 0, resync: 100))
        let missing = state.observeContinuity(late: nil, resync: nil, fresh: true,
            participant: .localRenderer, at: 1_000_000_000)
        #expect(!missing)
        #expect(!tick(&state, at: 2, resync: 101), "Missing counts must not erase the baseline")
        let boundary = state.observeContinuity(late: 0, resync: 101, fresh: true,
            participant: .localRenderer, at: 4_500_000_000)
        #expect(!boundary)
        for halfSecond in stride(from: 11, through: 27, by: 2) {
            let ready = state.observeContinuity(late: 0, resync: 101, fresh: true,
                participant: .localRenderer, at: UInt64(halfSecond) * 500_000_000)
            #expect(!ready)
        }
        let recovered = state.observeContinuity(late: 0, resync: 101, fresh: true,
            participant: .localRenderer, at: 14_500_000_000)
        #expect(recovered)
    }

    @Test func participantRemovalAndNewSessionDiscardTheirOwnHistory() {
        var state = SyncRecoveryState()
        #expect(tick(&state, at: 0, participant: .peer("a")))
        #expect(!tick(&state, at: 1, resync: 1, participant: .peer("a")))
        #expect(tick(&state, at: 1, participant: .localRenderer))
        #expect(tick(&state, at: 1, participant: .peer("b")))
        state.retainParticipants([.localRenderer, .peer("b")])
        #expect(tick(&state, at: 2, resync: 50, participant: .peer("a")))
        state = LiveSyncHealth().recovery
        #expect(tick(&state, at: 3, resync: 50, participant: .peer("a")))
    }

    @Test func backwardTimeCannotClearRecovery() {
        var state = SyncRecoveryState()
        #expect(tick(&state, at: 10))
        #expect(!tick(&state, at: 11, resync: 1))
        #expect(!tick(&state, at: 0, resync: 1))
        for second in 1...9 { #expect(!tick(&state, at: second, resync: 1)) }
        #expect(tick(&state, at: 10, resync: 1))
    }

    @Test func remoteCounterIncrementAffectsBroadcasterVerdict() {
        func host(_ count: UInt64, at now: UInt64, recovery: SyncRecoveryState,
                  fresh: Bool = true) -> DiagnosticCheckResult {
            let listener = HostListenerTimingDiagnostics(peerID: "remote", isTimingEligible: true,
                reportAgeMilliseconds: 10, recommendedBufferMilliseconds: 250,
                hardwareFloorMilliseconds: 20, driftMilliseconds: 0.1,
                driftSampleAgeMilliseconds: 10, playbackReportAgeMilliseconds: fresh ? 10 : nil,
                resyncCount: count)
            let timing = HostTimingDiagnostics(listenerCount: 1, reportingListenerCount: 1,
                groupBufferMilliseconds: 250, maximumLatenessMilliseconds: 0,
                totalResyncCount: count, listeners: [listener])
            return DiagnosticRoomContext(isActive: true, role: .broadcaster,
                participantCount: 2, remotePeerCount: 1, syncLabel: "Broadcasting",
                audioIsRendering: true, hasBroadcaster: true,
                timing: .init(receiver: nil, host: timing), recovery: recovery,
                observedAtNanos: now, peerPlaybackTiming: ["remote": .init(roundTripMilliseconds: 2,
                    driftMilliseconds: 0.1)]).result
        }
        let first = host(100, at: 1_000_000_000, recovery: .init())
        #expect(first.outcome == .passed)
        let next = host(101, at: 2_000_000_000, recovery: first.syncRecovery ?? .init())
        #expect(next.outcome == .warning)
        #expect(next.detail.contains("listener 1 playback was recently interrupted"))
        #expect(next.detail.contains("10 seconds of fresh reports without new playback interruptions"))
        let unavailable = host(100, at: 3_000_000_000, recovery: .init(), fresh: false)
        #expect(unavailable.outcome == .warning)
        #expect(unavailable.detail.contains("listener 1 playback continuity is not currently verified"))
        #expect(!unavailable.detail.contains("10 seconds"), "Missing first telemetry has no observed incident to recover from")
    }

    private func tick(_ state: inout SyncRecoveryState, at second: Int,
                      late: UInt64 = 0, resync: UInt64 = 0, fresh: Bool = true,
                      participant: SyncParticipant = .localRenderer) -> Bool {
        state.observeContinuity(late: late, resync: resync, fresh: fresh,
            participant: participant, at: UInt64(second) * 1_000_000_000)
    }

    private func context(late: UInt64, resync: UInt64,
                         drift: Double? = 0.1, age: Double? = 10) -> DiagnosticRoomContext {
        let receiver = ReceiverTimingDiagnostics(roundTripMilliseconds: 2,
            clockOffsetMilliseconds: 0, jitterMilliseconds: 1,
            recommendedBufferMilliseconds: 250, outputLatencyMilliseconds: 10,
            renderHeadroomMilliseconds: 20, outputSampleRate: 48_000,
            outputChannelCount: 2, latenessMilliseconds: 0,
            latePacketCount: late, resyncCount: resync,
            currentDriftMilliseconds: drift, driftMeasurementAgeMilliseconds: age)
        return DiagnosticRoomContext(isActive: true, role: .listener,
            participantCount: 2, remotePeerCount: 1, syncLabel: "Playing",
            audioIsRendering: true, hasBroadcaster: true,
            timing: SessionTimingDiagnostics(receiver: receiver, host: nil))
    }
}
