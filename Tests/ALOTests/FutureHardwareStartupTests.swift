import AVFoundation
import Foundation
import Testing
import ALOCore
@testable import ALO

/// Explicit opt-in hardware diagnostic. Emits only zero PCM to the existing
/// default output; never changes device, volume, capture, or microphone state.
@Suite(.serialized) @MainActor
struct FutureHardwareStartupTests {
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
                if let render = node.lastRenderTime, render.isSampleTimeValid,
                   render.isHostTimeValid, render.sampleRate.isFinite, render.sampleRate > 0,
                   let time = node.playerTime(forNodeTime: render), time.isSampleTimeValid {
                    sample = time.sampleTime
                } else { sample = nil }
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
        try #require(prestartPolls >= 10)
        try #require(maxPollGap < 100_000_000, "Scheduler stall invalidates this startup-only isolation")
        #expect(prestartRecoveries == 0, "Scheduled future start is not a stalled active renderer")
        #expect((finalSample ?? -1) > 0, "Actual hardware player must advance after the future start")
        #expect(player.syncReport().resyncCount == 0)
    }
}
