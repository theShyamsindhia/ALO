import Foundation
import Testing
@testable import ALO

struct DJLiveRecordingTests {
    @Test func capturesAcceptedDryInputAndConsumesTake() throws {
        let audio = DJLiveAudio()
        audio.configure(stage: .listening)
        _ = audio.process([1, 2], stage: .listening, captureTimeNanos: 1)
        try audio.startRecording()
        audio.setMix(gain: 0, low: 12, mid: -24, high: 3)
        audio.offerOverlay([300, 400, 500, 600])
        let first: [Int16] = [100, -200, 200, -300]
        let second: [Int16] = [700, -800]
        #expect(audio.process(first, stage: .listening, captureTimeNanos: 2) != first)
        _ = audio.process([9, 9], stage: .broadcast, captureTimeNanos: 3)
        _ = audio.process([8, 8], stage: .listening, captureTimeNanos: 2)
        _ = audio.process([7], stage: .listening, captureTimeNanos: 3)
        _ = audio.process(second, stage: .listening, captureTimeNanos: 3)
        #expect(audio.snapshot().recording)
        #expect(!audio.snapshot().recordingReady)
        #expect(audio.snapshot().recordingDuration == 3.0 / 48_000)
        #expect(try audio.finishRecording() == first + second)
        #expect(!audio.snapshot().recording)
        #expect(!audio.snapshot().recordingReady)
        #expect(audio.snapshot().recordingDuration == 0)
        #expect(throws: (any Error).self) { try audio.finishRecording() }
    }

    @Test func fullTakeStopsAtThirtyTwoSecondsAndRemainsStable() throws {
        let audio = DJLiveAudio()
        audio.configure(stage: .broadcast)
        let baseline = audio.snapshot().bufferedPCMBytes
        try audio.startRecording()
        #expect(audio.snapshot().bufferedPCMBytes == baseline + 6_144_000)
        let chunk = (0..<48_000).flatMap { _ -> [Int16] in [123, -456] }
        for _ in 0..<31 { _ = audio.process(chunk, stage: .broadcast) }
        _ = audio.process(chunk + [999, 999], stage: .broadcast)
        #expect(!audio.snapshot().recording)
        #expect(audio.snapshot().recordingReady)
        #expect(audio.snapshot().recordingDuration == 32)
        #expect(throws: (any Error).self) { try audio.startRecording() }
        _ = audio.process([888, 888], stage: .broadcast)
        let take = try audio.finishRecording()
        #expect(take.count == DJLiveAudio.maximumFrames * 2)
        #expect(take.enumerated().allSatisfy { $0.element == ($0.offset.isMultiple(of: 2) ? 123 : -456) })
        #expect(audio.snapshot().bufferedPCMBytes == baseline)
    }

    @Test func noAudioCancelAndStageChangeReleaseRecordingStorage() throws {
        let audio = DJLiveAudio()
        #expect(throws: (any Error).self) { try audio.startRecording() }
        audio.configure(stage: .broadcast)
        let baseline = audio.snapshot().bufferedPCMBytes
        try audio.startRecording()
        #expect(throws: (any Error).self) { try audio.startRecording() }
        #expect(throws: (any Error).self) { try audio.finishRecording() }
        #expect(!audio.snapshot().recording)
        #expect(audio.snapshot().bufferedPCMBytes == baseline)
        try audio.startRecording()
        _ = audio.process([1, 2], stage: .broadcast)
        audio.cancelRecording()
        #expect(audio.snapshot().bufferedPCMBytes == baseline)
        #expect(throws: (any Error).self) { try audio.finishRecording() }
        try audio.startRecording()
        _ = audio.process([3, 4], stage: .broadcast)
        audio.configure(stage: .listening)
        #expect(!audio.snapshot().recording)
        #expect(audio.snapshot().recordingDuration == 0)
        #expect(throws: (any Error).self) { try audio.finishRecording() }
        try audio.startRecording()
        audio.configure(stage: nil)
        #expect(audio.snapshot().bufferedPCMBytes == 0)
        #expect(!audio.snapshot().recordingReady)
    }

    @Test func captureDoesNotRecordTheLiveLoopPlayback() throws {
        let audio = DJLiveAudio()
        audio.configure(stage: .broadcast)
        _ = audio.process([Int16](repeating: 111, count: 48_000), stage: .broadcast)
        try audio.toggleLoop(beats: 1, bpm: 120)
        try audio.startRecording()
        audio.setMuted(true)
        #expect(audio.process([222, -333], stage: .broadcast) == [0, 0])
        #expect(try audio.finishRecording() == [222, -333])
    }
}
