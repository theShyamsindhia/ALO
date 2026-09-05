import Foundation
import Combine
import ALOCore

/// A bounded local result history. Only completed room matches with at least two
/// people count. Bots have no standing; training and unfinished games never count.
@MainActor
final class ArenaRecordStore: ObservableObject {
    static let shared = ArenaRecordStore()
    struct Player: Codable, Equatable, Sendable {
        let id: String
        let name: String
        var isBot = false
    }
    struct Result: Codable, Equatable, Sendable {
        let gameID: String
        let sessionID: String
        let round: Int
        let players: [Player]
        let winnerID: String?
        let isDraw: Bool
        let winnerWasBot: Bool?
        let completedAt: Date
        var key: String { "\(gameID)/\(sessionID)/\(round)" }
        var valid: Bool {
            !gameID.isEmpty && gameID.count <= 100 && !sessionID.isEmpty && sessionID.count <= 128 && (0...10_000).contains(round)
                && (2...4).contains(players.count) && Set(players.map(\.id)).count == players.count
                && players.allSatisfy { !$0.isBot && !$0.id.isEmpty && $0.id.count <= 128 && !$0.name.isEmpty && $0.name.count <= 128 }
                && (isDraw ? winnerID == nil && winnerWasBot != true : winnerWasBot == true ? winnerID == nil : winnerID.map { id in players.contains { $0.id == id } } == true)
        }
    }
    struct Standing: Identifiable, Equatable {
        let id: String
        var name: String
        var played = 0
        var wins = 0
        var draws = 0
    }
    static let maximumResults = 1000
    @Published private(set) var results: [Result] = []
    @Published private(set) var lastError: String?
    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ALO/GameRecords.json")
        guard let size = try? self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
              let data = try? Data(contentsOf: self.url), let loaded = try? JSONDecoder().decode([Result].self, from: data) else { return }
        var keys = Set<String>()
        results = Array(loaded.filter { $0.valid && keys.insert($0.key).inserted }.suffix(Self.maximumResults))
    }

    @discardableResult
    func record(gameID: String = "rift-arena", sessionID: String, round: Int, players: [Player], winnerID: String?, isDraw: Bool = false, practice: Bool = false, winnerWasBot: Bool = false) -> Bool {
        guard !practice else { return false }
        let result = Result(gameID: gameID, sessionID: sessionID, round: round, players: players, winnerID: winnerID, isDraw: isDraw, winnerWasBot: winnerWasBot, completedAt: Date())
        guard result.valid, !results.contains(where: { $0.key == result.key }) else { return false }
        var next = Array((results + [result]).suffix(Self.maximumResults))
        do {
            var data = try JSONEncoder().encode(next)
            while data.count > 2_000_000 && next.count > 1 {
                let excess = max(1, Int(ceil(Double(data.count - 2_000_000) / Double(data.count) * Double(next.count))))
                next.removeFirst(min(excess, next.count - 1))
                data = try JSONEncoder().encode(next)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            results = next; lastError = nil
            return true
        } catch {
            lastError = "This match result could not be saved on this Mac."
            return false
        }
    }

    @discardableResult
    func record(_ result: ArenaMatchResult) -> Bool {
        guard result.participantIDs.count == result.playerNames.count,
              (2...4).contains(result.participantIDs.count),
              result.winner == -1 || result.participantIDs.indices.contains(result.winner) else { return false }
        let humanSlots = result.participantIDs.indices.filter { !result.botSlots.contains($0) }
        guard humanSlots.count >= 2, humanSlots.allSatisfy({ result.participantIDs[$0] != nil }) else { return false }
        let players = humanSlots.map { Player(id: result.participantIDs[$0]!, name: result.playerNames[$0]) }
        let botWon = result.winner >= 0 && result.botSlots.contains(result.winner)
        let winner = result.winner >= 0 && !botWon ? result.participantIDs[result.winner] : nil
        return record(sessionID: result.sessionID, round: result.round, players: players, winnerID: winner, isDraw: result.winner == -1, winnerWasBot: botWon)
    }

    func standings(gameID: String = "rift-arena") -> [Standing] {
        var players: [String: Standing] = [:]
        for result in results where result.gameID == gameID {
            for player in result.players {
                var row = players[player.id] ?? Standing(id: player.id, name: player.name)
                row.name = player.name; row.played += 1
                if result.winnerID == player.id { row.wins += 1 }
                if result.isDraw { row.draws += 1 }
                players[player.id] = row
            }
        }
        return players.values.sorted {
            if $0.wins != $1.wins { return $0.wins > $1.wins }
            if $0.played != $1.played { return $0.played < $1.played }
            return $0.id < $1.id
        }
    }
}
