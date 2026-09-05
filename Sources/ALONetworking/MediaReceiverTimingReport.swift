import Foundation
import ALOCore

/// Measurements, not authority to retime a room. Hardware floor excludes RTT;
/// network recommendations may include it. The host applies its shared policy.
public struct MediaReceiverTimingReport: Codable, Equatable, Sendable {
    public let hardwareOutputFloorNanos: UInt64
    public let networkRecommendedDelayNanos: UInt64
    public let roundTripNanos: UInt64?
    public let sampleAgeNanos: UInt64
    public static let maximumAgeNanos: UInt64 = 2_000_000_000

    public init(hardwareOutputFloorNanos: UInt64, networkRecommendedDelayNanos: UInt64,
                roundTripNanos: UInt64? = nil, sampleAgeNanos: UInt64 = 0) throws {
        self.hardwareOutputFloorNanos = hardwareOutputFloorNanos
        self.networkRecommendedDelayNanos = networkRecommendedDelayNanos
        self.roundTripNanos = roundTripNanos; self.sampleAgeNanos = sampleAgeNanos
        try validate()
    }
    func validate() throws {
        guard hardwareOutputFloorNanos >= 120_000_000,
              hardwareOutputFloorNanos <= RoomTiming.maximumPlayoutDelayNanos,
              networkRecommendedDelayNanos >= hardwareOutputFloorNanos,
              networkRecommendedDelayNanos <= RoomTiming.maximumPlayoutDelayNanos,
              roundTripNanos.map({ $0 <= Self.maximumAgeNanos }) ?? true,
              sampleAgeNanos <= Self.maximumAgeNanos else { throw SecureTransportError.malformed }
    }
    func aged(by elapsed: UInt64) -> Self? {
        guard elapsed <= Self.maximumAgeNanos - sampleAgeNanos else { return nil }
        return try? Self(hardwareOutputFloorNanos: hardwareOutputFloorNanos,
            networkRecommendedDelayNanos: networkRecommendedDelayNanos,
            roundTripNanos: roundTripNanos, sampleAgeNanos: sampleAgeNanos + elapsed)
    }
}
