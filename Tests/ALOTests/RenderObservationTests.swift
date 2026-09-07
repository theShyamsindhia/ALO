import Foundation
import ALOCore
import Testing
@testable import ALO

struct RenderObservationTests {
    @Test func measuredRealignmentIsDistinctAndStillOnePollOutcome() throws {
        let outcome = RenderObservationReason.afterMeasurement(realigned: true)
        #expect(outcome.label == "measured-realigned")
        #expect(outcome != .recovery)
        var recorder = RenderObservationRecorder()
        recorder.record(.init(reason: outcome, observedAtNanos: 1))
        let snapshot = try #require(recorder.snapshot(at: 1))
        #expect(snapshot.counts.reduce(0, +) == 1)
        #expect(snapshot.counts[outcome.rawValue] == 1)
    }

    @Test func deliberateRecoveryDoesNotFabricateSampleClockRegression() throws {
        var recorder = RenderObservationRecorder()
        recorder.record(.init(reason: .measured, observedAtNanos: 1, sampleTime: 200_000))
        recorder.record(.init(reason: .recovery, observedAtNanos: 2, sampleTime: 200_240))
        recorder.record(.init(reason: .measured, observedAtNanos: 3, sampleTime: 0))
        #expect(try #require(recorder.snapshot(at: 3)).sampleTimeDelta == nil)
        recorder.record(.init(reason: .measured, observedAtNanos: 4, sampleTime: 240))
        #expect(try #require(recorder.snapshot(at: 4)).sampleTimeDelta == 240)
        #expect(try #require(recorder.snapshot(at: 4)).counts.reduce(0, +) == 4)
    }

    @Test func missingObservationIsExplicitInsteadOfSilentlyAbsent() {
        let receiver = ReceiverTimingDiagnostics(roundTripMilliseconds: 4, clockOffsetMilliseconds: 0,
            jitterMilliseconds: 0, recommendedBufferMilliseconds: 250, outputLatencyMilliseconds: 1,
            renderHeadroomMilliseconds: 25, outputSampleRate: 48_000, outputChannelCount: 2,
            latenessMilliseconds: 0, latePacketCount: 0, resyncCount: 0)
        let detail = DiagnosticRoomContext(isActive: true, role: .listener, participantCount: 2,
            remotePeerCount: 1, syncLabel: "Checking", audioIsRendering: false, hasBroadcaster: true,
            timing: .init(receiver: receiver, host: nil)).result.detail
        #expect(detail.contains("render observation unavailable"))
    }

    @Test(arguments: [UInt64(11_593_167), 22_250_625])
    func recordedHardwareFutureLeadIsRejectedByCurrentPolicy(lead: UInt64) {
        // Bounds recorded on the actual 48kHz/512-frame output in the separate
        // live engine probe (150 valid host timestamps). This is not yet proof
        // of the integrated app's missing-measurement gate.
        let observed: UInt64 = 10_000_000_000
        let render = observed + lead
        let estimate = RenderDriftEstimate(nowNanos: observed, renderLocalNanos: render,
            renderHostNanos: render, outputLatencyNanos: 0,
            captureAnchorNanos: render - 1_250_000_000, playoutDelayNanos: 250_000_000,
            sampleTime: 48_000, sampleRate: 48_000)
        #expect(estimate == nil)
        #expect(RenderObservationSample.clockGate(pollNanos: observed, renderNanos: render) == .renderAheadOfPoll)
        #expect(lead < RoomTiming.renderSchedulingHeadroomNanos)
    }

    @Test func pollEntryOrderingIsDistinguishableFromPersistentFutureLead() {
        let entry: UInt64 = 10_000_000_000
        let render = entry + 2_000_000
        let observed = entry + 4_000_000
        func estimate(now: UInt64) -> RenderDriftEstimate? {
            RenderDriftEstimate(nowNanos: now, renderLocalNanos: render, renderHostNanos: render,
                outputLatencyNanos: 0, captureAnchorNanos: 8_750_000_000,
                playoutDelayNanos: 250_000_000, sampleTime: 48_000, sampleRate: 48_000)
        }
        // Characterizes the production ordering (entry-now, work, node snapshot),
        // not evidence that this condition occurred on a physical output device.
        #expect(estimate(now: entry) == nil)
        #expect(estimate(now: observed) != nil)
        #expect(RenderObservationSample.clockGate(pollNanos: entry, renderNanos: render) == .renderAheadOfPoll)
        #expect(RenderObservationSample.signedAgeMilliseconds(now: entry, sample: render) == -2)
        #expect(RenderObservationSample.signedAgeMilliseconds(now: observed, sample: render) == 2)
        let futureLead = observed + 5_000_000
        #expect(RenderObservationSample.signedAgeMilliseconds(now: observed, sample: futureLead) == -5)
        #expect(RenderObservationSample.clockGate(pollNanos: observed, renderNanos: futureLead) == .renderAheadOfPoll)
        #expect(RenderObservationSample.clockGate(pollNanos: render + 250_000_001, renderNanos: render) == .staleRender)
        #expect(RenderObservationSample.clockGate(pollNanos: render + 250_000_000, renderNanos: render) == nil)
    }

