import AVFoundation
import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct DJRecordingStudioTests {
    @Test func recordedATakeReplacesDryInputAndPlaysThroughRoomRoute() throws {
        let studio = DJStudio()
        defer { studio.setLiveStage(nil); studio.stopAll(); studio.clearRecordings(); studio.engine.stop() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try studio.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        studio.setLiveStage(.broadcast)
        try studio.toggleDeckRecording("A", stage: .broadcast)
        let tone: [Int16] = (0..<48_000).flatMap { frame in
            let sample = Int16(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 12_000)
            return [sample, sample]
        }
        _ = DJLiveAudio.shared.process(tone, stage: .broadcast)
        try studio.toggleDeckRecording("A", stage: .broadcast)
        #expect(studio.recordingDeck == nil)
        #expect(studio.a.isRecordingClip && studio.a.duration == 1)
        #expect(studio.liveEnabled && studio.usesLiveDeckA)
        #expect(!studio.a.isPlaying)
        #expect(studio.engine.mainMixerNode.outputVolume == 0)
        let dry = [Int16](repeating: 3000, count: 2048)
        #expect(DJLiveAudio.shared.process(dry, stage: .broadcast) == dry)
        try studio.playRecordedA()
        #expect(!studio.usesLiveDeckA && studio.a.isPlaying)
        #expect(DJLiveAudio.shared.process(dry, stage: .broadcast).allSatisfy { $0 == 0 })
        var peak = 0
        for _ in 0..<12 {
            _ = try studio.engine.renderOffline(1024, to: output)
            studio.relay.flushForTesting()
            let mixed = DJLiveAudio.shared.process(dry, stage: .broadcast)
            peak = max(peak, mixed.map { abs(Int($0)) }.max() ?? 0)
        }
        #expect(peak > 5000)
        studio.setLiveStage(.broadcast) // Return live without ending the room source.
        #expect(studio.usesLiveDeckA && !studio.a.isPlaying)
        #expect(DJLiveAudio.shared.process(dry, stage: .broadcast) == dry)
    }

    @Test func recordBRetainsLiveInputAndStopCancelsPendingRecording() throws {
        let studio = DJStudio()
        defer { studio.setLiveStage(nil); studio.clearRecordings(); studio.stopAll() }
        #expect(throws: (any Error).self) { try studio.toggleDeckRecording("B", stage: nil) }
        try studio.toggleDeckRecording("B", stage: .listening)
        _ = DJLiveAudio.shared.process([Int16](repeating: 1234, count: 9600), stage: .listening)
        try studio.toggleDeckRecording("B", stage: .listening)
        #expect(studio.b.isRecordingClip && studio.usesLiveDeckA)
        let location = try #require(studio.b.recordingURL)
        try studio.toggleDeckRecording("A", stage: .listening)
        studio.stopAll()
        #expect(studio.recordingDeck == nil && !DJLiveAudio.shared.snapshot().recording)
        #expect(studio.b.isRecordingClip)
        studio.clearRecordings()
        #expect(!FileManager.default.fileExists(atPath: location.path))
    }
}
