import Testing
import ALOCore

@Suite("Fourfold rules and bot")
struct FourfoldTests {
    @Test func verticalWinAndFinishedBoardRejectsMoves() {
        var game = FourfoldSimulation()
        for move in [0,1,0,1,0,1,0] { let accepted = game.drop(in: move); #expect(accepted) }
        #expect(game.winner == 1)
        #expect(game.winningCells == [0,7,14,21])
        let finishedMove = game.drop(in: 2); #expect(!finishedMove)
    }
    @Test func horizontalWin() {
        var game = FourfoldSimulation()
        for move in [0,6,1,6,2,5,3] { game.drop(in: move) }
        #expect(game.winner == 1)
    }
    @Test func diagonalWin() {
        var game = FourfoldSimulation()
        for move in [0,1,1,2,4,2,2,3,4,3,5,3,3] { game.drop(in: move) }
        #expect(game.winner == 1)
        #expect(game.winningCells.contains(0))
        #expect(game.winningCells.contains(24))
    }
    @Test func invalidAndFullColumnsDoNotConsumeTurn() {
        var game = FourfoldSimulation()
        let left = game.drop(in: -1), right = game.drop(in: 7)
        #expect(!left); #expect(!right)
        for _ in 0..<6 { game.drop(in: 0) }
        let previous = game
        let full = game.drop(in: 0); #expect(!full); #expect(game == previous)
    }
    @Test func botTakesWinAndBlocksLoss() {
        var win = FourfoldSimulation()
        for move in [6,0,6,0,5,0,5] { win.drop(in: move) }
        #expect(win.botColumn() == 0)
        var block = FourfoldSimulation()
        for move in [0,6,0,6,0] { block.drop(in: move) }
        #expect(block.botColumn() == 0)
        #expect(FourfoldSimulation().botColumn() == FourfoldSimulation().botColumn())
    }
}
