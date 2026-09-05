import Foundation
import ALOCore

/// Queue-owned measurements policy, separate from the future playback transaction.
/// A late/CPU-starved joiner cannot vote its network delay onto established peers;
/// genuine fresh hardware latency still applies to every synchronized output.
public struct SecureRoomTimingPolicy: Sendable {
    public struct Measurement: Sendable {
        public let peerID: UUID
        public let report: MediaReceiverTimingReport
        public let ageNanos: UInt64
        public let receivedElapsedNanos: UInt64
        public let isNetworkTimingEligible: Bool
    }
    private struct Sample: Sendable { let report: MediaReceiverTimingReport; let received: UInt64 }
    private var reports: [UUID: Sample] = [:]
    private var captureStartedAt: UInt64?
    private var cohort: Set<UUID>?
    public init() {}
    public mutating func remove(peer: UUID) { reports.removeValue(forKey: peer) }

    public func measurements(at now: UInt64) -> [Measurement] {
        reports.compactMap { peer, sample in
            guard now >= sample.received, now - sample.received <= MediaReceiverTimingReport.maximumAgeNanos,
                  sample.report.sampleAgeNanos <= MediaReceiverTimingReport.maximumAgeNanos - (now - sample.received) else { return nil }
            return Measurement(peerID: peer, report: sample.report,
                ageNanos: now - sample.received + sample.report.sampleAgeNanos,
                receivedElapsedNanos: now - sample.received,
                isNetworkTimingEligible: cohort?.contains(peer) ?? true)
        }.sorted { $0.peerID.uuidString < $1.peerID.uuidString }
    }

    public mutating func captureStarted(at now: UInt64) {
        if captureStartedAt == nil { captureStartedAt = now }
    }

    public mutating func record(peer: UUID, report: MediaReceiverTimingReport, receivedAt now: UInt64) {
        freezeCohortIfNeeded(now: now)
        expire(now: now)
        guard reports[peer] != nil || reports.count < 64 else { return }
        reports[peer] = Sample(report: report, received: now)
    }

    public mutating func desiredDelay(now: UInt64, current: UInt64,
                                     localHardwareFloor: UInt64, playing: Bool) -> UInt64 {
        freezeCohortIfNeeded(now: now)
        expire(now: now)
        let recommendations = reports.compactMap { peer, sample -> UInt64? in
            guard cohort?.contains(peer) ?? true else { return nil }
            return sample.report.networkRecommendedDelayNanos
        }.sorted()
        let network = recommendations.isEmpty ? RoomTiming.defaultPlayoutDelayNanos
            : recommendations[(recommendations.count - 1) / 2]
        let hardware = max(RoomTiming.clampedPlayoutDelay(localHardwareFloor),
            reports.values.map { $0.report.hardwareOutputFloorNanos }.max() ?? RoomTiming.defaultPlayoutDelayNanos)
        let required = max(network, hardware)
        if required > current {
            return playing && captureStartedAt != nil ? RoomTiming.liveIncreasePlayoutDelay(required: required) : required
        }
        return playing ? current : RoomTiming.pausedPlayoutDelay(required: required, current: current)
    }

    private mutating func freezeCohortIfNeeded(now: UInt64) {
        guard cohort == nil, let start = captureStartedAt, now >= start,
              now - start >= 1_000_000_000 else { return }
        // Freeze before adding a new report at/after the established boundary.
        cohort = Set(reports.keys)
    }

    private mutating func expire(now: UInt64) {
        reports = reports.filter { _, sample in
            now >= sample.received && now - sample.received <= MediaReceiverTimingReport.maximumAgeNanos
                && sample.report.sampleAgeNanos <= MediaReceiverTimingReport.maximumAgeNanos - (now - sample.received)
        }
    }
}
