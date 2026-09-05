import Foundation
import ALOCore

/// Measurements, not authority to retime a room. Hardware floor excludes RTT;
/// network recommendations may include it. The host applies its shared policy.
public struct MediaReceiverTimingReport: Codable, Equatable, Sendable {
    public let hardwareOutputFloorNanos: UInt64
    public let networkRecommendedDelayNanos: UInt64
    public let roundTripNanos: UInt64?
    public let sampleAgeNanos: UInt64
    /// Relative render measurements only. measuredAtNanos is normalized to zero;
    /// the host uses its receipt time, never the receiver's absolute uptime.
    /// Nested ages include queue aging; add only time elapsed since host receipt.
    public let playback: PlaybackSyncReport?
    public static let maximumAgeNanos: UInt64 = 2_000_000_000

    public init(hardwareOutputFloorNanos: UInt64, networkRecommendedDelayNanos: UInt64,
                roundTripNanos: UInt64? = nil, sampleAgeNanos: UInt64 = 0,
                playback: PlaybackSyncReport? = nil) throws {
        self.hardwareOutputFloorNanos = hardwareOutputFloorNanos
        self.networkRecommendedDelayNanos = networkRecommendedDelayNanos
        self.roundTripNanos = roundTripNanos; self.sampleAgeNanos = sampleAgeNanos
        self.playback = Self.sanitize(playback, elapsed: 0)
        try validate()
    }
    func validate() throws {
        guard hardwareOutputFloorNanos >= 120_000_000,
              hardwareOutputFloorNanos <= RoomTiming.maximumPlayoutDelayNanos,
              networkRecommendedDelayNanos >= hardwareOutputFloorNanos,
              networkRecommendedDelayNanos <= RoomTiming.maximumPlayoutDelayNanos,
              roundTripNanos.map({ $0 <= Self.maximumAgeNanos }) ?? true,
              sampleAgeNanos <= Self.maximumAgeNanos else { throw SecureTransportError.malformed }
        guard playback == Self.sanitize(playback, elapsed: 0) else { throw SecureTransportError.malformed }
    }
    func aged(by elapsed: UInt64) -> Self? {
        guard elapsed <= Self.maximumAgeNanos - sampleAgeNanos else { return nil }
        return try? Self(hardwareOutputFloorNanos: hardwareOutputFloorNanos,
            networkRecommendedDelayNanos: networkRecommendedDelayNanos,
            roundTripNanos: roundTripNanos, sampleAgeNanos: sampleAgeNanos + elapsed,
            playback: Self.sanitize(playback, elapsed: elapsed))
    }
    func normalized() throws -> Self {
        try Self(hardwareOutputFloorNanos: hardwareOutputFloorNanos, networkRecommendedDelayNanos: networkRecommendedDelayNanos,
                 roundTripNanos: roundTripNanos, sampleAgeNanos: sampleAgeNanos, playback: playback)
    }
    private static func sanitize(_ value: PlaybackSyncReport?, elapsed: UInt64) -> PlaybackSyncReport? {
        guard let value else { return nil }
        let maximum: UInt64 = 60_000_000_000
        func age(_ old: UInt64?) -> UInt64? {
            old.map { min($0, maximum) + min(elapsed, maximum - min($0, maximum)) }
        }
        let driftAge = age(value.driftSampleAgeNanos)
        let driftFresh = value.driftNanos != nil && driftAge.map { $0 <= maximumAgeNanos } == true
        let screen = value.screenTiming.map { screen in
            PlaybackScreenTimingReport(latestHandoffAgeNanos: age(screen.latestHandoffAgeNanos),
                latestDeadlineMissNanos: screen.latestHandoffAgeNanos == nil ? nil : screen.latestDeadlineMissNanos.map { min($0, maximum) },
                oldestPendingDeadlineMissNanos: screen.oldestPendingDeadlineMissNanos.map { min($0, maximum) })
        }
        return PlaybackSyncReport(measuredAtNanos: 0, latenessNanos: min(value.latenessNanos, maximum),
            latePacketCount: min(value.latePacketCount, UInt64(Int64.max)), resyncCount: min(value.resyncCount, UInt64(Int64.max)),
            driftNanos: driftFresh ? value.driftNanos.map { min($0, maximum) } : nil,
            driftSampleAgeNanos: driftFresh ? driftAge : nil, screenTiming: screen)
    }
}
