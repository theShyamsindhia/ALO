import AVFoundation
import Foundation
import Testing
import ALOCore
@testable import ALO

/// Explicit local hardware probe: zero PCM only, default output unchanged.
/// No identity, network, input device, capture, or acoustic alignment claim.
@Suite(.serialized)
struct LiveProductionRenderProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALO_RUN_ZERO_PCM_HARDWARE_PROBE"] == "1"))
    func productionPlayerReportsActualRenderGate() async throws {
        let output = RoomAudioOutputEngine()
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio())
        defer { player.stop(); output.engine.stop() }
        player.clockOffsetNanos = 0
        let began = MonotonicClock.nowNanos()
        var next: UInt64 = 0
        var lastPrint: UInt64 = 0
        var advancingSamples = 0
        var lastSample: Int64?
        var minimumDrift: UInt64?
        var maximumDrift: UInt64 = 0
        while MonotonicClock.nowNanos() - began < 3_000_000_000 {
            let now = MonotonicClock.nowNanos()
            let current = (now - began) / 5_000_000
            // Bound catch-up work after a scheduling stall; skipped PCM is zero.
            if current > next + 8 { next = current - 8 }
            while next <= current {
                player.accept(AudioPacket(sequence: UInt32(next), frameIndex: next * 240,
                    captureTimeNanos: began + next * 5_000_000,
                    samples: [Int16](repeating: 0, count: 480)))
                next += 1
            }
            player.maintainSync()
            if let drift = player.syncReport().driftNanos {
                minimumDrift = min(minimumDrift ?? drift, drift)
                maximumDrift = max(maximumDrift, drift)
            }
            if let observation = player.renderObservation {
                if let sample = observation.sample.sampleTime {
                    if let lastSample, sample > lastSample { advancingSamples += 1 }
                    lastSample = sample
                }
                if now - began >= lastPrint + 1_000_000_000 {
                    print("LIVE_ZERO_PCM \(observation.detail)")
                    lastPrint = now - began
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let observation = try #require(player.renderObservation)
        let report = player.syncReport()
        print("LIVE_ZERO_PCM_FINAL advancing=\(advancingSamples) late=\(report.latePacketCount) resync=\(report.resyncCount) driftMinNs=\(minimumDrift.map(String.init) ?? "unavailable") driftMaxNs=\(maximumDrift) \(observation.detail)")
        #expect(advancingSamples > 20, "Probe requires actual advancing production player sample time")
        #expect(observation.counts.reduce(0, +) > 20)
        #expect(observation.counts[RenderObservationReason.measured.rawValue] > 20,
                "Advancing production playback must produce useful render measurements on this route")
        #expect(report.driftNanos != nil && report.driftSampleAgeNanos != nil,
                "A valid estimate must survive report freshness gating")
        #expect(maximumDrift < LocalAudioSyncPolicy.thresholdNanos,
                "Synthetic continuous playback must not merely produce nonsensical nonnil drift")
        #expect(player.automaticSyncState == "Watching estimated playback timing")
    }
}
