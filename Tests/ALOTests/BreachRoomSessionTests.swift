import Foundation
import Testing
@testable import ALO
@testable import ALOCore

@Suite @MainActor struct BreachRoomSessionTests {
    @MainActor final class Harness {
        var time = ProcessInfo.processInfo.systemUptime
        let host = BreachRoomSession(), guest = BreachRoomSession()
        var packets: [BreachPacket] = []
        init() {
            host.clock = { [unowned self] in time }; guest.clock = { [unowned self] in time }
            host.send = { [weak self] data, target in
                guard let self else { return }
                if let packet = try? JSONDecoder().decode(BreachPacket.self, from: data) { packets.append(packet) }
                if target == nil || target == "guest" { guest.receive(from: "host", data: data) }
            }
            guest.send = { [weak self] data, target in
                guard let self else { return }
                if let packet = try? JSONDecoder().decode(BreachPacket.self, from: data) { packets.append(packet) }
                if target == nil || target == "host" { host.receive(from: "guest", data: data) }
            }
        }
        func connect() throws { host.host(); guest.join(try #require(guest.lobbies.first)); guest.readyUp(); host.readyUp() }
        func step(_ count: Int = 1) { for _ in 0..<count { time += 1.0 / 60; guest.update(at: time); host.update(at: time) } }
        func close() { guest.disconnect(); host.disconnect() }
    }
    @Test func hostStartsWithBotsAndGuestReadyIsRequired() throws {
        let h = Harness(); defer { h.close() }
        h.host.host(); h.guest.join(try #require(h.guest.lobbies.first))
        #expect(h.host.slots.count == 4); #expect(!h.host.slots[1].isBot)
        h.host.readyUp(); #expect(!h.host.started)
        h.guest.readyUp(); #expect(h.host.started); #expect(h.guest.started)
        #expect(h.host.simulation.isValidSnapshot)
    }
    @Test func fourHumansAndSpectatorReceiveSameAuthoritativeMatch() throws {
        let host = BreachRoomSession(), a = BreachRoomSession(), b = BreachRoomSession(), c = BreachRoomSession(), watcher = BreachRoomSession()
        let clients = [a, b, c, watcher]
        var now = ProcessInfo.processInfo.systemUptime
        for session in [host] + clients { session.clock = { now } }
        host.send = { [weak a, weak b, weak c, weak watcher] data, target in
            for (id, peer) in [("a", a), ("b", b), ("c", c), ("watcher", watcher)] where target == nil || target == id { peer?.receive(from: "host", data: data) }
        }
        for (id, peer) in zip(["a", "b", "c", "watcher"], clients) {
            peer.send = { [weak host] data, _ in host?.receive(from: id, data: data) }
        }
        defer { for peer in clients { peer.disconnect() }; host.disconnect() }
        host.host()
        for peer in [a, b, c] { peer.join(try #require(peer.lobbies.first)); peer.readyUp() }
        watcher.join(try #require(watcher.lobbies.first), spectate: true)
        #expect(host.slots.filter { !$0.isBot }.count == 4)
        #expect(watcher.mode == .spectator)
        host.readyUp()
        for _ in 0..<120 {
            now += 1.0 / 60
            for peer in clients { peer.update(at: now) }; host.update(at: now)
        }
        for peer in clients {
            #expect(peer.started)
            #expect(abs(peer.simulation.frame - host.simulation.frame) <= 2)
            #expect(peer.simulation.players.map(\.money) == host.simulation.players.map(\.money))
        }
    }
    @Test func hostCanStartSoloAndLateJoinWaitsForNextRound() throws {
        let h = Harness(); defer { h.close() }
        h.host.host(); h.host.readyUp(); #expect(h.host.started)
        h.guest.join(try #require(h.guest.lobbies.first))
        #expect(h.guest.mode == .guest); #expect(h.guest.waitingForRound)
        #expect(h.guest.notice.contains("next round"))
        let seat = h.guest.localIndex
        h.guest.leave(); #expect(h.host.slots[seat].isBot)
    }
    @Test func buyPulseIsAuthoritativeAndCannotSpendOtherSeatsMoney() throws {
        let h = Harness(); defer { h.close() }; try h.connect()
        var buy = BreachInput(); buy.buyArmor = true
        h.guest.setInput(buy); h.guest.setInput(BreachInput()); h.step(6)
        #expect(h.host.simulation.players[1].armor == 100)
        #expect(h.host.simulation.players[1].money == 150)
        #expect(h.host.simulation.players[0].money == 800)
        #expect(h.guest.simulation.players[1].money == h.host.simulation.players[1].money)
        h.step(10); #expect(h.host.simulation.players[1].money == 150)
    }
    @Test func shortBuyTapSurvivesCoalescedMovementBackpressure() throws {
        let h = Harness(); defer { h.close() }; try h.connect()
        var queue = GameSendQueue()
        h.guest.send = { data, _ in
            if let packet = try? JSONDecoder().decode(BreachPacket.self, from: data) {
                queue.enqueue(kind: packet.kind.rawValue, data: data, stream: "breach")
            }
        }
        var tap = BreachInput(); tap.buyArmor = true
        h.guest.setInput(tap); h.guest.setInput(BreachInput())
        for _ in 0..<5 { h.time += 1.0 / 60; h.guest.update(at: h.time) }
        // Five movement samples collapse to one, but the action remains queued.
        #expect(queue.count == 2)
        while let data = queue.popFirst() { h.host.receive(from: "guest", data: data) }
        h.host.update(at: h.time)
        #expect(h.host.simulation.players[1].armor == 100)
        #expect(h.host.simulation.players[1].money == 150)
    }
    @Test func malformedStaleAndNonmemberInputsAreIgnored() throws {
        let h = Harness(); defer { h.close() }; try h.connect()
        let id = try #require(h.guest.lobbies.first).sessionID
        var input = BreachInput(); input.buyArmor = true
        var p = BreachPacket(kind: .input, session: id, sequence: 900); p.input = input
        h.host.receive(from: "intruder", data: try JSONEncoder().encode(p)); h.step(2)
        #expect(h.host.simulation.players[1].armor == 0)
        input.forward = 999; p.input = input
        h.host.receive(from: "guest", data: try JSONEncoder().encode(p)); h.step(2)
        #expect(h.host.simulation.players[1].armor == 0)
        p.input = BreachInput(); p.sequence = 1000
        h.host.receive(from: "guest", data: try JSONEncoder().encode(p))
        input.forward = 0; p.input = input; p.sequence = 999
        h.host.receive(from: "guest", data: try JSONEncoder().encode(p)); h.step(2)
        #expect(h.host.simulation.players[1].armor == 0)
    }
    @Test func shootingRunsOnlyOnHostAndClientsCannotSetBombProgress() throws {
        let h = Harness(); defer { h.close() }; try h.connect(); h.step(902)
        #expect(h.host.simulation.phase == .live)
        let ammo = h.host.simulation.players[1].ammo
        var input = BreachInput(); input.fire = true
        h.guest.setInput(input); h.guest.setInput(BreachInput()); h.step(4)
        #expect(h.host.simulation.players[1].ammo < ammo)
        #expect(h.guest.simulation.players[1].ammo == h.host.simulation.players[1].ammo)
        let lobby = try #require(h.guest.lobbies.first)
        var fake = BreachPacket(kind: .input, session: lobby.sessionID, sequence: 100_000)
        fake.input = BreachInput(); fake.state = h.host.simulation.networkSnapshot
        fake.state?.plantProgress = 3
        let progress = h.host.simulation.plantProgress
        #expect(!fake.isValid)
        h.host.receive(from: "guest", data: try JSONEncoder().encode(fake))
        #expect(h.host.simulation.plantProgress == progress)
    }
    @Test func disconnectedHeldMovementExpiresWithoutPausingHost() throws {
        let h = Harness(); defer { h.close() }; try h.connect(); h.step(902)
        var movement = BreachInput(); movement.forward = 1
        h.guest.setInput(movement); h.step(4)
        for _ in 0..<30 { h.time += 1.0 / 60; h.host.update(at: h.time) }
        let stopped = h.host.simulation.players[1].position
        for _ in 0..<30 { h.time += 1.0 / 60; h.host.update(at: h.time) }
        #expect(h.host.simulation.players[1].position == stopped)
    }
    @Test func snapshotsCannotBeInjectedByOtherRoomMembersOrRegress() throws {
        let h = Harness(); defer { h.close() }; try h.connect(); h.step(10)
        let old = try #require(h.packets.first { $0.kind == .state })
        let frame = h.guest.simulation.frame
        h.guest.receive(from: "host", data: try JSONEncoder().encode(old))
        #expect(h.guest.simulation.frame == frame)
        var fake = old; fake.sequence = 100_000
        h.guest.receive(from: "intruder", data: try JSONEncoder().encode(fake))
        #expect(h.guest.simulation.frame == frame)
        h.guest.leave(); h.guest.receive(from: "host", data: try JSONEncoder().encode(fake))
        #expect(h.guest.mode == .picker)
    }
    @Test func delayedJoinAfterLeaveCannotReclaimSeat() throws {
        let h = Harness(); defer { h.close() }; try h.connect()
        let oldJoin = try #require(h.packets.first { $0.kind == .join })
        let slot = h.guest.localIndex
        h.guest.leave(); #expect(h.host.slots[slot].isBot)
        h.host.receive(from: "guest", data: try JSONEncoder().encode(oldJoin))
        #expect(h.host.slots[slot].isBot)
    }
    @Test func menusDoNotPauseOnlineAndHostDepartureIsActionable() throws {
        let h = Harness(); defer { h.close() }; try h.connect()
        h.host.showsMenu = true; h.guest.showsMenu = true
        let before = h.host.simulation.frame; h.step(60)
        #expect(h.host.simulation.frame > before)
        h.host.leave(); #expect(h.guest.mode == .picker); #expect(h.guest.roomConnected)
        #expect(h.guest.notice.contains("host left"))
    }
    @Test func guestPredictsNoDamageMoneyOrBombProgress() throws {
        let h = Harness(); defer { h.close() }; try h.connect()
        // Drop host snapshots while guest runs; only local movement can be predicted.
        h.host.send = { _, _ in }
        var input = BreachInput(); input.fire = true; input.interact = true; input.buyArmor = true
        h.guest.setInput(input); let state = h.guest.simulation
        h.step(20)
        #expect(h.guest.simulation.players.map(\.health) == state.players.map(\.health))
        #expect(h.guest.simulation.players.map(\.money) == state.players.map(\.money))
        #expect(h.guest.simulation.plantProgress == state.plantProgress)
    }
    @Test func everyPublishedSnapshotFitsTransportBudget() throws {
        let h = Harness(); defer { h.close() }; try h.connect(); h.step(1_000)
        let states = h.packets.filter { $0.kind == .state }
        #expect(states.count > 200)
        for packet in states { #expect(packet.isValid); #expect(try JSONEncoder().encode(packet).count <= GameRealtimePolicy.maximumPacketBytes) }
        #expect(h.guest.mode == .guest)
    }
}
