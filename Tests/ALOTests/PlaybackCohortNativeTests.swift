import AVFoundation
import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite(.serialized) @MainActor
struct PlaybackCohortNativeTests {
    @Test(arguments: [1, 2, 3], [UInt64(5_000_000), 20_000_000])
    func silentSourceTailFlushesThroughRealMaintenance(tail: Int, cadence: UInt64) throws {
        var now = MonotonicClock.nowNanos()
        let capture = now
        var calls = 0
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(),
            beforeNativeSchedule: { calls += 1 }, nowNanos: { now }, maintenanceIntervalNanos: cadence)
        defer { player.stop(); output.engine.stop() }
        player.clockOffsetNanos = 0
        player.accept(.init(sequence: 0, frameIndex: 0, captureTimeNanos: capture, samples: [Int16](repeating: 0, count: 480)))
        try #require(calls == 1)
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        node.stop()
        let seed = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        seed.frameLength = 240
        for channel in 0..<2 { try #require(seed.floatChannelData)[channel].initialize(repeating: 0, count: 240) }
        node.scheduleBuffer(seed, completionHandler: nil)
        node.play()
        for index in 1...tail {
            player.accept(.init(sequence: UInt32(index), frameIndex: UInt64(index*240),
                captureTimeNanos: capture + UInt64(index)*5_000_000, samples: [Int16](repeating: 24_000, count: 480)))
        }
        try #require(calls == 1 && player.pendingPlaybackPacketCount == tail)
        #expect(player.outstandingPlaybackBufferCount == 1)
        // No next packet or private flush. Exercise each real owner's tick;
        // the5ms owner must retain across early ticks, then anticipate expiry.
        for step in 1...Int(20_000_000 / cadence) {
            now = capture + UInt64(step) * cadence
            player.maintainSync()
            if cadence == 5_000_000 && step < 3 { #expect(calls == 1) }
            if calls == 2 { break }
        }
        #expect(now - capture == (cadence == 5_000_000 ? 15_000_000 : 20_000_000))
        try #require(calls == 2 && player.pendingPlaybackPacketCount == 0)
        #expect(player.outstandingPlaybackBufferCount == 1 + tail)
        #expect(player.syncReport().resyncCount == 0)
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        var marker: Int?
        for block in 0..<12 {
            let status = try output.engine.renderOffline(240, to: scratch)
            try #require(status == .success)
            if marker == nil, let index = (0..<240).first(where: { scratch.floatChannelData![0][$0] > 0.25 }) {
                marker = block*240 + index
            }
        }
        let first = try #require(marker)
        #expect((240...336).contains(first), "A real held tail must retain the known seed prefix")
    }
    @Test(arguments: [0, 1, 2])
    func unsupportedOrAbsentCadenceDoesNotHoldPCM(mode: Int) throws {
        let now = MonotonicClock.nowNanos()
        let cadence: UInt64? = mode == 0 ? nil : (mode == 1 ? 0 : 50_000_000)
        var calls = 0
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(),
            beforeNativeSchedule: { calls += 1 }, nowNanos: { now }, maintenanceIntervalNanos: cadence)
        defer { player.stop(); output.engine.stop() }
        player.clockOffsetNanos = 0
        for index in 0..<4 {
            player.accept(.init(sequence: UInt32(index), frameIndex: UInt64(index*240),
                captureTimeNanos: now + UInt64(index)*5_000_000, samples: [Int16](repeating: 0, count: 480)))
        }
        #expect(calls == 4 && player.pendingPlaybackPacketCount == 0)
        #expect(player.outstandingPlaybackBufferCount == 4)
    }
    @Test(arguments: [0, 1, 2])
    func lifecycleDiscardsHeldPCM(action: Int) throws {
        var now = MonotonicClock.nowNanos()
        var calls = 0
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(),
            beforeNativeSchedule: { calls += 1 }, nowNanos: { now })
        defer { player.stop(); output.engine.stop() }
        player.clockOffsetNanos = 0
        for index in 0..<4 {
            player.accept(.init(sequence: UInt32(index), frameIndex: UInt64(index*240),
                captureTimeNanos: now + UInt64(index)*5_000_000, samples: [Int16](repeating: 24_000, count: 480)))
        }
        try #require(calls == 1 && player.pendingPlaybackPacketCount == 3)
        switch action {
        case 0: player.stop()
        case 1: player.setRoomPlayback(playing: false)
        default: player.forceResync(atOrAfterCaptureNanos: now + 100_000_000)
        }
        #expect(player.pendingPlaybackPacketCount == 0 && player.outstandingPlaybackBufferCount == 0)
        now += 20_000_000
        player.maintainSync()
        #expect(calls == 1, "Maintenance cannot replay held PCM from a retired lifecycle")
    }
    @Test func weightedNativePlusHeldReachesPacketCapacity() throws {
        var now = MonotonicClock.nowNanos()
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(), nowNanos: { now })
        defer { player.stop(); output.engine.stop() }
        player.clockOffsetNanos = 0
        for index in 0..<140 {
            player.accept(.init(sequence: UInt32(index), frameIndex: UInt64(index*240),
                captureTimeNanos: now + UInt64(index)*5_000_000, samples: [Int16](repeating: 0, count: 480)))
        }
        #expect(player.outstandingPlaybackBufferCount == 137)
        #expect(player.pendingPlaybackPacketCount == 3)
        #expect(player.outstandingPlaybackBufferCount + player.pendingPlaybackPacketCount == SecureMacPlaybackTimeline.maximumScheduledPackets)
        now += 20_000_000
        player.maintainSync()
        #expect(player.outstandingPlaybackBufferCount == 140 && player.pendingPlaybackPacketCount == 0)
    }
}
