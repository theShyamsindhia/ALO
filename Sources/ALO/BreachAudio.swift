import AVFoundation

/// Small original synthesized effects, cached in memory; no network or external assets.
@MainActor
final class BreachAudio {
    private var players: [String: AVAudioPlayer] = [:]
    init() {
        for (name, duration, frequency) in [("shot", 0.13, 95.0), ("reload", 0.18, 700.0), ("hit", 0.10, 1500.0), ("hurt", 0.16, 160.0)] {
            let count = Int(duration * 22050)
            var samples = Data()
            var seed: UInt32 = 17
            for i in 0..<count {
                seed = 1664525 &* seed &+ 1013904223
                let t = Double(i) / 22050
                let noise = Double(seed & 65535) / 32768 - 1
                let envelope = exp(-t / (duration * 0.22))
                let wave = (sin(t * frequency * 2 * .pi) * 0.35 + noise * (name == "shot" ? 0.65 : 0.15)) * envelope
                var sample = Int16(wave * 22000).littleEndian
                withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
            }
            var wav = Data()
            func word(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
            func half(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
            wav.append(contentsOf: "RIFF".utf8); word(UInt32(samples.count + 36)); wav.append(contentsOf: "WAVEfmt ".utf8)
            word(16); half(1); half(1); word(22050); word(44100); half(2); half(16)
            wav.append(contentsOf: "data".utf8); word(UInt32(samples.count)); wav.append(samples)
            if let player = try? AVAudioPlayer(data: wav) { player.prepareToPlay(); players[name] = player }
        }
    }
    func play(_ name: String, volume: Float) {
        guard volume > 0, let player = players[name] else { return }
        player.currentTime = 0; player.volume = volume; player.play()
    }
}
