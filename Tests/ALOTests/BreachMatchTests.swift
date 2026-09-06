import XCTest
@testable import ALOCore

final class BreachMatchTests: XCTestCase {
    private let neutral = [BreachInput](repeating: .init(), count: 4)
    private func live() -> BreachMatch {
        var game = BreachMatch(); game.phase = .live; game.seconds = 90; return game
    }
    private func advance(_ game: inout BreachMatch, frames: Int, inputs: [BreachInput]? = nil) {
        for _ in 0..<frames { game.tick(inputs ?? neutral) }
    }
    func testBuyPricesArmorAndNoPurchasesDuringLive() {
        var game = BreachMatch(), commands = neutral
        commands[0].buy = .rifle
        game.tick(commands)
        XCTAssertEqual(game.players[0].weapon, .pistol)
        commands[0].buyArmor = true
        game.tick(commands)
        XCTAssertEqual(game.players[0].armor, 100)
        XCTAssertEqual(game.players[0].money, 150)
        game.tick(commands)
        XCTAssertEqual(game.players[0].money, 150, "Repeated held buy cannot charge twice")
        game.players[0].money = 4000; game.phase = .live
        game.tick(commands)
        XCTAssertEqual(game.players[0].weapon, .pistol)
        game.phase = .buy; game.players[0].position = .init(0, 5)
        game.tick(commands)
        XCTAssertEqual(game.players[0].weapon, .pistol, "Purchases require own spawn")
        game.players[0].position = BreachMatch.spawns[0]
        game.tick(commands)
        XCTAssertEqual(game.players[0].weapon, .rifle)
        XCTAssertEqual(game.players[0].money, 1600)
    }
    func testBuyExpiresAndMovementCannotCrossWallsOrAccelerateDiagonally() {
        var game = BreachMatch(), commands = neutral
        commands[0].forward = 1
        advance(&game, frames: 899, inputs: commands)
        XCTAssertEqual(game.players[0].position, BreachMatch.spawns[0])
        advance(&game, frames: 1, inputs: commands)
        XCTAssertEqual(game.phase, .live)
        let start = game.players[0].position
        commands[0].strafe = 1; game.tick(commands)
        XCTAssertEqual(game.players[0].position.distance(to: start), 4.2/60, accuracy: 0.00001)
        game.players[0].position = .init(-8, -5)
        commands[0].forward = 0; commands[0].strafe = 1
        advance(&game, frames: 200, inputs: commands)
        XCTAssertLessThan(game.players[0].position.x, -7.8)
    }
    func testInvalidInputIsNeutralAndSnapshotsRejectCorruption() throws {
        var game = live(), input = BreachInput()
        input.forward = .infinity; input.fire = true
        let before = game.players[0]
        game.tick([input])
        XCTAssertEqual(game.players[0].position, before.position)
        XCTAssertEqual(game.players[0].ammo, before.ammo)
        XCTAssertTrue(game.isValidSnapshot)
        let data = try JSONEncoder().encode(game.networkSnapshot)
        XCTAssertLessThan(data.count, 8192)
        let decoded = try JSONDecoder().decode(BreachMatch.self, from: data)
        XCTAssertTrue(decoded.isValidSnapshot)
        game.players[0].position.x = .nan
        XCTAssertFalse(game.isValidSnapshot)
        game = live(); game.players.removeLast()
        XCTAssertFalse(game.isValidSnapshot)
        game = live(); game.bombCarrier = 20
        XCTAssertFalse(game.isValidSnapshot)
        game = live(); game.players[0].ammo = -1
        XCTAssertFalse(game.isValidSnapshot)
    }
    func testShotOcclusionFriendlyFireArmorAndKillCredit() {
        var game = live(), commands = neutral
        game.players[0].position = .init(0, 8)
        game.players[1].position = .init(0, 6)
        game.players[2].position = .init(0, 4)
        commands[0].fire = true
        game.tick(commands)
        XCTAssertEqual(game.players[1].health, 100)
        XCTAssertEqual(game.players[2].health, 100, "Teammate blocks bullet")
        game.players[1].position = .init(3, 8); game.players[2].armor = 100
        advance(&game, frames: 18, inputs: commands)
        XCTAssertEqual(game.players[2].health, 60)
        XCTAssertEqual(game.players[2].armor, 60)
        advance(&game, frames: 36, inputs: commands)
        XCTAssertEqual(game.players[2].health, 0)
        XCTAssertEqual(game.players[0].kills, 1)
        XCTAssertEqual(game.players[2].deaths, 1)
        XCTAssertEqual(game.players[0].money, 1100)
        game = live(); game.players[0].position = .init(-9, -5); game.players[2].position = .init(-5, -5)
        commands[0].yaw = -.pi / 2
        advance(&game, frames: 40, inputs: commands)
        XCTAssertEqual(game.players[2].health, 100, "Wall stops bullets")
    }
    func testReloadUsesReserveAndBlocksFire() {
        var game = live(), commands = neutral
        commands[0].fire = true; commands[0].pitch = 1.3
        game.tick(commands)
        XCTAssertEqual(game.players[0].ammo, 11)
        commands[0].reload = true
        game.tick(commands)
        XCTAssertEqual(game.players[0].ammo, 11)
        commands[0].fire = false; commands[0].reload = false
        advance(&game, frames: 78, inputs: commands)
        XCTAssertEqual(game.players[0].ammo, 12)
        XCTAssertEqual(game.players[0].reserve, 59)
        XCTAssertEqual(game.players[0].reloadRemaining, 0)
    }
    func testPlantRequiresHoldingStillAndDefuseCancelsOnRelease() {
        var game = live(), commands = neutral
        game.players[0].position = BreachMatch.sites[0]; commands[0].interact = true
        advance(&game, frames: 100, inputs: commands)
        XCTAssertGreaterThan(game.plantProgress, 1)
        commands[0].interact = false; game.tick(commands)
        XCTAssertEqual(game.plantProgress, 0)
        commands[0].interact = true
        advance(&game, frames: 180, inputs: commands)
        XCTAssertEqual(game.phase, .planted)
        XCTAssertNil(game.bombCarrier)
        XCTAssertEqual(game.bombPosition, game.players[0].position)
        XCTAssertEqual(game.seconds, 40)
        game.players[2].position = BreachMatch.sites[0]; commands[2].interact = true
        advance(&game, frames: 200, inputs: commands)
        XCTAssertGreaterThan(game.defuseProgress, 3)
        commands[2].interact = false; game.tick(commands)
        XCTAssertEqual(game.defuseProgress, 0)
        commands[2].interact = true
        advance(&game, frames: 300, inputs: commands)
        XCTAssertEqual(game.phase, .roundOver)
        XCTAssertEqual(game.roundWinner, .defenders)
        XCTAssertEqual(game.defendersScore, 1)
    }
    func testCarrierDeathDropsDeviceAndLivingTeammateRecoversIt() {
        var game = live()
        game.players[0].health = 0
        game.tick(neutral)
        XCTAssertNil(game.bombCarrier)
        XCTAssertEqual(game.bombPosition, BreachMatch.spawns[0])
        game.players[1].position = BreachMatch.spawns[0]
        game.tick(neutral)
        XCTAssertEqual(game.bombCarrier, 1)
        XCTAssertNil(game.bombPosition)
        XCTAssertTrue(game.isValidSnapshot)
    }
    func testBombSurvivesAttackerEliminationAndExplosionWins() {
        var game = live()
        game.phase = .planted; game.bombCarrier = nil; game.bombPosition = BreachMatch.sites[0]; game.seconds = 0.1
        game.players[0].health = 0; game.players[1].health = 0
        game.tick(neutral)
        XCTAssertEqual(game.phase, .planted)
        advance(&game, frames: 6)
        XCTAssertEqual(game.roundWinner, .attackers)
        XCTAssertEqual(game.attackersScore, 1)
    }
    func testRoundEconomyEquipmentLossAndFirstFiveMatchCompletion() {
        var game = live()
        game.players[0].weapon = .rifle; game.players[0].ammo = 24; game.players[0].health = 0
        game.players[1].health = 0
        game.tick(neutral)
        XCTAssertEqual(game.defendersScore, 1)
        XCTAssertEqual(game.players[0].money, 2700)
        advance(&game, frames: 240)
        XCTAssertEqual(game.phase, .buy)
        XCTAssertEqual(game.round, 2)
        XCTAssertEqual(game.players[0].weapon, .pistol)
        XCTAssertEqual(game.players[0].health, 100)
        XCTAssertEqual(game.bombCarrier, 0)
        for _ in 0..<4 {
            game.phase = .live; game.seconds = 0
            game.tick(neutral)
            if game.phase != .matchOver { advance(&game, frames: 240) }
        }
        XCTAssertEqual(game.phase, .matchOver)
        XCTAssertEqual(game.winner, .defenders)
        XCTAssertEqual(game.defendersScore, 5)
        let frame = game.frame; game.tick(neutral)
        XCTAssertEqual(game.frame, frame)
        XCTAssertTrue(game.isValidSnapshot)
        game.restart()
        XCTAssertEqual(game.round, 1)
        XCTAssertEqual(game.players[0].money, 800)
    }
    func testBotsAimAboveLowCoverInsteadOfShootingItsFace() {
        var game = live()
        game.players[0].position = .init(-2, 3)
        game.players[2].position = .init(-2, -3)
        game.players[3].health = 0
        let input = game.botInput(for: 0)
        XCTAssertEqual(input.pitch, 0)
        XCTAssertTrue(input.fire)
        game.tick([input])
        XCTAssertLessThan(game.players[2].health, 100)
    }
    func testBotAimsAboveLowCoverWhenBodyRayIsBlocked() {
        var game = live()
        game.players[0].position = .init(-2, 3)
        game.players[2].position = .init(-2, -3)
        game.players[3].health = 0
        let input = game.botInput(for: 0)
        XCTAssertEqual(input.pitch, 0, accuracy: 0.0001)
        var commands = neutral; commands[0] = input
        game.tick(commands)
        XCTAssertLessThan(game.players[2].health, 100)
    }
    func testBotsNavigateFightAndFinishRoundsWithoutInvalidState() {
        var game = BreachMatch()
        for _ in 0..<12_000 {
            game.tick((0..<4).map { game.botInput(for: $0) })
            if game.frame % 300 == 0 { XCTAssertTrue(game.isValidSnapshot) }
        }
        XCTAssertGreaterThan(game.attackersScore + game.defendersScore, 0)
        XCTAssertGreaterThan(game.players.map(\.kills).reduce(0, +), 0, "Bots should reach enemies, not wait behind walls")
    }
}
