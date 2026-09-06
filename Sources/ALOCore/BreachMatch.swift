import Foundation

public enum BreachTeam: String, Codable, Sendable { case attackers, defenders
    public var opponent: Self { self == .attackers ? .defenders : .attackers }
}
public enum BreachPhase: String, Codable, Sendable { case buy, live, planted, roundOver, matchOver }
public struct BreachInput: Codable, Equatable, Sendable {
    public var forward = 0.0, strafe = 0.0, yaw = 0.0, pitch = 0.0
    public var fire = false, reload = false, interact = false, walk = false, buyArmor = false
    public var buy: BreachWeapon? = nil
    public init() {}
    public var isValid: Bool {
        forward.isFinite && strafe.isFinite && yaw.isFinite && pitch.isFinite &&
        abs(forward) <= 1 && abs(strafe) <= 1 && abs(yaw) <= 1_000_000 && abs(pitch) <= 1.4
    }
}
public struct BreachPlayer: Identifiable, Codable, Sendable {
    public let id: Int
    public let team: BreachTeam
    public var position: BreachPoint
    public var yaw = 0.0, pitch = 0.0
    public var health = 100, armor = 0, money = 800
    public var weapon: BreachWeapon = .pistol
    public var ammo = 12, reserve = 60, kills = 0, deaths = 0
    public var reloadRemaining = 0.0
    public var alive: Bool { health > 0 }
    public init(id: Int, team: BreachTeam, position: BreachPoint) {
        self.id = id; self.team = team; self.position = position
    }
}

/// Deterministic, host-authoritative four-seat tactical match. All time advances at 60 Hz.
/// Identity and transport remain outside the simulation; bots use the same inputs as people.
public struct BreachMatch: Codable, Sendable {
    public static let sites: [BreachPoint] = [.init(-11, -7.5), .init(11, -10)]
    public static let armorPrice = 650
    public static let spawns: [BreachPoint] = [.init(-2, 13), .init(2, 13), .init(-12, -13), .init(12, -13)]
    public internal(set) var players: [BreachPlayer] = []
    public internal(set) var phase: BreachPhase = .buy
    public internal(set) var seconds = 15.0, round = 1, attackersScore = 0, defendersScore = 0, frame = 0
    public internal(set) var bombPosition: BreachPoint? = nil
    public internal(set) var bombCarrier: Int? = 0
    public internal(set) var plantProgress = 0.0, defuseProgress = 0.0
    public internal(set) var winner: BreachTeam? = nil, roundWinner: BreachTeam? = nil
    public internal(set) var notice = "Buy equipment. Attackers plant; defenders protect the sites."
    private var cooldowns = [Double](repeating: 0, count: 4)
    private var paths = [[BreachPoint]](repeating: [], count: 4)
    private var pathRefresh = [Int](repeating: 0, count: 4)
    private var planter: Int? = nil, defuser: Int? = nil
    private static let dt = 1.0 / 60.0
    public init() {
        players = (0..<4).map { BreachPlayer(id: $0, team: $0 < 2 ? .attackers : .defenders, position: Self.spawns[$0]) }
        for i in 2..<4 { players[i].yaw = .pi }
    }
    public static func price(_ weapon: BreachWeapon) -> Int {
        switch weapon { case .pistol: 0; case .smg: 1_250; case .rifle: 2_400 }
    }
    public mutating func restart() { self = Self() }
    /// Navigation routes are host-only caches; stripping them keeps snapshots small.
    public var networkSnapshot: Self {
        var copy = self
        copy.paths = [[BreachPoint]](repeating: [], count: 4)
        copy.pathRefresh = [Int](repeating: 0, count: 4)
        return copy
    }

