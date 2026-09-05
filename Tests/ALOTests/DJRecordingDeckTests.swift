import AVFoundation
import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct DJRecordingDeckTests {
    @Test func recordedClipRendersLoopsAndSeeksWithoutImportingAFile() throws {
        let (engine, deck, format) = try makeDeck()
        defer { deck.clearRecording(); engine.stop() }
        try deck.loadRecording(tone(seconds: 1), title: "Room capture")
        #expect(deck.isRecordingClip && deck.title == "Room capture")
        #expect(abs(deck.duration - 1) < 0.0001)
        #expect(!deck.isPlaying)
        let url = try #require(deck.recordingURL)
        let bytes = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
        #expect(bytes.intValue <= 192_000 + 4096)
        let reader = try AVAudioFile(forReading: url)
        #expect(reader.fileFormat.commonFormat == .pcmFormatInt16)
        try deck.seek(0.25)
        deck.setCue()
        try deck.setLoopBeats(1)
        try deck.toggleBeatLoop()
        #expect(deck.loopStart == 0.25 && deck.loopEnd == 0.75)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        try deck.toggle()
        var latePeak: Float = 0
        for index in 0..<110 {
            #expect(try engine.renderOffline(1024, to: output) == .success)
            deck.tick()
            #expect(deck.position >= 0.25 && deck.position < 0.75)
            if index > 90 {
                for frame in 0..<Int(output.frameLength) {
                    latePeak = max(latePeak, abs(output.floatChannelData![0][frame]))
                }
            }
        }
        #expect(latePeak > 0.05)
        try deck.toggle()
        try deck.seek(0.9)
        #expect(!deck.loopEnabled && abs(deck.position - 0.9) < 0.0001)
        try deck.returnToCue()
        #expect(abs(deck.position - 0.25) < 0.0001)
    }

    @Test func invalidReplacementKeepsTheExistingRecording() throws {
        let (engine, deck, _) = try makeDeck()
        defer { deck.clearRecording(); engine.stop() }
        try deck.loadRecording(tone(seconds: 1), title: "Keep this")
        let url = try #require(deck.recordingURL)
        #expect(throws: (any Error).self) { try deck.load(URL(fileURLWithPath: "/nonexistent-\(UUID()).wav")) }
        #expect(throws: (any Error).self) { try deck.loadRecording([], title: "Empty") }
        #expect(throws: (any Error).self) { try deck.loadRecording([1], title: "Odd") }
        #expect(throws: (any Error).self) {
            try deck.loadRecording([Int16](repeating: 1, count: 48_000 * 2 * 32 + 2), title: "Too long")
        }
        #expect(deck.recordingURL == url && deck.isRecordingClip && deck.title == "Keep this")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func replacementAndClearRemoveOnlyOwnedFiles() throws {
        let (engine, deck, _) = try makeDeck()
        defer { deck.clearRecording(); engine.stop() }
        try deck.loadRecording(tone(seconds: 1), title: "First")
        let first = try #require(deck.recordingURL)
        try deck.loadRecording(tone(seconds: 1), title: "Second")
        let second = try #require(deck.recordingURL)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        let imported = FileManager.default.temporaryDirectory.appendingPathComponent("dj-user-file-\(UUID()).wav")
        try FileManager.default.copyItem(at: second, to: imported)
        defer { try? FileManager.default.removeItem(at: imported) }
        try deck.load(imported)
        #expect(!deck.isRecordingClip && deck.recordingURL == nil)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        deck.clearRecording()
        #expect(deck.duration == 1 && FileManager.default.fileExists(atPath: imported.path))
        try deck.loadRecording(tone(seconds: 1), title: "Third")
        let third = try #require(deck.recordingURL)
        deck.clearRecording()
        #expect(!FileManager.default.fileExists(atPath: third.path))
        #expect(!deck.isRecordingClip && deck.duration == 0 && deck.waveform.isEmpty)
    }

    @Test func releasingDeckDeletesItsTemporaryRecording() throws {
        let engine = AVAudioEngine(), mixer = AVAudioMixerNode()
        engine.attach(mixer)
        var deck: DJDeck? = DJDeck(engine: engine, mixer: mixer)
        try deck?.loadRecording(tone(seconds: 1), title: "Temporary")
        let url = try #require(deck?.recordingURL)
        deck = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private func makeDeck() throws -> (AVAudioEngine, DJDeck, AVAudioFormat) {
        let engine = AVAudioEngine(), mixer = AVAudioMixerNode()
        engine.attach(mixer)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        return (engine, DJDeck(engine: engine, mixer: mixer), format)
    }

    private func tone(seconds: Int) -> [Int16] {
        (0..<(48_000 * seconds * 2)).map { index in
            Int16(sin(Double(index / 2) * 2 * .pi * 440 / 48_000) * 8192)
        }
    }
}
