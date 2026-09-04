import Foundation
import Automerge
import Testing
@testable import ALO
@testable import ALOCore

@Suite("Repeatable room network simulation", .serialized)
struct RoomNetworkSimulationTests {
    @Test("Partitioned rooms merge offline edits after restart and delayed reconnect",
          arguments: [UInt64(7), 41, 991, 65_537])
    func partitionRestartAndLateJoin(seed: UInt64) throws {
        let network = try SimulatedRoomNetwork(seed: seed, deviceCount: 4)
        network.connect(0, 1)
        network.connect(1, 2)
        network.connect(2, 3)
        network.connect(0, 3)
        for index in 0..<24 { try network.chat(at: index % 4) }
        try network.settle()
        try network.assertConverged()

        for cycle in 0..<3 {
            // Queue traffic immediately before severing both cross-partition
            // connections. Lost bytes belong to the dead connections only;
            // reconnect creates fresh protocol sessions, as real TCP does.
            for node in 0..<4 { try network.chat(at: node) }
            try network.step()
            network.disconnect(1, 2)
            network.disconnect(0, 3)
            for round in 0..<12 {
                for node in 0..<4 {
                    try network.chat(at: node)
                    if round.isMultiple(of: 3) { try network.enqueueTrack(at: node) }
                    if round % 3 == 2 { try network.removeTrack(at: node) }
                }
                try network.advance(ticks: 2)
            }
            try network.settle()
            let left = Set(try network.nodes[0].snapshot().chatEvents.map(\.id))
            let right = Set(try network.nodes[3].snapshot().chatEvents.map(\.id))
            #expect(left != right, "seed \(seed), cycle \(cycle): partition was not exercised")

            try network.restart(3)
            network.connect(2, 3)
            try network.chat(at: 3)
            network.connect(1, 2)
            network.connect(0, 3)
            try network.settle()
            try network.assertConverged()
        }

        let joiner = try network.addDevice()
        network.connect(0, joiner)
        try network.settle()
        try network.assertConverged()
        #expect(network.droppedMessages > 0, "seed \(seed): no in-flight disconnect was tested")
        #expect(network.deliveredMessages > 100)
        print("Simulation seed \(seed): \(network.deliveredMessages) sync messages, \(network.droppedMessages) interrupted deliveries, 3 partitions/restarts and a fresh late join converged")
    }
}

/// Logical time controls only the network. Storage, Automerge sessions, wire
/// chunk encoding and newline decoding are the production implementations.
/// Delays vary by link; bytes within each live TCP direction remain ordered.
private final class SimulatedRoomNetwork {
    struct Link {
        let left: Int
        let right: Int
        let leftSession: RoomStateSyncSession
        let rightSession: RoomStateSyncSession
        var leftDeliveryTick = 0
        var rightDeliveryTick = 0
    }
    struct Delivery {
        let linkID: Int
        let sender: Int
        let tick: Int
        let serial: Int
        let message: Data
    }
    let seed: UInt64
    let roomID: String
    private(set) var nodes = [AutomergeRoomStateSync]()
    private var links = [Int: Link]()
    private var pending = [Delivery]()
    private var nextLink = 0
    private var serial = 0
    private var tick = 0
    private var random: UInt64
    private var eventCounter: UInt64 = 0
    private var expectedChats = Set<String>()
    private var expectedTracks = Set<String>()
    private var tracksByCreator = [Int: [String]]()
    private var incarnations = [Int: Int]()
    private(set) var deliveredMessages = 0
    private(set) var droppedMessages = 0

    init(seed: UInt64, deviceCount: Int) throws {
        self.seed = seed
        random = seed
        roomID = "simulation-\(seed)"
        for _ in 0..<deviceCount { _ = try addDevice() }
    }

    func addDevice() throws -> Int {
        nodes.append(try AutomergeRoomStateSync(roomID: roomID, testingActorID: actor(for: nodes.count)))
        return nodes.count - 1
    }

    func connect(_ left: Int, _ right: Int) {
        precondition(!links.values.contains { $0.left == left && $0.right == right })
        nextLink += 1
        links[nextLink] = Link(
            left: left, right: right,
            leftSession: nodes[left].makeSession(), rightSession: nodes[right].makeSession()
        )
    }

    func disconnect(_ left: Int, _ right: Int) {
        let removed = Set(links.keys.filter { links[$0]?.left == left && links[$0]?.right == right })
        droppedMessages += pending.filter { removed.contains($0.linkID) }.count
        pending.removeAll { removed.contains($0.linkID) }
        for id in removed { links.removeValue(forKey: id) }
    }

    func restart(_ node: Int) throws {
        for link in Array(links.values) where link.left == node || link.right == node {
            disconnect(link.left, link.right)
        }
        let snapshot = try nodes[node].snapshot()
        incarnations[node, default: 0] += 1
        nodes[node] = try AutomergeRoomStateSync(
            roomID: roomID, savedDocument: nodes[node].save(), testingActorID: actor(for: node)
        )
        #expect(try nodes[node].snapshot() == snapshot, "seed \(seed): restart lost durable state")
    }

