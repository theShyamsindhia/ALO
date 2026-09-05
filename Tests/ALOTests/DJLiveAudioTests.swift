import Foundation
import Testing
@testable import ALO

struct DJLiveAudioTests {
    @Test func staleCapturesRespectMuteGainWithoutAdvancingHistory() {
        let audio = DJLiveAudio()
        audio.configure(stage: .listening)
        #expect(audio.process([100, -100], stage: .listening, captureTimeNanos: 100) == [100, -100])
        let duration = audio.snapshot().historyDuration
        audio.setMuted(true)
        #expect(audio.process([100, -100], stage: .listening, captureTimeNanos: 99) == [0, 0])
        audio.setMuted(false); audio.setMix(gain: 0.5, low: 0, mid: 0, high: 0)
        #expect(audio.process([100, -100], stage: .listening, captureTimeNanos: 100) == [50, -50])
        #expect(audio.snapshot().historyDuration == duration)
        audio.configure(stage: nil); audio.configure(stage: .listening)
        #expect(audio.process([100, -100], stage: .listening, captureTimeNanos: 1) == [100, -100])
        #expect(audio.snapshot().historyDuration == duration)
    }

    @Test func expiredOverlayIsSilentAndInputAgeTracksAcceptedFrames() async throws {
        let audio = DJLiveAudio()
        audio.configure(stage: .broadcast)
        #expect(audio.snapshot().secondsSinceInput == nil)
        _ = audio.process([1, 1], stage: .broadcast)
        #expect(try #require(audio.snapshot().secondsSinceInput) < 0.1)
        audio.offerOverlay([1000, 1000])
        try await Task.sleep(for: .milliseconds(130))
        #expect(try #require(audio.snapshot().secondsSinceInput) >= 0.1)
        #expect(audio.process([0, 0], stage: .broadcast) == [0, 0])
        audio.offerOverlay([1000, 1000]); audio.clearOverlay()
        #expect(audio.process([0, 0], stage: .broadcast) == [0, 0])
        audio.configure(stage: nil)
        #expect(audio.snapshot().secondsSinceInput == nil)
    }

    @Test func disabledAndWrongStageDoNotRecordOrTransform() throws {
        let audio = DJLiveAudio()
        let input: [Int16] = [100, -100, 500, -500]
        audio.setMix(gain: 0.5, low: 0, mid: 0, high: 0)
        #expect(audio.process(input, stage: .broadcast) == input)
        #expect(audio.snapshot().bufferedPCMBytes == 0)
        audio.configure(stage: .listening)
        audio.setMix(gain: 0.5, low: 0, mid: 0, high: 0)
        #expect(audio.process(input, stage: .broadcast) == input)
        #expect(audio.snapshot().historyDuration == 0)
        #expect(audio.process(input, stage: .listening) == [50, -50, 250, -250])
        #expect(audio.snapshot().historyDuration > 0)
        audio.configure(stage: nil)
        #expect(audio.snapshot().bufferedPCMBytes == 0)
        #expect(audio.snapshot().waveform.isEmpty)
        #expect(audio.process(input, stage: .listening) == input)
    }

    @Test func nativePCMLoopRepeatsAcrossUnevenChunksWhileDryHistoryContinues() throws {
        let audio = DJLiveAudio()
        audio.configure(stage: .broadcast)
        let frames = 24_000
        let source = (0..<frames).flatMap { frame -> [Int16] in [Int16(frame % 15_000), Int16(-(frame % 15_000))] }
        #expect(audio.process(source, stage: .broadcast) == source)
        try audio.toggleLoop(beats: 1, bpm: 120)
        #expect(audio.snapshot().loopDuration == 0.5)
        var rendered: [Int16] = []
        for size in [123, 1011, 25000, 22000] {
            rendered += audio.process([Int16](repeating: 17, count: size * 2), stage: .broadcast)
        }
        #expect(rendered.enumerated().allSatisfy { $0.element == source[$0.offset % source.count] })
        #expect(audio.snapshot().historyDuration > 1)
        try audio.clearLoop()
        #expect(audio.process([77, -88], stage: .broadcast) == [77, -88])
    }

