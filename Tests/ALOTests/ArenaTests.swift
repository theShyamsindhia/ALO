import Foundation
import Testing
@testable import ALOCore
@testable import ALO

@Suite struct ArenaSimulationTests {
    private func started() -> ArenaSimulation {
        var simulation = ArenaSimulation(); simulation.countdown = 0
        for i in 0..<2 { simulation.fighters[i].y = 150; simulation.fighters[i].grounded = true }
        return simulation
    }
    @Test func countdownDoesNotMoveFighters() {
        var sim = ArenaSimulation(); let positions = sim.fighters
        var input = ArenaInput(); input.horizontal = 1; input.jump = true
        sim.tick([input, ArenaInput()])
        #expect(sim.fighters == positions); #expect(sim.countdown == 179)
    }
    @Test func jumpIsEdgeTriggeredAndHasTwoAirJumps() {
        var sim = started(); var jump = ArenaInput(); jump.jump = true
        sim.tick([jump, ArenaInput()]); #expect(sim.fighters[0].airJumps == 2)
        for _ in 0..<5 { sim.tick([jump, ArenaInput()]) }
        #expect(sim.fighters[0].airJumps == 2)
        for remaining in [1, 0] {
            sim.tick([ArenaInput(), ArenaInput()]); sim.tick([jump, ArenaInput()])
            #expect(sim.fighters[0].airJumps == remaining)
        }
        sim.tick([ArenaInput(), ArenaInput()]); sim.tick([jump, ArenaInput()])
        #expect(sim.fighters[0].airJumps == 0)
    }
    @Test func platformLandingRefreshesRecovery() {
        var sim = started(); sim.fighters[0].y = 152; sim.fighters[0].vy = -300
        sim.fighters[0].airJumps = 0; sim.fighters[0].recoveryAvailable = false
        sim.tick([ArenaInput(), ArenaInput()])
        #expect(sim.fighters[0].grounded); #expect(sim.fighters[0].y == 150)
        #expect(sim.fighters[0].airJumps == 2); #expect(sim.fighters[0].recoveryAvailable)
    }
    @Test func dropThroughUpperPlatformButNotMainFloor() {
        var sim = started(); sim.fighters[0].y = 305; var down = ArenaInput(); down.vertical = -1
        sim.tick([down, ArenaInput()]); #expect(sim.fighters[0].y < 305)
        sim.fighters[0].y = 150
        sim.tick([down, ArenaInput()]); #expect(sim.fighters[0].y == 150)
    }
    @Test func attackHasStartupHitsOnlyOnceAndDamageIncreasesLaunch() {
        func strike(damage: Double) -> ArenaSimulation {
            var sim = started(); sim.fighters[1].x = 403; sim.fighters[1].damage = damage
            var input = ArenaInput(); input.heavy = true
            for _ in 0..<13 { sim.tick([input, ArenaInput()]) }
            #expect(sim.fighters[1].damage == damage)
            sim.tick([input, ArenaInput()])
            #expect(sim.fighters[1].damage > damage)
            return sim
        }
        let fresh = strike(damage: 0), hurt = strike(damage: 100)
        #expect(hurt.fighters[1].vx > fresh.fighters[1].vx)
        var sim = fresh
        for _ in 0..<8 { sim.tick([ArenaInput(), ArenaInput()]) }
        #expect(sim.fighters[1].hitSerial == 1)
    }
    @Test func dodgeAvoidsActiveAttackAndCannotBeSpammed() {
        var sim = started(); sim.fighters[1].x = 405
        var light = ArenaInput(); light.light = true
        var dodge = ArenaInput(); dodge.dodge = true
        for _ in 0..<8 { sim.tick([light, dodge]) }
        #expect(sim.fighters[1].damage == 0); #expect(sim.fighters[1].dodgeCooldown > 0)
    }
    @Test func ringOutLosesStockAndRespawnsProtected() {
        var sim = started(); sim.fighters[0].y = -150
        sim.tick([ArenaInput(), ArenaInput()]); #expect(sim.fighters[0].stocks == 2)
        for _ in 0..<75 { sim.tick([ArenaInput(), ArenaInput()]) }
        #expect(sim.fighters[0].damage == 0); #expect(sim.fighters[0].invulnerable == 120)
    }
    @Test func finalStockAndSimultaneousRingOutResolve() {
        var sim = started()
        for i in 0..<2 { sim.fighters[i].stocks = 1; sim.fighters[i].y = -150 }
        sim.tick([ArenaInput(), ArenaInput()]); #expect(sim.winner == -1)
        let frame = sim.frame; sim.tick([ArenaInput(), ArenaInput()]); #expect(sim.frame == frame)
    }
    @Test func simulationIsDeterministicAndRoundBounded() {
        var a = ArenaSimulation(), b = a
        for step in 0..<12_000 {
            var input = ArenaInput(); input.horizontal = step % 180 < 90 ? 1 : -1
            input.jump = step % 47 == 0; input.light = step % 23 == 0; input.heavy = step % 67 == 0
            let inputs = [input, a.botInput()]
            a.tick(inputs); b.tick(inputs)
            #expect(a.isValidSnapshot)
        }
        #expect(a == b); #expect(a.winner != nil)
    }
    @Test func packetRejectsBadVersionsDirectionsAndSnapshots() throws {
        let id = UUID().uuidString
        var input = ArenaInput(); input.horizontal = 2
        #expect(!ArenaPacket(kind: .input, session: id, input: input).isValid)
        #expect(!ArenaPacket(kind: .join, session: "not-a-session", fighter: .nova).isValid)
        var sim = ArenaSimulation(); sim.fighters.removeLast()
        #expect(!ArenaPacket(kind: .state, session: id, state: sim).isValid)
        var packet = ArenaPacket(kind: .state, session: id, state: ArenaSimulation())
        packet.version = 999; #expect(!packet.isValid)
        packet.version = 1
        let encoded = try JSONEncoder().encode(packet)
        #expect(encoded.count < 8192)
        #expect(try JSONDecoder().decode(ArenaPacket.self, from: encoded).isValid)
    }
}

