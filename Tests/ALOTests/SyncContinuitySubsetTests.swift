import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite("Unavailable continuity subsets preserve known interruptions")
struct SyncContinuitySubsetTests {
    @Test func missingLocalSubsetCannotClearAKnownInterruption() {
        let noHistory = room(local: nil, at: 1).result
        #expect(noHistory.outcome == .passed,
            "A broadcaster without local telemetry or an incident keeps the existing baseline contract")
        let baseline = room(local: 0, at: 1).result
        #expect(baseline.outcome == .passed)
        let incident = room(local: 1, at: 2, recovery: baseline.syncRecovery ?? .init()).result
        #expect(incident.outcome == .warning)
        #expect(incident.detail.contains("playback was recently interrupted"))
        let missing = room(local: nil, at: 3, recovery: incident.syncRecovery ?? .init()).result
        #expect(missing.syncRecovery?.hasContinuityWarning(for: .localRenderer) == true)
        #expect(missing.outcome == .warning,
            "Healthy remote telemetry cannot clear the unresolved local interruption")
        #expect(missing.detail.contains("playback was recently interrupted"),
            "Unavailable local telemetry must not hide the recorded incident")
    }

    @Test func missingHostSubsetStillExplainsItsRetainedPeerIncident() {
        let baseline = room(local: 0, at: 1).result
        let incident = room(local: 0, peer: 1, at: 2,
            recovery: baseline.syncRecovery ?? .init()).result
        #expect(incident.outcome == .warning)
        let missing = room(local: 0, peer: 1, hostAvailable: false, at: 3,
            recovery: incident.syncRecovery ?? .init()).result
        #expect(missing.outcome == .warning)
        #expect(missing.syncRecovery?.hasContinuityWarning(for: .peer("remote")) == true)
        #expect(missing.detail.contains("playback was recently interrupted"),
            "Unavailable host telemetry must not hide the retained listener incident")
    }

    private func room(local: UInt64?, peer: UInt64 = 0, hostAvailable: Bool = true,
                      at second: UInt64, recovery: SyncRecoveryState = .init()) -> DiagnosticRoomContext {
        let receiver = local.map { resync in
            ReceiverTimingDiagnostics(roundTripMilliseconds: 2, clockOffsetMilliseconds: 0,
                jitterMilliseconds: 1, recommendedBufferMilliseconds: 250,
                outputLatencyMilliseconds: 10, renderHeadroomMilliseconds: 20,
                outputSampleRate: 48_000, outputChannelCount: 2, latenessMilliseconds: 0,
                latePacketCount: 0, resyncCount: resync,
                currentDriftMilliseconds: 0.1, driftMeasurementAgeMilliseconds: 10)
        }
        let listener = HostListenerTimingDiagnostics(peerID: "remote", isTimingEligible: true,
            reportAgeMilliseconds: 10, recommendedBufferMilliseconds: 250,
            hardwareFloorMilliseconds: 20, driftMilliseconds: 0.1,
            driftSampleAgeMilliseconds: 10, playbackReportAgeMilliseconds: 10,
            resyncCount: peer)
        let host = HostTimingDiagnostics(listenerCount: 1, reportingListenerCount: 1,
            groupBufferMilliseconds: 250, maximumLatenessMilliseconds: 0,
            totalResyncCount: peer, listeners: [listener])
        return DiagnosticRoomContext(isActive: true, role: .broadcaster, participantCount: 2,
            remotePeerCount: 1, syncLabel: "Broadcasting", audioIsRendering: true,
            hasBroadcaster: true, timing: .init(receiver: receiver, host: hostAvailable ? host : nil),
            recovery: recovery, observedAtNanos: second * 1_000_000_000,
            peerPlaybackTiming: ["remote": .init(roundTripMilliseconds: 2, driftMilliseconds: 0.1)])
    }
}
