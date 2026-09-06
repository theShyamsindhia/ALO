import XCTest
@testable import ALOCore

final class BreachTests: XCTestCase {
    func testLargeMovementCannotTunnelThroughWall() {
        var game = BreachSimulation()
        game.move(dx: 12, dz: 0)
        XCTAssertLessThan(game.player.x, 6.2)
        XCTAssertTrue(BreachSimulation.canStand(game.player))
        game.move(dx: .nan, dz: 0)
        XCTAssertTrue(game.player.x.isFinite)
    }

    func testRaysRespectHeightAndWalls() {
        XCTAssertFalse(BreachSimulation.visible(from: .init(-9, -5), to: .init(-5, -5)))
        // This crate is only 1.4 m high, below a standing shot's eye line.
        XCTAssertTrue(BreachSimulation.visible(from: .init(-2, -3), to: .init(-2, 3)))
        XCTAssertFalse(BreachSimulation.visible(from: .init(-11, -12), to: .init(-11, -8)))
    }

    func testReloadTransfersOnlyMissingRoundsAndBlocksFire() {
        var game = BreachSimulation()
        XCTAssertTrue(game.fire(yaw: 0, pitch: 0.8))
        XCTAssertEqual(game.ammo, 23)
        game.reload()
        XCTAssertFalse(game.fire(yaw: 0, pitch: 0))
        for _ in 0..<40 { game.tick(0.05) }
        XCTAssertEqual(game.reloadRemaining, 0)
        XCTAssertEqual(game.ammo, 24)
        XCTAssertEqual(game.reserve, 119)
    }

    func testWeaponSwitchDoesNotRefillAmmunition() {
        var game = BreachSimulation()
        _ = game.fire(yaw: 0, pitch: 0.8)
        game.equip(.smg)
        XCTAssertEqual(game.ammo, 32)
        game.equip(.rifle)
        XCTAssertEqual(game.ammo, 23)
        XCTAssertEqual(game.reserve, 120)
    }

    func testShotsDamageAndKillOnce() {
        var game = BreachSimulation()
        XCTAssertTrue(game.fire(yaw: 0, pitch: 0))
        XCTAssertTrue(game.lastHit)
        XCTAssertEqual(game.bots[1].health, 32)
        XCTAssertFalse(game.fire(yaw: 0, pitch: 0))
        for _ in 0..<3 { game.tick(0.05) }
        XCTAssertTrue(game.fire(yaw: 0, pitch: 0))
        XCTAssertEqual(game.bots[1].health, 0)
        XCTAssertEqual(game.kills, 1)
        XCTAssertEqual(game.bots[1].deaths, 1)
    }

    func testEliminationWinsRoundAndNextRoundRestoresLoadout() {
        var game = BreachSimulation()
        game.move(dx: 0, dz: -26)
        for id in [1, 0, 2] {
            for _ in 0..<2 {
                let target = game.bots[id].position
                let yaw = atan2(-(target.x - game.player.x), -(target.z - game.player.z))
                XCTAssertTrue(game.fire(yaw: yaw, pitch: 0))
                for _ in 0..<3 { game.tick(0.05) }
            }
        }
        XCTAssertTrue(game.roundOver)
        XCTAssertEqual(game.wins, 1)
        XCTAssertEqual(game.kills, 3)
        game.nextRound()
        XCTAssertFalse(game.roundOver)
        XCTAssertEqual(game.round, 2)
        XCTAssertEqual(game.ammo, game.weapon.magazine)
        XCTAssertTrue(game.bots.allSatisfy { $0.health == 100 && $0.deaths == 1 })
    }

    func testMatchEndsAtFiveAndDoesNotScoreRepeatedly() {
        var game = BreachSimulation()
        for loss in 1...5 {
            for _ in 0..<2000 { game.tick(0.05) }
            XCTAssertTrue(game.roundOver)
            XCTAssertEqual(game.losses, loss)
            XCTAssertTrue(game.bots.allSatisfy { BreachSimulation.canStand($0.position) })
            if loss < 5 { game.nextRound(); XCTAssertEqual(game.health, 100) }
        }
        XCTAssertTrue(game.matchOver)
        XCTAssertEqual(game.round, 5)
        game.nextRound(); game.resetRound(); game.tick(0.05)
        XCTAssertEqual(game.losses, 5)
        XCTAssertTrue(game.roundOver)
    }

    func testInvalidDifficultyCannotCorruptHealth() {
        var game = BreachSimulation()
        game.tick(.nan, difficulty: 0)
        XCTAssertEqual(game.seconds, 90)
        for _ in 0..<25 { game.tick(0.05, difficulty: .nan) }
        XCTAssertGreaterThan(game.health, 0)
        XCTAssertLessThanOrEqual(game.health, 100)
    }
}
