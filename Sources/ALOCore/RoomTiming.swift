import Foundation

public enum RoomTiming {
    public static let defaultPlayoutDelayNanos: UInt64 = 250_000_000
    public static let maximumPlayoutDelayNanos: UInt64 = 600_000_000
    public static let timingStepNanos: UInt64 = 5_000_000
    public static let renderSchedulingHeadroomNanos: UInt64 = 25_000_000

    public static func clampedPlayoutDelay(_ nanos: UInt64) -> UInt64 {
        min(max(nanos, defaultPlayoutDelayNanos), maximumPlayoutDelayNanos)
    }

    /// Round up to a 50 ms boundary and reserve another 50 ms when moving an
    /// audible timeline forward (50–<100 ms extra, capped at the room maximum).
    /// This cushions small successive latency reports without restarting every
    /// output for each report; it does not assert a hardware-specific cause.
    /// This margin is applied only on a real increase, never cumulatively to
    /// reports already covered by the current shared buffer.
    public static func liveIncreasePlayoutDelay(required nanos: UInt64) -> UInt64 {
        let step: UInt64 = 50_000_000
        let required = clampedPlayoutDelay(nanos)
        let rounded = ((required + step - 1) / step) * step
        return min(maximumPlayoutDelayNanos, rounded + step)
    }

    /// Keep the existing allowance across short pauses. Only a material drop
    /// reduces it; a return to the default budget removes it completely.
    public static func pausedPlayoutDelay(required nanos: UInt64, current: UInt64) -> UInt64 {
        let required = clampedPlayoutDelay(nanos)
        if required == defaultPlayoutDelayNanos { return required }
        return min(clampedPlayoutDelay(current), liveIncreasePlayoutDelay(required: required))
    }

    public static func outputLatencyFloor(
        _ outputLatencyNanos: UInt64,
        roundTripNanos _: UInt64? = nil,
        renderSchedulingHeadroomNanos: UInt64 = renderSchedulingHeadroomNanos
    ) -> UInt64 {
        // This field bypasses network consensus because genuine output latency
        // must be accommodated by every synchronized output. RTT belongs only
        // in NetworkJitterEstimator's recommendation; including it here lets a
        // single late/slow peer repeatedly retime the whole established room.
        // Retain the argument label for source compatibility with callers.
        let required = 120_000_000
            &+ min(outputLatencyNanos, maximumPlayoutDelayNanos)
            &+ min(renderSchedulingHeadroomNanos, maximumPlayoutDelayNanos)
        let clamped = clampedPlayoutDelay(required)
        return ((clamped + timingStepNanos - 1) / timingStepNanos) * timingStepNanos
    }
}

public final class NetworkJitterEstimator {
    private var transitSamples = [UInt64]()

    public var sampleCount: Int { transitSamples.count }

    public init() {}

    public func reset() {
        transitSamples.removeAll(keepingCapacity: true)
    }

    public func observe(
        captureTimeNanos: UInt64,
        receivedAt clientNanos: UInt64,
        clockOffsetNanos: Int64
    ) {
        let hostArrivalNanos: UInt64
        if clockOffsetNanos >= 0 {
            hostArrivalNanos = clientNanos &+ UInt64(clockOffsetNanos)
        } else {
            let magnitude = UInt64(-clockOffsetNanos)
            hostArrivalNanos = clientNanos > magnitude ? clientNanos - magnitude : 0
        }
        guard hostArrivalNanos >= captureTimeNanos else { return }

        transitSamples.append(hostArrivalNanos - captureTimeNanos)
        if transitSamples.count > 500 {
            transitSamples.removeFirst(100)
        }
    }

    public var jitterNanos: UInt64 {
        guard transitSamples.count >= 20 else { return 0 }
        let sorted = transitSamples.sorted()
        let low = percentile(0.05, in: sorted)
        let high = percentile(0.95, in: sorted)
        return high > low ? high - low : 0
    }

    public func recommendedPlayoutDelayNanos(
        roundTripNanos: UInt64?,
        outputLatencyNanos: UInt64 = 0,
        renderSchedulingHeadroomNanos: UInt64 = RoomTiming.renderSchedulingHeadroomNanos
    ) -> UInt64 {
        let halfRoundTrip = (roundTripNanos ?? 0) / 2
        let jitterBudget = transitSamples.count >= 40
            ? min(jitterNanos, 100_000_000) &* 4
            : 0
        // `targetLatencyNanos` describes when audio should be audible. The
        // renderer must start earlier by the hardware presentation latency;
        // Bluetooth output can consume most of the old fixed 250 ms budget.
        let audibleBudget = 120_000_000
            &+ halfRoundTrip
            &+ jitterBudget
            &+ min(outputLatencyNanos, RoomTiming.maximumPlayoutDelayNanos)
            &+ renderSchedulingHeadroomNanos
        let clamped = RoomTiming.clampedPlayoutDelay(audibleBudget)
        let step = RoomTiming.timingStepNanos
        return ((clamped + step - 1) / step) * step
    }

    private func percentile(_ percentile: Double, in sorted: [UInt64]) -> UInt64 {
        let index = Int((Double(sorted.count - 1) * percentile).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
