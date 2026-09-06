import Foundation
import Network
import Testing
@testable import ALONetworking
@testable import ALOCore

@Suite("Breach authenticated loopback transport", .serialized)
struct BreachTransportTests {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var storedPort: NWEndpoint.Port?
        private var storedParticipants = 0
        private var storedPackets: [(String, Data)] = []
        private var storedEvents: [MeshRoomEvent] = []
        var port: NWEndpoint.Port? { lock.withLock { storedPort } }
        var participants: Int { lock.withLock { storedParticipants } }
        var packets: [(String, Data)] { lock.withLock { storedPackets } }
        var events: [MeshRoomEvent] { lock.withLock { storedEvents } }
        func setPort(_ value: NWEndpoint.Port) { lock.withLock { storedPort = value } }
        func people(_ value: [RoomParticipant]) { lock.withLock { storedParticipants = value.count } }
        func receive(_ sender: String, _ data: Data) { lock.withLock { storedPackets.append((sender, data)) } }
        func replica(_ value: MeshRoomReplica) { lock.withLock { storedEvents = value.events } }
    }
    private func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return predicate()
    }
    @Test func privateRoomCarriesLobbySnapshotsAndReverseInputs() throws {
        let room = RoomConfiguration(id: UUID().uuidString, name: "Breach transport QA", isPrivate: true, accessKey: UUID().uuidString)
        let hostProbe = Probe(), guestProbe = Probe()
        let host = MeshControlPlane(room: room, nodeID: "breach-a", displayName: "Host", listenerReadyHandler: hostProbe.setPort,
                                    replicaHandler: hostProbe.replica, participantsHandler: hostProbe.people, arenaHandler: hostProbe.receive)
        let guest = MeshControlPlane(room: room, nodeID: "breach-b", displayName: "Guest", listenerReadyHandler: guestProbe.setPort,
                                     replicaHandler: guestProbe.replica, participantsHandler: guestProbe.people, arenaHandler: guestProbe.receive)
        try host.start(advertise: false); try guest.start(advertise: false)
        defer { host.stop(); guest.stop() }
        try #require(wait { guestProbe.port != nil })
        host.connectForTesting(to: .hostPort(host: "127.0.0.1", port: try #require(guestProbe.port)))
        try #require(wait { hostProbe.participants == 2 && guestProbe.participants == 2 })
        let session = UUID().uuidString
        let roster = (0..<4).map { BreachSlot(index: $0, name: "Player \($0)", isBot: $0 > 1, ready: true) }
        var lobby = BreachPacket(kind: .lobby, session: session, sequence: 1)
        lobby.slots = roster; lobby.availableSlots = 2; lobby.started = true
        let lobbyData = try JSONEncoder().encode(lobby)
        host.publishArena(lobbyData, targetID: "breach-b")
        try #require(wait { guestProbe.packets.contains { $0.0 == "breach-a" && $0.1 == lobbyData } })
        var state = BreachPacket(kind: .state, session: session, sequence: 2)
        state.slots = roster; state.state = BreachMatch().networkSnapshot
        state.started = true; state.assignedSlot = 1; state.spectating = false; state.acknowledgedInput = -1
        #expect(state.isValid)
        let stateData = try JSONEncoder().encode(state)
        #expect(stateData.count <= GameRealtimePolicy.maximumPacketBytes)
        host.publishArena(stateData, targetID: "breach-b")
        try #require(wait { guestProbe.packets.contains { $0.0 == "breach-a" && $0.1 == stateData } })
        var input = BreachInput(); input.forward = 1; input.fire = true
        var command = BreachPacket(kind: .input, session: session, sequence: 3); command.input = input
        let commandData = try JSONEncoder().encode(command)
        guest.publishArena(commandData, targetID: "breach-a")
        try #require(wait { hostProbe.packets.contains { $0.0 == "breach-b" && $0.1 == commandData } })
        // Invalid commands and snapshots cannot reach the authenticated wire.
        state.state?.players[1].health = 999; command.input?.forward = 99
        host.publishArena(try JSONEncoder().encode(state), targetID: "breach-b")
        guest.publishArena(try JSONEncoder().encode(command), targetID: "breach-a")
        host.publishChat("Host barrier"); guest.publishChat("Guest barrier")
        try #require(wait { guestProbe.events.contains { $0.text == "Host barrier" } && hostProbe.events.contains { $0.text == "Guest barrier" } })
        #expect(guestProbe.packets.count == 2); #expect(hostProbe.packets.count == 1)
        #expect(guestProbe.events.allSatisfy { $0.kind != .chat || $0.text == "Host barrier" || $0.text == "Guest barrier" })
    }
}
