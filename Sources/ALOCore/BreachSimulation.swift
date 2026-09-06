import Foundation

public struct BreachPoint: Equatable, Sendable {
    public var x: Double
    public var z: Double
    public init(_ x: Double, _ z: Double) { self.x = x; self.z = z }
    public func distance(to p: Self) -> Double { hypot(x - p.x, z - p.z) }
}
public struct BreachWall: Sendable {
    public let x: Double, z: Double, width: Double, depth: Double, height: Double
    public init(_ x: Double, _ z: Double, _ width: Double, _ depth: Double, _ height: Double = 3.5) {
        self.x = x; self.z = z; self.width = width; self.depth = depth; self.height = height
    }
    public func contains(_ p: BreachPoint, margin: Double = 0) -> Bool {
        abs(p.x - x) < width / 2 + margin && abs(p.z - z) < depth / 2 + margin
    }
}
public enum BreachWeapon: String, CaseIterable, Sendable {
    case rifle = "AR-24", smg = "VX-9", pistol = "P-12"
    public var magazine: Int { switch self { case .rifle: 24; case .smg: 32; case .pistol: 12 } }
    public var damage: Int { switch self { case .rifle: 34; case .smg: 22; case .pistol: 40 } }
    public var interval: Double { switch self { case .rifle: 0.14; case .smg: 0.085; case .pistol: 0.28 } }
    public var reloadTime: Double { self == .pistol ? 1.3 : 1.9 }
}
public struct BreachBot: Identifiable, Sendable {
    public let id: Int
    public var position: BreachPoint
    public var health = 100
    public var cooldown = 1.0
    public var kills = 0
    public var deaths = 0
}
public struct BreachSimulation: Sendable {
    public static let walls: [BreachWall] = [
        .init(-16, 0, 1, 33), .init(16, 0, 1, 33), .init(0, -16, 33, 1), .init(0, 16, 33, 1),
        .init(-7, -5, 1, 14), .init(7, 5, 1, 14),
        .init(-10, 5, 6, 1), .init(10, -5, 6, 1),
        .init(-2, 0, 3, 3, 1.4), .init(4, -9, 2.5, 2.5, 1.8),
        .init(-11, -10, 2.5, 2.5, 1.8), .init(10, 10, 3, 2, 1.5), .init(-5, 10, 2, 2, 1.6)
    ]
    public private(set) var player = BreachPoint(0, 12)
    public private(set) var health = 100
    public private(set) var bots: [BreachBot] = []
    public private(set) var weapon: BreachWeapon = .rifle
    public private(set) var ammo = 24
    public private(set) var reserve = 120
    public private(set) var reloadRemaining = 0.0
    public private(set) var shotCooldown = 0.0
    public private(set) var seconds = 90.0
    public private(set) var round = 1
    public private(set) var wins = 0
    public private(set) var losses = 0
    public private(set) var kills = 0
    public private(set) var roundOver = false
    public private(set) var lastHit = false
    private var ammunition: [BreachWeapon: (loaded: Int, spare: Int)] = [:]
    private var routes: [Int: [BreachPoint]] = [:]
    private var routeTimers: [Int: Double] = [:]
    public var matchOver: Bool { wins >= 5 || losses >= 5 }
    public init() { resetRound() }
    public mutating func equip(_ weapon: BreachWeapon) {
        guard weapon != self.weapon, !roundOver else { return }
        ammunition[self.weapon] = (ammo, reserve)
        self.weapon = weapon
        let stored = ammunition[weapon] ?? (weapon.magazine, weapon.magazine * 5)
        ammo = stored.0; reserve = stored.1
        reloadRemaining = 0; shotCooldown = 0.3
    }
    public mutating func resetRound() {
        guard !matchOver else { return }
        player = .init(0, 12); health = 100; seconds = 90; roundOver = false
        let previousBots = bots
        bots = (0..<3).map { id in
            var bot = BreachBot(id: id, position: .init(Double(id - 1) * 11, -12))
            bot.kills = previousBots.first { $0.id == id }?.kills ?? 0
            bot.deaths = previousBots.first { $0.id == id }?.deaths ?? 0
            return bot
        }
        ammunition.removeAll(); routes.removeAll(); routeTimers.removeAll(); lastHit = false
        ammo = weapon.magazine; reserve = weapon.magazine * 5; reloadRemaining = 0; shotCooldown = 0
    }
    public mutating func nextRound() { guard roundOver && !matchOver else { return }; round += 1; resetRound() }
    public static func canStand(_ p: BreachPoint) -> Bool {
        abs(p.x) < 15.2 && abs(p.z) < 15.2 && !walls.contains { $0.contains(p, margin: 0.34) }
    }
    public static func visible(from a: BreachPoint, to b: BreachPoint) -> Bool {
        clearSegment(from: a, to: b, startHeight: 1.65, endHeight: 1.65)
    }
    // Slab intersection avoids sampled rays missing thin walls, and respects low cover.
    private static func clearSegment(from a: BreachPoint, to b: BreachPoint,
                                     startHeight: Double, endHeight: Double, margin: Double = 0) -> Bool {
        guard a.x.isFinite, a.z.isFinite, b.x.isFinite, b.z.isFinite else { return false }
        return !walls.contains { wall in
            var entry = 0.0, exit = 1.0
            let axes = [(a.x, b.x - a.x, wall.x - wall.width / 2 - margin, wall.x + wall.width / 2 + margin),
                        (a.z, b.z - a.z, wall.z - wall.depth / 2 - margin, wall.z + wall.depth / 2 + margin),
                        (startHeight, endHeight - startHeight, -margin, wall.height + margin)]
            for (origin, direction, low, high) in axes {
                if abs(direction) < 0.000001 {
                    if origin < low || origin > high { return false }
                } else {
                    let first = (low - origin) / direction, second = (high - origin) / direction
                    entry = max(entry, min(first, second)); exit = min(exit, max(first, second))
                    if entry > exit { return false }
                }
            }
            return true
        }
    }
    public mutating func move(dx: Double, dz: Double) {
        guard !roundOver, dx.isFinite, dz.isFinite else { return }
        // Substeps preserve wall sliding without allowing a delayed frame to cross a wall.
        let distance = hypot(dx, dz)
        guard distance.isFinite, distance > 0 else { return }
        let fraction = min(1, 32 / distance)
        let steps = max(1, Int(ceil(distance * fraction / 0.15)))
        for _ in 0..<steps {
            let x = BreachPoint(player.x + dx * fraction / Double(steps), player.z)
            if Self.canStand(x) { player = x }
            let z = BreachPoint(player.x, player.z + dz * fraction / Double(steps))
            if Self.canStand(z) { player = z }
        }
    }
    public mutating func reload() {
        guard !roundOver, reloadRemaining == 0, ammo < weapon.magazine, reserve > 0 else { return }
        reloadRemaining = weapon.reloadTime
    }
    @discardableResult public mutating func fire(yaw: Double, pitch: Double) -> Bool {
        lastHit = false
        guard !roundOver, yaw.isFinite, pitch.isFinite, abs(pitch) < .pi / 2, shotCooldown == 0, reloadRemaining == 0, ammo > 0 else { return false }
        ammo -= 1; shotCooldown = weapon.interval
        let dx = -sin(yaw), dz = -cos(yaw)
        let targets = bots.indices.filter { bots[$0].health > 0 }.sorted { bots[$0].position.distance(to: player) < bots[$1].position.distance(to: player) }
        for i in targets {
            let p = bots[i].position
            let along = (p.x-player.x)*dx + (p.z-player.z)*dz
            let side = abs((p.x-player.x)*dz - (p.z-player.z)*dx)
            let hitHeight = 1.65 + tan(pitch)*along
            if along > 0, side < 0.42, hitHeight > 0.2, hitHeight < 1.95,
               Self.clearSegment(from: player, to: .init(player.x + dx * along, player.z + dz * along),
                                 startHeight: 1.65, endHeight: hitHeight) {
                bots[i].health = max(0, bots[i].health - (hitHeight > 1.55 ? weapon.damage * 2 : weapon.damage))
                lastHit = true
                if bots[i].health <= 0 { kills += 1; bots[i].deaths += 1 }
                break
            }
        }
        if bots.allSatisfy({ $0.health <= 0 }) { endRound(won: true) }
        return true
    }
    public mutating func tick(_ delta: Double, difficulty: Double = 1) {
        guard !roundOver, delta.isFinite, delta > 0 else { return }
        let dt = min(delta, 0.05)
        let difficulty = difficulty.isFinite ? min(2, max(0.5, difficulty)) : 1
        seconds = max(0, seconds-dt); shotCooldown = max(0, shotCooldown-dt)
        if reloadRemaining > 0 {
            reloadRemaining = max(0, reloadRemaining-dt)
            if reloadRemaining == 0 { let n = min(weapon.magazine-ammo, reserve); ammo += n; reserve -= n }
        }
        for i in bots.indices where bots[i].health > 0 {
            routeTimers[i, default: 0] -= dt
            let p = bots[i].position, d = p.distance(to: player)
            if Self.visible(from: p, to: player) {
                bots[i].cooldown = max(0, bots[i].cooldown-dt)
                if bots[i].cooldown == 0 {
                    health = max(0, health - Int(7 * difficulty)); bots[i].cooldown = 0.85 / difficulty
                    if health == 0 { bots[i].kills += 1; break }
                }
                if d > 7 { navigateBot(i, dt: dt) }
            } else {
                // A guard must reacquire the player, rather than firing instantly from cover.
                bots[i].cooldown = max(bots[i].cooldown, 0.4 / difficulty)
                navigateBot(i, dt: dt)
            }
        }
        if health == 0 || seconds == 0 { endRound(won: false) }
    }
    private mutating func endRound(won: Bool) {
        guard !roundOver else { return }
        roundOver = true
        if won { wins += 1 } else { losses += 1 }
    }
    private mutating func navigateBot(_ i: Int, dt: Double) {
        if routeTimers[i, default: 0] <= 0 {
            routes[i] = Self.route(from: bots[i].position, to: player)
            routeTimers[i] = 0.8 + Double(i) * 0.07
        }
        while let first = routes[i]?.first, bots[i].position.distance(to: first) < 0.12 {
            routes[i]?.removeFirst()
        }
        guard let target = routes[i]?.first else { return }
        let p = bots[i].position, distance = p.distance(to: target)
        guard distance > 0 else { return }
        let speed = min(distance, 2.1 * dt)
        let next = BreachPoint(p.x + (target.x-p.x)/distance*speed, p.z + (target.z-p.z)/distance*speed)
        if Self.canStand(next) { bots[i].position = next }
        else { routeTimers[i] = 0 }
    }
    // Build geometry connectivity once; paths are refreshed under twice a second per guard.
    private static let navigation: (points: [BreachPoint], edges: [[Int]]) = {
        let points = (0..<841).map { BreachPoint(Double($0 % 29) - 14, Double($0 / 29) - 14) }
        let valid = points.map { canStand($0) }
        let edges = points.indices.map { n -> [Int] in
            guard valid[n] else { return [] }
            return [n-29,n+29,n-1,n+1].filter { m in
                m >= 0 && m < 841 && abs(m % 29 - n % 29) <= 1 && valid[m] &&
                clearSegment(from: points[n], to: points[m], startHeight: 0.5, endHeight: 0.5, margin: 0.34)
            }
        }
        return (points, edges)
    }()
    private static func route(from: BreachPoint, to: BreachPoint) -> [BreachPoint] {
        if clearSegment(from: from, to: to, startHeight: 0.5, endHeight: 0.5, margin: 0.34) { return [to] }
        let graph = navigation
        func nearest(_ p: BreachPoint) -> Int? {
            graph.points.indices.filter { !graph.edges[$0].isEmpty }.sorted {
                graph.points[$0].distance(to: p) < graph.points[$1].distance(to: p)
            }.first { clearSegment(from: p, to: graph.points[$0], startHeight: 0.5, endHeight: 0.5, margin: 0.34) }
        }
        guard let start = nearest(from), let goal = nearest(to) else { return [] }
        var queue = [start], parent = Array(repeating: -1, count: graph.points.count), cursor = 0
        parent[start] = start
        while cursor < queue.count {
            let n = queue[cursor]; cursor += 1
            if n == goal { break }
            for m in graph.edges[n] where parent[m] == -1 {
                parent[m] = n; queue.append(m)
            }
        }
        guard parent[goal] != -1 else { return [] }
        var path = [to], n = goal
        while n != start { path.append(graph.points[n]); n = parent[n] }
        path.append(graph.points[start])
        return path.reversed()
    }
}
