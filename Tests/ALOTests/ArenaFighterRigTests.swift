import AppKit
import SpriteKit
import Testing
import ALOCore
@testable import ALO

@MainActor
struct ArenaFighterRigTests {
    @Test("Attacks articulate the hand and forearm without rebuilding the fighter", arguments: ArenaFighterKind.allCases)
    func articulatedAttack(kind: ArenaFighterKind) throws {
        let rig = ArenaFighterRig(kind: kind, color: .gray)
        var fighter = ArenaFighter(kind: kind, x: 0, facing: 1)
        fighter.grounded = true
        rig.update(fighter: fighter, frame: 0, reducedMotion: false)
        let hand = try #require(rig.childNode(withName: "//front-hand"))
        let idle = hand.convert(.zero, to: rig)
        let count = nodeCount(rig)
        fighter.attackFrames = 20; fighter.attackHeavy = false; fighter.attackAge = 9
        rig.update(fighter: fighter, frame: 9, reducedMotion: false)
        let strike = hand.convert(.zero, to: rig)
        #expect(hypot(idle.x - strike.x, idle.y - strike.y) > 10)
        for frame in 10..<120 {
            fighter.vx = 240; fighter.attackFrames = 0
            rig.update(fighter: fighter, frame: frame, reducedMotion: false)
        }
        #expect(nodeCount(rig) == count)
        #expect(rig.childNode(withName: "//front-hand") === hand)
    }

    @Test("Reduced motion preserves readable attacks and eliminated fighters hide")
    func reducedMotionAndElimination() throws {
        let rig = ArenaFighterRig(kind: .nova, color: .gray)
        var fighter = ArenaFighter(kind: .nova, x: 0, facing: 1)
        fighter.grounded = true
        rig.update(fighter: fighter, frame: 0, reducedMotion: true)
        let arm = try #require(rig.childNode(withName: "//front-upper-arm"))
        let idle = arm.zRotation
        fighter.attackFrames = 10; fighter.attackAge = 9
        rig.update(fighter: fighter, frame: 9, reducedMotion: true)
        #expect(abs(arm.zRotation - idle) > 0.5)
        fighter.stocks = 0
        rig.update(fighter: fighter, frame: 10, reducedMotion: true)
        #expect(rig.isHidden)
    }

    private func nodeCount(_ node: SKNode) -> Int { 1 + node.children.reduce(0) { $0 + nodeCount($1) } }
}
