import Foundation

public struct StickFightInput: Codable, Equatable, Sendable {
    public var horizontal = 0
    public var aimY = 0
    public var aimAngle: Double?
    public var throwWeapon = false
    public var jump = false
    public var punch = false
    public var shoot = false
    public var block = false
    public init() {}
    public var isValid: Bool { (-1...1).contains(horizontal) && (-1...1).contains(aimY) && (aimAngle.map { $0.isFinite && (-Double.pi...Double.pi).contains($0) } ?? true) }
}

public struct StickFightPlatform: Codable, Equatable, Sendable {
    public var left: Double
    public var right: Double
    public var top: Double
    public var bottom: Double
    public init(left: Double, right: Double, top: Double, bottom: Double) {
        self.left = left; self.right = right; self.top = top; self.bottom = bottom
    }
}
public struct StickFightHazard: Codable, Equatable, Sendable {
    public var left: Double
    public var right: Double
    public var bottom: Double
    public var top: Double
}
public enum StickFightMap: String, Codable, CaseIterable, Sendable {
    case crimsonKeep, foundry, frostfall
    public var title: String { switch self { case .crimsonKeep: "Crimson Keep"; case .foundry: "Ember Foundry"; case .frostfall: "Frostfall" } }
    public var platforms: [StickFightPlatform] {
        switch self {
        case .crimsonKeep:
            return [.init(left: 70, right: 280, top: 190, bottom: 0), .init(left: 370, right: 630, top: 260, bottom: 224), .init(left: 720, right: 930, top: 190, bottom: 0)]
        case .foundry:
            return [.init(left: 65, right: 935, top: 120, bottom: 0), .init(left: 185, right: 350, top: 250, bottom: 220), .init(left: 420, right: 580, top: 350, bottom: 320), .init(left: 650, right: 815, top: 250, bottom: 220)]
        case .frostfall:
            return [.init(left: 70, right: 275, top: 230, bottom: 195), .init(left: 375, right: 625, top: 150, bottom: 115), .init(left: 725, right: 930, top: 230, bottom: 195), .init(left: 420, right: 580, top: 345, bottom: 310)]
        }
    }
    public var spikes: [StickFightHazard] {
        switch self {
        case .crimsonKeep: return [.init(left: 280, right: 720, bottom: -10, top: 35)]
        case .foundry: return [.init(left: 460, right: 540, bottom: 120, top: 143)]
        case .frostfall: return [.init(left: 0, right: 1000, bottom: -30, top: 8)]
        }
    }
}
public enum StickFightWeapon: String, Codable, CaseIterable, Sendable {
    case pistol, scatter, blaster
    public var title: String { switch self { case .pistol: "Pistol"; case .scatter: "Scattergun"; case .blaster: "Blaster" } }
    public var ammunition: Int { switch self { case .pistol: 12; case .scatter: 6; case .blaster: 8 } }
    public var cooldown: Int { switch self { case .pistol: 13; case .scatter: 35; case .blaster: 23 } }
    public var damage: Double { switch self { case .pistol: 19; case .scatter: 11; case .blaster: 28 } }
}
public struct StickFightFighter: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var vx = 0.0
    public var vy = 0.0
    public var facing = 1.0
    public var aimAngle = 0.0
    public var health = 100.0
    public var alive = true
    public var wins = 0
    public var grounded = false
    public var airJumps = 1
    public var coyoteFrames = 0
    public var jumpBufferFrames = 0
    public var wallFrames = 0
    public var wallSide = 0
    public var stun = 0
    public var hitSerial = 0
    public var punchFrames = 0
    public var shootCooldown = 0
    public var blocking = false
    public var shield = 100.0
    public var weapon: StickFightWeapon?
    public var ammo = 0
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct StickFightProjectile: Codable, Equatable, Sendable {
    public var id: Int
    public var owner: Int
    public var x: Double
    public var y: Double
    public var vx: Double
    public var vy: Double
    public var weapon: StickFightWeapon
    public var life = 120
    public var thrown = false
    public var ammunition = 0
}
public struct StickFightPickup: Codable, Equatable, Sendable {
    public var ammunition: Int? = nil
    public var id: Int
    public var x: Double
    public var y: Double
    public var weapon: StickFightWeapon
}

