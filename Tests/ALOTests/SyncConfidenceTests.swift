import Foundation
import Testing
import ALOTiming
import ALOCore
@testable import ALO

@Suite("Synchronization confidence under asymmetric paths")
struct SyncConfidenceTests {
    @Test("Chart evidence is unknown before samples and after they expire")
    func chartEvidenceNeverManufacturesGreen() {
        var health = LiveSyncHealth()
        #expect(health.evidence(at: 0) == .unknown)
        #expect(health.evidence(at: 0).title == "No current timing")
        health.observe(listenerContext(drift: nil, rtt: nil).result, at: 1)
        #expect(health.evidence(at: 2) == .needsAttention)
        health.observe(listenerContext(drift: 2, rtt: 2).result, at: 3)
        #expect(health.evidence(at: 4) == .estimated)
        #expect(health.evidence(at: 2_500_000_003) == .unknown)
        health.invalidateCurrentSample()
        #expect(health.evidence(at: 4) == .unknown)
    }

    @Test("Video warnings and independent signals do not tighten each other's bands")
    func recoveryIsSignalSpecific() {
        var health = LiveSyncHealth()
        func tick(drift: Double?, rtt: Double?, video: VideoPresentationTimingSnapshot? = nil) -> DiagnosticOutcome {
            var room = listenerContext(drift: drift, rtt: rtt, video: video)
            room.recovery = health.recovery
            let result = room.result
            health.observe(result, at: 1)
            return result.outcome
        }
        let lateVideo = VideoPresentationTimingSnapshot(measuredAtNanos: 1_000_000_000,
            latestHandoffAtNanos: 1_000_000_000, latestDeadlineMissNanos: 150_000_000,
            maximumDeadlineMissNanos: 150_000_000, presentedCount: 1,
            pendingCount: 0, oldestPendingDeadlineNanos: nil)
        #expect(tick(drift: 30, rtt: 35, video: lateVideo) == .warning)
        #expect(tick(drift: 30, rtt: 35) == .passed)
        #expect(tick(drift: 70, rtt: 35) == .warning)
        #expect(tick(drift: 20, rtt: 35) == .passed)
        #expect(tick(drift: 30, rtt: 82) == .warning)
        #expect(tick(drift: 30, rtt: 30) == .passed)
    }

    @Test("Recovery state follows only the participant that exceeded the threshold")
    func recoveryIsParticipantSpecific() {
        var state = SyncRecoveryState()
        let outside = state.observeDrift(70, age: 1, participant: "a")
        #expect(!outside)
        let other = state.observeDrift(30, age: 1, participant: "b")
        #expect(other)
        let missing = state.observeDrift(nil, age: nil, participant: "a")
        #expect(!missing)
        let intermediate = state.observeDrift(30, age: 1, participant: "a")
        #expect(!intermediate)
        let recovered = state.observeDrift(20, age: 1, participant: "a")
        #expect(recovered)
        let clockOutside = state.observeClockRTT(82, participant: "a")
        #expect(!clockOutside)
        let otherClock = state.observeClockRTT(35, participant: "b")
        #expect(otherClock)
        state.retainParticipants(["b"])
        #expect(state.clockParticipants.isEmpty)
    }

