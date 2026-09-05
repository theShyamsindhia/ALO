import CryptoKit
import Foundation

/// Downloadable packs contain presentation data only. Native engine behavior ships with ALO.
public struct GamePackDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let engine: String
    public let title: String
    public let summary: String
    public let version: Int
    public let url: URL
    public let sha256: String
    public let bytes: Int
    public init(id: String, engine: String, title: String, summary: String, version: Int, url: URL, sha256: String, bytes: Int) {
        self.id = id; self.engine = engine; self.title = title; self.summary = summary
        self.version = version; self.url = url; self.sha256 = sha256; self.bytes = bytes
    }
    public var supported: Bool {
        (id == "rift-arena" && engine == "rift-arena-v1") || (id == "fourfold" && engine == "fourfold-v1")
    }
    public func validate() throws {
        guard Self.validID(id), title.count <= 80, !title.isEmpty, summary.count <= 500,
              engine.count <= 80, version > 0, version < 1_000_000,
              bytes > 0, bytes <= GamePackContent.maximumBytes,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              GameCatalog.isTrustedURL(url) else { throw GamePackError.invalidManifest }
    }
    public static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 60 && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}

public struct GameCatalog: Codable, Sendable {
    public static let maximumBytes = 65_536
    public static let url = URL(string: "https://raw.githubusercontent.com/theShyamsindhia/ALO/main/GamePacks/catalog.json")!
    public let schemaVersion: Int
    public let games: [GamePackDescriptor]
    public init(games: [GamePackDescriptor]) { schemaVersion = 1; self.games = games }
    public static func isTrustedURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "raw.githubusercontent.com" && url.port == nil
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
            && url.path.hasPrefix("/theShyamsindhia/ALO/main/GamePacks/")
            && !url.pathComponents.contains("..")
    }
    public static func decode(_ data: Data) throws -> GameCatalog {
        guard data.count <= maximumBytes else { throw GamePackError.tooLarge }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, catalog.games.count <= 24,
              Set(catalog.games.map(\.id)).count == catalog.games.count else { throw GamePackError.invalidManifest }
        try catalog.games.forEach { try $0.validate() }
        return catalog
    }
}

public struct GamePackContent: Codable, Sendable, Equatable {
    public static let maximumBytes = 16 * 1_024 * 1_024
    public let schemaVersion: Int
    public let id: String
    public let engine: String
    public let version: Int
    public let arenaName: String
    public let subtitle: String
    public let accentHex: String
    public let backgroundImageBase64: String?
    public let fighterImageBase64: String?
    public var backgroundImageData: Data? { backgroundImageBase64.flatMap { Data(base64Encoded: $0) } }
    public var fighterImageData: Data? { fighterImageBase64.flatMap { Data(base64Encoded: $0) } }
    public init(id: String, engine: String, version: Int, arenaName: String, subtitle: String, accentHex: String, backgroundImageBase64: String? = nil, fighterImageBase64: String? = nil) {
        schemaVersion = 1; self.id = id; self.engine = engine; self.version = version
        self.arenaName = arenaName; self.subtitle = subtitle; self.accentHex = accentHex
        self.backgroundImageBase64 = backgroundImageBase64
        self.fighterImageBase64 = fighterImageBase64
    }
    public static func verify(_ data: Data, descriptor: GamePackDescriptor) throws -> GamePackContent {
        try descriptor.validate()
        guard descriptor.supported else { throw GamePackError.unsupportedEngine }
        guard data.count == descriptor.bytes, data.count <= maximumBytes else { throw GamePackError.sizeMismatch }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == descriptor.sha256 else { throw GamePackError.checksumMismatch }
        let pack = try JSONDecoder().decode(Self.self, from: data)
        guard pack.schemaVersion == 1, pack.id == descriptor.id, pack.engine == descriptor.engine,
              pack.version == descriptor.version, !pack.arenaName.isEmpty, pack.arenaName.count <= 80,
              pack.subtitle.count <= 500, pack.accentHex.count == 6,
              pack.accentHex.allSatisfy(\.isHexDigit) else { throw GamePackError.invalidPack }
        for image in [pack.backgroundImageBase64, pack.fighterImageBase64].compactMap({ $0 }) {
            guard let decoded = Data(base64Encoded: image), !decoded.isEmpty, decoded.count <= 10 * 1_024 * 1_024 else { throw GamePackError.invalidPack }
            let png = decoded.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            let jpeg = decoded.starts(with: [255, 216, 255])
            guard png || jpeg else { throw GamePackError.invalidPack }
        }
        return pack
    }
}

public struct InstalledGamePack: Sendable {
    public let descriptor: GamePackDescriptor
    public let content: GamePackContent
    public init(descriptor: GamePackDescriptor, content: GamePackContent) { self.descriptor = descriptor; self.content = content }
}

public enum GamePackError: Error, LocalizedError {
    case invalidManifest, tooLarge, sizeMismatch, checksumMismatch, invalidPack, unsupportedEngine, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "The game catalog could not be verified. Try refreshing it."
        case .tooLarge, .sizeMismatch: return "The download size did not match this game pack. Please retry."
        case .checksumMismatch: return "The game pack did not pass verification. Nothing was installed."
        case .invalidPack: return "This game pack contains unsupported or damaged content."
        case .unsupportedEngine: return "Update ALO to play this game."
        case .http: return "The download is unavailable right now. Check your connection and retry."
        }
    }
}
