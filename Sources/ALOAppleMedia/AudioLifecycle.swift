import Foundation

public enum IncomingVoicePolicy: Sendable, Equatable {
    case unchanged
    case duckMedia(multiplier: Float)
}

public struct AudioMixLevels: Sendable, Equatable {
    public var mediaVolume: Float
    public var voiceVolume: Float
    public var mediaMuted: Bool
    public var voiceMuted: Bool
    public var incomingVoiceActive: Bool
    public var incomingVoicePolicy: IncomingVoicePolicy

    public init(mediaVolume: Float = 1, voiceVolume: Float = 1, mediaMuted: Bool = false,
                voiceMuted: Bool = false, incomingVoiceActive: Bool = false,
                incomingVoicePolicy: IncomingVoicePolicy = .unchanged) {
        self.mediaVolume = mediaVolume; self.voiceVolume = voiceVolume
        self.mediaMuted = mediaMuted; self.voiceMuted = voiceMuted
        self.incomingVoiceActive = incomingVoiceActive; self.incomingVoicePolicy = incomingVoicePolicy
    }
    public var effectiveMediaVolume: Float {
        guard !mediaMuted else { return 0 }
        let level = Self.unit(mediaVolume)
        guard incomingVoiceActive, effectiveVoiceVolume > 0,
              case .duckMedia(let multiplier) = incomingVoicePolicy else { return level }
        return level * Self.unit(multiplier)
    }
    public var effectiveVoiceVolume: Float { voiceMuted ? 0 : Self.unit(voiceVolume) }
    private static func unit(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
}

/// Explicit user microphone intent never survives interruption, route changes,
/// suspension, or a permission result belonging to an earlier lifecycle.
public struct AudioLifecycle: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case inactive, listening, requestingMicrophone, transmitting, interrupted, suspended }
    public private(set) var phase: Phase = .inactive
    public private(set) var generation: UInt64 = 0
    public private(set) var microphoneRequestGeneration: UInt64 = 0
    public private(set) var needsResynchronization = true
    public private(set) var wantsListening = false
    public var isMicrophoneActive: Bool { phase == .transmitting }
    public var canRender: Bool { phase == .listening || phase == .requestingMicrophone || phase == .transmitting }
    public init() {}

    @discardableResult public mutating func startListening() -> UInt64 {
        advance(to: .listening)
        wantsListening = phase == .listening
        return generation
    }
    public mutating func requestMicrophoneFromUserAction() throws -> UInt64 {
        guard phase == .listening else { throw AppleMediaError.invalidState }
        guard microphoneRequestGeneration < .max else { throw AppleMediaError.generationExhausted }
        microphoneRequestGeneration += 1
        phase = .requestingMicrophone
        return microphoneRequestGeneration
    }
    @discardableResult public mutating func completeMicrophonePermission(generation expected: UInt64, granted: Bool) -> Bool {
        guard expected == microphoneRequestGeneration, phase == .requestingMicrophone else { return false }
        if granted { advance(to: .transmitting) } else { phase = .listening }
        return granted
    }
    public mutating func stopMicrophone() { advance(to: wantsListening ? .listening : .inactive) }
    public mutating func routeChanged() {
        let next: Phase = phase == .suspended ? .suspended : phase == .interrupted ? .interrupted : wantsListening ? .listening : .inactive
        advance(to: next)
    }
    public mutating func interrupt() { advance(to: .interrupted) }
    public mutating func suspend() { advance(to: .suspended) }
    public mutating func stop() { wantsListening = false; advance(to: .inactive) }
    public mutating func resynchronized(generation expected: UInt64) {
        guard expected == generation, canRender else { return }
        needsResynchronization = false
    }
    public mutating func requireResynchronization() { needsResynchronization = true }
    private mutating func advance(to next: Phase) {
        guard generation < .max else { phase = .inactive; wantsListening = false; return }
        generation += 1
        if microphoneRequestGeneration < .max { microphoneRequestGeneration += 1 }
        phase = next
        needsResynchronization = true
    }
}
