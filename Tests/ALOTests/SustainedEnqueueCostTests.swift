import AVFoundation
import Foundation
import Testing
import ALOCore
@testable import ALO

/// Synthetic7.5ms enqueue workload motivated by observed scheduling p95, not
/// a claim that physical Core Audio calls always block for this duration.
/// Offline dataPlayedBack callbacks are not a credit oracle in this fixture.
@Suite(.serialized) @MainActor
struct SustainedEnqueueCostTests {
    @Test(arguments: [false, true])
    func identicalPCMWorkloadPreservesQueuedLead(nativeCohortReference: Bool) throws {
        var clock = MonotonicClock.nowNanos()
        let capture = clock
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        var renderedFrames = 0
        var firstMarker: Int?
        func advance(_ nanos: UInt64) throws {
            var frames = Int(nanos * 48_000 / 1_000_000_000)
            try #require(UInt64(frames) * 1_000_000_000 / 48_000 == nanos)
            while frames > 0 {
                let count = min(frames, 240)
                let status = try output.engine.renderOffline(AVAudioFrameCount(count), to: scratch)
                try #require(status == .success)
                if firstMarker == nil,
                   let index = (0..<count).first(where: { scratch.floatChannelData![0][$0] > 0.25 }) {
                    firstMarker = renderedFrames + index
                }
                renderedFrames += count
                frames -= count
            }
            clock += nanos
        }
        var armed = false
        var enqueueCalls = 0
        var hookError: Error?
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(),
            outputTimingMeasurement: { .init(latencyNanos: 0, bufferFrames: 512, safetyFrames: 48, sampleRate: 48_000) },
            beforeNativeSchedule: {
                guard armed else { return }
                enqueueCalls += 1
                do { try advance(7_500_000) } catch { hookError = error }
            }, nowNanos: { clock })
        defer { player.stop(); output.engine.stop() }
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        func packet(_ sequence: Int, marker: Bool) -> AudioPacket {
            AudioPacket(sequence: UInt32(sequence), frameIndex: UInt64(sequence * 240),
                captureTimeNanos: capture + UInt64(sequence) * 5_000_000,
                samples: [Int16](repeating: marker ? 24_000 : 0, count: 480))
        }
        func pcm(_ frames: Int, marker: Bool) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                try #require(buffer.floatChannelData)[channel].initialize(repeating: marker ? Float(24_000)/Float(Int16.max) : 0, count: frames)
            }
            return buffer
        }
        player.clockOffsetNanos = 0
        for sequence in 0..<50 { player.accept(packet(sequence, marker: false)) }
        try #require(player.expectedSequenceForTesting == 50 && player.syncReport().resyncCount == 0)
        // Production maintenance services the partial priming cohort before
        // replacing native PCM; otherwise the offline adapter duplicates it.
        clock += 20_000_000
        player.maintainSync()
        try #require(player.pendingPlaybackPacketCount == 0)
        try #require(player.outstandingPlaybackBufferCount == 50)
        // Same supported offline adapter as existing production marker tests.
        // Native reference uses the identical graph, source PCM and250ms prefix.
        node.stop()
        node.scheduleBuffer(try pcm(12_000, marker: false), completionHandler: nil)
        node.play()
        clock = capture + player.activePlayoutDelayNanos - player.outputLatencyForTimingNanos
        let outputStart = clock
        armed = true
        var pendingCohort = 0
        var inputPackets = 0
        var firstRecoveryPacket: Int?
        for index in 0..<160 {
            let arrival = outputStart + UInt64(index) * 5_000_000
            if clock < arrival { try advance(arrival - clock) }
            inputPackets += 1
            if nativeCohortReference {
                pendingCohort += 1
                if pendingCohort == 4 {
                    enqueueCalls += 1
                    try advance(7_500_000)
                    node.scheduleBuffer(try pcm(pendingCohort * 240, marker: true), completionCallbackType: .dataPlayedBack) { _ in }
                    pendingCohort = 0
                }
            } else {
                player.accept(packet(50 + index, marker: true))
                if let hookError { throw hookError }
                if player.syncReport().resyncCount > 0 {
                    firstRecoveryPacket = index
                    break // Do not rely on unsupported offline host restart after RED.
                }
            }
        }
        try #require(pendingCohort == 0)
        let marker = try #require(firstMarker, "Original incoming PCM must reach the native output before the workload verdict")
        #expect((12_000...12_096).contains(marker))
        print("SUSTAINED_ENQUEUE reference=\(nativeCohortReference) packets=\(inputPackets) enqueueCalls=\(enqueueCalls) nativeFrames=\(renderedFrames) marker=\(marker) firstRecoveryPacket=\(firstRecoveryPacket.map(String.init) ?? "none") resync=\(player.syncReport().resyncCount) controlledElapsedMs=\(Double(clock-outputStart)/1_000_000)")
        if nativeCohortReference {
            #expect(inputPackets == 160 && enqueueCalls == 40,
                    "Native-only reference characterizes exact workload and PCM, not production recovery state")
        } else {
            #expect(firstRecoveryPacket == nil && inputPackets == 160,
                    "The actual player must not exhaust its initial250ms source lead")
            #expect(enqueueCalls == 40, "Production coalescing must execute the intended four-packet workload")
        }
    }
}
