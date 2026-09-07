import Foundation
import Testing
import ALOTiming
import ALOCore
@testable import ALO

@Suite("Synchronization confidence under asymmetric paths")
struct SyncConfidenceTests {
    @Test("Drift and clock warnings retain hysteresis across missing measurements")
    func recoveryRequiresMeasuredRecovery() {
        var health = LiveSyncHealth()
        func tick(drift: Double?, rtt: Double?) -> DiagnosticOutcome {
            var room = listenerContext(drift: drift, rtt: rtt)
            room.requiresRecovery = health.requiresRecovery
            let result = room.result
            health.observe(result, at: 1)
            return result.outcome
        }
        #expect(tick(drift: 2, rtt: 2) == .passed)
        #expect(tick(drift: 70, rtt: 2) == .warning)
        #expect(tick(drift: 30, rtt: 2) == .warning)
        health.invalidateCurrentSample()
        #expect(health.requiresRecovery)
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

    private func listenerContext(drift: Double?, rtt: Double?, age: Double? = 10) -> DiagnosticRoomContext {
        let receiver = ReceiverTimingDiagnostics(roundTripMilliseconds: rtt,
            clockOffsetMilliseconds: 0, jitterMilliseconds: 0,
            recommendedBufferMilliseconds: 250, outputLatencyMilliseconds: 10,
            renderHeadroomMilliseconds: 25, outputSampleRate: 48_000,
            outputChannelCount: 2, latenessMilliseconds: 0,
            latePacketCount: 0, resyncCount: 0,
            currentDriftMilliseconds: drift, driftMeasurementAgeMilliseconds: age)
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
