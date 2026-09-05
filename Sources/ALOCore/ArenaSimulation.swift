import Foundation

public struct ArenaInput: Codable, Equatable, Sendable {
    public var horizontal: Int = 0
    public var vertical: Int = 0
    public var jump = false
    public var light = false
    public var heavy = false
    public var dodge = false
    public init() {}
    public var isValid: Bool { (-1...1).contains(horizontal) && (-1...1).contains(vertical) }
}

public enum ArenaFighterKind: String, Codable, CaseIterable, Sendable {
    case nova, atlas
    public var title: String { self == .nova ? "Nova" : "Atlas" }
    public var subtitle: String { self == .nova ? "Quick blade · agile pressure" : "Heavy gauntlets · launching power" }
    public var speed: Double { self == .nova ? 310 : 270 }
}

/// Attack-specific timing and geometry used by both authority and presentation.
public struct ArenaAttackProfile: Equatable, Sendable {
    public let title: String
    public let startup: Int
    public let activeFrames: Int
    public let totalFrames: Int
    public let damage: Double
    public let baseForce: Double
    public let scaling: Double
    public let reach: Double
    public let lift: Double
    public let radius: Double
    public let launchX: Double
    public let launchY: Double
    public let selfVelocityX: Double
    public let selfVelocityY: Double

    public static func resolve(kind: ArenaFighterKind, heavy: Bool, direction: Int, aerial: Bool) -> Self {
        func move(_ title: String, _ startup: Int, _ total: Int, _ damage: Double,
                  _ reach: Double, _ lift: Double, _ radius: Double,
                  _ launchX: Double, _ launchY: Double, _ speedX: Double = 0, _ speedY: Double = 0) -> Self {
            Self(title: title, startup: startup, activeFrames: heavy ? 6 : 5, totalFrames: total, damage: damage,
                 baseForce: heavy ? (kind == .atlas ? 390 : 330) : (kind == .atlas ? 210 : 185),
                 scaling: heavy ? (kind == .atlas ? 3.8 : 3.5) : (kind == .atlas ? 2.4 : 2.1),
                 reach: reach, lift: lift, radius: radius, launchX: launchX, launchY: launchY,
                 selfVelocityX: speedX, selfVelocityY: speedY)
        }
        switch (kind, heavy, aerial, direction) {
        case (.nova, false, false, 1): return move("Rising Edge", 6, 24, 8, 14, 62, 34, 0.25, 1.25)
        case (.nova, false, false, -1): return move("Low Sweep", 7, 26, 10, 54, -8, 34, 1, 0.3)
        case (.nova, false, false, _): return move("Crescent Cut", 5, 23, 9, 58, 0, 37, 1, 0.65)
        case (.nova, false, true, 1): return move("Star Pierce", 5, 24, 9, 12, 75, 34, 0.2, 1.25)
        case (.nova, false, true, -1): return move("Falling Point", 8, 28, 12, 20, -50, 34, 0.3, -1)
        case (.nova, false, true, _): return move("Sky Arc", 5, 25, 10, 65, 20, 40, 1, 0.55)
        case (.nova, true, false, 1): return move("Lunar Rise", 11, 42, 18, 18, 68, 48, 0.3, 1.35, 0, 380)
        case (.nova, true, false, -1): return move("Moonwake", 15, 44, 20, 0, 0, 70, 0.9, 0.7)
        case (.nova, true, false, _): return move("Comet Lunge", 13, 40, 19, 78, 0, 45, 1.2, 0.55, 360)
        case (.nova, true, true, 1): return move("Astral Step", 9, 38, 15, 16, 64, 42, 0.25, 1.3, 0, 700)
        case (.nova, true, true, -1): return move("Comet Dive", 12, 44, 21, 20, -54, 46, 0.35, -1.1, 90, -520)
        case (.nova, true, true, _): return move("Crosswind", 11, 38, 17, 74, 10, 45, 1.1, 0.5, 460)
        case (.atlas, false, false, 1): return move("Rising Knuckle", 7, 28, 10, 12, 60, 32, 0.25, 1.3)
        case (.atlas, false, false, -1): return move("Ankle Breaker", 8, 29, 13, 45, -4, 34, 1.1, 0.25)
        case (.atlas, false, false, _): return move("Iron Jab", 7, 27, 12, 42, 0, 33, 1, 0.6)
        case (.atlas, false, true, 1): return move("Sky Knuckle", 6, 26, 10, 12, 68, 33, 0.2, 1.35)
        case (.atlas, false, true, -1): return move("Hammer Heel", 9, 30, 14, 18, -52, 35, 0.2, -1.15)
        case (.atlas, false, true, _): return move("Air Hook", 6, 25, 11, 48, 20, 35, 1.05, 0.6)
        case (.atlas, true, false, 1): return move("Titan Uppercut", 14, 46, 23, 12, 66, 53, 0.2, 1.5, 0, 330)
        case (.atlas, true, false, -1): return move("Faultline", 19, 52, 27, 0, -5, 90, 1.1, 0.65)
        case (.atlas, true, false, _): return move("Meteor Fist", 17, 48, 25, 55, 0, 55, 1.25, 0.65, 180)
        case (.atlas, true, true, 1): return move("Rocket Knuckle", 10, 42, 18, 12, 65, 48, 0.2, 1.45, 0, 740)
        case (.atlas, true, true, -1): return move("Meteor Drop", 13, 50, 25, 14, -58, 52, 0.2, -1.3, 0, -600)
        case (.atlas, true, true, _): return move("Hammer Drive", 15, 43, 22, 60, 12, 50, 1.25, 0.4, 260)
        }
    }
}

