import AppKit
import AVFoundation
import SwiftUI
import Testing
import ALOCore
@testable import ALO

@Suite(.serialized) @MainActor
struct DJStudioTests {
    @Test func onlyPendingDJIntentIsCancelledWhenStudioCloses() {
        #expect(MeshSession.shouldStopDJBroadcast(intendsToBroadcast: true, audioSource: .djStudio))
        #expect(!MeshSession.shouldStopDJBroadcast(intendsToBroadcast: false, audioSource: .djStudio))
        #expect(!MeshSession.shouldStopDJBroadcast(intendsToBroadcast: true, audioSource: .allSystemAudio))
    }

    @Test func equalPowerCrossfade() {
        for x in stride(from: 0.0, through: 1.0, by: 0.01) {
            let (a, b) = DJMixMath.gains(crossfade: x)
            #expect(abs(a * a + b * b - 1) < 0.00001)
        }
        #expect(DJMixMath.gains(crossfade: -1).0 == 1)
        #expect(abs(DJMixMath.gains(crossfade: 1).0) < 0.00001)
        #expect(DJMixMath.gains(crossfade: 2).1 == 1)
        #expect(DJMixMath.gains(crossfade: .nan).0.isFinite)
    }

    @Test func tempoMatchingRespectsPlaybackBounds() {
        #expect(DJMixMath.syncRate(sourceBPM: 120, targetBPM: 120, targetRate: 1) == 1)
        #expect(DJMixMath.syncRate(sourceBPM: 120, targetBPM: 150, targetRate: 1) == 1.25)
        #expect(DJMixMath.syncRate(sourceBPM: 120, targetBPM: 90, targetRate: 1) == 0.75)
        #expect(DJMixMath.syncRate(sourceBPM: 120, targetBPM: 151, targetRate: 1) == nil)
        #expect(DJMixMath.syncRate(sourceBPM: 120, targetBPM: 89, targetRate: 1) == nil)
        #expect(DJMixMath.syncRate(sourceBPM: 0, targetBPM: 120, targetRate: 1) == nil)
        #expect(DJMixMath.syncRate(sourceBPM: .nan, targetBPM: 120, targetRate: 1) == nil)
        #expect(DJMixMath.syncRate(sourceBPM: 120, targetBPM: .infinity, targetRate: 1) == nil)
        #expect(DJMixMath.syncRate(sourceBPM: 100, targetBPM: 100, targetRate: 1.1) == 1.1)
    }

