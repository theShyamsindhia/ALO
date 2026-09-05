import Foundation

/// A small, independently versioned room preference. Older clients can ignore
/// its envelope without changing how they decode chat or playback history.
public struct RoomIcon: Codable, Sendable, Equatable, Hashable {
    public static let choices: [(symbol: String, name: String)] = [
        ("person.3.fill", "People"), ("music.note", "Music"),
        ("headphones", "Headphones"), ("film.fill", "Movies"),
        ("tv.fill", "Television"), ("gamecontroller.fill", "Games"),
        ("moon.fill", "After hours"), ("sun.max.fill", "Daytime"),
        ("leaf.fill", "Quiet"), ("cup.and.saucer.fill", "Coffee"),
        ("heart.fill", "Favorites"), ("star.fill", "Star")
    ]

    public let symbol: String
    public let version: MeshVersion

    public init(symbol: String, version: MeshVersion) {
        self.symbol = symbol
        self.version = version
    }

    public var isValid: Bool {
        Self.choices.contains { $0.symbol == symbol }
            && version.counter > 0 && version.counter < UInt64.max
            && !version.nodeID.isEmpty && version.nodeID.utf8.count <= 128
    }

    public func supersedes(_ previous: RoomIcon?) -> Bool {
        guard isValid else { return false }
        guard let previous, previous.isValid else { return true }
        return previous.version == version ? previous.symbol < symbol : previous.version < version
    }
}