public struct ArenaFighter: Codable, Equatable, Sendable {
    public var kind: ArenaFighterKind
    public var x: Double
    public var y: Double = 260
    public var vx: Double = 0
    public var vy: Double = 0
    public var facing: Double
    public var damage: Double = 0
    public var stocks: Int = 3
    public var airJumps: Int = 2
    public var recoveryAvailable = true
    public var grounded = false
    public var stun: Int = 0
    public var invulnerable: Int = 0
    public var dodgeCooldown: Int = 0
    public var dodgeFrames: Int = 0
    public var attackFrames: Int = 0
    public var attackAge: Int = 0
    public var attackAerial: Bool? = nil
    public var attackHeavy = false
    public var attackDirection: Int = 0
    public var attackConnected = false
    public var respawn: Int = 0
    public var hitSerial: Int = 0
    public var attackProfile: ArenaAttackProfile {
        ArenaAttackProfile.resolve(kind: kind, heavy: attackHeavy, direction: attackDirection, aerial: attackAerial ?? !grounded)
    }
    public init(kind: ArenaFighterKind, x: Double, facing: Double) {
        self.kind = kind; self.x = x; self.facing = facing
    }
}

public struct ArenaPlatform: Sendable {
    public let left: Double
    public let right: Double
    public let top: Double
    public let droppable: Bool
}

public enum ArenaMap: String, Codable, CaseIterable, Sendable {
    case observatory, moonGarden, skybridge
    public var title: String {
        switch self { case .observatory: "Hollow Observatory"; case .moonGarden: "Moon Garden"; case .skybridge: "Skybridge" }
    }
    public var subtitle: String {
        switch self { case .observatory: "Balanced · twin platforms"; case .moonGarden: "Vertical · three platforms"; case .skybridge: "Open · no upper platforms" }
    }
    public var platforms: [ArenaPlatform] {
        let floor = ArenaPlatform(left: 180, right: 820, top: 150, droppable: false)
        switch self {
        case .observatory: return [floor,
            ArenaPlatform(left: 255, right: 415, top: 305, droppable: true),
            ArenaPlatform(left: 585, right: 745, top: 305, droppable: true)]
        case .moonGarden: return [floor,
            ArenaPlatform(left: 225, right: 365, top: 280, droppable: true),
            ArenaPlatform(left: 635, right: 775, top: 280, droppable: true),
            ArenaPlatform(left: 425, right: 575, top: 405, droppable: true)]
        case .skybridge: return [floor]
        }
    }
}

