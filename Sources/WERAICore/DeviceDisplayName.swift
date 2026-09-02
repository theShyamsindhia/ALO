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
