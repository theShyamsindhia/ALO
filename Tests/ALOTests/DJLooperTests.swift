import AVFoundation
import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct DJLooperTests {
    @Test func relayMetersUnsharedAndHonorsSubscriberRevocation() throws {
        let relay = DJAudioRelay()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        for channel in 0..<2 {
            for frame in 0..<32 { buffer.floatChannelData![channel][frame] = 0.25 }
        }
        let time = AVAudioTime(sampleTime: 0, atRate: 48_000)
        relay.consume(buffer, time: time)
        #expect(relay.level == 0.25)
        let first = UUID(), second = UUID()
        let firstCalls = DJLoopCallCounter(), secondCalls = DJLoopCallCounter()
        try relay.install(owner: first) { _, _ in firstCalls.increment() }
        relay.consume(buffer, time: time)
        #expect(firstCalls.value == 1)
        #expect(relay.remove(owner: first))
        relay.consume(buffer, time: time)
        #expect(firstCalls.value == 1)
        try relay.install(owner: second) { _, _ in secondCalls.increment() }
        #expect(!relay.remove(owner: first))
        relay.consume(buffer, time: time)
        #expect(firstCalls.value == 1 && secondCalls.value == 1)
        #expect(relay.remove(owner: second))
    }

    @Test func waveformIncludesTransientsLateInEachBin() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dj-waveform-transient-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            buffer.floatChannelData![channel].initialize(repeating: 0, count: 48_000)
            buffer.floatChannelData![channel][23_999] = 0.7
            buffer.floatChannelData![channel][47_999] = -0.8
        }
        do { let writer = try AVAudioFile(forWriting: url, settings: format.settings); try writer.write(from: buffer) }
        let peaks = try DJWaveform.peaks(url: url, count: 2)
        #expect(peaks.count == 2)
        #expect(abs(peaks[0] - 0.7) < 0.0001)
        #expect(abs(peaks[1] - 0.8) < 0.0001)
    }

    @Test func pcmCapsRejectHighRateAndOverflowWithoutAllocation() {
        #expect(DJPCMStorage.fits(frames: 48_000 * 32, channels: 2))
        #expect(!DJPCMStorage.fits(frames: 192_000 * 32, channels: 2))
        #expect(DJPCMStorage.fits(frames: 192_000 * 10, channels: 2))
        #expect(!DJPCMStorage.fits(frames: 384_000 * 10, channels: 2))
        #expect(DJPCMStorage.fits(frames: 2_097_152, channels: 2))
        #expect(!DJPCMStorage.fits(frames: 2_097_153, channels: 2))
        #expect(!DJPCMStorage.fits(frames: .max, channels: 2))
        #expect(!DJPCMStorage.fits(frames: Int64(UInt32.max), channels: .max))
        #expect(!DJPCMStorage.fits(frames: 1, channels: 0))
        #expect(!DJPCMStorage.fits(frames: 0, channels: 2))
    }

    @Test func loopRendersBeyondRegionAndPauseSeekExitStayConsistent() throws {
        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        let deck = DJDeck(engine: engine, mixer: mixer)
        let url = try fixture(seconds: 2)
        defer { deck.stop(); engine.stop(); try? FileManager.default.removeItem(at: url) }
        try deck.load(url)
        deck.bpm = 120
        try deck.setLoopBeats(1)
        try deck.toggleBeatLoop()
        #expect(deck.loopStart == 0 && deck.loopEnd == 0.5)
        #expect(deck.loopEnabled && !deck.isPlaying)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        try deck.toggle()
        var latePeak: Float = 0
        for block in 0..<120 {
            #expect(try engine.renderOffline(1024, to: output) == .success)
            deck.tick()
            #expect(deck.position >= 0 && deck.position < 0.5)
            if block > 100 {
                let channel = try #require(output.floatChannelData)[0]
                for frame in 0..<Int(output.frameLength) { latePeak = max(latePeak, abs(channel[frame])) }
            }
        }
        // This runs longer than the entire source file: sustained output proves
        // the region is really scheduled repeatedly, rather than a UI-only loop.
        #expect(latePeak > 0.05)
        try deck.toggle()
        #expect(!deck.isPlaying && deck.loopEnabled)
        let pausedAt = deck.position
        try deck.toggle()
        #expect(deck.isPlaying && abs(deck.position - pausedAt) < 0.0001)
        var resumedPeak: Float = 0
        for block in 0..<40 {
            #expect(try engine.renderOffline(1024, to: output) == .success)
            if block > 30 {
                let channel = try #require(output.floatChannelData)[0]
                for frame in 0..<Int(output.frameLength) { resumedPeak = max(resumedPeak, abs(channel[frame])) }
            }
        }
        #expect(resumedPeak > 0.05)
        try deck.seek(1.2)
        #expect(!deck.loopEnabled && abs(deck.position - 1.2) < 0.0001)
        deck.stop()
        #expect(!deck.loopEnabled && deck.position == 0 && !deck.isPlaying)
    }

    @Test func manualBoundsBeatValidationAndReplacement() throws {
        let studio = DJStudio()
        let url = try fixture(seconds: 3)
        let second = try fixture(seconds: 1)
        defer { studio.stopAll(); try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: second) }
        let deck = studio.a
        try deck.load(url)
        try deck.seek(0.4)
        try deck.setLoopIn()
        #expect(throws: (any Error).self) { try deck.setLoopOut() }
        try deck.seek(1.4)
        try deck.setLoopOut()
        #expect(deck.loopEnabled && deck.loopStart == 0.4 && deck.loopEnd == 1.4)
        try deck.clearLoop()
        #expect(!deck.loopEnabled && deck.loopStart == nil && deck.loopEnd == nil)
        deck.bpm = 0
        #expect(throws: (any Error).self) { try deck.toggleBeatLoop() }
        deck.bpm = 1
        #expect(throws: (any Error).self) { try deck.toggleBeatLoop() }
        #expect(throws: (any Error).self) { try deck.setLoopBeats(3) }
        deck.bpm = 120
        try deck.seek(2.9)
        #expect(throws: (any Error).self) { try deck.toggleBeatLoop() }
        try deck.seek(0)
        try deck.setLoopBeats(1)
        try deck.toggleBeatLoop()
        try deck.load(second)
        #expect(deck.loopStart == nil && deck.loopEnd == nil && !deck.loopEnabled)
        #expect(deck.position == 0 && !deck.isPlaying)
    }

    @Test func waveformIsBoundedAndReplacementCannotPublishOldPeaks() async throws {
        let studio = DJStudio()
        let loud = try fixture(seconds: 3)
        let silent = try fixture(seconds: 1, amplitude: 0)
        defer { studio.stopAll(); try? FileManager.default.removeItem(at: loud); try? FileManager.default.removeItem(at: silent) }
        let peaks = try DJWaveform.peaks(url: loud)
        #expect(peaks.count == 256 && peaks.allSatisfy { $0.isFinite && $0 <= 1 })
        #expect(peaks.max()! > 0.15)
        try studio.a.load(loud)
        try studio.a.load(silent)
        for _ in 0..<100 where studio.a.waveformLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!studio.a.waveformLoading)
        #expect(studio.a.waveform.count == 256)
        #expect(studio.a.waveform.allSatisfy { $0 == 0 })
    }

    private func fixture(seconds: Double, amplitude: Float = 0.2) throws -> URL {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48_000)))
        buffer.frameLength = buffer.frameCapacity
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            let sample = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * amplitude
            channels[0][frame] = sample; channels[1][frame] = sample
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dj-loop-\(UUID()).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private final class DJLoopCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
