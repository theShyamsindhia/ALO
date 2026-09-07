import AVFoundation
import Foundation
import Testing
import ALOCore
import ALONetworking
@testable import ALO

/// Synthetic300ms delivery silence, not a claim that observed jitter equals
/// transit delay. Captures are generated every5ms, never before their time.
/// Offline native output is the PCM oracle; offline callbacks are not a
/// completion-credit model or an acoustic alignment measurement.
@Suite(.serialized) @MainActor
struct DeliveryGapBufferTests {
    @Test(arguments: [0, 1, 2])
    func sharedBufferMustCoverBoundedDeliveryGap(mode: Int) throws {
        var policy = SecureRoomTimingPolicy()
        policy.captureStarted(at: 0)
        let firstReport = try MediaReceiverTimingReport(hardwareOutputFloorNanos: 250_000_000,
            networkRecommendedDelayNanos: 550_000_000)
        policy.record(peer: UUID(), report: firstReport, receivedAt: 10_000_000_000)
        let policyDelay = policy.desiredDelay(now: 10_000_000_000, current: 250_000_000,
            localHardwareFloor: 250_000_000, playing: true)
        let delay: UInt64 = mode == 0 ? 250_000_000 : (mode == 1 ? 550_000_000 : policyDelay)
        var clock = MonotonicClock.nowNanos()
        let epoch = clock
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(),
            outputTimingMeasurement: { .init(latencyNanos: 0, bufferFrames: 512, safetyFrames: 48, sampleRate: 48_000) },
            nowNanos: { clock }, maintenanceIntervalNanos: 20_000_000)
        defer { player.stop(); output.engine.stop() }
        player.setTargetLatencyNanos(delay)
        player.clockOffsetNanos = 0
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        var deferred: [AudioPacket] = []
        var firstMarker: Int?
        var laterMarker: Int?
        var rendered = 0
        var generated = 0
        var delivered = 0
        var recoveryTick: Int?
        let startTick = Int(delay / 5_000_000)
        for tick in 0...600 {
            clock = epoch + UInt64(tick)*5_000_000
            if tick == startTick {
                // Keep ALL actual production-scheduled and held PCM. Only the
                // unsupported offline host-start time is adapted, no reseeding.
                node.play()
            } else if tick > startTick {
                let status = try output.engine.renderOffline(240, to: scratch)
                try #require(status == .success)
                for index in 0..<240 {
                    let value = scratch.floatChannelData![0][index]
                    if firstMarker == nil && value > 0.25 { firstMarker = rendered + index }
                    if laterMarker == nil && value < -0.25 { laterMarker = rendered + index }
                }
                rendered += 240
            }
            let value: Int16 = tick == 100 ? 24_000 : (tick == 400 ? -24_000 : 0)
            let packet = AudioPacket(sequence: UInt32(tick), frameIndex: UInt64(tick*240),
                captureTimeNanos: clock, samples: [Int16](repeating: value, count: 480))
            generated += 1
            if (200..<260).contains(tick) {
                deferred.append(packet)
            } else {
                if !deferred.isEmpty {
                    try #require(tick == 260 && deferred.count == 60)
                    for held in deferred {
                        try #require(held.captureTimeNanos <= clock)
                        player.accept(held); delivered += 1
                    }
                    deferred.removeAll()
                }
                player.accept(packet); delivered += 1
            }
            // No-render offline priming cannot model a hardware graph's
            // pre-start clock progress. Exclude that artificial watchdog stall;
            // once playback starts, real20ms maintenance remains unchanged.
            if tick >= startTick && tick % 4 == 0 { player.maintainSync() }
            if player.syncReport().resyncCount > 0 {
                recoveryTick = tick
                break // Do not disguise an offline future restart as recovery PCM.
            }
        }
        print("DELIVERY_GAP mode=\(mode) delayMs=\(delay/1_000_000) generated=\(generated) delivered=\(delivered) deferred=\(deferred.count) nativeFrames=\(rendered) firstMarker=\(firstMarker.map(String.init) ?? "none") laterMarker=\(laterMarker.map(String.init) ?? "none") recoveryTick=\(recoveryTick.map(String.init) ?? "none") late=\(player.syncReport().latePacketCount) resync=\(player.syncReport().resyncCount)")
        let marker = try #require(firstMarker, "Native pre-gap source marker is a prerequisite")
        try #require((24_000...24_096).contains(marker), "Original source/native mapping must be valid before the delivery gap")
        if mode == 0 {
            #expect(recoveryTick == 260 && player.syncReport().resyncCount > 0,
                    "Fixed250ms is the intentionally insufficient-budget control")
        } else {
            #expect(recoveryTick == nil, "Shared sufficient or policy-selected budget must cover this bounded delivery gap")
        }
        if recoveryTick == nil {
            #expect(generated == 601 && delivered == 601 && deferred.isEmpty)
            let second = try #require(laterMarker)
            #expect((96_000...96_096).contains(second), "Post-gap native PCM must preserve its original source frame")
        }
    }
}
