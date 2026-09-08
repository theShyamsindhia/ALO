import AVFoundation
import Foundation
import Testing
import ALOCore
@testable import ALO

/// Injects controlled scheduling-clock delay, not actual engine-lock contention.
/// PCM and advancing player sample time are native offline output, not acoustic evidence.
@Suite(.serialized) @MainActor
struct NativeEnqueueRaceTests {
    @Test(arguments: [Float(0.99), 1, 1.01], [0, 1, 2, 3])
    func nativeEnqueueCannotSilentlyMissAdmittedSourcePosition(rate: Float, mode: Int) async throws {
        let delayed = mode == 1
        var fixtureNow = MonotonicClock.nowNanos()
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        var armed = false
        var hookError: Error?
        var hookElapsed: UInt64 = 0
        var renderedInHook = 0
        var hookSample: AVAudioFramePosition?
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(), beforeNativeSchedule: {
            guard armed else { return }
            armed = false
            guard mode != 0 else { return }
            let began = fixtureNow
            if mode != 3 { fixtureNow += 60_000_000 }
            do {
                for _ in 0..<(mode == 2 ? 0 : 12) {
                    try #require(try output.engine.renderOffline(240, to: scratch) == .success)
                    renderedInHook += 240
                }
                let native = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
                let time = try #require(native.lastRenderTime)
                let sample = try #require(native.playerTime(forNodeTime: time))
                hookSample = sample.sampleTime
            } catch { hookError = error }
            hookElapsed = fixtureNow - began
        }, nowNanos: { fixtureNow })
        defer { player.stop(); output.engine.stop() }
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        let speed = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioUnitVarispeed }.first)
        player.clockOffsetNanos = 0
        let capture = fixtureNow
        player.accept(AudioPacket(sequence: 0, frameIndex: 0, captureTimeNanos: capture,
                                  samples: [Int16](repeating: 0, count: 480)))
        try #require(player.expectedSequenceForTesting == 1)
        // Offline host starts are unsupported. Adapt the native seed/start only;
        // the wrapper retains its real accepted source anchor and next sequence.
        node.stop()
        let seed = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        seed.frameLength = 240
        for channel in 0..<2 { try #require(seed.floatChannelData)[channel].initialize(repeating: 0, count: 240) }
        node.scheduleBuffer(seed, completionHandler: nil)
        speed.rate = rate
        node.play()
        try #require(try output.engine.renderOffline(120, to: scratch) == .success)
        let beforeTime = try #require(node.lastRenderTime)
        let before = try #require(node.playerTime(forNodeTime: beforeTime)).sampleTime
        try #require(before >= 0 && before < 240 && !beforeTime.isHostTimeValid)
        let desired = capture + 5_000_000 + player.activePlayoutDelayNanos - player.outputLatencyForTimingNanos
        let wake = desired - 20_000_000
        fixtureNow = wake
        let arrival = fixtureNow
        try #require(arrival < desired, "Fixture must admit the source position before its wall deadline")
        armed = true
        player.accept(AudioPacket(sequence: 1, frameIndex: 240, captureTimeNanos: capture + 5_000_000,
                                  samples: [Int16](repeating: 24_000, count: 480)))
        player.maintainSync()
        if let hookError { throw hookError }
        try #require(!armed, "The real native enqueue must reach the delay seam")
        try #require(player.expectedSequenceForTesting == 2)
        let after: AVAudioFramePosition
        if delayed {
            after = try #require(hookSample)
            try #require(hookElapsed >= 60_000_000 && renderedInHook == 2_880 && after > 480)
            try #require(hookElapsed < 90_000_000, "Fixture scheduling delay exceeded its bounded window")
            try #require(player.syncReport().resyncCount == 1)
            #expect(player.syncReport().driftNanos == nil)
            player.accept(AudioPacket(sequence: 2, frameIndex: 480, captureTimeNanos: fixtureNow,
                                      samples: [Int16](repeating: 24_000, count: 480)))
            try #require(player.expectedSequenceForTesting == 3)
            node.play() // Keep the actual fresh packet; adapt only its offline host start.
        } else {
            try #require(player.syncReport().latePacketCount == 0 && player.syncReport().resyncCount == 0)
            let afterTime = try #require(node.lastRenderTime)
            after = try #require(node.playerTime(forNodeTime: afterTime)).sampleTime
            if mode == 2 { #expect(hookElapsed == 60_000_000 && renderedInHook == 0 && after < 240) }
            if mode == 3 { #expect(hookElapsed == 0 && renderedInHook == 2_880 && after > 480) }
        }
        var absoluteMarker: Int?
        for block in 0..<20 {
            try #require(try output.engine.renderOffline(240, to: scratch) == .success)
            if absoluteMarker == nil,
               let index = (0..<240).first(where: { scratch.floatChannelData![0][$0] > 0.25 }) {
                absoluteMarker = (delayed ? 0 : 120 + renderedInHook) + block * 240 + index
            }
        }
        let marker = try #require(absoluteMarker)
        player.maintainSync()
        let recovery = try #require(player.renderObservation?.sample.contentRecovery)
        #expect(recovery.enqueueWindow == (delayed ? 1 : 0))
        let expected = delayed ? 0 : Double(240) / Double(rate)
        print("NATIVE_ENQUEUE_RACE rate=\(rate) delayed=\(delayed) beforeSample=\(before) afterSample=\(after) controlledHookMs=\(Double(hookElapsed)/1_000_000) marker=\(marker) expected=\(expected) displacementMs=\((Double(marker)-expected)/48) late=\(player.syncReport().latePacketCount) resync=\(player.syncReport().resyncCount)")
        if mode == 3 {
            // Deliberately independent clocks pin the AND policy gate only.
            // This does not claim a physical underrun can occur in zero time.
            #expect(Double(marker) > expected + 960)
        } else {
            #expect(Double(marker) <= expected + 960,
                    "An uncertain stalled enqueue must recover on fresh real PCM; ordinary enqueue must retain its original source position")
        }
    }
}
