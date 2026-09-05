import Foundation
import Testing
@testable import ALO

@MainActor
struct ArenaRecordStoreTests {
    private let players = [ArenaRecordStore.Player(id: "alice", name: "Alice"), ArenaRecordStore.Player(id: "bob", name: "Bob")]

    @Test func countsRealResultsAndDeduplicatesPersistedRounds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("records.json")
        let store = ArenaRecordStore(url: url)
        #expect(store.standings().isEmpty)
        #expect(store.record(sessionID: "s1", round: 0, players: players, winnerID: "alice"))
        #expect(!store.record(sessionID: "s1", round: 0, players: players, winnerID: "bob"))
        #expect(store.record(sessionID: "s1", round: 1, players: players, winnerID: nil, isDraw: true))
        let reloaded = ArenaRecordStore(url: url)
        #expect(!reloaded.record(sessionID: "s1", round: 0, players: players, winnerID: "alice"))
        let alice = reloaded.standings().first { $0.id == "alice" }!
        let bob = reloaded.standings().first { $0.id == "bob" }!
        #expect(alice.played == 2 && alice.wins == 1 && alice.draws == 1)
        #expect(bob.played == 2 && bob.wins == 0 && bob.draws == 1)
    }

    @Test func excludesBotsPracticeAndInvalidWinners() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArenaRecordStore(url: directory.appendingPathComponent("records.json"))
        #expect(!store.record(sessionID: "practice", round: 0, players: players, winnerID: "alice", practice: true))
        let bots = [players[0], ArenaRecordStore.Player(id: "bot", name: "Bot", isBot: true)]
        #expect(!store.record(sessionID: "bots", round: 0, players: bots, winnerID: "alice"))
        #expect(!store.record(sessionID: "bad", round: 0, players: players, winnerID: "unknown"))
        #expect(!store.record(sessionID: "draw", round: 0, players: players, winnerID: "alice", isDraw: true))
        #expect(store.results.isEmpty)
    }

    @Test func fourPlayersAreTrackedByIdentityAndUseLatestName() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArenaRecordStore(url: directory.appendingPathComponent("records.json"))
        let four = players + [.init(id: "c", name: "Casey"), .init(id: "d", name: "Drew")]
        #expect(store.record(sessionID: "room4", round: 0, players: four, winnerID: "d"))
        let renamed = [ArenaRecordStore.Player(id: "alice", name: "New Alice"), players[1]]
        #expect(store.record(sessionID: "next", round: 0, players: renamed, winnerID: "alice"))
        #expect(store.standings().count == 4)
        #expect(store.standings().first(where: { $0.id == "alice" })?.name == "New Alice")
        #expect(store.standings().first(where: { $0.id == "d" })?.wins == 1)
    }
    @Test func twoHumanBotVictoryCountsPlayedWithoutInventingAHumanWin() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArenaRecordStore(url: directory.appendingPathComponent("records.json"))
        let result = ArenaMatchResult(sessionID: "mixed", round: 0, participantIDs: ["alice", "bob", nil], playerNames: ["Alice", "Bob", "Bot"], winner: 2, botSlots: [2])
        #expect(store.record(result))
        #expect(store.standings().count == 2)
        #expect(store.standings().allSatisfy { $0.played == 1 && $0.wins == 0 && $0.draws == 0 })
        let reloaded = ArenaRecordStore(url: directory.appendingPathComponent("records.json"))
        #expect(reloaded.standings() == store.standings())
        let training = ArenaMatchResult(sessionID: "training", round: 0, participantIDs: ["alice", nil], playerNames: ["Alice", "Bot"], winner: 0, botSlots: [1])
        #expect(!store.record(training))
    }

}