public struct ArenaSimulation: Codable, Equatable, Sendable {
    public static let maximumFighters = 4
    public static let step = 1.0 / 60.0
    public static var platforms: [ArenaPlatform] { ArenaMap.observatory.platforms }
    public var map: ArenaMap
    public var arenaPlatforms: [ArenaPlatform] { map.platforms }
    public var fighters: [ArenaFighter]
    public var frame = 0
    public var countdown = 180
    public var remainingFrames = 60 * 180
    /// -1 is a draw; nil means the round is still running.
    public var winner: Int?
    private var previousInputs = [ArenaInput(), ArenaInput()]
    public init(first: ArenaFighterKind = .nova, second: ArenaFighterKind = .atlas, map: ArenaMap = .observatory) {
        self.init(kinds: [first, second], map: map)
    }
    public init(kinds: [ArenaFighterKind], map: ArenaMap = .observatory) {
        self.map = map
        let roster = kinds.isEmpty ? [.nova] : Array(kinds.prefix(Self.maximumFighters))
        fighters = roster.enumerated().map { index, kind in
            ArenaFighter(kind: kind, x: Self.spawnX(index, count: roster.count), facing: index % 2 == 0 ? 1 : -1)
        }
        previousInputs = Array(repeating: ArenaInput(), count: roster.count)
    }
    private static func spawnX(_ index: Int, count: Int) -> Double {
        count == 2 ? (index == 0 ? 350 : 650) : 280 + Double(index) * 440 / Double(max(1, count - 1))
    }

    public mutating func tick(_ inputs: [ArenaInput]) {
        guard fighters.count >= 2, inputs.count == fighters.count, previousInputs.count == fighters.count, inputs.allSatisfy(\.isValid), winner == nil else { return }
        frame += 1
        if countdown > 0 { countdown -= 1; previousInputs = inputs; return }
        remainingFrames -= 1
        for i in fighters.indices { advance(i, input: inputs[i], old: previousInputs[i]) }
        // Resolve both active hitboxes from the same pre-hit state, allowing trades.
        let hits = fighters.indices.flatMap { attacker in
            fighters.indices.filter { $0 != attacker && canHit(attacker, $0) }.map { (attacker, $0) }
        }
        for (attacker, target) in hits { hit(attacker, target) }
        for i in fighters.indices {
            if fighters[i].stocks > 0 && fighters[i].respawn == 0 &&
                (fighters[i].x < -100 || fighters[i].x > 1100 || fighters[i].y < -130 || fighters[i].y > 780) {
                fighters[i].stocks -= 1
                fighters[i].respawn = 75
                fighters[i].attackFrames = 0
            }
        }
        let alive = fighters.indices.filter { fighters[$0].stocks > 0 }
        if alive.count < 2 { winner = alive.first ?? -1 }
        if remainingFrames <= 0 && winner == nil {
            let ranked = fighters.indices.sorted {
                fighters[$0].stocks != fighters[$1].stocks ? fighters[$0].stocks > fighters[$1].stocks : fighters[$0].damage < fighters[$1].damage
            }
            let first = ranked[0], second = ranked[1]
            winner = fighters[first].stocks == fighters[second].stocks && fighters[first].damage == fighters[second].damage ? -1 : first
        }
        previousInputs = inputs
    }