    @Test func allFactoryPadsContainFiniteBoundedStereoAudio() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        for index in 0..<16 {
            let pad = DJStudio.makePad(index, format: format)
            #expect(pad.frameLength > 0)
            let channels = try #require(pad.floatChannelData)
            var peak: Float = 0
            for frame in 0..<Int(pad.frameLength) {
                let value = channels[0][frame]
                if !value.isFinite || abs(value) > 1 || value != channels[1][frame] {
                    Issue.record("Pad \(index) has invalid stereo PCM at frame \(frame)")
                    break
                }
                peak = max(peak, abs(value))
            }
            #expect(peak > 0.01)
        }
    }

    @Test func liveInputUsesMixerAndPadsWithoutDoubledMonitoring() async throws {
        let studio = DJStudio()
        defer { studio.setLiveStage(nil); studio.stopAll(); studio.engine.stop() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try studio.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        studio.setLiveStage(.broadcast)
        #expect(DJLiveAudio.shared.process([1000, -1000], stage: .broadcast) == [1000, -1000])
        studio.crossfade = 0
        studio.master = 1
        studio.a.gain = 0.5
        let dry = [Int16](repeating: 10_000, count: 2048)
        let mixed = DJLiveAudio.shared.process(dry, stage: .broadcast)
        #expect(abs(Int(mixed[0]) - 5_000) <= 1)
        #expect(studio.engine.mainMixerNode.outputVolume == 0)
        studio.a.gain = 0
        studio.trigger(8)
        var overlayPeak = 0
        for _ in 0..<12 {
            _ = try studio.engine.renderOffline(1024, to: output)
            let heard = DJLiveAudio.shared.process([Int16](repeating: 0, count: 2048), stage: .broadcast)
            overlayPeak = max(overlayPeak, heard.map { abs(Int($0)) }.max() ?? 0)
        }
        #expect(overlayPeak > 100)
        studio.stopAll()
        #expect(DJLiveAudio.shared.snapshot().muted)
        #expect(DJLiveAudio.shared.process(dry, stage: .broadcast).allSatisfy { $0 == 0 })
        studio.setLiveStage(nil)
        #expect(DJLiveAudio.shared.snapshot().bufferedPCMBytes == 0)
        #expect(studio.engine.mainMixerNode.outputVolume == 1)
        #expect(DJLiveAudio.shared.process(dry, stage: .broadcast) == dry)
    }

    @Test func deckLoadSeekCueAndReplacement() throws {
        let studio = DJStudio()
        defer { studio.stopAll() }
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try writeTone(folder: folder, name: "First", seconds: 2)
        let second = try writeTone(folder: folder, name: "Second", seconds: 1)
        try studio.a.load(first)
        #expect(studio.a.title == "First")
        #expect(studio.a.duration == 2)
        try studio.a.seek(0.75)
        studio.a.setCue()
        try studio.a.seek(20)
        #expect(studio.a.position == 2)
        try studio.a.returnToCue()
        #expect(studio.a.position == 0.75)
        try studio.a.seek(-1)
        #expect(studio.a.position == 0)
        studio.a.rate = 1.2
        studio.a.loops = true
        try studio.a.load(second)
        #expect(studio.a.title == "Second")
        #expect(studio.a.duration == 1)
        #expect(studio.a.position == 0 && studio.a.cue == 0)
        #expect(studio.a.rate == 1 && !studio.a.loops && !studio.a.isPlaying)
        do {
            try studio.a.load(folder.appendingPathComponent("missing.wav"))
            Issue.record("Missing audio file unexpectedly loaded")
        } catch {}
        #expect(studio.a.title == "Second")
        #expect(!studio.engine.isRunning)
    }

    @Test func deckProducesAudioOfflineAndCrossfaderMutesIt() async throws {
        let studio = DJStudio()
        let folder = try fixtureFolder()
        defer { studio.stopAll(); studio.engine.stop(); try? FileManager.default.removeItem(at: folder) }
        let song = try writeTone(folder: folder, name: "Offline tone", seconds: 3)
        try studio.a.load(song)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        // Offline rendering never opens the hardware output or emits audible audio.
        try studio.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        studio.crossfade = 0
        try studio.a.toggle()
        func peakOverBlocks() throws -> Float {
            var peak: Float = 0
            for _ in 0..<16 {
                let status = try studio.engine.renderOffline(1024, to: output)
                #expect(status == .success)
                let channel = try #require(output.floatChannelData)[0]
                for frame in 0..<Int(output.frameLength) { peak = max(peak, abs(channel[frame])) }
            }
            return peak
        }
        #expect(try peakOverBlocks() > 0.01)
        studio.crossfade = 1
        _ = try peakOverBlocks() // Drain the time-pitch unit's buffered samples.
        #expect(try peakOverBlocks() < 0.00001)
        studio.crossfade = 0
        studio.master = 0
        _ = try peakOverBlocks()
        #expect(try peakOverBlocks() < 0.00001)
        try await Task.sleep(for: .milliseconds(100))
        #expect(studio.relay.level < 0.00001)
        studio.master = 0.75
        let received = DJTestPCMCollector()
        let owner = UUID()
        try studio.beginSharing(owner: owner) { samples, _ in received.append(samples) }
        #expect(studio.engine.mainMixerNode.outputVolume == 0)
        _ = try peakOverBlocks()
        #expect(try peakOverBlocks() < 0.00001)
        try await Task.sleep(for: .milliseconds(100))
        #expect(received.peak > 100)
        #expect(studio.relay.level > 0.01)
        studio.endSharing(owner: owner)
        #expect(!studio.sharing)
        studio.a.stop()
        #expect(!studio.a.isPlaying && studio.a.position == 0)
    }

    private func fixtureFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("alo-dj-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeTone(folder: URL, name: String, seconds: Double) throws -> URL {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48_000)))
        buffer.frameLength = buffer.frameCapacity
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            let value = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.2
            channels[0][frame] = value; channels[1][frame] = value
        }
        let url = folder.appendingPathComponent(name).appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct DJStudioPresentationTests {
        @Test func studioNativeSnapshot() async throws {
            _ = NSApplication.shared
            let model = ALOViewModel(discoverRooms: false)
            model.nowPlayingCallback(NowPlayingMedia(title: "Simply Falling", artist: "Iyeoka", isPlaying: false, elapsedTime: 90, duration: 240))
            let studio = DJStudio()
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("dj-preview-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let url = fixture.appendingPathComponent("Practice beat.wav")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 8))
            buffer.frameLength = buffer.frameCapacity
            for frame in 0..<Int(buffer.frameLength) {
                let t = Double(frame) / 48_000
                let pulse = exp(-t.truncatingRemainder(dividingBy: 0.5) * 12)
                let sample = Float(sin(t * 2 * .pi * 110) * pulse * 0.7)
                buffer.floatChannelData![0][frame] = sample
                buffer.floatChannelData![1][frame] = sample
            }
            do { let writer = try AVAudioFile(forWriting: url, settings: format.settings); try writer.write(from: buffer) }
            try studio.b.load(url)
            try studio.b.seek(2)
            try studio.b.toggleBeatLoop()
            studio.setLiveStage(.listening)
            for block in 0..<400 {
                let samples: [Int16] = (0..<960).flatMap { frame in
                    let t = Double(block * 960 + frame) / 48_000
                    let pulse = exp(-t.truncatingRemainder(dividingBy: 0.5) * 12)
                    let value = Int16(sin(t * 2 * .pi * 110) * pulse * 22_000)
                    return [value, value]
                }
                _ = DJLiveAudio.shared.process(samples, stage: .listening)
            }
            try studio.toggleLiveLoop()
            studio.refreshLive()
            let waveformDeadline = ContinuousClock.now + .seconds(10)
            while studio.b.waveformLoading && ContinuousClock.now < waveformDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!studio.b.waveformLoading && studio.b.waveform.count == 256)
            let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 1040, height: 1020),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let hosting = NSHostingView(rootView: DJStudioView(model: model, studio: studio)
                .transaction { $0.disablesAnimations = true })
            window.contentView = hosting
            defer { window.close(); studio.setLiveStage(nil); studio.stopAll() }
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 1040 && bitmap.pixelsHigh >= 1020)
            #expect(!studio.engine.isRunning)
            if let directory = ProcessInfo.processInfo.environment["ALO_SPACES_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("dj-studio.png"))
            }
        }
    }
}

private final class DJTestPCMCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum = 0
    var peak: Int { lock.withLock { maximum } }
    func append(_ samples: [Int16]) {
        lock.withLock { maximum = max(maximum, samples.map { abs(Int($0)) }.max() ?? 0) }
    }
}