    @Test("A transient missing sample does not tighten healthy unrelated signals forever")
    func missingSampleMustNotLatchHealthySignals() {
        var health = LiveSyncHealth()
        health.observe(listenerContext(drift: 30, rtt: 35).result, at: 1)
        #expect(health.result?.outcome == .passed)
        health.observe(listenerContext(drift: nil, rtt: 35).result, at: 2)
        #expect(health.result?.outcome == .warning)
        var resumed = listenerContext(drift: 30, rtt: 35)
        resumed.recovery = health.recovery
        #expect(resumed.result.outcome == .passed,
            "Neither drift nor RTT crossed its warning threshold; missing data must not latch both")
    }

    @Test("Drift and clock warnings retain hysteresis across missing measurements")
    func recoveryRequiresMeasuredRecovery() {
        var health = LiveSyncHealth()
        func tick(drift: Double?, rtt: Double?) -> DiagnosticOutcome {
            var room = listenerContext(drift: drift, rtt: rtt)
            room.recovery = health.recovery
            let result = room.result
            health.observe(result, at: 1)
            return result.outcome
        }
        #expect(tick(drift: 2, rtt: 2) == .passed)
        #expect(tick(drift: 70, rtt: 2) == .warning)
        #expect(tick(drift: 30, rtt: 2) == .warning)
        health.invalidateCurrentSample()
        #expect(!health.recovery.driftParticipants.isEmpty)
        #expect(tick(drift: nil, rtt: 2) == .warning)
        #expect(tick(drift: 30, rtt: 2) == .warning)
        #expect(tick(drift: 20, rtt: 2) == .passed)
        #expect(tick(drift: 2, rtt: 82) == .warning)
        #expect(tick(drift: 2, rtt: 35) == .warning)
        #expect(tick(drift: 2, rtt: nil) == .warning)
        #expect(tick(drift: 2, rtt: 35) == .warning)
        #expect(tick(drift: 2, rtt: 30) == .passed)
        #expect(health.playbackLabel(isHost: false, now: 2) == "Estimated sync")
    }

    @Test("Missing, malformed or stale timing cannot confer confidence")
    func invalidEvidenceStaysUnknown() {
        for rtt in [nil, Double.nan, Double.infinity, -1, 40] as [Double?] {
            #expect(listenerContext(drift: 1, rtt: rtt).result.outcome == .warning)
        }
        #expect(listenerContext(drift: 1, rtt: 2, age: 501).result.outcome == .warning)
        #expect(listenerContext(drift: 1, rtt: 2, age: nil).result.outcome == .warning)
        #expect(listenerContext(drift: 1, rtt: 2).result.detail.contains("not measured acoustic alignment"))
        #expect(listenerContext(drift: 40, rtt: 2).result.outcome == .warning)
        #expect(listenerContext(drift: 39, rtt: 2).result.outcome == .passed)
    }

    @Test("Host confidence requires the matching listener's current clock report")
    func hostMustNotBorrowAnotherPeersClock() {
        let listener = HostListenerTimingDiagnostics(peerID: "listener",
            isTimingEligible: true, reportAgeMilliseconds: 10,
            recommendedBufferMilliseconds: 250, hardwareFloorMilliseconds: 50,
            driftMilliseconds: 1, driftSampleAgeMilliseconds: 10,
            playbackReportAgeMilliseconds: 10)
        let host = HostTimingDiagnostics(listenerCount: 1, reportingListenerCount: 1,
            groupBufferMilliseconds: 250, maximumLatenessMilliseconds: 0,
            totalResyncCount: 0, listeners: [listener])
        var room = DiagnosticRoomContext(isActive: true, role: .broadcaster,
            participantCount: 2, remotePeerCount: 1, syncLabel: "Broadcasting",
            audioIsRendering: true, hasBroadcaster: true,
            timing: SessionTimingDiagnostics(receiver: nil, host: host))
        let healthy = PeerPlaybackTiming(roundTripMilliseconds: 2, driftMilliseconds: 1)
        #expect(room.result.outcome == .warning)
        room.peerPlaybackTiming = ["unrelated": healthy]
        #expect(room.result.outcome == .warning)
        room.peerPlaybackTiming = ["listener": healthy]
        #expect(room.result.outcome == .passed)
        room.peerPlaybackTiming = ["listener": .init(roundTripMilliseconds: 82, driftMilliseconds: 1)]
        #expect(room.result.outcome == .warning)
        // The control plane removes stale telemetry before publishing the
        // participant snapshot; losing that entry must not retain old green.
        #expect(!healthy.isFresh(receivedAt: 0, now: 3_000_000_001))
        room.peerPlaybackTiming = [:]
        #expect(room.result.outcome == .warning)
        #expect(!room.result.detail.contains("listener clock"))
    }

    private func listenerContext(drift: Double?, rtt: Double?, age: Double? = 10,
                                 video: VideoPresentationTimingSnapshot? = nil) -> DiagnosticRoomContext {
        let receiver = ReceiverTimingDiagnostics(roundTripMilliseconds: rtt,
            clockOffsetMilliseconds: 0, jitterMilliseconds: 0,
            recommendedBufferMilliseconds: 250, outputLatencyMilliseconds: 10,
            renderHeadroomMilliseconds: 25, outputSampleRate: 48_000,
            outputChannelCount: 2, latenessMilliseconds: 0,
            latePacketCount: 0, resyncCount: 0,
            currentDriftMilliseconds: drift, driftMeasurementAgeMilliseconds: age, video: video)
        return DiagnosticRoomContext(isActive: true, role: .listener,
            participantCount: 2, remotePeerCount: 1, syncLabel: "Checking sync",
            audioIsRendering: true, hasBroadcaster: true,
            timing: SessionTimingDiagnostics(receiver: receiver, host: nil))
    }

    @Test("The live verdict must agree with the monitor's measured-drift warning")
    func monitorWarningMustNotShowSynced() {
        let drift = 70.0
        #expect(drift >= RoomSyncMonitor.correctionThresholdMilliseconds)
        let receiver = ReceiverTimingDiagnostics(
            roundTripMilliseconds: 2, clockOffsetMilliseconds: 0,
            jitterMilliseconds: 0, recommendedBufferMilliseconds: 250,
            outputLatencyMilliseconds: 10, renderHeadroomMilliseconds: 25,
            outputSampleRate: 48_000, outputChannelCount: 2,
            latenessMilliseconds: 0, latePacketCount: 0, resyncCount: 0,
            currentDriftMilliseconds: drift, driftMeasurementAgeMilliseconds: 10)
        let room = DiagnosticRoomContext(isActive: true, role: .listener,
            participantCount: 2, remotePeerCount: 1, syncLabel: "Synced",
            audioIsRendering: true, hasBroadcaster: true,
            timing: SessionTimingDiagnostics(receiver: receiver, host: nil))
        #expect(room.result.outcome == .warning,
            "The monitor warns at 40 ms; the diagnostics must not wait for the 100 ms hard-resync threshold")
        var health = LiveSyncHealth()
        health.observe(room.result, at: 1_000_000_000)
        #expect(health.playbackLabel(isHost: false, now: 1_000_000_001) != "Synced")
    }

    @Test("A small render residual cannot verify alignment over an uncertain clock path")
    func stableAsymmetryMustNotShowVerifiedSync() throws {
        // Both clocks actually agree. An 80 ms outward / 2 ms return path
        // produces a stable 39 ms offset estimate. Four timestamps cannot
        // identify which direction contributes the delay.
        let clock = ClockSynchronizer()
        for index in 0..<120 {
            let sent = UInt64(index + 1) * 1_000_000_000
            let probe = clock.makeProbe(at: sent)
            #expect(clock.acceptReply(id: probe.id, echoedSendNanos: sent,
                hostNanos: sent + 80_000_000, receivedAt: sent + 82_000_000,
                hostReceivedNanos: sent + 80_000_000))
        }
        #expect(clock.isReady)
        let roundTrip = try #require(clock.bestRoundTripNanos)
        let offset = try #require(clock.offsetNanos)
        #expect(roundTrip == 82_000_000)
        #expect(abs(offset - 39_000_000) < 1_000)
        // Even with zero model instability, the path alone permits more than
        // the desired 20 ms alignment target. RTT/2 is not a complete bound:
        // model dispersion, aging and device uncertainty would add to it.
        #expect(roundTrip / 2 > 20_000_000)
        let receiver = ReceiverTimingDiagnostics(
            roundTripMilliseconds: Double(roundTrip) / 1_000_000,
            clockOffsetMilliseconds: Double(offset) / 1_000_000,
            jitterMilliseconds: 0, recommendedBufferMilliseconds: 250,
            outputLatencyMilliseconds: 10, renderHeadroomMilliseconds: 25,
            outputSampleRate: 48_000, outputChannelCount: 2,
            latenessMilliseconds: 0, latePacketCount: 0, resyncCount: 0,
            currentDriftMilliseconds: 1, driftMeasurementAgeMilliseconds: 10)
        let room = DiagnosticRoomContext(isActive: true, role: .listener,
            participantCount: 2, remotePeerCount: 1, syncLabel: "Synced",
            audioIsRendering: true, hasBroadcaster: true,
            timing: SessionTimingDiagnostics(receiver: receiver, host: nil))
        let result = room.result
        #expect(result.outcome == .warning,
            "A stable estimated clock and 1 ms residual do not establish physical alignment")
        var health = LiveSyncHealth()
        health.observe(result, at: 1_000_000_000)
        #expect(health.playbackLabel(isHost: false, now: 1_000_000_001) != "Synced",
            "The visible verdict must not discard clock uncertainty")
    }
}