    private mutating func advance(_ i: Int, input: ArenaInput, old: ArenaInput) {
        var f = fighters[i]
        guard f.stocks > 0 else { return }
        if f.respawn > 0 {
            f.respawn -= 1
            if f.respawn == 0 {
                let stocks = f.stocks, serial = f.hitSerial
                f = ArenaFighter(kind: f.kind, x: Self.spawnX(i, count: fighters.count), facing: i % 2 == 0 ? 1 : -1)
                f.stocks = stocks; f.invulnerable = 120; f.hitSerial = serial
            }
            fighters[i] = f; return
        }
        f.invulnerable = max(0, f.invulnerable - 1)
        f.dodgeCooldown = max(0, f.dodgeCooldown - 1)
        f.dodgeFrames = max(0, f.dodgeFrames - 1)
        f.stun = max(0, f.stun - 1)
        if f.attackFrames > 0 { f.attackFrames -= 1; f.attackAge += 1 }
        if f.stun == 0 && f.dodgeFrames == 0 {
            let acceleration = f.grounded ? 2400.0 : 1500.0
            let target = Double(input.horizontal) * f.kind.speed
            f.vx += min(acceleration * Self.step, max(-acceleration * Self.step, target - f.vx))
            if input.horizontal != 0 && f.attackFrames == 0 { f.facing = Double(input.horizontal) }
            if input.jump && !old.jump && (f.grounded || f.airJumps > 0) {
                if !f.grounded { f.airJumps -= 1 }
                f.vy = 560; f.grounded = false
            }
            if input.dodge && !old.dodge && f.dodgeCooldown == 0 && f.attackFrames == 0 {
                f.dodgeCooldown = f.grounded ? 60 : 150
                f.dodgeFrames = 12; f.invulnerable = 12
                f.vx = Double(input.horizontal) * 620
                f.vy = Double(input.vertical) * 440
            } else if f.attackFrames == 0 && ((input.light && !old.light) || (input.heavy && !old.heavy)) {
                f.attackHeavy = input.heavy
                f.attackAerial = !f.grounded
                f.attackDirection = input.vertical
                f.attackAge = 0; f.attackConnected = false
                let move = ArenaAttackProfile.resolve(kind: f.kind, heavy: f.attackHeavy, direction: f.attackDirection, aerial: f.attackAerial == true)
                f.attackFrames = move.totalFrames
                // Attacking forfeits respawn protection.
                f.invulnerable = 0
                if input.heavy && input.vertical == 1 && !f.grounded && f.recoveryAvailable {
                    f.vy = move.selfVelocityY; f.recoveryAvailable = false
                }
            }
        }
        if f.attackFrames > 0 {
            let move = ArenaAttackProfile.resolve(kind: f.kind, heavy: f.attackHeavy, direction: f.attackDirection, aerial: f.attackAerial ?? !f.grounded)
            if f.attackAge == move.startup {
                if move.selfVelocityX != 0 { f.vx = f.facing * move.selfVelocityX }
                // Aerial recovery thrust is consumed once at startup, never again on active frames.
                if move.selfVelocityY != 0 && !(f.attackAerial == true && f.attackDirection == 1) {
                    f.vy = move.selfVelocityY; f.grounded = false
                }
            }
        }
        let oldY = f.y
        if f.dodgeFrames == 0 { f.vy -= (input.vertical == -1 ? 1850 : 1350) * Self.step }
        f.vy = max(-850, f.vy)
        f.x += f.vx * Self.step; f.y += f.vy * Self.step
        f.grounded = false
        if f.vy <= 0 {
            for p in arenaPlatforms where !(p.droppable && input.vertical == -1) {
                if f.x + 16 > p.left && f.x - 16 < p.right && oldY >= p.top && f.y <= p.top {
                    f.y = p.top; f.vy = 0; f.grounded = true
                    f.airJumps = 2; f.recoveryAvailable = true
                    break
                }
            }
        }
        fighters[i] = f
    }

