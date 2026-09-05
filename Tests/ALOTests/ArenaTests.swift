import Foundation
import Testing
@testable import ALOCore
@testable import ALO

@Suite struct ArenaSimulationTests {
    @Test func mapGeometryChangesCollisionAndSurvivesWireRoundTrip() throws {
        var garden = ArenaSimulation(map: .moonGarden)
        garden.countdown = 0; garden.fighters[0].x = 500; garden.fighters[0].y = 430
        var bridge = ArenaSimulation(map: .skybridge)
        bridge.countdown = 0; bridge.fighters[0].x = 500; bridge.fighters[0].y = 430
        for _ in 0..<20 { garden.tick([ArenaInput(), ArenaInput()]); bridge.tick([ArenaInput(), ArenaInput()]) }
        #expect(garden.fighters[0].y == 405)
        #expect(bridge.fighters[0].y < 405)
        let packet = ArenaPacket(kind: .state, session: UUID().uuidString, state: garden)
        let decoded = try JSONDecoder().decode(ArenaPacket.self, from: JSONEncoder().encode(packet))
        #expect(decoded.isValid); #expect(decoded.state?.map == .moonGarden)
        var incompatible = packet; incompatible.version = 1
        #expect(!incompatible.isValid)
    }

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
        packet.version = 4
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
    @Test func fiveMembersUseTwoSlotsAndThreeSpectatorsWithSharedMap() throws {
        let host = ArenaSession(), guest = ArenaSession(), watchers = (0..<3).map { _ in ArenaSession() }, wire = Wire()
        defer { host.disconnect(); guest.disconnect(); watchers.forEach { $0.disconnect() } }
        wire.add("host", host); wire.add("guest", guest)
        for (index, watcher) in watchers.enumerated() { wire.add("watcher-\(index)", watcher) }
        host.selectedMap = .moonGarden; host.host(); wire.drain()
        let lobby = try #require(guest.lobbies.first)
        #expect(lobby.map == .moonGarden)
        guest.join(lobby); wire.drain(); guest.readyUp(); host.readyUp(); wire.drain()
        #expect(host.latencyMilliseconds != nil); #expect(guest.latencyMilliseconds != nil)
        for watcher in watchers { watcher.join(lobby, spectate: true); wire.drain() }
        #expect(host.spectatorCount == 3)
        #expect(guest.simulation.map == .moonGarden)
        #expect(watchers.allSatisfy { $0.simulation.map == .moonGarden && $0.mode == .spectator })
        host.leave(); wire.drain()
        #expect(watchers.allSatisfy { $0.mode == .picker })
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

@Suite("Four fighter room arenas", .serialized)
struct ArenaRoomRosterTests {
    @MainActor final class Bus {
        var peers: [String: ArenaSession] = [:]
        var pending: [(String, Data, String?)] = []
        func add(_ id: String) -> ArenaSession {
            let session = ArenaSession(); session.localName = id; session.localParticipantID = id
            session.send = { [weak self] data, target in self?.pending.append((id, data, target)) }
            peers[id] = session
            return session
        }
        func drain() {
            var count = 0
            while !pending.isEmpty && count < 1000 {
                let (sender, data, target) = pending.removeFirst(); count += 1
                if let target { peers[target]?.receive(from: sender, data: data) }
                else { for (id, session) in peers where id != sender { session.receive(from: sender, data: data) } }
            }
            #expect(pending.isEmpty)
        }
        func stop() { for session in peers.values { session.disconnect() }; pending = [] }
    }

    @Test @MainActor func humansReplaceBotsWithoutResetAndOverflowSpectates() throws {
        let bus = Bus(), host = bus.add("host"), one = bus.add("one"), two = bus.add("two"), three = bus.add("three"), four = bus.add("four"), five = bus.add("five")
        defer { bus.stop() }
        host.host(botCount: 3); host.readyUp(); bus.drain()
        #expect(host.mode == .host)
        host.simulation.countdown = 0; host.simulation.frame = 120
        host.simulation.fighters[1].damage = 73; host.simulation.fighters[1].stocks = 2
        let oldFighter = host.simulation.fighters[1]
        one.join(try #require(one.lobbies.first)); bus.drain()
        #expect(one.mode == .guest); #expect(one.localIndex == 1)
        #expect(host.simulation.fighters[1] == oldFighter)
        #expect(one.simulation.fighters[1] == oldFighter)
        two.join(try #require(two.lobbies.first)); bus.drain()
        three.join(try #require(three.lobbies.first)); bus.drain()
        #expect(host.botSlots.isEmpty); #expect(host.playerSlots.count == 4)
        #expect(two.localIndex == 2); #expect(three.localIndex == 3)
        four.join(try #require(four.lobbies.first)); bus.drain()
        five.join(try #require(five.lobbies.first), spectate: true); bus.drain()
        #expect(four.mode == .spectator); #expect(five.mode == .spectator)
        #expect(host.spectatorCount == 2)
        one.leave(); bus.drain()
        #expect(host.mode == .host); #expect(host.botSlots.contains(1))
        #expect(host.simulation.fighters[1] == oldFighter)
    }

    @Test @MainActor func allHumanReadinessAndHostDeparture() throws {
        let bus = Bus(), host = bus.add("host"), guest = bus.add("guest")
        defer { bus.stop() }
        host.host(); bus.drain(); guest.join(try #require(guest.lobbies.first)); bus.drain()
        host.readyUp(); bus.drain(); #expect(host.mode == .readyHost)
        guest.readyUp(); bus.drain(); #expect(host.mode == .host); #expect(guest.mode == .guest)
        host.leave(); bus.drain(); #expect(guest.mode == .picker)
        #expect(guest.notice.contains("host left"))
    }

    @Test @MainActor func receivedResultsCarryStableIDsAndDeduplicate() async throws {
        let bus = Bus(), host = bus.add("host"), guest = bus.add("guest")
        defer { bus.stop() }
        var hostResults: [ArenaMatchResult] = [], guestResults: [ArenaMatchResult] = []
        host.onMatchFinished = { hostResults.append($0) }; guest.onMatchFinished = { guestResults.append($0) }
        host.host(botCount: 3); host.readyUp(); bus.drain()
        guest.join(try #require(guest.lobbies.first)); bus.drain()
        host.simulation.winner = 1
        try await Task.sleep(for: .milliseconds(120)); bus.drain()
        #expect(hostResults.count == 1); #expect(guestResults.count == 1)
        #expect(guestResults.first?.participantIDs == ["host", "guest", nil, nil])
        #expect(guestResults.first?.botSlots == Set([2,3]))
        #expect(guestResults.first?.winner == 1)
        try await Task.sleep(for: .milliseconds(80)); bus.drain()
        #expect(guestResults.count == 1)
    }

    @Test func fourWaySimulationHasBoundedValidatedSnapshot() throws {
        var simulation = ArenaSimulation(kinds: [.nova, .atlas, .nova, .atlas])
        simulation.countdown = 0
        for _ in 0..<1200 {
            simulation.tick(simulation.fighters.indices.map { simulation.botInput(for: $0) })
            #expect(simulation.isValidSnapshot)
        }
        let packet = ArenaPacket(kind: .state, session: UUID().uuidString, state: simulation)
        #expect(try JSONEncoder().encode(packet).count < 8192)
        #expect(packet.version == 4)
        var legacy = packet; legacy.version = 2; #expect(!legacy.isValid)
        var oversized = simulation; oversized.fighters.append(simulation.fighters[0]); #expect(!oversized.isValidSnapshot)
    }

    @Test func fourWayTimeoutAndSimultaneousHits() {
        var simulation = ArenaSimulation(kinds: [.nova, .atlas, .nova, .atlas])
        simulation.countdown = 0; simulation.remainingFrames = 1
        simulation.fighters[2].stocks = 3
        for i in [0,1,3] { simulation.fighters[i].stocks = 2 }
        simulation.tick(Array(repeating: ArenaInput(), count: 4)); #expect(simulation.winner == 2)
        var hits = ArenaSimulation(kinds: [.nova, .atlas, .nova, .atlas]); hits.countdown = 0
        hits.fighters[0].x = 350; hits.fighters[0].y = 150
        for i in 1..<4 { hits.fighters[i].x = 403; hits.fighters[i].y = 150 }
        var attack = ArenaInput(); attack.light = true
        for _ in 0..<6 { hits.tick([attack, ArenaInput(), ArenaInput(), ArenaInput()]) }
        #expect(hits.fighters.dropFirst().allSatisfy { $0.hitSerial == 1 })
    }
}

@Suite("Directional sword and gauntlet combat")
struct ArenaAttackProfileTests {
    @Test func eachCharacterHasTwelveDistinctMoves() {
        for kind in ArenaFighterKind.allCases {
            var titles = Set<String>()
            for aerial in [false, true] { for heavy in [false, true] { for direction in -1...1 {
                let move = ArenaAttackProfile.resolve(kind: kind, heavy: heavy, direction: direction, aerial: aerial)
                titles.insert(move.title)
                #expect(move.startup > 0 && move.activeFrames > 0)
                #expect(move.startup + move.activeFrames < move.totalFrames)
                #expect(move.totalFrames <= 60)
            } } }
            #expect(titles.count == 12)
        }
        let sword = ArenaAttackProfile.resolve(kind: .nova, heavy: true, direction: 0, aerial: false)
        let fist = ArenaAttackProfile.resolve(kind: .atlas, heavy: true, direction: 0, aerial: false)
        #expect(sword.startup < fist.startup); #expect(sword.reach > fist.reach); #expect(fist.damage > sword.damage)
    }

    @Test func aerialMoveDoesNotChangeWhenLanding() {
        var sim = ArenaSimulation(); sim.countdown = 0
        sim.fighters[0].y = 152; sim.fighters[0].vy = -200
        var attack = ArenaInput(); attack.light = true; attack.vertical = -1
        sim.tick([attack, ArenaInput()])
        #expect(sim.fighters[0].grounded)
        #expect(sim.fighters[0].attackAerial == true)
        #expect(sim.attackProfile(0).title == "Falling Point")
        #expect(sim.attackProfile(0).launchY < 0)
    }

    @Test func aerialRecoveryCannotBeRepeatedBeforeLanding() {
        var sim = ArenaSimulation(); sim.countdown = 0
        sim.fighters[0].x = -50; sim.fighters[0].y = 200
        var recovery = ArenaInput(); recovery.heavy = true; recovery.vertical = 1
        sim.tick([recovery, ArenaInput()])
        #expect(sim.fighters[0].vy > 600); #expect(!sim.fighters[0].recoveryAvailable)
        sim.fighters[0].attackFrames = 0
        sim.tick([ArenaInput(), ArenaInput()])
        let velocity = sim.fighters[0].vy
        sim.tick([recovery, ArenaInput()])
        #expect(sim.fighters[0].vy < velocity)
        #expect(!sim.fighters[0].recoveryAvailable)
    }

    @Test func faultlineLaunchesNearbyOpponentsAwayOnBothSides() {
        var sim = ArenaSimulation(kinds: [.atlas, .nova, .nova]); sim.countdown = 0
        for index in sim.fighters.indices { sim.fighters[index].y = 150; sim.fighters[index].grounded = true }
        sim.fighters[0].x = 500; sim.fighters[1].x = 430; sim.fighters[2].x = 570
        var smash = ArenaInput(); smash.heavy = true; smash.vertical = -1
        for _ in 0..<20 { sim.tick([smash, ArenaInput(), ArenaInput()]) }
        #expect(sim.attackProfile(0).title == "Faultline")
        #expect(sim.fighters[1].damage == 27 && sim.fighters[2].damage == 27)
        #expect(sim.fighters[1].vx < 0 && sim.fighters[2].vx > 0)
    }

    @Test func novaLungeMovesOnlyWhenSignatureBecomesActive() {
        var sim = ArenaSimulation(); sim.countdown = 0
        sim.fighters[0].grounded = true; sim.fighters[0].y = 150
        var signature = ArenaInput(); signature.heavy = true
        for _ in 0..<13 { sim.tick([signature, ArenaInput()]) }
        #expect(sim.fighters[0].vx == 0)
        sim.tick([signature, ArenaInput()])
        #expect(sim.fighters[0].vx == 360)
    }
}

@Suite("Five fighter roster and bot difficulty")
struct ArenaRosterDifficultyTests {
    @Test func fiveWeaponsHaveDistinctTradeoffsAndSixtyMoves() {
        #expect(ArenaFighterKind.allCases.count == 5)
        var titles = Set<String>()
        for fighter in ArenaFighterKind.allCases {
            for aerial in [false,true] { for heavy in [false,true] { for direction in -1...1 {
                let move = ArenaAttackProfile.resolve(kind: fighter, heavy: heavy, direction: direction, aerial: aerial)
                titles.insert(move.title)
                #expect(move.totalFrames <= 60)
            } } }
        }
        #expect(titles.count == 60)
        let spear = ArenaAttackProfile.resolve(kind: .ember, heavy: true, direction: 0, aerial: false)
        let hammer = ArenaAttackProfile.resolve(kind: .rook, heavy: true, direction: 0, aerial: false)
        #expect(spear.reach > hammer.reach); #expect(hammer.damage > spear.damage)
        #expect(ArenaFighterKind.wisp.speed > ArenaFighterKind.rook.speed)
    }
    @Test func everyDifficultyAndRosterProducesDeterministicValidInputs() {
        for difficulty in ArenaBotDifficulty.allCases {
            var a = ArenaSimulation(kinds: [.ember,.wisp,.rook,.atlas]), b = a
            a.countdown = 0; b.countdown = 0
            for _ in 0..<600 {
                let inputs = a.fighters.indices.map { a.botInput(for: $0, difficulty: difficulty) }
                #expect(inputs.allSatisfy(\.isValid))
                #expect(inputs == b.fighters.indices.map { b.botInput(for: $0, difficulty: difficulty) })
                a.tick(inputs); b.tick(inputs)
                #expect(a == b); #expect(a.isValidSnapshot)
            }
        }
    }
    @Test func nearbyBotTurnsTowardOpponentThenHoldsSpacing() {
        var sim = ArenaSimulation(); sim.countdown = 0
        sim.fighters[0].x = 400; sim.fighters[0].y = 150; sim.fighters[0].grounded = true
        sim.fighters[1].x = 425; sim.fighters[1].y = 150; sim.fighters[1].grounded = true
        sim.fighters[1].facing = 1
        let turn = sim.botInput(for: 1)
        #expect(turn.horizontal == -1)
        sim.tick([ArenaInput(), turn])
        #expect(sim.fighters[1].facing == -1)
        #expect(sim.botInput(for: 1).horizontal == 0)
    }

    @Test func recoveryTakesPriorityAndHardBotsDefendEarlier() {
        var sim = ArenaSimulation(kinds: [.rook,.wisp]); sim.countdown = 0
        sim.frame = 0; sim.fighters[0].x = 100; sim.fighters[0].y = 60; sim.fighters[0].airJumps = 0
        let recovery = sim.botInput(for: 0, difficulty: .hard)
        #expect(recovery.horizontal == 1); #expect(recovery.vertical == 1); #expect(recovery.heavy)
        sim.fighters[0].x = 400; sim.fighters[0].y = 150; sim.fighters[1].x = 450; sim.fighters[1].y = 150
        sim.fighters[1].attackFrames = 20
        #expect(sim.botInput(for: 0, difficulty: .hard).dodge)
        #expect(!sim.botInput(for: 0, difficulty: .easy).dodge)
        #expect(ArenaBotDifficulty.hard.decisionInterval < ArenaBotDifficulty.normal.decisionInterval)
        #expect(ArenaBotDifficulty.normal.decisionInterval < ArenaBotDifficulty.easy.decisionInterval)
    }
}
