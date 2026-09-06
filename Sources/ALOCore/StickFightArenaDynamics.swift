import Foundation

/// An analytic pendulum avoids accumulating integration drift across clients.
/// Coordinates use the same world units and seconds as fighter physics.
public struct StickFightMovingHazard: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let radius: Double
    public let pivotX: Double
    public let pivotY: Double

    public func intersects(_ fighter: StickFightFighter) -> Bool {
        let nearestX = max(fighter.x - 12, min(x, fighter.x + 12))
        let nearestY = max(fighter.y, min(y, fighter.y + 48))
        let dx = x - nearestX, dy = y - nearestY
        return dx * dx + dy * dy <= radius * radius
    }
}

public extension StickFightSimulation {
    var movingHazards: [StickFightMovingHazard] {
        guard map == .foundry else { return [] }
        let length = 380.0, gravity = Self.gravity
        let time = Double(frame) * Self.step
        // Small-angle pendulum frequency, with a controlled 41-degree sweep.
        let angle = 0.72 * sin(sqrt(gravity / length) * time)
        return [.init(x: 500 + length * sin(angle), y: 640 - length * cos(angle),
                      radius: 32, pivotX: 500, pivotY: 640)]
    }
}
