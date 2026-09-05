import Foundation

/// Seven columns, six rows. Row zero is the bottom; all moves are legal drops.
public struct FourfoldSimulation: Equatable, Sendable {
    public static let columns = 7
    public static let rows = 6
    public private(set) var cells = Array(repeating: 0, count: 42)
    public private(set) var turn = 1
    public private(set) var winner: Int?
    public private(set) var winningCells: [Int] = []
    public private(set) var lastDrop: Int?
    public init() {}
    public var isDraw: Bool { winner == nil && !cells.contains(0) }
    public var finished: Bool { winner != nil || isDraw }
    public var legalColumns: [Int] { finished ? [] : (0..<7).filter { cells[35 + $0] == 0 } }
    public func cell(column: Int, row: Int) -> Int { cells[row * 7 + column] }

    @discardableResult
    public mutating func drop(in column: Int) -> Bool {
        guard (0..<7).contains(column), !finished,
              let row = (0..<6).first(where: { cells[$0 * 7 + column] == 0 }) else { return false }
        let index = row * 7 + column
        cells[index] = turn; lastDrop = index
        for direction in [(1, 0), (0, 1), (1, 1), (1, -1)] {
            var run = [index]
            for sign in [-1, 1] {
                var x = column + direction.0 * sign, y = row + direction.1 * sign
                while (0..<7).contains(x), (0..<6).contains(y), cell(column: x, row: y) == turn {
                    run.append(y * 7 + x); x += direction.0 * sign; y += direction.1 * sign
                }
            }
            if run.count >= 4 { winner = turn; winningCells = run.sorted(); return true }
        }
        turn = 3 - turn
        return true
    }

    /// Immediate wins, forced blocks, then a bounded deterministic minimax search.
    public func botColumn() -> Int? {
        let choices = [3, 2, 4, 1, 5, 0, 6].filter(legalColumns.contains)
        guard !choices.isEmpty else { return nil }
        for column in choices {
            var next = self; next.drop(in: column)
            if next.winner == turn { return column }
        }
        for column in choices {
            var threat = self; threat.turn = 3 - turn; threat.drop(in: column)
            if threat.winner == 3 - turn { return column }
        }
        var best = choices[0], bestScore = Int.min
        for column in choices {
            var next = self; next.drop(in: column)
            let score = next.score(for: turn, depth: 3, alpha: -100_000, beta: 100_000)
            if score > bestScore { bestScore = score; best = column }
        }
        return best
    }

    private func score(for player: Int, depth: Int, alpha: Int, beta: Int) -> Int {
        if let winner { return winner == player ? 10_000 + depth : -10_000 - depth }
        if isDraw { return 0 }
        if depth == 0 {
            var value = 0
            for row in 0..<6 { value += cell(column: 3, row: row) == player ? 4 : cell(column: 3, row: row) == 0 ? 0 : -4 }
            for row in 0..<6 { for column in 0..<7 {
                for (dx, dy) in [(1,0), (0,1), (1,1), (1,-1)] {
                    guard (0..<7).contains(column + 3 * dx), (0..<6).contains(row + 3 * dy) else { continue }
                    let line = (0..<4).map { cell(column: column + $0 * dx, row: row + $0 * dy) }
                    let ours = line.filter { $0 == player }.count, theirs = line.filter { $0 == 3 - player }.count
                    if theirs == 0 { value += [0,1,6,30,1000][ours] }
                    if ours == 0 { value -= [0,1,6,30,1000][theirs] }
                }
            } }
            return value
        }
        var low = alpha, high = beta
        var best = turn == player ? -100_000 : 100_000
        for column in [3,2,4,1,5,0,6] where legalColumns.contains(column) {
            var next = self; next.drop(in: column)
            let value = next.score(for: player, depth: depth - 1, alpha: low, beta: high)
            if turn == player { best = max(best, value); low = max(low, best) }
            else { best = min(best, value); high = min(high, best) }
            if low >= high { break }
        }
        return best
    }
}
