import Foundation
import Testing
@testable import ALOCore

@Suite struct StickFightTests {
    private func started() -> StickFightSimulation {
        var sim = StickFightSimulation(map: .foundry)
        sim.countdown = 0
        sim.fighters[0].x = 110; sim.fighters[0].y = 120
        sim.fighters[1].x = 165; sim.fighters[1].y = 120
        sim.fighters[1].facing = -1
        return sim
    }
    @Test func countdownAndInputBounds() {
        var sim = StickFightSimulation()
        let fighters = sim.fighters
        var input = StickFightInput(); input.horizontal = 1; input.jump = true
        sim.tick([input])
        #expect(sim.fighters == fighters); #expect(sim.countdown == 59)
        input.horizontal = 9; #expect(!input.isValid)
        sim.countdown = 0; sim.tick([input]); #expect(sim.fighters[0].vx == 0)
    }
    @Test func doubleJumpRequiresReleaseAndResetsOnLanding() {
        var sim = started(); var jump = StickFightInput(); jump.jump = true
        sim.tick([jump]); #expect(sim.fighters[0].airJumps == 1)
        sim.tick([jump]); #expect(sim.fighters[0].airJumps == 1)
        sim.tick([]); sim.tick([jump]); #expect(sim.fighters[0].airJumps == 0)
        sim.tick([]); sim.tick([jump]); #expect(sim.fighters[0].airJumps == 0)
        for _ in 0..<100 { sim.tick([]) }
        #expect(sim.fighters[0].grounded); #expect(sim.fighters[0].airJumps == 1)
    }
    @Test func punchDealsDamageAndBlockReducesIt() {
        var a = started(), b = started()
        var punch = StickFightInput(); punch.punch = true
        var block = StickFightInput(); block.block = true
        for _ in 0..<5 { a.tick([punch]); b.tick([punch, block]) }
        #expect(a.fighters[1].health == 83)
        #expect(b.fighters[1].health > a.fighters[1].health)
        #expect(b.fighters[1].shield < 100)
    }
    @Test func simultaneousPunchesCanTrade() {
        var sim = started(); var punch = StickFightInput(); punch.punch = true
        for _ in 0..<5 { sim.tick([punch, punch]) }
        #expect(sim.fighters[0].health == 83); #expect(sim.fighters[1].health == 83)
    }
    @Test func firingConsumesAmmoAndSweptProjectileHits() {
        var sim = started(); sim.fighters[1].x = 180
        sim.fighters[0].weapon = .pistol; sim.fighters[0].ammo = 1
        var fire = StickFightInput(); fire.shoot = true
        sim.tick([fire]); #expect(sim.fighters[0].weapon == nil); #expect(sim.fighters[0].ammo == 0)
        for _ in 0..<6 { sim.tick([]) }
        #expect(sim.fighters[1].health == 81)
        #expect(sim.projectiles.isEmpty)
    }
    @Test func spikesRoundRotationAndMatchWin() {
        var sim = StickFightSimulation(); sim.countdown = 0
        sim.fighters[0].x = 500; sim.fighters[0].y = 20
        sim.tick([])
        #expect(!sim.fighters[0].alive); #expect(sim.roundWinner == 1); #expect(sim.fighters[1].wins == 1)
        for _ in 0..<60 { sim.tick([]) }
        #expect(sim.round == 2); #expect(sim.map == .foundry); #expect(sim.fighters.allSatisfy { $0.alive })
        #expect(sim.fighters[1].wins == 1)
        sim.countdown = 0; sim.fighters[1].wins = 4; sim.fighters[0].alive = false; sim.fighters[0].health = 0
        sim.tick([]); #expect(sim.winner == 1)
        let complete = sim; sim.tick([]); #expect(sim == complete)
    }
    @Test func snapshotRoundTripReplayAndLongBotRun() throws {
        var sim = StickFightSimulation(playerCount: 4)
        for _ in 0..<700 {
            sim.tick(sim.fighters.indices.map { sim.botInput(for: $0) })
            #expect(sim.isValidSnapshot)
        }
        var restored = try JSONDecoder().decode(StickFightSimulation.self, from: JSONEncoder().encode(sim))
        #expect(restored == sim)
        for _ in 0..<500 {
            let input = sim.fighters.indices.map { sim.botInput(for: $0) }
            sim.tick(input); restored.tick(input)
            #expect(sim == restored); #expect(sim.isValidSnapshot)
        }
        restored.fighters[0].x = .infinity; #expect(!restored.isValidSnapshot)
    }
    @Test func idleTimeoutTiesDoNotAwardWins() {
        var sim = started(); sim.remainingFrames = 1
        sim.tick([]); #expect(sim.roundWinner == -1); #expect(sim.fighters.allSatisfy { $0.wins == 0 })
    }
    @Test func predictionDoesNotAdvanceCombatOrOtherSeats() {
        var sim = started(); sim.fighters[0].weapon = .pistol; sim.fighters[0].ammo = 12
        let before = sim
        var input = StickFightInput(); input.horizontal = 1; input.shoot = true; input.punch = true
        sim.predictMovement(slot: 0, input: input)
        #expect(sim.fighters[0].x > before.fighters[0].x)
        #expect(sim.fighters[1] == before.fighters[1]); #expect(sim.frame == before.frame)
        #expect(sim.projectiles.isEmpty); #expect(sim.fighters[0].ammo == 12)
        #expect(sim.fighters[0].punchFrames == 0)
    }
    @Test func maximumProjectileSnapshotFitsRoomPacket() throws {
        var sim = StickFightSimulation(playerCount: 4); sim.countdown = 0
        var fire = StickFightInput(); fire.shoot = true
        for i in sim.fighters.indices { sim.fighters[i].weapon = .scatter; sim.fighters[i].ammo = 6 }
        sim.tick(Array(repeating: fire, count: 4))
        let sample = try #require(sim.projectiles.first)
        sim.projectiles = Array(repeating: sample, count: 16)
        var packet = StickFightPacket(kind: .state, session: UUID().uuidString, sequence: 99_999)
        packet.state = sim
        packet.slots = (0..<4).map { .init(index: $0, name: String(repeating: "x", count: 160), isBot: false, ready: true) }
        packet.started = true; packet.spectating = false; packet.assignedSlot = 0; packet.acknowledgedInput = 99_999
        #expect(try JSONEncoder().encode(packet).count < 8192)
    }

