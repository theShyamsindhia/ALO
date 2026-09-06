import Foundation

/// A peer's own measurements relative to the active broadcaster, never a local ping proxy.
public struct PeerPlaybackTiming: Codable, Sendable, Equatable {
    public let roundTripMilliseconds: Double?
    public let driftMilliseconds: Double?

    public init(roundTripMilliseconds: Double?, driftMilliseconds: Double?) {
        self.roundTripMilliseconds = roundTripMilliseconds
        self.driftMilliseconds = driftMilliseconds
    }

    public var isValid: Bool {
        (roundTripMilliseconds.map { $0.isFinite && (0...60_000).contains($0) } ?? true)
        && (driftMilliseconds.map { $0.isFinite && abs($0) <= 60_000 } ?? true)
    }

    public static let unavailable = Self(roundTripMilliseconds: nil, driftMilliseconds: nil)

    public func isFresh(receivedAt: UInt64, now: UInt64) -> Bool {
        now >= receivedAt && now - receivedAt <= 3_000_000_000
    }
}
