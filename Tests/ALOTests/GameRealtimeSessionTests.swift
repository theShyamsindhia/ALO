import Foundation
import Testing
@testable import ALO
import ALOCore

@MainActor struct GameRealtimeSessionTests {
    @Test func riftMovesBeforeHostReplyAndGuestMenuNeverPausesHost() throws {
        let bus = ArenaRoomRosterTests.Bus(), host = bus.add("host"), guest = bus.add("guest")
        defer { bus.stop() }
        host.host(); bus.drain()
        guest.join(try #require(guest.lobbies.first)); bus.drain()
        guest.readyUp(); host.readyUp(); bus.drain()
        host.simulation.countdown = 0
        var now = ProcessInfo.processInfo.systemUptime + 0.05
        host.update(at: now); bus.drain()
        let index = guest.localIndex, original = guest.simulation.fighters[index].x
        var input = ArenaInput(); input.horizontal = -1; input.jump = true
        guest.setInput(input); guest.update(at: now + GameRealtimePolicy.step)
        // Bus remains undrained: the host has not received this input or replied.
        #expect(guest.simulation.fighters[index].x < original)
        let sent = bus.pending.compactMap { try? JSONDecoder().decode(ArenaPacket.self, from: $0.1) }.filter { $0.kind == .input }
        #expect(!sent.isEmpty)
        guest.togglePause(); bus.drain()
        let hostFrame = host.simulation.frame
        now += 0.1; host.update(at: now); bus.drain()
        #expect(host.simulation.frame > hostFrame)
        #expect(guest.showsMenu && !guest.paused)
        #expect(guest.mode == .guest)
        #expect(guest.simulation.frame == host.simulation.frame)
        #expect(!guest.sampledInput().jump && guest.sampledInput().horizontal == 0)
    }
    @Test func stickGuestMenuKeepsNetworkStateMoving() throws {
        let host = StickFightSession(), guest = StickFightSession()
        defer { guest.disconnect(); host.disconnect() }
        var messages: [(Bool,Data)] = []
        host.send = { data, _ in messages.append((true,data)) }
        guest.send = { data, _ in messages.append((false,data)) }
        func drain() {
            var count = 0
            while !messages.isEmpty && count < 100 {
                let (fromHost, data) = messages.removeFirst(); count += 1
                if fromHost { guest.receive(from:"host",data:data) } else { host.receive(from:"guest",data:data) }
            }
        }
        host.host(); drain(); guest.join(try #require(guest.lobbies.first)); drain()
        guest.readyUp(); host.readyUp(); drain()
        guest.togglePause()
        let before = guest.simulation.frame
        let now = ProcessInfo.processInfo.systemUptime
        for tick in 1...12 {
            host.update(at:now + Double(tick)*GameRealtimePolicy.step)
            guest.update(at:now + Double(tick)*GameRealtimePolicy.step)
            drain()
        }
        #expect(guest.showsMenu && guest.started)
        #expect(guest.simulation.frame > before)
        #expect(guest.simulation.frame == host.simulation.frame)
    }
}
