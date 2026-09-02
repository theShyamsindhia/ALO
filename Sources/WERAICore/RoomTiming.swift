import Foundation

public enum RoomTiming {
    public static let defaultPlayoutDelayNanos: UInt64 = 250_000_000
    public static let maximumPlayoutDelayNanos: UInt64 = 600_000_000
    public static let timingStepNanos: UInt64 = 5_000_000

    public static func clampedPlayoutDelay(_ nanos: UInt64) -> UInt64 {
        min(max(nanos, defaultPlayoutDelayNanos), maximumPlayoutDelayNanos)
    }
}

public final class NetworkJitterEstimator {
    private var transitSamples = [UInt64]()

    public var sampleCount: Int { transitSamples.count }

    public init() {}

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

    public func recommendedPlayoutDelayNanos(roundTripNanos: UInt64?) -> UInt64 {
        guard transitSamples.count >= 40 else {
            return RoomTiming.defaultPlayoutDelayNanos
        }

        let halfRoundTrip = (roundTripNanos ?? 0) / 2
        let networkBudget = 120_000_000
            &+ halfRoundTrip
            &+ min(jitterNanos, 100_000_000) &* 4
        let clamped = RoomTiming.clampedPlayoutDelay(networkBudget)
        let step = RoomTiming.timingStepNanos
        return ((clamped + step - 1) / step) * step
    }

    private func percentile(_ percentile: Double, in sorted: [UInt64]) -> UInt64 {
        let index = Int((Double(sorted.count - 1) * percentile).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
