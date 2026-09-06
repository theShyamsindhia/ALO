import Foundation

/// Receiver-local drift realignment; does not control mandatory device/stall recovery.
public struct LocalAudioSyncPolicy: Sendable {
    public static let thresholdNanos: UInt64 = 40_000_000
    public static let sustainedNanos: UInt64 = 1_000_000_000
    public static let cooldownNanos: UInt64 = 8_000_000_000
    public private(set) var enabled = true
    private var excessSince: UInt64?
    private var lastSample: UInt64?
    private var lastReset: UInt64?
    public init() {}
    public mutating func setEnabled(_ enabled: Bool) { self.enabled = enabled; resetEvidence() }
    public mutating func resetEvidence() { excessSince = nil; lastSample = nil }
    public mutating func didRealign(at now: UInt64) { lastReset = now; resetEvidence() }
    public func isCoolingDown(at now: UInt64) -> Bool {
        guard let lastReset else { return false }
        return now < lastReset || now - lastReset < Self.cooldownNanos
    }
    public mutating func shouldRealign(driftNanos: UInt64?, now: UInt64) -> Bool {
        guard enabled, !isCoolingDown(at: now), let driftNanos,
              driftNanos >= Self.thresholdNanos else { resetEvidence(); return false }
        if let lastSample, now < lastSample || now - lastSample > 250_000_000 { excessSince = nil }
        self.lastSample = now
        guard let excessSince else { self.excessSince = now; return false }
        guard now >= excessSince, now - excessSince >= Self.sustainedNanos else { return false }
        didRealign(at: now)
        return true
    }
}

/// Difference between the scheduled room timeline and the player's render clock.
/// This measures software playout timing; it cannot measure acoustic speaker delay.
public struct RenderDriftEstimate: Sendable {
    public static let maximumAgeNanos: UInt64 = 250_000_000
    public let errorSeconds: Double
    public let magnitudeNanos: UInt64

    public init?(nowNanos: UInt64, renderLocalNanos: UInt64, renderHostNanos: UInt64,
                 outputLatencyNanos: UInt64, captureAnchorNanos: UInt64,
                 playoutDelayNanos: UInt64, sampleTime: Int64, sampleRate: Double,
                 captureOffsetNanos: Double = 0) {
        guard nowNanos >= renderLocalNanos,
              nowNanos - renderLocalNanos <= Self.maximumAgeNanos,
              sampleTime >= 0, sampleRate.isFinite, sampleRate > 0, captureOffsetNanos.isFinite else { return nil }
        let audible = renderHostNanos.addingReportingOverflow(outputLatencyNanos)
        let start = captureAnchorNanos.addingReportingOverflow(playoutDelayNanos)
        guard !audible.overflow, !start.overflow, audible.partialValue >= start.partialValue else { return nil }
        errorSeconds = (Double(audible.partialValue - start.partialValue) - captureOffsetNanos) / 1_000_000_000
            - Double(sampleTime) / sampleRate
        let magnitude = abs(errorSeconds) * 1_000_000_000
        guard magnitude.isFinite, magnitude < Double(UInt64.max) else { return nil }
        magnitudeNanos = UInt64(magnitude)
    }
}

/// Checks that content timestamps still describe the PCM timeline being played.
/// Packet loss preserves frame indices; missing source PCM does not.
public enum CaptureTimelineAlignment: Sendable, Equatable {
    case aligned, stale, discontinuous

    public static func check(frameIndex: UInt64, captureNanos: UInt64,
                             anchorFrameIndex: UInt64, anchorCaptureNanos: UInt64) -> Self {
        guard frameIndex >= anchorFrameIndex, captureNanos >= anchorCaptureNanos else { return .stale }
        let elapsedNanos = Double(captureNanos - anchorCaptureNanos)
        let frameNanos = Double(frameIndex - anchorFrameIndex)
            * 1_000_000_000 / Double(AudioPacket.sampleRate)
        return abs(elapsedNanos - frameNanos) > Double(LocalAudioSyncPolicy.thresholdNanos)
            ? .discontinuous : .aligned
    }
}

/// Follows gradual capture-clock skew using content timestamps, never arrival times.
/// Abrupt gaps are rejected before smoothing so they still require a new anchor.
public struct CaptureTimelineTracker: Sendable {
    public private(set) var offsetNanos: Double = 0
    private var lastFrame: UInt64?
    public init() {}
    public mutating func reset() { offsetNanos = 0; lastFrame = nil }

    public mutating func observe(frameIndex: UInt64, captureNanos: UInt64,
                                 anchorFrameIndex: UInt64, anchorCaptureNanos: UInt64) -> CaptureTimelineAlignment {
        guard frameIndex >= anchorFrameIndex, captureNanos >= anchorCaptureNanos,
              lastFrame.map({ frameIndex > $0 }) ?? true else { return .stale }
        let frames = frameIndex - anchorFrameIndex
        let observed = Double(captureNanos - anchorCaptureNanos)
            - Double(frames) * 1_000_000_000 / Double(AudioPacket.sampleRate)
        guard abs(observed - offsetNanos) <= Double(LocalAudioSyncPolicy.thresholdNanos) else {
            return .discontinuous
        }
        let delta = frameIndex - (lastFrame ?? anchorFrameIndex)
        // Half-second low-pass, bounded even after many lost packets.
        let seconds = Double(delta) / Double(AudioPacket.sampleRate)
        let weight = min(0.25, seconds / (0.5 + seconds))
        offsetNanos += (observed - offsetNanos) * weight
        lastFrame = frameIndex
        return .aligned
    }
}

/// Shared bounded rate controller used by live playback and clock-skew tests.
public enum PlaybackRateCorrection {
    public static func next(previous: Double, errorSeconds: Double) -> Double {
        let desired = abs(errorSeconds) < 0.0005 ? 0 : max(-0.01, min(0.01, errorSeconds * 0.25))
        let smoothed = previous + (desired - previous) * 0.12
        return abs(smoothed) < 0.000_005 ? 0 : smoothed
    }
}
