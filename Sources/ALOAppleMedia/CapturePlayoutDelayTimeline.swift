import Foundation
import ALOCore

/// Committed audio cutovers expressed in the capture clock, not arrival order.
/// Decode completion can cross a cutover, so old frames retain their old delay.
public struct CapturePlayoutDelayTimeline: Sendable {
    private var initialDelay = RoomTiming.defaultPlayoutDelayNanos
    private var boundaries: [(capture: UInt64, delay: UInt64)] = []
    private var oldestCapture: UInt64?
    public init() {}
    public mutating func reset(delayNanos: UInt64 = RoomTiming.defaultPlayoutDelayNanos) {
        initialDelay = RoomTiming.clampedPlayoutDelay(delayNanos)
        boundaries.removeAll(); oldestCapture = nil
    }
    public mutating func stage(captureTimeNanos: UInt64, delayNanos: UInt64) {
        let delay = RoomTiming.clampedPlayoutDelay(delayNanos)
        guard boundaries.last.map({ captureTimeNanos >= $0.capture }) ?? true else { return }
        guard (boundaries.last?.delay ?? initialDelay) != delay else { return }
        if boundaries.last?.capture == captureTimeNanos { boundaries.removeLast() }
        boundaries.append((captureTimeNanos, delay))
        if boundaries.count > 8 {
            let retired = boundaries.removeFirst()
            initialDelay = retired.delay; oldestCapture = retired.capture
        }
    }
    public func delay(forCapture captureTimeNanos: UInt64) -> UInt64? {
        guard oldestCapture.map({ captureTimeNanos >= $0 }) ?? true else { return nil }
        return boundaries.last(where: { captureTimeNanos >= $0.capture })?.delay ?? initialDelay
    }
}
