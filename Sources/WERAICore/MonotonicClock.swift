import Darwin
import Foundation

public enum MonotonicClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func nowNanos() -> UInt64 {
        ticksToNanos(mach_absolute_time())
    }

    public static func ticksToNanos(_ ticks: UInt64) -> UInt64 {
        UInt64(Double(ticks) * Double(timebase.numer) / Double(timebase.denom))
    }

    public static func nanosToTicks(_ nanos: UInt64) -> UInt64 {
        UInt64(Double(nanos) * Double(timebase.denom) / Double(timebase.numer))
    }
}

public final class ClockSynchronizer {
    private struct Sample {
        let roundTripNanos: UInt64
        let offsetNanos: Int64
    }

    private var sentAt = [UInt64: UInt64]()
    private var samples = [Sample]()
    private var nextID: UInt64 = 0

    public private(set) var offsetNanos: Int64?
    public var sampleCount: Int { samples.count }
    public var isReady: Bool { sampleCount >= 4 }

    public init() {}

    public func makePing(at clientNanos: UInt64) -> ControlMessage {
        let id = nextID
        nextID &+= 1
        sentAt[id] = clientNanos
        return ControlMessage(type: "ping", id: id, clientNanos: clientNanos)
    }

    @discardableResult
    public func acceptPong(_ message: ControlMessage, receivedAt: UInt64) -> Bool {
        guard message.type == "pong",
              let id = message.id,
              let hostNanos = message.hostNanos,
              let startedAt = sentAt.removeValue(forKey: id),
              receivedAt >= startedAt
        else { return false }

        let roundTrip = receivedAt - startedAt
        let midpoint = startedAt + roundTrip / 2
        let offset = Int64(clamping: hostNanos) - Int64(clamping: midpoint)
        samples.append(Sample(roundTripNanos: roundTrip, offsetNanos: offset))
        if samples.count > 12 {
            samples.removeFirst(samples.count - 12)
        }

        let lowLatencyOffsets = samples
            .sorted { $0.roundTripNanos < $1.roundTripNanos }
            .prefix(min(4, samples.count))
            .map(\.offsetNanos)
            .sorted()
        guard !lowLatencyOffsets.isEmpty else { return false }
        let middle = lowLatencyOffsets.count / 2
        let estimate = lowLatencyOffsets.count.isMultiple(of: 2)
            ? lowLatencyOffsets[middle - 1] + (lowLatencyOffsets[middle] - lowLatencyOffsets[middle - 1]) / 2
            : lowLatencyOffsets[middle]

        if let current = offsetNanos {
            offsetNanos = current + (estimate - current) / 8
        } else {
            offsetNanos = estimate
        }
        return true
    }
}