/// Deterministic 60 Hz authority. Every piece of state required for replay is on the wire.
public struct StickFightSimulation: Codable, Equatable, Sendable {
    public static let maximumFighters = 4
    public static let step = GameRealtimePolicy.step
    // World distances are points, speeds points/s, acceleration points/s².
    public static let gravity = 1750.0
    public static let jumpSpeed = 640.0
    public static let runSpeed = 340.0
    public static let groundAcceleration = 2800.0
    public static let airAcceleration = 1400.0
    public static let airborneDrag = 0.65
    public static let projectileMassRatio = 0.018
    public var map: StickFightMap
    public var fighters: [StickFightFighter]
    public var projectiles: [StickFightProjectile] = []
    public var pickups: [StickFightPickup] = []
    public var frame = 0
    public var countdown = 60
    public var round = 1
    public var roundOverFrames = 0
    public var roundWinner: Int?
    public var winner: Int?
    public var remainingFrames = 3600
    private var previousInputs: [StickFightInput]
    private var nextID = 0
    public var arenaPlatforms: [StickFightPlatform] { map.platforms }
    public init(playerCount: Int = 2, map: StickFightMap = .crimsonKeep) {
        self.map = map
        let count = min(4, max(1, playerCount))
        fighters = (0..<count).map { _ in StickFightFighter(x: 0, y: 0) }
        previousInputs = Array(repeating: StickFightInput(), count: count)
        resetPositions()
    }
    private mutating func resetPositions() {
        let platforms = map.platforms
        for i in fighters.indices {
            let wins = fighters[i].wins
            let p = platforms[i % platforms.count]
            // Four seats remain separated even on a three-platform arena.
            let x = i >= platforms.count ? p.right - 36 : p.left + 40
            fighters[i] = StickFightFighter(x: x, y: p.top)
            fighters[i].wins = wins; fighters[i].grounded = true
            fighters[i].facing = x < 500 ? 1 : -1
            fighters[i].aimAngle = x < 500 ? 0 : Double.pi
        }
        previousInputs = Array(repeating: StickFightInput(), count: fighters.count)
        projectiles = []; pickups = []
        spawnPickup()
    }
    private mutating func spawnPickup() {
        guard pickups.count < 4 else { return }
        let p = map.platforms[(round + frame / 240) % map.platforms.count]
        pickups.append(.init(id: nextID, x: (p.left + p.right) / 2, y: p.top + 18,
                             weapon: StickFightWeapon.allCases[(round + frame / 240) % 3]))
        nextID += 1
    }
    public mutating func tick(inputs: [StickFightInput]) { tick(inputs) }
    public mutating func tick(_ requested: [StickFightInput]) {
        guard winner == nil else { return }
        let inputs = fighters.indices.map { requested.indices.contains($0) && requested[$0].isValid ? requested[$0] : StickFightInput() }
        frame += 1
        if countdown > 0 { countdown -= 1; previousInputs = inputs; return }
        if roundOverFrames > 0 {
            roundOverFrames -= 1
            if roundOverFrames == 0 {
                round += 1; map = StickFightMap.allCases[(StickFightMap.allCases.firstIndex(of: map)! + 1) % 3]
                roundWinner = nil; remainingFrames = 3600; countdown = 45; resetPositions()
            }
            return
        }
        remainingFrames = max(0, remainingFrames - 1)
        let oldPositions = fighters.map(\.x)
        for i in fighters.indices { move(i, input: inputs[i], previous: previousInputs[i]) }
        resolveContacts(previousX: oldPositions)
        // Gather strikes before applying damage, allowing fair simultaneous knockouts.
        var hits: [(Int, Int, Double, Double, Double)] = []
        for i in fighters.indices where fighters[i].alive && fighters[i].punchFrames == 12 {
            let f = fighters[i]
            for j in fighters.indices where i != j && fighters[j].alive {
                let t = fighters[j]
                if (t.x - f.x) * f.facing >= -5 && (t.x - f.x) * f.facing < 73 && abs(t.y - f.y) < 52 {
                    hits.append((i, j, 17, f.facing * 430, 270))
                }
            }
        }
        for h in hits {
            let blocked = fighters[h.1].blocking && (fighters[h.0].x - fighters[h.1].x) * fighters[h.1].facing >= 0
            // Ground contact couples the attacker to the floor; airborne equal masses exchange opposite impulses.
            let supportMass = fighters[h.0].grounded ? 4.5 : 1.0
            let recoil = h.3 * (blocked ? 0.25 : 1)
            damage(h.1, from: h.0, amount: h.2, vx: h.3, vy: h.4)
            fighters[h.0].vx -= recoil / supportMass
        }
        advanceProjectiles()
        for i in fighters.indices where fighters[i].alive {
            if fighters[i].y < -65 || fighters[i].x < -70 || fighters[i].x > 1070 || movingHazards.contains(where: { $0.intersects(fighters[i]) }) || map.spikes.contains(where: {
                fighters[i].x + 10 > $0.left && fighters[i].x - 10 < $0.right && fighters[i].y < $0.top && fighters[i].y + 46 > $0.bottom
            }) { fighters[i].health = 0; fighters[i].alive = false; fighters[i].blocking = false }
            if fighters[i].weapon == nil, let p = pickups.firstIndex(where: { abs($0.x - fighters[i].x) < 30 && abs($0.y - fighters[i].y - 20) < 45 }) {
                fighters[i].weapon = pickups[p].weapon; fighters[i].ammo = pickups[p].ammunition ?? pickups[p].weapon.ammunition; pickups.remove(at: p)
            }
        }
        if frame % 240 == 0 { spawnPickup() }
        let alive = fighters.indices.filter { fighters[$0].alive }
        if alive.count <= 1 { finishRound(alive.first ?? -1) }
        else if remainingFrames == 0 {
            let best = alive.map { fighters[$0].health }.max()!
            let tied = alive.filter { fighters[$0].health == best }
            finishRound(tied.count == 1 ? tied[0] : -1)
        }
        previousInputs = inputs
    }
    private mutating func finishRound(_ victor: Int) {
        roundWinner = victor; roundOverFrames = 60
        if victor >= 0 { fighters[victor].wins += 1; if fighters[victor].wins >= 5 { winner = victor } }
        // Bound draws so maliciously idle peers cannot create an endless match.
        if round >= 25 && winner == nil {
            let best = fighters.map(\.wins).max() ?? 0
            let tied = fighters.indices.filter { fighters[$0].wins == best }
            winner = tied.count == 1 ? tied[0] : -1
        }
    }
    /// Guest-side movement prediction; combat, shared clocks and other seats remain authoritative.
    public mutating func predictMovement(slot: Int, input: StickFightInput) {
        guard fighters.indices.contains(slot), input.isValid, countdown == 0,
              roundOverFrames == 0, winner == nil else { return }
        let authoritative = fighters[slot]
        move(slot, input: input, previous: previousInputs[slot], combat: false)
        fighters[slot].stun = authoritative.stun
        fighters[slot].punchFrames = authoritative.punchFrames
        fighters[slot].shootCooldown = authoritative.shootCooldown
        fighters[slot].blocking = authoritative.blocking
        fighters[slot].shield = authoritative.shield
        previousInputs[slot] = input
    }
    private mutating func move(_ i: Int, input: StickFightInput, previous: StickFightInput, combat: Bool = true) {
        var f = fighters[i]
        guard f.alive else { return }
        f.stun = max(0, f.stun - 1); f.punchFrames = max(0, f.punchFrames - 1); f.shootCooldown = max(0, f.shootCooldown - 1)
        f.blocking = input.block && f.shield > 1 && f.stun == 0 && f.punchFrames == 0
        f.shield = min(100, max(0, f.shield + (f.blocking ? -0.55 : 0.35)))
        f.coyoteFrames = f.grounded ? 6 : max(0, f.coyoteFrames - 1)
        f.wallFrames = max(0, f.wallFrames - 1)
        f.jumpBufferFrames = input.jump && !previous.jump ? 6 : max(0, f.jumpBufferFrames - 1)
        if f.stun == 0 {
            let speed = f.blocking ? 95.0 : Self.runSpeed
            let acceleration = f.grounded ? Self.groundAcceleration : Self.airAcceleration
            if input.horizontal != 0 {
                let direction = Double(input.horizontal)
                // Inputs accelerate toward run speed without erasing faster external impulses.
                if f.vx * direction < speed { f.vx += direction * min(acceleration * Self.step, speed - f.vx * direction) }
                f.facing = direction
            } else {
                f.vx *= exp(-(f.grounded ? 12.0 : Self.airborneDrag) * Self.step)
            }
            if f.jumpBufferFrames > 0 && (f.coyoteFrames > 0 || f.airJumps > 0 || f.wallFrames > 0) {
                if f.coyoteFrames == 0 && f.wallFrames == 0 { f.airJumps -= 1 }
                if f.wallFrames > 0 && f.coyoteFrames == 0 { f.vx = Double(-f.wallSide) * 390; f.facing = Double(-f.wallSide) }
                f.vy = Self.jumpSpeed; f.grounded = false
                f.coyoteFrames = 0; f.wallFrames = 0; f.jumpBufferFrames = 0
            }
            if combat && input.punch && f.weapon == nil && !f.blocking && f.punchFrames == 0 { f.punchFrames = 16 }
        } else { f.vx *= exp(-Self.airborneDrag * Self.step) }
        let oldX = f.x, oldY = f.y
        // Constant-acceleration integration preserves the analytic jump arc at fixed 60 Hz.
        f.x += f.vx * Self.step
        f.y += f.vy * Self.step - 0.5 * Self.gravity * Self.step * Self.step
        f.vy = max(-1000, f.vy - Self.gravity * Self.step); f.grounded = false
        for p in map.platforms.sorted(by: { $0.top > $1.top }) {
            guard f.x + 12 > p.left && f.x - 12 < p.right else { continue }
            if f.vy <= 0 && oldY >= p.top - 0.01 && f.y <= p.top {
                f.y = p.top; f.vy = 0; f.grounded = true; f.airJumps = 1
            } else if oldY + 48 <= p.bottom && f.y + 48 >= p.bottom && f.vy > 0 {
                f.y = p.bottom - 48; f.vy = 0
            } else if f.y < p.top - 2 && f.y + 46 > p.bottom {
                if oldX + 12 <= p.left { f.x = p.left - 12; f.vx = 0; f.wallFrames = 5; f.wallSide = 1 }
                else if oldX - 12 >= p.right { f.x = p.right + 12; f.vx = 0; f.wallFrames = 5; f.wallSide = -1 }
            }
        }
        f.aimAngle = input.aimAngle ?? atan2(sin(Double(input.aimY) * 0.7), f.facing * cos(Double(input.aimY) * 0.7))
        if abs(cos(f.aimAngle)) > 0.05 { f.facing = cos(f.aimAngle) > 0 ? 1 : -1 }
        fighters[i] = f
        if combat && input.throwWeapon && !previous.throwWeapon, let weapon = f.weapon {
            let angle = f.aimAngle
            projectiles.append(.init(id: nextID, owner: i, x: f.x + cos(angle) * 25, y: f.y + 32,
                                     vx: cos(angle) * 600 + f.vx, vy: sin(angle) * 600 + 130,
                                     weapon: weapon, life: 120, thrown: true, ammunition: f.ammo))
            nextID += 1; fighters[i].weapon = nil; fighters[i].ammo = 0
            fighters[i].vx -= cos(angle) * 600 * 0.06
            return
        }
        if combat && (input.shoot || input.punch) && !f.blocking && f.stun == 0 && f.shootCooldown == 0, let weapon = f.weapon, f.ammo > 0 {
            let slopes: [Double] = weapon == .scatter ? [-0.16, 0, 0.16] : [0]
            for slope in slopes {
                let angle = f.aimAngle + slope
                projectiles.append(.init(id: nextID, owner: i, x: f.x + cos(angle) * 23, y: f.y + 31,
                                         vx: 860 * cos(angle), vy: 860 * sin(angle), weapon: weapon))
                fighters[i].vx -= 860 * cos(angle) * Self.projectileMassRatio
                fighters[i].vy -= 860 * sin(angle) * Self.projectileMassRatio
                nextID += 1
            }
            fighters[i].shootCooldown = weapon.cooldown; fighters[i].ammo -= 1
            if fighters[i].ammo == 0 { fighters[i].weapon = nil }
        }
    }
    /// Equal-mass horizontal contacts: positional projection and a low-restitution impulse.
    /// Three sequential passes settle four-player piles without adding energy.
    private mutating func resolveContacts(previousX: [Double]) {
        guard fighters.count > 1 else { return }
        for _ in 0..<3 {
            for a in 0..<(fighters.count - 1) where fighters[a].alive {
                for b in (a + 1)..<fighters.count where fighters[b].alive {
                    guard abs(fighters[a].y - fighters[b].y) < 43 else { continue }
                    let dx = fighters[b].x - fighters[a].x
                    let priorDX = previousX[b] - previousX[a]
                    let crossed = priorDX * dx < 0
                    guard abs(dx) < 24 || crossed else { continue }
                    let normal = (crossed ? priorDX : dx) >= 0 ? 1.0 : -1.0
                    let overlap = crossed ? 24 + abs(dx) : 24 - abs(dx)
                    let requestedA = fighters[a].x - normal * overlap / 2
                    let requestedB = fighters[b].x + normal * overlap / 2
                    let actualA = contactSafeX(requestedA, fighter: fighters[a])
                    let actualB = contactSafeX(requestedB, fighter: fighters[b])
                    fighters[a].x = actualA; fighters[b].x = actualB
                    // A wall absorbs positional correction; give its residual to the free fighter.
                    if actualA != requestedA { fighters[b].x = contactSafeX(actualB + actualA - requestedA, fighter: fighters[b]) }
                    if actualB != requestedB { fighters[a].x = contactSafeX(actualA + actualB - requestedB, fighter: fighters[a]) }
                    let relativeVelocity = (fighters[b].vx - fighters[a].vx) * normal
                    if relativeVelocity < 0 {
                        let impulse = -(1 + 0.12) * relativeVelocity / 2
                        fighters[a].vx -= impulse * normal; fighters[b].vx += impulse * normal
                    }
                }
            }
        }
    }
    private func contactSafeX(_ requested: Double, fighter: StickFightFighter) -> Double {
        var x = requested
        for platform in map.platforms where fighter.y < platform.top - 2 && fighter.y + 46 > platform.bottom {
            if fighter.x <= platform.left - 11 { x = min(x, platform.left - 12) }
            else if fighter.x >= platform.right + 11 { x = max(x, platform.right + 12) }
        }
        return x
    }
    private mutating func damage(_ target: Int, from owner: Int, amount: Double, vx: Double, vy: Double) {
        guard fighters[target].alive else { return }
        let frontal = (fighters[owner].x - fighters[target].x) * fighters[target].facing >= 0
        let blocked = fighters[target].blocking && frontal
        fighters[target].health = max(0, fighters[target].health - amount * (blocked ? 0.12 : 1))
        fighters[target].vx += vx * (blocked ? 0.25 : 1); fighters[target].vy += vy * (blocked ? 0.3 : 1)
        fighters[target].grounded = false; fighters[target].hitSerial += 1
        if blocked { fighters[target].shield = max(0, fighters[target].shield - amount * 1.5) }
        else { fighters[target].stun = 11; fighters[target].punchFrames = 0 }
        if fighters[target].health == 0 { fighters[target].alive = false; fighters[target].blocking = false }
    }
    private mutating func advanceProjectiles() {
        var survivors: [StickFightProjectile] = []
        for var p in projectiles {
            let oldX = p.x, oldY = p.y
            p.x += p.vx * Self.step; p.y += p.vy * Self.step; p.life -= 1
            if p.thrown { p.vy -= Self.gravity * Self.step }
            guard p.life > 0, p.x > -100, p.x < 1100, p.y > -100, p.y < 800 else { continue }
            // Substeps avoid skipping thin fighters at full bullet speed.
            var consumed = false
            for sub in 1...4 {
                let x = oldX + (p.x - oldX) * Double(sub) / 4, y = oldY + (p.y - oldY) * Double(sub) / 4
                if let platform = map.platforms.first(where: { x >= $0.left && x <= $0.right && y >= $0.bottom && y <= $0.top }) {
                    if p.thrown && pickups.count < 4 {
                        pickups.append(.init(ammunition: p.ammunition, id: nextID, x: x, y: platform.top + 18, weapon: p.weapon)); nextID += 1
                    }
                    consumed = true; break
                }
                if let target = fighters.indices.first(where: { $0 != p.owner && fighters[$0].alive && abs(fighters[$0].x - x) < 16 && y > fighters[$0].y - 2 && y < fighters[$0].y + 50 }) {
                    damage(target, from: p.owner, amount: p.thrown ? 25 : p.weapon.damage, vx: p.vx * 0.44, vy: 170 + max(0, p.vy * 0.2))
                    consumed = true; break
                }
            }
            if !consumed { survivors.append(p) }
        }
        projectiles = Array(survivors.suffix(16))
    }
    public func botInput(for index: Int) -> StickFightInput {
        var input = StickFightInput()
        guard fighters.indices.contains(index), fighters[index].alive,
              let enemy = fighters.indices.filter({ $0 != index && fighters[$0].alive }).min(by: { abs(fighters[$0].x - fighters[index].x) < abs(fighters[$1].x - fighters[index].x) }) else { return input }
        let f = fighters[index], foe = fighters[enemy]
        let recover = f.y < 90 || f.x < 80 || f.x > 920
        let weaponTarget = f.weapon == nil && abs(foe.x - f.x) > 100 ? pickups.min(by: { abs($0.x - f.x) + abs($0.y - f.y) < abs($1.x - f.x) + abs($1.y - f.y) }) : nil
        let targetX = recover ? 500 : weaponTarget?.x ?? foe.x
        input.horizontal = abs(targetX - f.x) > (weaponTarget != nil ? 12 : f.weapon == nil ? 42 : 170) ? (targetX > f.x ? 1 : -1) : 0
        if input.horizontal == 0 && (foe.x - f.x) * f.facing < 0 { input.horizontal = foe.x > f.x ? 1 : -1 }
        let supportAhead = map.platforms.contains { f.x + Double(input.horizontal) * 45 > $0.left && f.x + Double(input.horizontal) * 45 < $0.right && abs(f.y - $0.top) < 12 }
        input.jump = (frame + index * 5) % 16 == 0 && (recover || (weaponTarget?.y ?? foe.y) > f.y + 55 || (!supportAhead && input.horizontal != 0))
        input.aimY = foe.y - f.y > 75 ? 1 : foe.y - f.y < -75 ? -1 : 0
        input.punch = abs(foe.x - f.x) < 78 && abs(foe.y - f.y) < 50
        input.shoot = abs(foe.y - f.y) < 140
        input.block = foe.punchFrames > 7 && abs(foe.x - f.x) < 85 && (frame + index * 11) % 60 < 35
        return input
    }
    public var isValidSnapshot: Bool {
        (1...4).contains(fighters.count) && previousInputs.count == fighters.count && previousInputs.allSatisfy(\.isValid)
        && (0...110_000).contains(frame) && (0...60).contains(countdown) && (1...25).contains(round)
        && (0...60).contains(roundOverFrames) && (0...3600).contains(remainingFrames)
        && (winner == nil || (-1..<fighters.count).contains(winner!)) && (roundWinner == nil || (-1..<fighters.count).contains(roundWinner!))
        && (0...1_000_000).contains(nextID) && projectiles.count <= 16 && pickups.count <= 4
        && fighters.allSatisfy {
            [$0.x, $0.y, $0.vx, $0.vy, $0.health, $0.shield, $0.facing, $0.aimAngle].allSatisfy(\.isFinite)
            && abs($0.x) < 2000 && abs($0.y) < 2000 && abs($0.vx) < 5000 && abs($0.vy) < 5000
            && (-Double.pi...Double.pi).contains($0.aimAngle) && [-1.0, 1.0].contains($0.facing) && (0...100).contains($0.health) && (0...100).contains($0.shield)
            && (0...5).contains($0.wins) && (0...1).contains($0.airJumps) && (0...6).contains($0.coyoteFrames) && (0...6).contains($0.jumpBufferFrames) && (0...5).contains($0.wallFrames) && (-1...1).contains($0.wallSide) && (0...16).contains($0.punchFrames)
            && (0...35).contains($0.shootCooldown) && (0...11).contains($0.stun) && (0...12).contains($0.ammo)
            && (0...1_000_000).contains($0.hitSerial)
        }
        && projectiles.allSatisfy {
            fighters.indices.contains($0.owner) && (0..<nextID).contains($0.id) && (1...120).contains($0.life)
            && [$0.x, $0.y, $0.vx, $0.vy].allSatisfy(\.isFinite) && abs($0.x) < 1200 && abs($0.y) < 900 && abs($0.vx) < 6000 && abs($0.vy) < 5000 && (0...12).contains($0.ammunition)
        }
        && pickups.allSatisfy { (0..<nextID).contains($0.id) && $0.x.isFinite && $0.y.isFinite && (0...1000).contains($0.x) && (0...600).contains($0.y) && ($0.ammunition.map { (0...12).contains($0) } ?? true) }
    }
}
