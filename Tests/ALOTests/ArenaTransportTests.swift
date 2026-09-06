import Foundation
import Network
import Testing
@testable import ALONetworking
@testable import ALO
@testable import ALOCore

@Suite("Ephemeral activity transport", .serialized)
struct ArenaTransportTests {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        var port: NWEndpoint.Port? { lock.withLock { storedPort } }
        var participants: Int { lock.withLock { storedParticipants } }
        var packets: [(String, Data)] { lock.withLock { storedPackets } }
        var events: [MeshRoomEvent] { lock.withLock { storedEvents } }
        private var storedPort: NWEndpoint.Port?
        private var storedParticipants = 0
        private var storedPackets: [(String, Data)] = []
        private var storedEvents: [MeshRoomEvent] = []
        func setPort(_ port: NWEndpoint.Port) { lock.withLock { storedPort = port } }
        func people(_ people: [RoomParticipant]) { lock.withLock { storedParticipants = people.count } }
        func receive(_ peer: String, _ data: Data) { lock.withLock { storedPackets.append((peer, data)) } }
        func replica(_ replica: MeshRoomReplica) { lock.withLock { storedEvents = replica.events } }
    }
    private func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return predicate()
    }
    @Test("Private-room activity frames coexist with chat without durable history")
    func activityStaysEphemeral() throws {
        let room = RoomConfiguration(id: UUID().uuidString, name: "Arena QA", isPrivate: true, accessKey: UUID().uuidString)
        let aProbe = Probe(), bProbe = Probe()
        let a = MeshControlPlane(room: room, nodeID: "arena-a", displayName: "A", listenerReadyHandler: aProbe.setPort,
                                 replicaHandler: aProbe.replica, participantsHandler: aProbe.people, arenaHandler: aProbe.receive)
        let b = MeshControlPlane(room: room, nodeID: "arena-b", displayName: "B", listenerReadyHandler: bProbe.setPort,
                                 replicaHandler: bProbe.replica, participantsHandler: bProbe.people, arenaHandler: bProbe.receive)
        try a.start(advertise: false); try b.start(advertise: false)
        defer { a.stop(); b.stop() }
        try #require(wait { bProbe.port != nil })
        a.connectForTesting(to: .hostPort(host: "127.0.0.1", port: try #require(bProbe.port)))
        try #require(wait { aProbe.participants == 2 && bProbe.participants == 2 })
        let session = UUID().uuidString
        for frame in 0..<20 {
            var state = ArenaSimulation(); state.frame = frame
            let packet = ArenaPacket(kind: .state, session: session, sequence: frame, state: state)
            a.publishArena(try JSONEncoder().encode(packet), targetID: "arena-b")
        }
        a.publishChat("Chat remains independent")
        let leave = ArenaPacket(kind: .leave, session: session, sequence: 21)
        a.publishArena(try JSONEncoder().encode(leave), targetID: "arena-b")
        try #require(wait { bProbe.packets.contains { (try? JSONDecoder().decode(ArenaPacket.self, from: $0.1))?.kind == .leave } })
        try #require(wait { bProbe.events.contains { $0.text == "Chat remains independent" } })
        #expect(bProbe.packets.allSatisfy { $0.0 == "arena-a" })
        #expect(bProbe.events.filter { $0.kind == .chat }.count == 1)
        #expect(bProbe.events.allSatisfy { $0.text == nil || $0.text == "Chat remains independent" })
        let count = bProbe.packets.count
        a.publishArena(Data(repeating: 0, count: 9000), targetID: "arena-b")
        a.publishChat("Barrier")
        try #require(wait { bProbe.events.contains { $0.text == "Barrier" } })
        #expect(bProbe.packets.count == count)
    }
    @Test("Stick Fight uses authenticated activity transport and rejects invalid frames")
    func stickFightActivityTransport() throws {
        let room = RoomConfiguration(id: UUID().uuidString, name: "Stick Fight QA", isPrivate: true, accessKey: UUID().uuidString)
        let aProbe = Probe(), bProbe = Probe()
        let a = MeshControlPlane(room: room, nodeID: "stick-a", displayName: "A", listenerReadyHandler: aProbe.setPort,
                                 replicaHandler: aProbe.replica, participantsHandler: aProbe.people, arenaHandler: aProbe.receive)
        let b = MeshControlPlane(room: room, nodeID: "stick-b", displayName: "B", listenerReadyHandler: bProbe.setPort,
                                 replicaHandler: bProbe.replica, participantsHandler: bProbe.people, arenaHandler: bProbe.receive)
        try a.start(advertise: false); try b.start(advertise: false)
        defer { a.stop(); b.stop() }
        try #require(wait { bProbe.port != nil })
        a.connectForTesting(to: .hostPort(host: "127.0.0.1", port: try #require(bProbe.port)))
        try #require(wait { aProbe.participants == 2 && bProbe.participants == 2 })
        var packet = StickFightPacket(kind: .lobby, session: UUID().uuidString, sequence: 1)
        packet.availableSlots = 3; packet.started = false
        packet.slots = [StickFightSlot(index: 0, name: "A", isBot: false, ready: false)]
        let data = try JSONEncoder().encode(packet)
        a.publishArena(data, targetID: "stick-b")
        try #require(wait { bProbe.packets.contains { $0.0 == "stick-a" && $0.1 == data } })
        packet.game = "unsupported-game"
        a.publishArena(try JSONEncoder().encode(packet), targetID: "stick-b")
        a.publishChat("Stick Fight transport barrier")
        try #require(wait { bProbe.events.contains { $0.text == "Stick Fight transport barrier" } })
        #expect(bProbe.packets.count == 1)
        #expect(bProbe.events.filter { $0.kind == .chat }.count == 1)
    }

}
