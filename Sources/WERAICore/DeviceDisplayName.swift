import Foundation

public enum DeviceDisplayName {
    private static let adjectives = [
        "amber", "bold", "brisk", "calm", "clever", "cosmic", "crisp", "daring",
        "eager", "electric", "gentle", "golden", "happy", "jolly", "kind", "lively",
        "lucky", "mellow", "nimble", "quiet", "rapid", "silver", "steady", "vivid",
    ]

    private static let nouns = [
        "badger", "comet", "dolphin", "falcon", "fox", "gecko", "heron", "koala",
        "lynx", "meteor", "otter", "panda", "puffin", "raven", "rocket", "seal",
        "sparrow", "tiger", "turtle", "walrus", "whale", "wolf", "wombat", "yak",
    ]

    public static func generated(from stableID: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stableID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let adjective = adjectives[Int(hash % UInt64(adjectives.count))]
        let noun = nouns[Int((hash / UInt64(adjectives.count)) % UInt64(nouns.count))]
        let suffix = String(format: "%03x", hash & 0xFFF)
        return "\(adjective)-\(noun)-\(suffix)"
    }
}

public struct DeviceAppearance: Sendable, Equatable {
    public static let icons = [
        "🐶", "🐱", "🦊", "🐼", "🐸", "🐙", "🦄", "🦋",
        "🐯", "🐨", "🐧", "🦉", "🐬", "🐳", "🦖", "🤖",
    ]
    public static let colors = [
        "E45B69", "7C6FF2", "2AA7A1", "E2903A", "3F86E8", "A95BC4", "5A9A54", "D9578B",
    ]
    public static let maximumProfileImageBytes = 16 * 1_024

    public let icon: String
    public let colorHex: String

    public init(icon: String, colorHex: String) {
        self.icon = Self.icons.contains(icon) ? icon : Self.icons[0]
        self.colorHex = Self.colors.contains(colorHex.uppercased()) ? colorHex.uppercased() : Self.colors[0]
    }

    public static func generated(from stableID: String) -> Self {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stableID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Self(
            icon: icons[Int(hash % UInt64(icons.count))],
            colorHex: colors[Int((hash / UInt64(icons.count)) % UInt64(colors.count))]
        )
    }

    public static func sanitizedProfileImageData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= maximumProfileImageBytes else { return nil }
        return data
    }
}
