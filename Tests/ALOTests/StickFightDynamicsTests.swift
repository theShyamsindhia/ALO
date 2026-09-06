import Testing
import Foundation
import ALOCore

struct StickFightDynamicsTests {
    @Test func pendulumKeepsItsLengthAndCollisionMatchesItsDrawnCircle() {
        var simulation = StickFightSimulation(playerCount: 4, map: .foundry)
        for frame in stride(from: 0, through: 3600, by: 7) {
            simulation.frame = frame
            let hazard = simulation.movingHazards[0]
            #expect(abs(hypot(hazard.x - hazard.pivotX, hazard.y - hazard.pivotY) - 380) < 0.000_001)
            #expect(hazard.intersects(StickFightFighter(x: hazard.x, y: hazard.y - 24)))
            #expect(!hazard.intersects(StickFightFighter(x: hazard.x + hazard.radius + 13, y: hazard.y)))
        }
    }
    @Test func stationaryMapsDoNotAcquireInvisibleMovingHazards() {
        #expect(StickFightSimulation(map: .crimsonKeep).movingHazards.isEmpty)
        #expect(StickFightSimulation(map: .frostfall).movingHazards.isEmpty)
    }
}