    @Test func jumpArcMatchesBallisticEquation() {
        var sim = started(); var jump = StickFightInput(); jump.jump = true
        let origin = sim.fighters[0].y
        var peak = origin
        for tick in 1...25 {
            sim.tick(tick == 1 ? [jump] : [])
            let t = Double(tick) * StickFightSimulation.step
            let expected = origin + StickFightSimulation.jumpSpeed * t - 0.5 * StickFightSimulation.gravity * t * t
            #expect(abs(sim.fighters[0].y - expected) < 0.000_001)
            peak = max(peak, sim.fighters[0].y)
        }
        let theoreticalHeight = pow(StickFightSimulation.jumpSpeed, 2) / (2 * StickFightSimulation.gravity)
        #expect(abs(peak - origin - theoreticalHeight) < 0.2)
    }
    @Test func coyoteAndBufferedJumpAreForgiving() {
        var sim = started(); sim.fighters[0].grounded = false; sim.fighters[0].coyoteFrames = 4
        var jump = StickFightInput(); jump.jump = true
        sim.tick([jump]); #expect(sim.fighters[0].airJumps == 1); #expect(sim.fighters[0].vy > 500)
        sim = started(); sim.fighters[0].grounded = false; sim.fighters[0].airJumps = 0
        sim.fighters[0].y = 121; sim.fighters[0].vy = -100
        sim.tick([jump]); #expect(sim.fighters[0].grounded)
        sim.tick([]); #expect(sim.fighters[0].vy > 500)
    }
    @Test func projectileRecoilConservesHorizontalMomentum() {
        var sim = started(); sim.fighters[0].weapon = .pistol; sim.fighters[0].ammo = 12
        var fire = StickFightInput(); fire.shoot = true; fire.aimAngle = 0.3
        sim.tick([fire])
        let bullet = sim.projectiles[0]
        #expect(sim.fighters[0].vx < 0)
        #expect(abs(sim.fighters[0].vx + bullet.vx * StickFightSimulation.projectileMassRatio) < 0.000_001)
    }
    @Test func knockbackAddsImpulseRatherThanErasingMomentum() {
        var a = started(), b = started(); var punch = StickFightInput(); punch.punch = true
        for _ in 0..<4 { a.tick([punch]); b.tick([punch]) }
        b.fighters[1].vx = 100
        a.tick([punch]); b.tick([punch])
        #expect(b.fighters[1].vx > a.fighters[1].vx + 70)
        #expect(a.fighters[0].vx < 0)
    }
    @Test func throwIsEdgeTriggeredAndMouseAimIsValidated() {
        var sim = started(); sim.fighters[0].weapon = .scatter; sim.fighters[0].ammo = 3
        var toss = StickFightInput(); toss.throwWeapon = true; toss.aimAngle = 1.0
        sim.tick([toss])
        #expect(sim.fighters[0].weapon == nil); #expect(sim.projectiles.contains { $0.thrown && $0.ammunition == 3 && $0.vy > 0 })
        toss.aimAngle = .nan; #expect(!toss.isValid)
        toss.aimAngle = 4; #expect(!toss.isValid)
    }