    public var isValidSnapshot: Bool {
        guard players.count == 4, cooldowns.count == 4, paths.count == 4, pathRefresh.count == 4,
              (1...9).contains(round), (0...5).contains(attackersScore), (0...5).contains(defendersScore),
              frame >= 0, frame < 100_000_000, seconds.isFinite, (0...90).contains(seconds),
              plantProgress.isFinite, (0...3).contains(plantProgress), defuseProgress.isFinite, (0...5).contains(defuseProgress),
              notice.utf8.count <= 512, cooldowns.allSatisfy({ $0.isFinite && (0...2).contains($0) }),
              pathRefresh.allSatisfy({ $0 >= 0 && $0 < 100_000_100 }),
              paths.allSatisfy({ $0.count <= 850 && $0.allSatisfy(Self.validPoint) }),
              bombPosition.map(Self.validPoint) ?? true,
              bombCarrier.map({ (0...1).contains($0) }) ?? true,
              planter.map({ (0...1).contains($0) }) ?? true,
              defuser.map({ (2...3).contains($0) }) ?? true else { return false }
        for (i, p) in players.enumerated() {
            guard p.id == i, p.team == (i < 2 ? .attackers : .defenders), Self.validPoint(p.position),
                  p.yaw.isFinite, abs(p.yaw) <= 1_000_000, p.pitch.isFinite, abs(p.pitch) <= 1.4,
                  (0...100).contains(p.health), (0...100).contains(p.armor), (0...16_000).contains(p.money),
                  (0...p.weapon.magazine).contains(p.ammo), (0...160).contains(p.reserve),
                  (0...1000).contains(p.kills), (0...1000).contains(p.deaths),
                  p.reloadRemaining.isFinite, (0...2).contains(p.reloadRemaining) else { return false }
        }
        if let carrier = bombCarrier, !players[carrier].alive || bombPosition != nil { return false }
        if phase == .planted && (bombPosition == nil || bombCarrier != nil) { return false }
        if phase == .matchOver && winner == nil { return false }
        return true
    }
    private static func validPoint(_ p: BreachPoint) -> Bool {
        p.x.isFinite && p.z.isFinite && abs(p.x) < 15.3 && abs(p.z) < 15.3
    }
    public mutating func predictMovement(slot: Int, input: BreachInput) {
        guard players.indices.contains(slot), input.isValid, players[slot].alive,
              phase == .live || phase == .planted else { return }
        move(slot, input: input)
    }
    private mutating func move(_ slot: Int, input: BreachInput) {
        let length = max(1, hypot(input.forward, input.strafe))
        let distance = (input.walk ? 2.0 : 4.2) * Self.dt / length
        let dx = (-sin(input.yaw) * input.forward + cos(input.yaw) * input.strafe) * distance
        let dz = (-cos(input.yaw) * input.forward - sin(input.yaw) * input.strafe) * distance
        let x = BreachPoint(players[slot].position.x + dx, players[slot].position.z)
        if BreachSimulation.canStand(x) { players[slot].position = x }
        let z = BreachPoint(players[slot].position.x, players[slot].position.z + dz)
        if BreachSimulation.canStand(z) { players[slot].position = z }
        players[slot].yaw = input.yaw; players[slot].pitch = input.pitch
    }
    public mutating func tick(_ proposed: [BreachInput]) {
        guard phase != .matchOver else { return }
        frame += 1
        // Invalid/missing commands become neutral; a malformed packet cannot poison state.
        let inputs = (0..<4).map { proposed.indices.contains($0) && proposed[$0].isValid ? proposed[$0] : BreachInput() }
        seconds = max(0, seconds - Self.dt)
        if phase == .roundOver {
            if seconds <= 0.000001 { newRound() }
            return
        }
        if phase == .buy {
            for i in players.indices {
                players[i].yaw = inputs[i].yaw; players[i].pitch = inputs[i].pitch
                if players[i].position.distance(to: Self.spawns[i]) <= 3 { purchase(i, input: inputs[i]) }
            }
            if seconds <= 0.000001 { phase = .live; seconds = 90; notice = "Round live" }
            return
        }
        for i in players.indices where players[i].alive {
            cooldowns[i] = max(0, cooldowns[i] - Self.dt)
            if players[i].reloadRemaining > 0 {
                players[i].reloadRemaining = max(0, players[i].reloadRemaining - Self.dt)
                if players[i].reloadRemaining <= 0.000001 {
                    players[i].reloadRemaining = 0
                    let count = min(players[i].weapon.magazine - players[i].ammo, players[i].reserve)
                    players[i].ammo += count; players[i].reserve -= count
                }
            }
            move(i, input: inputs[i])
            while let first = paths[i].first, players[i].position.distance(to: first) < 0.2 { paths[i].removeFirst() }
            if inputs[i].reload, players[i].reloadRemaining == 0,
               players[i].ammo < players[i].weapon.magazine, players[i].reserve > 0 {
                players[i].reloadRemaining = players[i].weapon.reloadTime
            }
        }
        for i in players.indices where players[i].alive {
            if inputs[i].fire { shoot(i, input: inputs[i]) }
        }
        if let carrier = bombCarrier, !players[carrier].alive {
            bombPosition = players[carrier].position; bombCarrier = nil; notice = "Device dropped"
            plantProgress = 0; planter = nil
        }
        if phase == .live, bombCarrier == nil, let dropped = bombPosition,
           let collector = players.first(where: { $0.team == .attackers && $0.alive && $0.position.distance(to: dropped) < 1.2 }) {
            bombCarrier = collector.id; bombPosition = nil; notice = "Device recovered"
        }
        advanceObjective(inputs)
        if phase == .roundOver || phase == .matchOver { return }
        if !players.contains(where: { $0.team == .defenders && $0.alive }) { finish(.attackers, "Defenders eliminated") }
        else if phase == .live && !players.contains(where: { $0.team == .attackers && $0.alive }) { finish(.defenders, "Attackers eliminated") }
        else if seconds <= 0.000001 {
            if phase == .planted { finish(.attackers, "Device detonated") }
            else { finish(.defenders, "Time expired") }
        }
        if phase == .live || phase == .planted {
            for i in players.indices where players[i].alive && frame >= pathRefresh[i] {
                paths[i] = BreachSimulation.route(from: players[i].position, to: objectiveTarget(for: i))
                pathRefresh[i] = frame + 45 + i * 3
            }
        }
    }
    private mutating func purchase(_ i: Int, input: BreachInput) {
        if let weapon = input.buy, weapon != players[i].weapon, players[i].money >= Self.price(weapon) {
            players[i].money -= Self.price(weapon); players[i].weapon = weapon
            players[i].ammo = weapon.magazine; players[i].reserve = weapon.magazine * 5
            players[i].reloadRemaining = 0
        }
        if input.buyArmor && players[i].armor < 100 && players[i].money >= Self.armorPrice {
            players[i].money -= Self.armorPrice; players[i].armor = 100
        }
    }
    private mutating func shoot(_ slot: Int, input: BreachInput) {
        guard cooldowns[slot] <= 0, players[slot].reloadRemaining == 0, players[slot].ammo > 0 else { return }
        players[slot].ammo -= 1; cooldowns[slot] = players[slot].weapon.interval
        let source = players[slot], dx = -sin(input.yaw), dz = -cos(input.yaw)
        // Teammates block shots but cannot take damage. A ray can strike only the nearest body.
        let others = players.indices.filter { $0 != slot && players[$0].alive }.sorted {
            players[$0].position.distance(to: source.position) < players[$1].position.distance(to: source.position)
        }
        for target in others {
            let p = players[target].position
            let along = (p.x-source.position.x)*dx + (p.z-source.position.z)*dz
            let side = abs((p.x-source.position.x)*dz - (p.z-source.position.z)*dx)
            let height = 1.65 + tan(input.pitch)*along
            guard along > 0, side <= 0.42, height >= 0.2, height <= 1.95,
                  BreachSimulation.clearSegment(from: source.position,
                    to: .init(source.position.x + dx * along, source.position.z + dz * along), startHeight: 1.65, endHeight: height) else { continue }
            guard players[target].team != source.team else { break }
            var damage = source.weapon.damage * (height > 1.55 ? 2 : 1)
            let absorbed = min(players[target].armor, damage / 2)
            players[target].armor -= absorbed; damage -= absorbed
            players[target].health = max(0, players[target].health - damage)
            if !players[target].alive {
                players[target].deaths += 1; players[slot].kills += 1
                players[slot].money = min(16_000, players[slot].money + 300)
            }
            break
        }
    }
    private mutating func advanceObjective(_ inputs: [BreachInput]) {
        if phase == .live {
            guard let carrier = bombCarrier, players[carrier].alive, inputs[carrier].interact,
                  !inputs[carrier].fire, !inputs[carrier].reload,
                  hypot(inputs[carrier].forward, inputs[carrier].strafe) < 0.01,
                  Self.sites.contains(where: { players[carrier].position.distance(to: $0) <= 2 }) else {
                plantProgress = 0; planter = nil; return
            }
            if planter != carrier { plantProgress = 0; planter = carrier }
            plantProgress = min(3, plantProgress + Self.dt)
            if plantProgress >= 3 - 0.000001 {
                plantProgress = 3; bombPosition = players[carrier].position; bombCarrier = nil
                players[carrier].money = min(16_000, players[carrier].money + 300)
                phase = .planted; seconds = 40; notice = "Device planted. Defenders: hold E at the device to defuse."
                paths = [[BreachPoint]](repeating: [], count: 4); pathRefresh = [Int](repeating: 0, count: 4)
            }
        } else if phase == .planted, let device = bombPosition {
            guard let actor = players.first(where: {
                $0.team == .defenders && $0.alive && $0.position.distance(to: device) <= 2 &&
                inputs[$0.id].interact && !inputs[$0.id].fire && !inputs[$0.id].reload &&
                hypot(inputs[$0.id].forward, inputs[$0.id].strafe) < 0.01
            }) else { defuseProgress = 0; defuser = nil; return }
            if defuser != actor.id { defuseProgress = 0; defuser = actor.id }
            defuseProgress = min(5, defuseProgress + Self.dt)
            if defuseProgress >= 5 - 0.000001 {
                defuseProgress = 5; players[actor.id].money = min(16_000, players[actor.id].money + 300)
                finish(.defenders, "Device defused")
            }
        }
    }
    private mutating func finish(_ team: BreachTeam, _ reason: String) {
        guard phase != .roundOver && phase != .matchOver else { return }
        roundWinner = team; notice = reason
        if team == .attackers { attackersScore += 1 } else { defendersScore += 1 }
        for i in players.indices { players[i].money = min(16_000, players[i].money + (players[i].team == team ? 3_250 : 1_900)) }
        if max(attackersScore, defendersScore) >= 5 { winner = team; phase = .matchOver; seconds = 0 }
        else { phase = .roundOver; seconds = 4 }
    }
    private mutating func newRound() {
        round += 1; phase = .buy; seconds = 15; roundWinner = nil
        bombPosition = nil; bombCarrier = 0; plantProgress = 0; defuseProgress = 0; planter = nil; defuser = nil
        cooldowns = [Double](repeating: 0, count: 4); paths = [[BreachPoint]](repeating: [], count: 4)
        pathRefresh = [Int](repeating: 0, count: 4)
        notice = "Buy equipment. Attackers plant; defenders protect the sites."
        for i in players.indices {
            if !players[i].alive { players[i].weapon = .pistol; players[i].armor = 0 }
            players[i].health = 100; players[i].position = Self.spawns[i]
            players[i].yaw = i < 2 ? 0 : .pi; players[i].pitch = 0
            players[i].ammo = players[i].weapon.magazine; players[i].reserve = players[i].weapon.magazine * 5
            players[i].reloadRemaining = 0
        }
    }
    private func objectiveTarget(for slot: Int) -> BreachPoint {
        let player = players[slot]
        if let enemy = players.filter({ $0.alive && $0.team != player.team && BreachSimulation.visible(from: player.position, to: $0.position) })
            .min(by: { $0.position.distance(to: player.position) < $1.position.distance(to: player.position) }) { return enemy.position }
        if phase == .planted, let device = bombPosition { return device }
        if player.team == .attackers {
            if let dropped = bombPosition { return dropped }
            // Escorts take the other lane, then converge on the carrier's site.
            return Self.sites[(round - 1) % 2]
        }
        return Self.sites[slot - 2]
    }
    public func botInput(for slot: Int) -> BreachInput {
        var input = BreachInput()
        guard players.indices.contains(slot), players[slot].alive else { return input }
        let p = players[slot]; input.yaw = p.yaw; input.pitch = p.pitch
        if phase == .buy {
            if p.money >= Self.price(.rifle) { input.buy = .rifle }
            else if p.weapon == .pistol && p.money >= Self.price(.smg) { input.buy = .smg }
            input.buyArmor = p.armor < 100
            return input
        }
        guard phase == .live || phase == .planted else { return input }
        let enemy = players.filter { $0.alive && $0.team != p.team && BreachSimulation.visible(from: p.position, to: $0.position) }
            .min { $0.position.distance(to: p.position) < $1.position.distance(to: p.position) }
        if let enemy {
            let distance = p.position.distance(to: enemy.position)
            input.yaw = atan2(-(enemy.position.x-p.position.x), -(enemy.position.z-p.position.z))
            // Body aim and controlled bursts allow counterplay; bots obey reload/ammunition rules.
            let bodyClear = BreachSimulation.clearSegment(from: p.position, to: enemy.position, startHeight: 1.65, endHeight: 1.25)
            input.pitch = bodyClear ? atan2(-0.4, max(0.1, distance)) : 0
            input.fire = frame % 48 < 9
            input.reload = p.ammo == 0 || (p.ammo < 4 && frame % 48 > 30)
            return input
        }
        input.reload = p.ammo < p.weapon.magazine / 2
        let target = objectiveTarget(for: slot), distance = p.position.distance(to: target)
        if p.team == .attackers && phase == .live && bombCarrier == slot && distance <= 1.5 {
            input.interact = true; input.reload = false; return input
        }
        if p.team == .defenders && phase == .planted && distance <= 1.5 {
            input.interact = true; input.reload = false; return input
        }
        if distance < 1.0 { return input }
        let waypoint = paths[slot].first ?? target
        input.yaw = atan2(-(waypoint.x-p.position.x), -(waypoint.z-p.position.z)); input.pitch = 0
        input.forward = 1
        return input
    }
}