    func chat(at node: Int) throws {
        eventCounter += 1
        let id = "chat-\(eventCounter)"
        expectedChats.insert(id)
        _ = try nodes[node].ingest([MeshRoomEvent(
            id: id, roomID: roomID,
            version: MeshVersion(counter: eventCounter, nodeID: "node-\(node)"),
            kind: .chat, senderID: "node-\(node)", sender: "Node \(node)", text: id
        )])
    }

    func enqueueTrack(at node: Int) throws {
        eventCounter += 1
        let id = "track-\(eventCounter)"
        expectedTracks.insert(id)
        tracksByCreator[node, default: []].append(id)
        _ = try nodes[node].ingest([MeshRoomEvent(
            id: "add-\(id)", roomID: roomID,
            version: MeshVersion(counter: eventCounter, nodeID: "node-\(node)"), kind: .queueAdd,
            queueItem: RoomQueueItem(id: id, title: id, url: "https://example.invalid/\(id)")
        )])
    }

    func removeTrack(at node: Int) throws {
        guard let id = tracksByCreator[node]?.first else { return }
        tracksByCreator[node]?.removeFirst()
        expectedTracks.remove(id)
        eventCounter += 1
        _ = try nodes[node].ingest([MeshRoomEvent(
            id: "remove-\(id)", roomID: roomID,
            version: MeshVersion(counter: eventCounter, nodeID: "node-\(node)"),
            kind: .queueRemove, queueItemID: id
        )])
    }

    func advance(ticks: Int) throws {
        for _ in 0..<ticks { try step() }
    }

    func settle() throws {
        var quietTicks = 0
        for _ in 0..<1_000 {
            let before = deliveredMessages
            try step()
            quietTicks = pending.isEmpty && before == deliveredMessages ? quietTicks + 1 : 0
            if quietTicks >= 10 { return }
        }
        try #require(quietTicks >= 10,
                     "seed \(seed), tick \(tick): network did not settle, \(pending.count) pending messages")
    }

    func step() throws {
        tick += 1
        let due = pending.filter { $0.tick <= tick }.sorted {
            $0.tick == $1.tick ? $0.serial < $1.serial : $0.tick < $1.tick
        }
        pending.removeAll { $0.tick <= tick }
        for delivery in due {
            guard let link = links[delivery.linkID] else { continue }
            let fromLeft = delivery.sender == link.left
            let receiver = fromLeft ? link.right : link.left
            let session = fromLeft ? link.rightSession : link.leftSession
            let message = try fragmentedRoundTrip(delivery.message)
            _ = try nodes[receiver].receiveSyncMessage(message, from: session)
            deliveredMessages += 1
        }
        for id in links.keys.sorted() {
            guard var link = links[id] else { continue }
            for fromLeft in [true, false] {
                let sender = fromLeft ? link.left : link.right
                let session = fromLeft ? link.leftSession : link.rightSession
                if let message = nodes[sender].generateSyncMessage(for: session) {
                    let previous = fromLeft ? link.leftDeliveryTick : link.rightDeliveryTick
                    let arrival = max(previous + 1, tick + 1 + Int(nextRandom() % 7))
                    if fromLeft { link.leftDeliveryTick = arrival } else { link.rightDeliveryTick = arrival }
                    serial += 1
                    pending.append(Delivery(linkID: id, sender: sender, tick: arrival, serial: serial, message: message))
                }
            }
            links[id] = link
        }
    }

    func assertConverged() throws {
        for (index, node) in nodes.enumerated() {
            let snapshot = try node.snapshot()
            #expect(Set(snapshot.chatEvents.map(\.id)) == expectedChats,
                    "seed \(seed), node \(index), tick \(tick): missing/extra chat")
            #expect(Set(snapshot.queue.map(\.id)) == expectedTracks,
                    "seed \(seed), node \(index), tick \(tick): missing/resurrected queue item")
            #expect(Set(snapshot.events.map(\.id)).count == snapshot.events.count)
        }
    }

    private func fragmentedRoundTrip(_ message: Data) throws -> Data {
        let envelopes = MeshControlPlane.roomStateSyncEnvelopes(message: message, messageID: "sim-\(serial)")
        try #require(!envelopes.isEmpty, "seed \(seed): message exceeds wire budget")
        let decoder = MeshEnvelopeDecoder()
        var decoded = [MeshEnvelope]()
        for envelope in envelopes {
            let line = try envelope.encodedLine()
            var offset = 0
            while offset < line.count {
                let end = min(line.count, offset + 1 + Int(nextRandom() % 257))
                decoded += decoder.append(line.subdata(in: offset..<end))
                offset = end
            }
        }
        try #require(!decoder.isOverflowed && decoded.count == envelopes.count)
        var result = Data()
        for (index, envelope) in decoded.enumerated() {
            try #require(envelope.roomStateSyncChunkIndex == UInt16(index))
            result.append(try #require(envelope.roomStateSyncMessage))
        }
        try #require(result == message)
        return result
    }

    private func nextRandom() -> UInt64 {
        random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return random
    }

    private func actor(for node: Int) -> ActorId {
        ActorId(data: Data("scenario-\(seed)-node-\(node)-boot-\(incarnations[node, default: 0])".utf8))!
    }
}