    @Test func recorderIsBoundedAndCountsPollsNotOnlySnapshotOutcomes() throws {
        var recorder = RenderObservationRecorder()
        #expect(recorder.snapshot(at: 0) == nil)
        for index in 0..<10_000 {
            var sample = RenderObservationSample(reason: index.isMultiple(of: 2) ? .measured : .invalidHostTime,
                observedAtNanos: UInt64(index), sampleTime: Int64(index) * 240, sampleRate: 48_000)
            sample.outputBufferMilliseconds = 10
            recorder.record(sample)
        }
        let snapshot = try #require(recorder.snapshot(at: 1_009_999))
        #expect(snapshot.counts.count == RenderObservationReason.allCases.count)
        #expect(snapshot.counts[RenderObservationReason.measured.rawValue] == 5_000)
        #expect(snapshot.counts[RenderObservationReason.invalidHostTime.rawValue] == 5_000)
        #expect(snapshot.sample.reason == .invalidHostTime)
        #expect(snapshot.sampleTimeDelta == 240)
        #expect(snapshot.observationAgeMilliseconds == 1)
        #expect(snapshot.detail.contains("measured=5000"))
        #expect(snapshot.detail.contains("host-time-unavailable=5000"))
        #expect(snapshot.detail.count < 1_000)
    }

    @Test func diagnosticsDistinguishUnavailableCountersAndActiveBuffer() {
        var listener = HostListenerTimingDiagnostics(peerID: "fixture-peer", isTimingEligible: true,
            reportAgeMilliseconds: 0, recommendedBufferMilliseconds: 550, hardwareFloorMilliseconds: 250)
        func hostDetail() -> String {
            DiagnosticRoomContext(isActive: true, role: .broadcaster, participantCount: 2,
                remotePeerCount: 1, syncLabel: "Checking", audioIsRendering: true, hasBroadcaster: true,
                timing: .init(receiver: nil, host: .init(listenerCount: 1, reportingListenerCount: 1,
                    groupBufferMilliseconds: 600, maximumLatenessMilliseconds: 0, totalResyncCount: 0,
                    listeners: [listener]))).result.detail
        }
        #expect(hostDetail().contains("audio send counters unavailable"))
        #expect(!hostDetail().contains("audio packets: 0/0"))
        listener.audioSendCountersAvailable = true
        #expect(hostDetail().contains("audio packets: 0/0"), "Measured zero is different from unavailable")
        var recorder = RenderObservationRecorder()
        recorder.record(.init(reason: .invalidHostTime, observedAtNanos: 0))
        let receiver = ReceiverTimingDiagnostics(roundTripMilliseconds: 4, clockOffsetMilliseconds: 0,
            jitterMilliseconds: 120, recommendedBufferMilliseconds: 550, outputLatencyMilliseconds: 1.2,
            renderHeadroomMilliseconds: 25, outputSampleRate: 48_000, outputChannelCount: 2,
            latenessMilliseconds: 0, latePacketCount: 20, resyncCount: 2,
            activePlayoutBufferMilliseconds: 600, renderObservation: recorder.snapshot(at: 0))
        let detail = DiagnosticRoomContext(isActive: true, role: .listener, participantCount: 2,
            remotePeerCount: 1, syncLabel: "Checking", audioIsRendering: true, hasBroadcaster: true,
            timing: .init(receiver: receiver, host: nil)).result.detail
        #expect(detail.contains("recommended buffer 550 ms"))
        #expect(detail.contains("active playout buffer 600 ms"))
        #expect(detail.contains("render observation host-time-unavailable"))
        #expect(!detail.contains("fixture-peer"))
    }
}
