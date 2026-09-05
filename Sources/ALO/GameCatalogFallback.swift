import Foundation
import ALOCore

// Tiny offline catalog metadata; game artwork/content is downloaded on demand.
enum GameCatalogFallback {
    static let games = [
        GamePackDescriptor(id: "rift-arena", engine: "rift-arena-v4", title: "Rift Arena", summary: "A room platform fighter for up to four players. Add bots, join a round, or watch.", version: 4, url: URL(string: "https://raw.githubusercontent.com/theShyamsindhia/ALO/main/GamePacks/rift-arena/4/pack.json")!, sha256: "19e17c9c654226e74ef8106969febc45a8b40bc6b5447ebd1de70f694c79dfae", bytes: 3600252),
        GamePackDescriptor(id: "fourfold", engine: "fourfold-v1", title: "Fourfold", summary: "A four-in-a-row board game. Play the bot or pass and play on this Mac.", version: 1, url: URL(string: "https://raw.githubusercontent.com/theShyamsindhia/ALO/main/GamePacks/fourfold/1/pack.json")!, sha256: "cf8ac91fd87854d95e71b4e40a1bdd53335c866ed037ebd04a1f05966868b5ed", bytes: 157),
    ]
}
