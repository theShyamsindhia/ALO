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
        return Int64(clamping: Int(modelOffsetNanos + modelDriftNanosPerSecond * elapsedSeconds))
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
            ? lowLatencyOffsets[middle - 1] + (lowLatencyOffsets[middle] - lowLatencyOffsets[middle - 1]) / 2
            : lowLatencyOffsets[middle]

        var estimatedDrift = 0.0
        var estimatedOffset = Double(medianOffset)
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
        offsetNanos = Int64(clamping: Int(modelOffsetNanos ?? estimatedOffset))
        driftPartsPerMillion = modelDriftNanosPerSecond / 1_000
    }

    private func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Double {
        lhs >= rhs ? Double(lhs - rhs) : -Double(rhs - lhs)
    }
}
