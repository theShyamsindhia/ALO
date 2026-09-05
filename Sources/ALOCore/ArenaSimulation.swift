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
    public var attackHeavy = false
    public var attackDirection: Int = 0
    public var attackConnected = false
    public var respawn: Int = 0
    public var hitSerial: Int = 0
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
                f.attackDirection = input.vertical
                f.attackAge = 0; f.attackConnected = false
                f.attackFrames = input.heavy ? 40 : 23
                // Attacking forfeits respawn protection.
                f.invulnerable = 0
                if input.heavy && input.vertical == 1 && !f.grounded && f.recoveryAvailable {
                    f.vy = 660; f.recoveryAvailable = false
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

    public func attackCenter(_ i: Int) -> (x: Double, y: Double, radius: Double) {
        let f = fighters[i]
        let reach = f.kind == .nova ? 58.0 : 48.0
        return (f.x + (f.attackDirection == 0 ? f.facing * reach : f.facing * 12),
                f.y + 25 + Double(f.attackDirection) * 48,
                f.attackHeavy ? 52 : 37)
    }
    public func attackActive(_ i: Int) -> Bool {
        let f = fighters[i]
        let startup = f.attackHeavy ? 13 : 5
        return f.attackFrames > 0 && f.attackAge >= startup && f.attackAge < startup + 5
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
        let damage = (f.attackHeavy ? 19.0 : 9.0) * (f.kind == .atlas ? 1.15 : 1)
        fighters[b].damage += damage
        let force = (f.attackHeavy ? 330.0 : 185.0) + fighters[b].damage * (f.attackHeavy ? 3.5 : 2.1)
        fighters[b].vx = f.facing * force * (f.attackDirection == 0 ? 1 : 0.45)
        fighters[b].vy = force * (f.attackDirection == -1 ? -0.8 : f.attackDirection == 1 ? 1.25 : 0.65)
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
        result.vertical = bot.y < 110 ? 1 : (foe.y > bot.y + 65 ? 1 : 0)
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
                && (0...40).contains($0.attackFrames) && (0...40).contains($0.attackAge) && (0...24).contains($0.stun)
                && (0...150).contains($0.dodgeCooldown) && (0...12).contains($0.dodgeFrames) && (-1...1).contains($0.attackDirection)
                && (0...1_000_000).contains($0.hitSerial) && (0...3).contains($0.stocks) && (0...10_000).contains($0.damage)
            }
    }
}
