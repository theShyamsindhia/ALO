import Foundation

/// Background execution is justified by current scheduled room audio, never
/// merely room membership, a running empty engine, or synthetic silence.
public enum BackgroundAudioEligibility {
    public static func allows(connected: Bool, running: Bool, hasScheduledAudio: Bool,
                              microphoneActive: Bool, lastPacketNanos: UInt64?, nowNanos: UInt64) -> Bool {
        guard connected, running, hasScheduledAudio, !microphoneActive,
              let lastPacketNanos, nowNanos >= lastPacketNanos else { return false }
        return nowNanos - lastPacketNanos <= 2_000_000_000
    }
}
