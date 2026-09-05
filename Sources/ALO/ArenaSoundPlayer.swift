import AVFoundation

/// Tiny synthesized impact cues, with a separate mixer from music and voice.
@MainActor
final class ArenaSoundPlayer {
    var volume: Float = 0.35
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connected = false
    private var pending = 0
    private var stopWork: DispatchWorkItem?
    func play(knockout: Bool) {
        guard volume > 0, pending < 4 else { return }
        let rate = 44_100.0, duration = knockout ? 0.3 : 0.10
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * duration)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let t = Double(i) / rate, envelope = pow(1 - t / duration, 3)
            let phase = 2 * Double.pi * (knockout ? 180 * t - 170 * t * t : 140 * t - 300 * t * t)
            samples[i] = Float(sin(phase) * envelope * 0.5)
        }
        if !connected {
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format); connected = true
        }
        do {
            if !engine.isRunning { try engine.start() }
            player.volume = max(0, min(1, volume))
            pending += 1
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.pending = max(0, (self?.pending ?? 1) - 1) }
            }
            if !player.isPlaying { player.play() }
            stopWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            stopWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        } catch { stop() }
    }
    func stop() {
        stopWork?.cancel(); stopWork = nil
        player.stop(); engine.stop(); pending = 0
    }
}
