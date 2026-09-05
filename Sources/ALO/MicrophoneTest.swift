import AppKit
import ALOCore
import AVFoundation
import SwiftUI

/// Five seconds of 48 kHz mono PCM16; memory only, never passed to the room transport.
struct MicrophoneTestClip {
    static let maximumBytes = 48_000 * 2 * 5
    private(set) var pcm = Data()
    var duration: Double { Double(pcm.count) / 96_000 }
    mutating func append(_ packet: Data) {
        let count = min(Self.maximumBytes - pcm.count, packet.count) & ~1
        guard count > 0 else { return }
        pcm.append(packet.prefix(count))
    }
    var wav: Data {
        var data = Data("RIFF".utf8)
        func word(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func short(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        word(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8)); word(16)
        short(1); short(1); word(48_000); word(96_000); short(2); short(16)
        data.append(Data("data".utf8)); word(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

@MainActor
final class MicrophoneTestController: ObservableObject {
    enum Phase: Equatable { case idle, requesting, recording, ready, playing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice = "Record up to 5 seconds, then listen back. Nothing is sent to the room."
    private let microphone = WalkieTalkieMicrophone()
    private var clip = MicrophoneTestClip()
    private var player: AVAudioPlayer?
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    func start(inputUID: String?) {
        cancel()
        let token = generation
        phase = .requesting
        notice = "Waiting for microphone access…"
        operation = Task { [weak self] in
            guard let self else { return }
            let allowed = await WalkieTalkieMicrophone.requestAccess()
            guard !Task.isCancelled, self.generation == token else { return }
            guard allowed else {
                self.phase = .idle
                self.notice = "Microphone access needed. Enable it in System Settings → Privacy & Security → Microphone."
                return
            }
            do {
                try await self.microphone.start(sessionID: token.uuidString, inputDeviceUID: inputUID) { [weak self] packet in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.phase == .recording else { return }
                        self.clip.append(packet)
                        if self.clip.pcm.count == MicrophoneTestClip.maximumBytes { self.finishRecording() }
                    }
                } failureHandler: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.cancel(); self.notice = error.localizedDescription
                    }
                }
                guard !Task.isCancelled, self.generation == token else {
                    self.microphone.stop(sessionID: token.uuidString); return
                }
                self.phase = .recording
                self.notice = "Recording locally… speak for up to 5 seconds."
                try await Task.sleep(for: .seconds(5))
                guard self.generation == token else { return }
                self.finishRecording()
            } catch is CancellationError {} catch {
                guard self.generation == token else { return }
                self.cancel(); self.notice = error.localizedDescription
            }
        }
    }

    func finishRecording() {
        microphone.stop(sessionID: generation.uuidString)
        operation?.cancel(); operation = nil
        phase = clip.pcm.isEmpty ? .idle : .ready
        notice = clip.pcm.isEmpty ? "No microphone audio received. Check the selected input and try again." : "Recording ready. Play it back to check your microphone."
    }

    func play() {
        guard phase == .ready, !clip.pcm.isEmpty else { return }
        do {
            let playback = try AVAudioPlayer(data: clip.wav)
            player = playback
            guard playback.play() else { throw ALOError("Could not play the microphone test.") }
            phase = .playing
            notice = "Playing your local microphone test…"
            let token = generation
            operation = Task { [weak self] in
                try? await Task.sleep(for: .seconds(playback.duration + 0.1))
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.player = nil; self.phase = .ready
                self.notice = "Playback finished. You can replay or record again."
            }
        } catch { notice = error.localizedDescription; player = nil }
    }

    func stop() {
        if phase == .recording { finishRecording(); return }
        if phase == .playing {
            operation?.cancel(); operation = nil; player?.stop(); player = nil
            phase = .ready; notice = "Playback stopped."
        } else { cancel() }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel(); operation = nil
        microphone.stop()
        player?.stop(); player = nil
        clip = MicrophoneTestClip(); phase = .idle
        notice = "Record up to 5 seconds, then listen back. Nothing is sent to the room."
    }
}

struct MicrophoneTestPanel: View {
    let selectedInputUID: String?
    let unavailable: Bool
    var showsTitle = true
    @StateObject private var test = MicrophoneTestController()
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if showsTitle { Label("Microphone test", systemImage: "mic.badge.plus").font(.system(size: 11, weight: .semibold)) }
                Spacer()
                if test.phase == .idle || test.phase == .ready {
                    Button(test.phase == .idle ? "Record 5s" : "Record again") { test.start(inputUID: selectedInputUID) }
                        .disabled(unavailable)
                }
                if test.phase == .ready { Button("Play back") { test.play() }.disabled(unavailable) }
                if test.phase == .requesting || test.phase == .recording || test.phase == .playing { Button("Stop") { test.stop() } }
            }
            Text(unavailable ? "Stop Talk, Open Line, and this Mac's broadcast before testing." : test.notice)
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered).controlSize(.small).padding(12)
        .onChange(of: unavailable) { _, blocked in if blocked { test.cancel() } }
        .onChange(of: selectedInputUID) { _, _ in test.cancel() }
        .onDisappear { test.cancel() }
    }
}
