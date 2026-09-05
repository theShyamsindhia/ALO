import Foundation
import ALOCore

// Tiny offline catalog metadata; game artwork/content is downloaded on demand.
enum GameCatalogFallback {
    static let games = [
        GamePackDescriptor(id: "rift-arena", engine: "rift-arena-v1", title: "Rift Arena", summary: "A two-player platform fighter. Practice, invite a room member, or watch a duel.", version: 1, url: URL(string: "https://raw.githubusercontent.com/theShyamsindhia/ALO/main/GamePacks/rift-arena/1/pack.json")!, sha256: "6a72774fffa5fc181fec62df562cc0ffaff490ca951d3d0edd214793de8a9eda", bytes: 876074),
        GamePackDescriptor(id: "fourfold", engine: "fourfold-v1", title: "Fourfold", summary: "A four-in-a-row board game. Play the bot or pass and play on this Mac.", version: 1, url: URL(string: "https://raw.githubusercontent.com/theShyamsindhia/ALO/main/GamePacks/fourfold/1/pack.json")!, sha256: "cf8ac91fd87854d95e71b4e40a1bdd53335c866ed037ebd04a1f05966868b5ed", bytes: 157),
    ]
}
