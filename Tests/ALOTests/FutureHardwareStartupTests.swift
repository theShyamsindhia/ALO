import AVFoundation
import Foundation
import Testing
import ALOCore
@testable import ALO

/// Explicit opt-in hardware diagnostic. Emits only zero PCM to the existing
/// default output; never changes device, volume, capture, or microphone state.
@Suite(.serialized) @MainActor
struct FutureHardwareStartupTests {
    private struct EarlyClockEvidence {
        var samples: [Int64] = []
        mutating func record(sample: Int64?, observed: UInt64, render: UInt64?, start: UInt64) {
            guard observed < start, start - observed >= 100_000_000,
                  let render, render < start, start - render >= 50_000_000,
                  let sample else { return }
            samples.append(sample)
        }
        var validatesFutureStart: Bool {
            // Establish some progress, not playback-rate accuracy or acoustics.
            samples.count >= 5 && samples.allSatisfy { $0 < 0 }
                && zip(samples, samples.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 }
                && (samples.last ?? 0) > (samples.first ?? 0)
        }
    }

    @Test func earlyClockContractRejectsImmediateMissingAndBoundaryEvidence() {
        func evidence(_ values: [Int64?], observed: UInt64 = 100_000_000,
                      render: UInt64? = 100_000_000) -> EarlyClockEvidence {
            var result = EarlyClockEvidence()
            for sample in values {
                result.record(sample: sample, observed: observed, render: render, start: 600_000_000)
            }
            return result
        }
        #expect(evidence([-500, -400, -300, -200, -100]).validatesFutureStart)
        #expect(!evidence([0, 100, 200, 300, 400]).validatesFutureStart)
        #expect(!evidence([nil, nil, nil, nil, nil]).validatesFutureStart)
        #expect(!evidence([-500, -500, -500, -500, -500]).validatesFutureStart)
        #expect(!evidence([-500, -400, -300, -200]).validatesFutureStart)
        #expect(!evidence([-400, -300, -200, -100, 0]).validatesFutureStart)
        #expect(evidence([-500, -400, -300, -200, -100], observed: 500_000_000).validatesFutureStart)
        #expect(!evidence([-500, -400, -300, -200, -100], observed: 500_000_001).validatesFutureStart)
        #expect(evidence([-500, -400, -300, -200, -100], render: 550_000_000).validatesFutureStart)
        #expect(!evidence([-500, -400, -300, -200, -100], render: 550_000_001).validatesFutureStart)
        #expect(!evidence([-500, -400, -300, -200, -100], observed: 700_000_000).validatesFutureStart)
        #expect(!evidence([-500, -400, -300, -200, -100], render: 700_000_000).validatesFutureStart)
        #expect(!evidence([-500, -400, -300, -200, -100], observed: 550_000_000).validatesFutureStart)
        #expect(!evidence([-500, -400, -300, -200, -100], render: 575_000_000).validatesFutureStart)
        #expect(!evidence([-500, -400, -300, -200, -100], render: nil).validatesFutureStart)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALO_TEST_HARDWARE_STARTUP"] == "1"))
    func shared600msDelaySurvivesPrestartMaintenance() async throws {
        let output = RoomAudioOutputEngine()
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(),
            maintenanceIntervalNanos: 20_000_000)
        defer { player.stop(); output.engine.stop() }
        player.clockOffsetNanos = 0
        player.setTargetLatencyNanos(600_000_000)
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        let began = MonotonicClock.nowNanos()
        let latency = player.outputLatencyForTimingNanos
        // The existing route must leave enough real prestart time to exercise
        // the 250ms watchdog. A high-latency route is not a passing control.
        try #require(latency < 250_000_000)
        let expectedStart = began + 600_000_000 - latency
        var sequence: UInt32 = 0
        var lastPoll = began
        var maxPollGap: UInt64 = 0
        var prestartPolls = 0
        var prestartNil = 0
        var prestartMinimum: Int64?
        var prestartMaximum: Int64?
        var prestartRecoveries: UInt64 = 0
        var finalSample: Int64?
        var nextMaintenance = began
        var earlyClock = EarlyClockEvidence()
        while MonotonicClock.nowNanos() - began < 1_600_000_000 {
            let now = MonotonicClock.nowNanos()
            maxPollGap = max(maxPollGap, now - lastPoll)
            lastPoll = now
            while began + UInt64(sequence) * 5_000_000 <= now {
                player.accept(.init(sequence: sequence, frameIndex: UInt64(sequence) * 240,
                    captureTimeNanos: began + UInt64(sequence) * 5_000_000,
                    samples: [Int16](repeating: 0, count: 480)))
                sequence += 1
            }
            if now >= nextMaintenance {
                player.maintainSync()
                nextMaintenance = now + 20_000_000
                let sample: Int64?
                var renderNanos: UInt64?
                if let render = node.lastRenderTime, render.isSampleTimeValid,
                   render.isHostTimeValid, render.sampleRate.isFinite, render.sampleRate > 0,
                   let time = node.playerTime(forNodeTime: render), time.isSampleTimeValid {
                    sample = time.sampleTime
                    renderNanos = MonotonicClock.ticksToNanos(render.hostTime)
                } else { sample = nil }
                earlyClock.record(sample: sample, observed: MonotonicClock.nowNanos(),
                    render: renderNanos, start: expectedStart)
                if now < expectedStart {
                    prestartPolls += 1
                    if let sample {
                        prestartMinimum = min(prestartMinimum ?? sample, sample)
                        prestartMaximum = max(prestartMaximum ?? sample, sample)
                    } else { prestartNil += 1 }
                    prestartRecoveries = max(prestartRecoveries, player.syncReport().resyncCount)
                } else { finalSample = sample }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        print("HARDWARE_FUTURE_START leadMs=\(Double(expectedStart-began)/1e6) polls=\(prestartPolls) nil=\(prestartNil) min=\(String(describing: prestartMinimum)) max=\(String(describing: prestartMaximum)) preResync=\(prestartRecoveries) finalSample=\(String(describing: finalSample)) finalResync=\(player.syncReport().resyncCount) maxPollGapMs=\(Double(maxPollGap)/1e6)")
        print("HARDWARE_FUTURE_EARLY count=\(earlyClock.samples.count) first=\(String(describing: earlyClock.samples.first)) last=\(String(describing: earlyClock.samples.last))")
        try #require(maxPollGap < 100_000_000, "Scheduler stall invalidates this startup-only isolation")
        try #require(prestartPolls >= 10)
        // Keep the original ten total polls. At least five of those same polls
        // must provide safely early valid observations, excluding a deadline-crossing read without allowing
        // an immediate start or missing native clock to masquerade as success.
        #expect(earlyClock.validatesFutureStart, "Expected advancing negative native samples well before the scheduled start")
        #expect(prestartRecoveries == 0, "Scheduled future start is not a stalled active renderer")
        #expect((finalSample ?? -1) > 0, "Actual hardware player must advance after the future start")
        #expect(player.syncReport().resyncCount == 0)
    }
}
