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