@Suite @MainActor struct ArenaSessionTests {
    /// Deferred packet delivery mirrors the asynchronous authenticated mesh callback.
    @MainActor final class Wire {
        var pending: [@MainActor () -> Void] = []
        var nodes: [String: ArenaSession] = [:]
        func add(_ id: String, _ session: ArenaSession) {
            nodes[id] = session
            session.send = { [weak self] data, target in
                guard let self else { return }
                for (peer, destination) in self.nodes where peer != id && (target == nil || target == peer) {
                    self.pending.append { destination.receive(from: id, data: data) }
                }
            }
        }
        func drain() {
            var count = 0
            while !pending.isEmpty && count < 100 {
                let work = pending.removeFirst(); work(); count += 1
            }
            #expect(pending.isEmpty)
        }
    }
    @Test func roomFlowRequiresBothReadySupportsSpectatingAndEndsOnHostLeave() throws {
        let host = ArenaSession(), guest = ArenaSession(), spectator = ArenaSession(), wire = Wire()
        defer { host.disconnect(); guest.disconnect(); spectator.disconnect() }
        wire.add("host", host); wire.add("guest", guest); wire.add("spectator", spectator)
        host.host(); wire.drain()
        #expect(guest.lobbies.count == 1)
        guest.join(try #require(guest.lobbies.first)); wire.drain()
        #expect(host.mode == .readyHost); #expect(guest.mode == .readyGuest)
        guest.readyUp(); wire.drain(); #expect(host.mode == .readyHost)
        host.readyUp(); wire.drain()
        #expect(host.mode == .host); #expect(guest.mode == .guest)
        spectator.join(try #require(spectator.lobbies.first), spectate: true); wire.drain()
        #expect(spectator.mode == .spectator); #expect(host.spectatorCount == 1)
        host.leave(); wire.drain()
        #expect(guest.mode == .picker); #expect(spectator.mode == .picker)
    }
    @Test func rematchRejectsOldRoundAndKeepsSpectators() throws {
        let host = ArenaSession(), guest = ArenaSession(), watcher = ArenaSession(), wire = Wire()
        defer { host.disconnect(); guest.disconnect(); watcher.disconnect() }
        wire.add("host", host); wire.add("guest", guest); wire.add("watcher", watcher)
        host.host(); wire.drain()
        let lobby = try #require(guest.lobbies.first)
        guest.join(lobby); wire.drain(); guest.readyUp(); host.readyUp(); wire.drain()
        watcher.join(lobby, spectate: true); wire.drain()
        host.simulation.winner = 0; guest.simulation.winner = 0
        guest.rematch(); wire.drain()
        #expect(host.mode == .readyHost); #expect(guest.mode == .readyGuest)
        #expect(watcher.mode == .spectator); #expect(host.spectatorCount == 1)
        var old = ArenaSimulation(); old.winner = 0; old.frame = 500
        let stale = ArenaPacket(kind: .state, session: lobby.sessionID, sequence: 9999, state: old, round: 0)
        guest.receive(from: "host", data: try JSONEncoder().encode(stale))
        #expect(guest.mode == .readyGuest); #expect(guest.simulation.winner == nil)
        guest.readyUp(); host.readyUp(); wire.drain()
        #expect(host.mode == .host); #expect(guest.mode == .guest)
        #expect(guest.simulation.countdown == 180)
    }
    @Test func lifecyclePacketsSurviveSnapshotBackpressure() {
        var queue = ArenaSendQueue()
        queue.enqueue(kind: "ready", data: Data([1]))
        for i in 2...100 { queue.enqueue(kind: "state", data: Data([UInt8(i)])) }
        #expect(queue.count == 2)
        #expect(queue.popFirst() == Data([1])); #expect(queue.popFirst() == Data([100]))
        queue.enqueue(kind: "state", data: Data([5]))
        queue.enqueue(kind: "leave", data: Data([9]))
        #expect(queue.count == 1); #expect(queue.popFirst() == Data([9])); #expect(queue.popFirst() == nil)
    }
    @Test func rejectsWrongPeerAndSessionSnapshots() throws {
        let host = ArenaSession(), guest = ArenaSession(), wire = Wire()
        defer { host.disconnect(); guest.disconnect() }
        wire.add("host", host); wire.add("guest", guest)
        host.host(); wire.drain()
        let lobby = try #require(guest.lobbies.first)
        guest.join(lobby); wire.drain(); guest.readyUp(); host.readyUp(); wire.drain()
        let before = guest.simulation
        var altered = before; altered.fighters[0].damage = 999
        let forged = ArenaPacket(kind: .state, session: lobby.sessionID, sequence: 9999, state: altered)
        guest.receive(from: "outsider", data: try JSONEncoder().encode(forged))
        #expect(guest.simulation == before)
        let wrongSession = ArenaPacket(kind: .state, session: UUID().uuidString, sequence: 9999, state: altered)
        guest.receive(from: "host", data: try JSONEncoder().encode(wrongSession))
        #expect(guest.simulation == before)
    }
}