    @Test func rewindCueAndManualLoopFollowRecordedAudio() throws {
        let audio = DJLiveAudio()
        audio.configure(stage: .listening)
        _ = audio.process([Int16](repeating: 100, count: 48_000), stage: .listening)
        audio.setCue()
        audio.setLoopIn()
        _ = audio.process([Int16](repeating: 200, count: 48_000), stage: .listening)
        try audio.setLoopOut()
        #expect(audio.snapshot().loopDuration == 0.5)
        #expect(audio.process([0, 0], stage: .listening) == [200, 200])
        try audio.clearLoop()
        try audio.returnToCue()
        #expect(audio.snapshot().delaySeconds > 0.5)
        #expect(audio.process([300, 300], stage: .listening) == [200, 200])
        try audio.setDelay(seconds: 0)
        #expect(audio.process([301, 301], stage: .listening) == [301, 301])
        #expect(throws: (any Error).self) { try audio.setDelay(seconds: .nan) }
        #expect(throws: (any Error).self) { try audio.setDelay(seconds: 33) }
        #expect(throws: (any Error).self) { try audio.toggleLoop(beats: 1, bpm: 0) }
    }

    @Test func overlayIsBoundedAddsAfterDryGainAndSurvivesDryMute() throws {
        let audio = DJLiveAudio()
        audio.configure(stage: .broadcast)
        audio.setMix(gain: 0.5, low: 0, mid: 0, high: 0)
        audio.offerOverlay([100, -100, 200, -200])
        #expect(audio.process([1000, -1000, 1000, -1000, 1000, -1000], stage: .broadcast) == [600, -600, 700, -700, 500, -500])
        audio.setMuted(true)
        audio.offerOverlay([123, -123])
        #expect(audio.process([1000, 1000], stage: .broadcast) == [123, -123])
        #expect(audio.process([1000, 1000], stage: .broadcast) == [0, 0])
        let long = [Int16](repeating: 10, count: DJLiveAudio.overlayFrames * 2) + [55, 66]
        audio.offerOverlay(long)
        let output = audio.process([Int16](repeating: 0, count: (DJLiveAudio.overlayFrames + 1) * 2), stage: .broadcast)
        #expect(Array(output.suffix(4)) == [55, 66, 0, 0])
        audio.setMuted(false); audio.setMix(gain: 2, low: 0, mid: 0, high: 0)
        audio.offerOverlay([30000, -30000])
        #expect(audio.process([30000, -30000], stage: .broadcast) == [32767, -32768])
        #expect(audio.snapshot().outputPeak == 1)
        #expect(audio.snapshot().inputPeak < 1)
    }

    @Test func EQChangesFrequencyEnergyWithoutCrossChannelLeakage() {
        let dry = tone(frequency: 50)
        let audio = DJLiveAudio()
        audio.configure(stage: .broadcast)
        audio.setMix(gain: 1, low: -24, mid: 0, high: 0)
        let cut = audio.process(dry, stage: .broadcast)
        #expect(energy(cut) < energy(dry) * 0.1)
        #expect(stride(from: 1, to: cut.count, by: 2).allSatisfy { cut[$0] == 0 })
        audio.configure(stage: .listening)
        audio.setMix(gain: 1, low: 0, mid: 12, high: 0)
        let mid = tone(frequency: 1_000)
        #expect(energy(audio.process(mid, stage: .listening)) > energy(mid) * 8)
        audio.configure(stage: .broadcast)
        audio.setMix(gain: 1, low: 0, mid: 0, high: -24)
        let high = tone(frequency: 18_000)
        #expect(energy(audio.process(high, stage: .broadcast)) < energy(high) * 0.1)
    }

    @Test func historyAndLoopMemoryAreBoundedAndResetReleasesPCM() throws {
        let audio = DJLiveAudio()
        audio.configure(stage: .broadcast)
        audio.setCue()
        let second = [Int16](repeating: 42, count: 96_000)
        for _ in 0..<33 { _ = audio.process(second, stage: .broadcast) }
        #expect(audio.snapshot().historyDuration == 32)
        #expect(!audio.snapshot().hasCue)
        #expect(throws: (any Error).self) { try audio.returnToCue() }
        try audio.toggleLoop(beats: 16, bpm: 30)
        #expect(audio.snapshot().loopDuration == 32)
        #expect(audio.snapshot().bufferedPCMBytes == 12_307_200)
        #expect(audio.snapshot().waveform.count == 256)
        #expect(audio.snapshot().waveform.max() == Float(42) / 32768)
        #expect(audio.process([9, 9], stage: .broadcast) == [42, 42])
        audio.configure(stage: .listening)
        #expect(!audio.snapshot().looping && audio.snapshot().historyDuration == 0)
        audio.configure(stage: nil)
        #expect(audio.snapshot().bufferedPCMBytes == 0)
    }

    private func tone(frequency: Double) -> [Int16] {
        (0..<24_000).flatMap { frame -> [Int16] in
            [Int16(sin(Double(frame) * 2 * .pi * frequency / 48_000) * 2_000), 0]
        }
    }
    private func energy(_ samples: [Int16]) -> Double {
        samples.dropFirst(4096).reduce(0) { $0 + Double($1) * Double($1) }
    }
}
