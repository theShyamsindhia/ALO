import Foundation

struct VoiceSignalLevels: Equatable, Sendable {
    let inputRMS: Float
    let inputPeak: Float
    let outputRMS: Float
    let outputPeak: Float
}

/// Numeric local playback evidence, not a microphone recording or wire clock.
struct VoicePlaybackTelemetry: Sendable {
    private(set) var acceptedAudioBuffers: UInt64 = 0
    private(set) var concealmentBuffers: UInt64 = 0
    private(set) var capDrops: UInt64 = 0
    private(set) var configurationResets: UInt64 = 0
    private(set) var maximumArrivalGapNanos: UInt64 = 0
    private(set) var levels: VoiceSignalLevels?
    private var previousArrival: UInt64?

    mutating func received(at now: UInt64) {
        if let previousArrival, now >= previousArrival {
            maximumArrivalGapNanos = max(maximumArrivalGapNanos, now - previousArrival)
        }
        previousArrival = now
    }
    mutating func scheduled(concealment: Bool, levels: VoiceSignalLevels?) {
        if concealment { Self.increment(&concealmentBuffers) }
        else { Self.increment(&acceptedAudioBuffers); self.levels = levels }
    }
    mutating func droppedAtCapacity() { Self.increment(&capDrops) }
    mutating func resetForConfiguration() { Self.increment(&configurationResets) }
    private static func increment(_ value: inout UInt64) { if value < UInt64.max { value += 1 } }

    func detail(session: UInt64, queuedFrames: Int64, participantGain: Float) -> String {
        let signal = levels.map {
            "last_audio_input_rms=\($0.inputRMS) last_audio_input_peak=\($0.inputPeak) last_audio_leveled_rms=\($0.outputRMS) last_audio_leveled_peak=\($0.outputPeak)"
        } ?? "last_audio_input_rms=unavailable last_audio_input_peak=unavailable last_audio_leveled_rms=unavailable last_audio_leveled_peak=unavailable"
        return "voice_playback session=\(session) accepted_audio=\(acceptedAudioBuffers) concealment=\(concealmentBuffers) cap_drops=\(capDrops) config_resets=\(configurationResets) player_arrival_gap_max_ns=\(maximumArrivalGapNanos) queued_frames=\(queuedFrames) participant_gain=\(participantGain) \(signal)"
    }
}

struct VoiceDiagnosticThrottle {
    private var lastEmission: UInt64?
    mutating func admit(at now: UInt64) -> Bool {
        if let lastEmission, now < lastEmission || now - lastEmission < 1_000_000_000 { return false }
        lastEmission = now
        return true
    }
}
