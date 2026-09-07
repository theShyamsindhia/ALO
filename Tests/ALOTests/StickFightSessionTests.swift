import Foundation
import Testing
@testable import ALO
@testable import ALOCore

@Suite @MainActor struct StickFightSessionTests {
    private func pair() -> (StickFightSession, StickFightSession) {
        let host = StickFightSession(), guest = StickFightSession()
        host.localName = "Host"; guest.localName = "Guest"
        host.send = { [weak guest] data, target in if target == nil || target == "guest" { guest?.receive(from: "host", data: data) } }
        guest.send = { [weak host] data, target in if target == nil || target == "host" { host?.receive(from: "guest", data: data) } }
        return (host, guest)
    }
    @Test func offlineHostHasActionableStateAndPracticeWorks() {
        let session = StickFightSession(); session.host()
        #expect(session.mode == .picker); #expect(session.notice.contains("Join a channel"))
        session.practice(); #expect(session.mode == .practice); #expect(session.slots.count == 4)
        session.disconnect()
    }
    @Test func joinReadyAndDuplicateJoinAreIdempotent() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(); let lobby = try #require(guest.lobbies.first); guest.join(lobby)
        #expect(guest.mode == .guest); #expect(!guest.started); #expect(host.slots.count == 2)
        let duplicate = StickFightPacket(kind: .join, session: lobby.sessionID, sequence: 100)
        host.receive(from: "guest", data: try JSONEncoder().encode(duplicate))
        #expect(host.slots.count == 2)
        guest.readyUp(); host.readyUp()
        #expect(host.mode == .host); #expect(guest.started)
        guest.leave(); #expect(host.slots[1].isBot)
    }
    @Test func fullLobbyAdmitsSpectatorAndFreedSeatCanBeJoined() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(botCount: 3); let lobby = try #require(guest.lobbies.first)
        // Bots are replaceable in a waiting lobby.
        guest.join(lobby); #expect(guest.mode == .guest); #expect(host.slots.count == 4)
        guest.readyUp(); host.readyUp(); guest.leave()
        let liveLobby = try #require(guest.lobbies.first)
        guest.join(liveLobby); #expect(guest.mode == .spectator); #expect(guest.started)
    }
    @Test func staleAcknowledgementAfterLeaveCannotRejoin() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(); guest.join(try #require(guest.lobbies.first))
        var captured: Data?
        host.send = { data, _ in if (try? JSONDecoder().decode(StickFightPacket.self, from: data).kind) == .state { captured = data } }
        host.addBot(); let packet = try #require(captured)
        guest.leave(); guest.receive(from: "host", data: packet)
        #expect(guest.mode == .picker)
    }
    @Test func hostDeparturePreservesRoomAndAllowsAnotherHost() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(); guest.join(try #require(guest.lobbies.first)); host.leave()
        #expect(guest.mode == .picker); #expect(guest.roomConnected)
        guest.host(); #expect(guest.mode == .hosting)
    }
    @Test func staleInputSequenceIsIgnoredAndHeldInputExpires() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(); let lobby = try #require(guest.lobbies.first); guest.join(lobby)
        guest.readyUp(); host.readyUp()
        var time = ProcessInfo.processInfo.systemUptime
        // Advance the opening countdown with no held input.
        for _ in 0..<150 { time += StickFightSimulation.step; host.update(at: time) }
        var input = StickFightInput(); input.horizontal = 1
        var packet = StickFightPacket(kind: .input, session: lobby.sessionID, sequence: 1000); packet.input = input
        host.receive(from: "guest", data: try JSONEncoder().encode(packet))
        input.horizontal = -1; packet.input = input; packet.sequence = 999
        host.receive(from: "guest", data: try JSONEncoder().encode(packet))
        // receive() timestamps use uptime, so align test callbacks to that clock.
        time = ProcessInfo.processInfo.systemUptime
        host.update(at: time)
        time += StickFightSimulation.step * 2; host.update(at: time)
        #expect(host.simulation.fighters[1].vx >= 0)
        for _ in 0..<50 { time += StickFightSimulation.step; host.update(at: time) }
        #expect(abs(host.simulation.fighters[1].vx) < 1)
    }
    @Test func olderStateCannotReplaceLatestSnapshot() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(); guest.join(try #require(guest.lobbies.first))
        var states: [Data] = []
        host.send = { data, _ in if (try? JSONDecoder().decode(StickFightPacket.self, from: data).kind) == .state { states.append(data) } }
        host.addBot(); host.addBot()
        guest.receive(from: "host", data: try #require(states.last)); #expect(guest.slots.count == 4)
        guest.receive(from: "host", data: try #require(states.first)); #expect(guest.slots.count == 4)
    }
    @Test func quickThrowTapKeepsItsAimUntilNetworkSampling() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(); guest.join(try #require(guest.lobbies.first)); guest.readyUp(); host.readyUp()
        var inputs: [StickFightInput] = []
        guest.send = { data, _ in if let packet = try? JSONDecoder().decode(StickFightPacket.self, from: data), let input = packet.input { inputs.append(input) } }
        var tap = StickFightInput(); tap.throwWeapon = true; tap.aimAngle = 0.75
        guest.setInput(tap); guest.setInput(StickFightInput())
        guest.update(at: ProcessInfo.processInfo.systemUptime + 0.05)
        let sampled = try #require(inputs.last)
        #expect(sampled.throwWeapon); #expect(sampled.aimAngle == 0.75)
        guest.update(at: ProcessInfo.processInfo.systemUptime + 0.1)
        #expect(inputs.last?.throwWeapon == false)
    }
    @Test func delayedSnapshotReplayNeverPredictsDamageOrThrows() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(); let lobby = try #require(guest.lobbies.first); guest.join(lobby); guest.readyUp(); host.readyUp()
        var state = host.simulation; state.countdown = 0
        state.fighters[0].x = 450; state.fighters[1].x = 480
        state.fighters[0].y = 260; state.fighters[1].y = 260
        state.fighters[1].weapon = .pistol; state.fighters[1].ammo = 12
        var snapshot = StickFightPacket(kind: .state, session: lobby.sessionID, sequence: 1000)
        snapshot.state = state; snapshot.slots = host.slots; snapshot.started = true
        snapshot.spectating = false; snapshot.assignedSlot = 1; snapshot.acknowledgedInput = -1
        guest.receive(from: "host", data: try JSONEncoder().encode(snapshot))
        guest.send = { _, _ in }
        var attack = StickFightInput(); attack.punch = true; attack.shoot = true; attack.throwWeapon = true; attack.aimAngle = .pi
        guest.setInput(attack); guest.update(at: ProcessInfo.processInfo.systemUptime + 0.05)
        #expect(guest.simulation.fighters[0].health == state.fighters[0].health)
        #expect(guest.simulation.fighters[1].weapon == .pistol)
        #expect(guest.simulation.projectiles.isEmpty)
        snapshot.sequence += 1
        guest.receive(from: "host", data: try JSONEncoder().encode(snapshot))
        #expect(guest.simulation.fighters[0].health == state.fighters[0].health)
        #expect(guest.simulation.fighters[1].ammo == 12)
        #expect(guest.simulation.projectiles.isEmpty)
        #expect(guest.simulation.frame == state.frame)
    }
    @Test func repeatedFocusClearsDoNotFloodTransport() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(); guest.join(try #require(guest.lobbies.first)); guest.readyUp(); host.readyUp()
        var inputCount = 0
        guest.send = { data, _ in if (try? JSONDecoder().decode(StickFightPacket.self, from: data).kind) == .input { inputCount += 1 } }
        var input = StickFightInput(); input.horizontal = 1; guest.setInput(input)
        for _ in 0..<200 { guest.clearInput() }
        #expect(inputCount == 1)
    }
    @Test func acknowledgementsOnlyIncludeSimulatedInputNotControlPackets() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(); let lobby = try #require(guest.lobbies.first); guest.join(lobby); guest.readyUp(); host.readyUp()
        var replies: [StickFightPacket] = []
        host.send = { data, _ in if let p = try? JSONDecoder().decode(StickFightPacket.self, from: data), p.kind == .state { replies.append(p) } }
        var packet = StickFightPacket(kind: .input, session: lobby.sessionID, sequence: 1000); packet.input = StickFightInput()
        host.receive(from: "guest", data: try JSONEncoder().encode(packet))
        let probe = StickFightPacket(kind: .join, session: lobby.sessionID, sequence: 1001)
        host.receive(from: "guest", data: try JSONEncoder().encode(probe))
        #expect(replies.last?.acknowledgedInput == -1)
        host.update(at: ProcessInfo.processInfo.systemUptime + 0.05)
        host.receive(from: "guest", data: try JSONEncoder().encode(probe))
        #expect(replies.last?.acknowledgedInput == 1000)
        var ready = StickFightPacket(kind: .ready, session: lobby.sessionID, sequence: 2000); ready.ready = true
        host.receive(from: "guest", data: try JSONEncoder().encode(ready))
        #expect(replies.last?.acknowledgedInput == 1000)
    }
    @Test func spectatorCanClaimAnOpenLobbySeatWithoutLeaving() throws {
        let (host, guest) = pair(); defer { guest.disconnect(); host.disconnect() }
        host.host(botCount: 1); guest.join(try #require(guest.lobbies.first), spectate: true)
        #expect(guest.mode == .spectator); #expect(guest.canJoinCurrentLobby)
        guest.joinCurrentLobby()
        #expect(guest.mode == .guest); #expect(guest.canReadyUp)
        #expect(host.slots.count == 2); #expect(!host.slots[1].isBot)
    }
    @Test func unansweredJoinTimesOutAndInvalidPacketIsRejected() throws {
        let session = StickFightSession(); session.send = { _, _ in }; defer { session.disconnect() }
        let lobby = StickFightSession.Lobby(peerID: "missing", sessionID: "session", started: false, availableSlots: 3, humanCount: 1, seen: 0)
        session.join(lobby); session.update(at: ProcessInfo.processInfo.systemUptime + 20)
        #expect(session.mode == .picker); #expect(session.notice.contains("connection lost"))
        var packet = StickFightPacket(kind: .lobby, session: "session", sequence: 0)
        packet.started = false; packet.availableSlots = 99
        session.receive(from: "bad", data: try JSONEncoder().encode(packet)); #expect(session.lobbies.isEmpty)
    }
}