    @Test func wallJumpKicksAwayWithoutConsumingAirJump() {
        var sim = started(); sim.fighters[0].grounded = false; sim.fighters[0].y = 200
        sim.fighters[0].wallSide = 1; sim.fighters[0].wallFrames = 4
        var jump = StickFightInput(); jump.jump = true
        sim.tick([jump]); #expect(sim.fighters[0].vx < -300)
        #expect(sim.fighters[0].vy > 500); #expect(sim.fighters[0].airJumps == 1)
    }

    @Test func contactSeparatesBodiesAndConservesHorizontalMomentum() {
        var sim = started()
        sim.fighters[0].x = 110; sim.fighters[1].x = 130
        sim.fighters[0].vx = 200; sim.fighters[1].vx = -100
        sim.tick([])
        #expect(sim.fighters[1].x - sim.fighters[0].x >= 23.999)
        let expectedMomentum = 100 * exp(-12 * StickFightSimulation.step)
        #expect(abs(sim.fighters[0].vx + sim.fighters[1].vx - expectedMomentum) < 0.000_001)
        #expect(sim.fighters[0].vx < sim.fighters[1].vx)
    }
    @Test func highSpeedContactCannotTunnelThroughAnotherFighter() {
        var sim = started(); sim.fighters[0].x = 100; sim.fighters[1].x = 150
        sim.fighters[0].vx = 2400; sim.fighters[1].vx = -2400
        sim.tick([])
        #expect(sim.fighters[0].x < sim.fighters[1].x)
        #expect(sim.fighters[1].x - sim.fighters[0].x >= 23.999)
    }
    @Test func armedPrimaryFiresWithoutPunchAndReplicatesAim() {
        var sim = started(); sim.fighters[0].weapon = .pistol; sim.fighters[0].ammo = 12
        var primary = StickFightInput(); primary.punch = true; primary.aimAngle = 2.2
        sim.tick([primary])
        #expect(sim.fighters[0].punchFrames == 0); #expect(sim.fighters[0].ammo == 11)
        #expect(sim.fighters[0].aimAngle == 2.2); #expect(sim.fighters[0].facing == -1)
        #expect(sim.projectiles.first?.vx ?? 0 < 0)
    }
    @Test func pendulumContactEliminatesFighter() throws {
        var sim = started()
        let hazard = try #require(sim.movingHazards.first)
        sim.fighters[0].x = hazard.x; sim.fighters[0].y = hazard.y - 24
        sim.fighters[0].grounded = false
        sim.tick([])
        #expect(!sim.fighters[0].alive); #expect(sim.roundWinner == 1)
    }

}
