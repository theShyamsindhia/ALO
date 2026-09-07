import AVFoundation
import ALOCore
import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct ContentAdmissionRecoveryTests {
    @Test
    func fullyCoveredStaleDuplicateDoesNotRetireMapping() throws {
        let fixtureNow = MonotonicClock.nowNanos()
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(), nowNanos: { fixtureNow })
        defer { player.stop(); output.engine.stop() }
        player.clockOffsetNanos = 0
        player.accept(AudioPacket(sequence: 0, frameIndex: 0, captureTimeNanos: fixtureNow,
            samples: [Int16](repeating: 0, count: 480)))
        player.accept(AudioPacket(sequence: 1, frameIndex: 0, captureTimeNanos: fixtureNow - 1,
            samples: [Int16](repeating: 0, count: 480)))
        #expect(player.expectedSequenceForTesting == 2)
        #expect(player.syncReport().resyncCount == 0,
            "A stale packet fully covered by queued PCM has no new content to lose")
    }
    @Test(arguments: [0, 1, 2, 3, 4])
    func rejectedAdmissionRetiresActiveSourceMapping(failure: Int) throws {
        var fixtureNow = MonotonicClock.nowNanos()
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        var allocationFails = false
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(),
            failBufferAllocation: { allocationFails }, nowNanos: { fixtureNow })
        defer { player.stop(); output.engine.stop() }
        let now = fixtureNow
        let capture = failure == 2 ? UInt64(Int64.max) + now : now
        player.clockOffsetNanos = failure == 2 ? Int64.max : 0
        player.accept(AudioPacket(sequence: 0, frameIndex: 0, captureTimeNanos: capture,
            samples: [Int16](repeating: 0, count: 480)))
        try #require(player.expectedSequenceForTesting == 1)
        try #require(player.syncReport().resyncCount == 0)
        if failure == 0 {
            player.clockOffsetNanos = .max
            try #require(RoomTiming.clientTimeNanos(hostTimeNanos: capture + 5_000_000, clockOffsetNanos: .max) == nil)
        } else if failure == 1 {
            allocationFails = true
        } else if failure == 2 {
            let local = UInt64.max - 100_000_000
            let magnitude = local - (capture + 5_000_000)
            player.clockOffsetNanos = -Int64(magnitude)
            try #require(RoomTiming.clientTimeNanos(hostTimeNanos: capture + 5_000_000,
                clockOffsetNanos: -Int64(magnitude)) == local)
            try #require(local.addingReportingOverflow(player.activePlayoutDelayNanos).overflow)
        }
        let dropped = AudioPacket(sequence: 1, frameIndex: failure == 4 ? 120 : 240,
            captureTimeNanos: failure >= 3 ? capture - 1 : capture + 5_000_000,
            samples: [Int16](repeating: 0, count: 480))
        try #require(AudioPacket(data: dropped.encoded()) == dropped)
        player.accept(dropped)
        #expect(player.expectedSequenceForTesting == 2)
        #expect(player.syncReport().resyncCount == 1,
            "Dropping active PCM must retire its source/sample mapping, not compress the next append")
        #expect(player.syncReport().driftNanos == nil)
        allocationFails = false
        player.clockOffsetNanos = 0
        fixtureNow += 10_000_000
        let fresh = AudioPacket(sequence: 2, frameIndex: 480, captureTimeNanos: fixtureNow,
            samples: [Int16](repeating: 24_000, count: 480))
        try #require(AudioPacket(data: fresh.encoded()) == fresh)
        player.accept(fresh)
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        node.play()
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        var marker: Int?
        for block in 0..<6 {
            try #require(try output.engine.renderOffline(240, to: scratch) == .success)
            if marker == nil, let index = (0..<240).first(where: { scratch.floatChannelData![0][$0] > 0.25 }) {
                marker = block * 240 + index
            }
        }
        #expect(marker.map { (0...96).contains($0) } == true,
            "A fresh real packet must anchor cleanly, without retained predecessor PCM")
        player.maintainSync()
        #expect(player.renderObservation?.sample.contentRecovery?.admissionDropped == 1)
    }

    @Test
    func largeOutputHeadroomAdmitsConcealmentBeforeHardwareLead() async throws {
        var fixtureNow = MonotonicClock.nowNanos()
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio(),
            outputTimingMeasurement: { .init(latencyNanos: 1_000_000,
                bufferFrames: 4_096, safetyFrames: 48, sampleRate: 48_000) }, nowNanos: { fixtureNow })
        defer { player.stop(); output.engine.stop() }
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        player.clockOffsetNanos = 0
        let capture = fixtureNow
        player.accept(AudioPacket(sequence: 0, frameIndex: 0, captureTimeNanos: capture,
            samples: [Int16](repeating: 0, count: 480)))
        player.accept(AudioPacket(sequence: 1, frameIndex: 240, captureTimeNanos: capture + 5_000_000,
            samples: [Int16](repeating: 0, count: 480)))
        try #require(player.expectedSequenceForTesting == 2)
        node.stop()
        let seed = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        seed.frameLength = 480
        for channel in 0..<2 { try #require(seed.floatChannelData)[channel].initialize(repeating: 0, count: 480) }
        node.scheduleBuffer(seed, completionHandler: nil)
        node.play()
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        try #require(try output.engine.renderOffline(240, to: scratch) == .success)
        let rendered = try #require(node.lastRenderTime)
        let position = try #require(node.playerTime(forNodeTime: rendered))
        try #require(position.sampleTime == 240)
        let deadline = capture + 10_000_000 + player.activePlayoutDelayNanos - player.outputLatencyForTimingNanos
        let wake = deadline - 75_000_000
        fixtureNow = wake
        let lead = deadline - fixtureNow
        try #require(lead > 50_000_000 && lead < player.renderSchedulingHeadroomForTimingNanos,
            "Fixture must exercise admission outside old 50ms window but inside measured hardware lead")
        player.accept(AudioPacket(sequence: 3, frameIndex: 720, captureTimeNanos: capture + 15_000_000,
            samples: [Int16](repeating: 24_000, count: 480)))
        #expect(player.expectedSequenceForTesting == 4, "High-headroom route must not defer timely concealment")
        var marker: Int?
        for block in 0..<6 {
            try #require(try output.engine.renderOffline(240, to: scratch) == .success)
            if marker == nil, let index = (0..<240).first(where: { scratch.floatChannelData![0][$0] > 0.25 }) {
                marker = block * 240 + index
            }
        }
        #expect(marker.map { (480...576).contains($0) } == true,
            "Known remaining seed and one missing packet of silence precede the real marker")
        #expect(player.syncReport().resyncCount == 0)
    }
}