@Suite struct StickFightPacketTests {
    @Test func rejectsNonfiniteAndOutOfRangeAim() {
        var packet = StickFightPacket(kind: .input, session: UUID().uuidString, sequence: 1)
        var input = StickFightInput(); input.aimAngle = .nan; packet.input = input
        #expect(!packet.isValid)
        input.aimAngle = .pi + 0.01; packet.input = input; #expect(!packet.isValid)
        input.aimAngle = -.pi; input.throwWeapon = true; packet.input = input; #expect(packet.isValid)
    }
    @Test func rejectsMixedPayloadAndOutOfRosterAssignment() {
        var packet = StickFightPacket(kind: .input, session: UUID().uuidString, sequence: 1)
        packet.input = StickFightInput(); #expect(packet.isValid)
        packet.state = StickFightSimulation(); #expect(!packet.isValid)
        packet.kind = .state; packet.input = nil; packet.started = true; packet.spectating = false
        packet.slots = [StickFightSlot(index: 0, name: "A", isBot: false, ready: true), StickFightSlot(index: 1, name: "B", isBot: false, ready: true)]
        packet.assignedSlot = 3; #expect(!packet.isValid)
        packet.assignedSlot = 1; #expect(packet.isValid)
        packet.session = "unbounded-or-invalid-session"; #expect(!packet.isValid)
    }
}
