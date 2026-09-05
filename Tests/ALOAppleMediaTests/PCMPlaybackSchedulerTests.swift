import Foundation
import Testing
import ALOCore
@testable import ALOAppleMedia

struct PCMPlaybackSchedulerTests {
    private func packet(frame: UInt64 = 0, capture: UInt64 = 1_000_000_000) -> AudioPacket {
        AudioPacket(sequence: UInt32(truncatingIfNeeded: frame / 240), frameIndex: frame,
                    captureTimeNanos: capture, samples: Array(repeating: 123, count: 480))
    }

    @Test("Future broadcaster anchors subtract host-minus-local offset and output latency")
    func futureAnchor() throws {
        var scheduler = PCMPlaybackScheduler()
        try scheduler.setAnchor(.init(captureTimeNanos: 1_000_000_000, hostPlaybackTimeNanos: 3_000_000_000),
                                clockOffsetNanos: 1_000_000_000, outputLatencyNanos: 10_000_000, nowNanos: 1_950_000_000)
        try scheduler.enqueueMedia(packet(), nowNanos: 1_950_000_000)
        let scheduled = try #require(scheduler.drain(nowNanos: 1_950_000_000).first)
        #expect(scheduled.renderTimeNanos == 1_990_000_000)
        #expect(scheduled.channels == 2)
        #expect(scheduled.frameCount == 240)
        #expect(scheduler.scheduledCount == 1)
        let firstCompletion = scheduler.completed(scheduled.token)
        let duplicateCompletion = scheduler.completed(scheduled.token)
        #expect(firstCompletion)
        #expect(!duplicateCompletion)
    }

    @Test("Late joins discard pre-anchor and expired samples instead of accumulating delay")
    func lateJoin() throws {
        var scheduler = PCMPlaybackScheduler()
        try scheduler.setAnchor(.init(captureTimeNanos: 1_000_000_000, hostPlaybackTimeNanos: 200_000_000),
                                clockOffsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        #expect(throws: AppleMediaError.invalidAnchor) {
            try scheduler.enqueueMedia(packet(capture: 995_000_000), nowNanos: 0)
        }
        #expect(throws: AppleMediaError.late) { try scheduler.enqueueMedia(packet(), nowNanos: 201_000_000) }
        #expect(scheduler.bufferedCount == 0)
        #expect(scheduler.lateDrops == 1)
        #expect(throws: AppleMediaError.invalidAnchor) {
            try scheduler.setAnchor(.init(captureTimeNanos: 0, hostPlaybackTimeNanos: 1),
                                    clockOffsetNanos: 0, outputLatencyNanos: 0, nowNanos: 2)
        }
    }

    @Test("Queue bounds include buffers already submitted to AVAudioPlayerNode")
    func boundedScheduledOwnership() throws {
        var scheduler = PCMPlaybackScheduler(limits: .init(maximumBuffers: 2))
        try scheduler.setAnchor(.init(captureTimeNanos: 1_000_000_000, hostPlaybackTimeNanos: 50_000_000),
                                clockOffsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try scheduler.enqueueMedia(packet(), nowNanos: 0)
        _ = scheduler.drain(nowNanos: 0)
        try scheduler.enqueueMedia(packet(frame: 240, capture: 1_005_000_000), nowNanos: 0)
        #expect(throws: AppleMediaError.capacity) {
            try scheduler.enqueueMedia(packet(frame: 480, capture: 1_010_000_000), nowNanos: 0)
        }
        #expect(scheduler.bufferedCount == 2)
    }

    @Test("Resynchronization rejects completions from the previous route generation")
    func staleCompletions() throws {
        var scheduler = PCMPlaybackScheduler()
        let anchor = AudioPlaybackAnchor(captureTimeNanos: 1_000_000_000, hostPlaybackTimeNanos: 50_000_000)
        try scheduler.setAnchor(anchor, clockOffsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try scheduler.enqueueMedia(packet(), nowNanos: 0)
        let old = try #require(scheduler.drain(nowNanos: 0).first)
        scheduler.invalidate()
        try scheduler.setAnchor(anchor, clockOffsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try scheduler.enqueueMedia(packet(), nowNanos: 0)
        let current = try #require(scheduler.drain(nowNanos: 0).first)
        let staleCompletion = scheduler.completed(old.token)
        #expect(!staleCompletion)
        #expect(scheduler.scheduledCount == 1)
        let currentCompletion = scheduler.completed(current.token)
        #expect(currentCompletion)
    }

    @Test("Reordered pending packets drain by frame and duplicates cannot play twice")
    func packetOrdering() throws {
        var scheduler = PCMPlaybackScheduler()
        try scheduler.setAnchor(.init(captureTimeNanos: 1_000_000_000, hostPlaybackTimeNanos: 50_000_000),
                                clockOffsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try scheduler.enqueueMedia(packet(frame: 240, capture: 1_005_000_000), nowNanos: 0)
        try scheduler.enqueueMedia(packet(), nowNanos: 0)
        #expect(scheduler.drain(nowNanos: 0).map(\.token.frameIndex) == [0, 240])
        #expect(throws: AppleMediaError.duplicate) { try scheduler.enqueueMedia(packet(), nowNanos: 0) }
    }

    @Test("Extreme timestamps and malformed PCM fail without arithmetic overflow")
    func malformedInputs() throws {
        var scheduler = PCMPlaybackScheduler()
        #expect(throws: AppleMediaError.invalidAnchor) {
            try scheduler.setAnchor(.init(captureTimeNanos: 0, hostPlaybackTimeNanos: .max),
                                    clockOffsetNanos: .min, outputLatencyNanos: 0, nowNanos: 0)
        }
        #expect(throws: AppleMediaError.invalidPCM) {
            try VoicePCMChunk(frameIndex: 0, captureTimeNanos: 0, samples: Array(repeating: 0, count: 960))
        }
        #expect(throws: AppleMediaError.invalidPCM) {
            try scheduler.enqueueMedia(AudioPacket(sequence: 0, frameIndex: 0, captureTimeNanos: 0, samples: [1]), nowNanos: 0)
        }
    }

    @Test("Independent peer voice schedulers preserve simultaneous timelines")
    func independentVoiceTimelines() throws {
        var first = PCMPlaybackScheduler(), second = PCMPlaybackScheduler()
        for peer in 0..<2 {
            let anchor = AudioPlaybackAnchor(captureTimeNanos: UInt64(peer) * 1_000_000_000, hostPlaybackTimeNanos: 50_000_000)
            if peer == 0 { try first.setAnchor(anchor, clockOffsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0) }
            else { try second.setAnchor(anchor, clockOffsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0) }
        }
        try first.enqueueVoice(VoicePCMChunk(frameIndex: 0, captureTimeNanos: 0, samples: Array(repeating: 1, count: 480)), nowNanos: 0)
        try second.enqueueVoice(VoicePCMChunk(frameIndex: 0, captureTimeNanos: 1_000_000_000, samples: Array(repeating: 2, count: 480)), nowNanos: 0)
        let a = try #require(first.drain(nowNanos: 0).first)
        let b = try #require(second.drain(nowNanos: 0).first)
        #expect(a.renderTimeNanos == b.renderTimeNanos)
        #expect(a.samples != b.samples)
        #expect(a.channels == 1 && b.channels == 1)
    }
}
