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
    private static let maximumPendingProbes = 64
    private static let probeLifetimeNanos: UInt64 = 30_000_000_000
    private struct Sample {
        let clientMidpointNanos: UInt64
        let roundTripNanos: UInt64
        let offsetNanos: Int64
    }

    private var sentAt = [UInt64: UInt64]()
    private var samples = [Sample]()
    private var nextID: UInt64 = 0
    private var modelReferenceNanos: UInt64?
    private var modelOffsetNanos: Double?
    private var modelDriftNanosPerSecond: Double = 0

    public private(set) var offsetNanos: Int64?
    public private(set) var driftPartsPerMillion: Double = 0
    public private(set) var bestRoundTripNanos: UInt64?
    public var sampleCount: Int { samples.count }
    public var isReady: Bool { sampleCount >= 4 }

    public init() {}

    /// Discards all timing learned from the current host. A reconnect may be
    /// served by a different Mac whose monotonic clock has a different epoch.
    public func reset() {
        sentAt.removeAll()
        samples.removeAll()
        nextID = 0
        modelReferenceNanos = nil
        modelOffsetNanos = nil
        modelDriftNanosPerSecond = 0
        offsetNanos = nil
        driftPartsPerMillion = 0
        bestRoundTripNanos = nil
    }

    public func makePing(at clientNanos: UInt64) -> ControlMessage {
        sentAt = sentAt.filter { _, started in
            clientNanos >= started && clientNanos - started <= Self.probeLifetimeNanos
        }
        if sentAt.count >= Self.maximumPendingProbes,
           let oldest = sentAt.min(by: { lhs, rhs in
               lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
           })?.key {
            sentAt.removeValue(forKey: oldest)
        }
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
              receivedAt >= startedAt,
              receivedAt - startedAt <= Self.probeLifetimeNanos
        else { return false }

        let roundTrip = receivedAt - startedAt
        let midpoint = startedAt + roundTrip / 2
        let offset = Int64(clamping: hostNanos) - Int64(clamping: midpoint)
        samples.append(Sample(
            clientMidpointNanos: midpoint,
            roundTripNanos: roundTrip,
            offsetNanos: offset
        ))
        if samples.count > 120 {
            samples.removeFirst(samples.count - 120)
        }
        bestRoundTripNanos = samples.map(\.roundTripNanos).min()
        updateModel(referenceNanos: midpoint)
        return true
    }

    public func offsetNanos(at clientNanos: UInt64) -> Int64? {
        guard let reference = modelReferenceNanos, let modelOffsetNanos else {
            return offsetNanos
        }
        let elapsedSeconds = signedDifference(clientNanos, reference) / 1_000_000_000
        return clampedOffset(modelOffsetNanos + modelDriftNanosPerSecond * elapsedSeconds)
    }

    private func updateModel(referenceNanos: UInt64) {
        let retainedCount = min(samples.count, max(4, (samples.count + 1) / 2))
        let candidates = samples
            .sorted { $0.roundTripNanos < $1.roundTripNanos }
            .prefix(retainedCount)
            .sorted { $0.clientMidpointNanos < $1.clientMidpointNanos }
        guard !candidates.isEmpty else { return }

        let lowLatencyOffsets = candidates
            .map(\.offsetNanos)
            .sorted()
        let middle = lowLatencyOffsets.count / 2
        let medianOffset = lowLatencyOffsets.count.isMultiple(of: 2)
            ? Double(lowLatencyOffsets[middle - 1]) / 2 + Double(lowLatencyOffsets[middle]) / 2
            : Double(lowLatencyOffsets[middle])

        var estimatedDrift = 0.0
        var estimatedOffset = medianOffset
        if candidates.count >= 6,
           let first = candidates.first,
           let last = candidates.last,
           last.clientMidpointNanos - first.clientMidpointNanos >= 5_000_000_000 {
            let xs = candidates.map { signedDifference($0.clientMidpointNanos, referenceNanos) / 1_000_000_000 }
            let ys = candidates.map { Double($0.offsetNanos) }
            let meanX = xs.reduce(0, +) / Double(xs.count)
            let meanY = ys.reduce(0, +) / Double(ys.count)
            let variance = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
            if variance > 0 {
                let covariance = zip(xs, ys).reduce(0) {
                    $0 + ($1.0 - meanX) * ($1.1 - meanY)
                }
                estimatedDrift = max(-500_000, min(500_000, covariance / variance))
                estimatedOffset = meanY + estimatedDrift * (0 - meanX)
            }
        }

        if let oldReference = modelReferenceNanos,
           let oldOffset = modelOffsetNanos {
            let oldAtReference = oldOffset
                + modelDriftNanosPerSecond * signedDifference(referenceNanos, oldReference) / 1_000_000_000
            modelOffsetNanos = oldAtReference + (estimatedOffset - oldAtReference) / 5
            modelDriftNanosPerSecond += (estimatedDrift - modelDriftNanosPerSecond) / 5
        } else {
            modelOffsetNanos = estimatedOffset
            modelDriftNanosPerSecond = estimatedDrift
        }
        modelReferenceNanos = referenceNanos
        offsetNanos = clampedOffset(modelOffsetNanos ?? estimatedOffset)
        driftPartsPerMillion = modelDriftNanosPerSecond / 1_000
    }

    private func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Double {
        lhs >= rhs ? Double(lhs - rhs) : -Double(rhs - lhs)
    }

    private func clampedOffset(_ value: Double) -> Int64 {
        // Double(Int64.max) rounds up to 2^63. Converting to Int before
        // clamping therefore traps even for an otherwise valid Int64 sample.
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }
}