    public func attackProfile(_ i: Int) -> ArenaAttackProfile {
        let f = fighters[i]
        return f.attackProfile
    }
    public func attackCenter(_ i: Int) -> (x: Double, y: Double, radius: Double) {
        let f = fighters[i], move = attackProfile(i)
        return (f.x + f.facing * move.reach, f.y + 25 + move.lift, move.radius)
    }
    public func attackActive(_ i: Int) -> Bool {
        let f = fighters[i], move = attackProfile(i)
        return f.attackFrames > 0 && f.attackAge >= move.startup && f.attackAge < move.startup + move.activeFrames
    }
    private func canHit(_ a: Int, _ b: Int) -> Bool {
        let f = fighters[a], target = fighters[b]
        guard f.stocks > 0, attackActive(a), !f.attackConnected, f.respawn == 0, target.respawn == 0,
              target.invulnerable == 0, target.stocks > 0 else { return false }
        let box = attackCenter(a)
        return abs(target.x - box.x) < box.radius + 17 && abs(target.y + 25 - box.y) < box.radius + 25
    }
    private mutating func hit(_ a: Int, _ b: Int) {
        let f = fighters[a]
        fighters[a].attackConnected = true
        let move = attackProfile(a)
        fighters[b].damage += move.damage
        let force = move.baseForce + fighters[b].damage * move.scaling
        let direction = move.reach == 0 ? (fighters[b].x >= f.x ? 1.0 : -1.0) : f.facing
        fighters[b].vx = direction * force * move.launchX
        fighters[b].vy = force * move.launchY
        fighters[b].stun = f.attackHeavy ? 24 : 14
        fighters[b].attackFrames = 0
        fighters[b].grounded = false
        fighters[b].hitSerial += 1
    }

    public func botInput(for index: Int = 1) -> ArenaInput {
        var result = ArenaInput()
        guard fighters.indices.contains(index), fighters[index].stocks > 0,
              let enemy = fighters.indices.filter({ $0 != index && fighters[$0].stocks > 0 }).min(by: {
                  abs(fighters[$0].x - fighters[index].x) < abs(fighters[$1].x - fighters[index].x)
              }) else { return result }
        let bot = fighters[index], foe = fighters[enemy]
        let targetX = bot.x < 200 || bot.x > 800 || bot.y < 130 ? 500 : foe.x
        let dx = targetX - bot.x
        result.horizontal = abs(dx) > 46 ? (dx > 0 ? 1 : -1) : 0
        result.jump = frame % 32 == 0 && (bot.y < 160 || foe.y > bot.y + 70 || bot.x < 210 || bot.x > 790)
        result.vertical = bot.y < 110 ? 1 : (foe.y > bot.y + 65 ? 1 : (foe.y < bot.y - 45 || frame % 183 == 0 ? -1 : 0))
        result.heavy = frame % 61 == 0 && (abs(foe.x - bot.x) < 110 || bot.y < 110)
        result.light = frame % 29 == 0 && abs(foe.x - bot.x) < 100
        result.dodge = frame % 77 == 0 && abs(foe.x - bot.x) < 130 && foe.attackFrames > 0
        return result
    }

    public var isValidSnapshot: Bool {
        (1...Self.maximumFighters).contains(fighters.count) && previousInputs.count == fighters.count && previousInputs.allSatisfy(\.isValid) && (0...20_000).contains(frame) && (0...180).contains(countdown)
            && (0...10_800).contains(remainingFrames) && (winner == nil || (-1..<fighters.count).contains(winner!))
            && fighters.allSatisfy {
                $0.facing.isFinite && [-1.0, 1.0].contains($0.facing) && $0.x.isFinite && $0.y.isFinite && $0.vx.isFinite && $0.vy.isFinite && $0.damage.isFinite
                && abs($0.x) < 3000 && abs($0.y) < 3000 && abs($0.vx) < 20_000 && abs($0.vy) < 20_000
                && (0...2).contains($0.airJumps) && (0...120).contains($0.invulnerable) && (0...75).contains($0.respawn)
                && (0...60).contains($0.attackFrames) && (0...60).contains($0.attackAge) && (0...24).contains($0.stun)
                && (0...150).contains($0.dodgeCooldown) && (0...12).contains($0.dodgeFrames) && (-1...1).contains($0.attackDirection)
                && (0...1_000_000).contains($0.hitSerial) && (0...3).contains($0.stocks) && (0...10_000).contains($0.damage)
            }
    }
}
