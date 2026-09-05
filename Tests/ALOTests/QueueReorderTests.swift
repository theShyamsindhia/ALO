import Foundation
import Testing
@testable import ALOCore

struct QueueReorderTests {
    private func add(_ id: String, _ counter: UInt64) -> MeshRoomEvent {
        MeshRoomEvent(id: "add-" + id, roomID: "room", version: MeshVersion(counter: counter, nodeID: "host"), kind: .queueAdd,
                      queueItem: RoomQueueItem(id: id, title: id, url: "https://example.com/" + id))
    }
    private func order(_ ids: [String], _ counter: UInt64) -> MeshRoomEvent {
        MeshRoomEvent(id: "order-\(counter)", roomID: "room", version: MeshVersion(counter: counter, nodeID: "host"),
                      kind: .queueReorder, senderID: "host", queueOrder: ids)
    }

    @Test("Queue reordering converges and retains concurrent additions and removals")
    func convergence() {
        let events = [add("a", 1), add("b", 2), order(["b", "a"], 3), add("c", 4),
                      MeshRoomEvent(roomID: "room", version: MeshVersion(counter: 5, nodeID: "host"), kind: .queueRemove, queueItemID: "a")]
        let forward = MeshRoomReplica(events: events)
        let reverse = MeshRoomReplica(events: events.reversed())
        #expect(forward.queue.map(\.id) == ["b", "c"])
        #expect(forward.queue == reverse.queue)
    }

    @Test("Only latest queue order survives durable retention and stale replay")
    func retention() throws {
        let sync = try AutomergeRoomStateSync(roomID: "room")
        try sync.ingest([add("a", 1), add("b", 2), order(["b", "a"], 3)])
        try sync.ingest([order(["a", "b"], 4)])
        try sync.ingest([order(["b", "a"], 3)])
        let snapshot = try sync.snapshot()
        #expect(snapshot.queue.map(\.id) == ["a", "b"])
        #expect(snapshot.events.filter { $0.kind == .queueReorder }.count == 1)
    }

    @Test("Malformed orders are rejected without crashing or changing queue")
    func malformed() throws {
        let invalid = order(["a", "a"], 3)
        #expect(MeshRoomReplica(events: [add("a", 1), invalid]).events.count == 1)
        let sync = try AutomergeRoomStateSync(roomID: "room")
        #expect(try sync.ingest([invalid]).isEmpty)
        #expect(try sync.snapshot().events.isEmpty)
    }
    @Test("Queue order uses a valid legacy tombstone without changing legacy queue or chat")
    func legacyWireCompatibility() throws {
        enum LegacyKind: String, Decodable { case chat, queueAdd, queueRemove, broadcaster, playback, video }
        struct LegacyEvent: Decodable {
            let kind: LegacyKind
            let queueItemID: String?
        }
        let original = order(["b", "a"], 3)
        let data = try JSONEncoder().encode(original)
        let legacy = try JSONDecoder().decode(LegacyEvent.self, from: data)
        #expect(legacy.kind == .queueRemove)
        #expect(legacy.queueItemID == "alo:queue-order:v1")
        #expect(try JSONDecoder().decode(MeshRoomEvent.self, from: data) == original)

        // A legacy decoder ignores unknown optional fields. Feed that exact
        // semantic event through the unchanged queueRemove validation path.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "queueOrder")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let tombstone = try JSONDecoder().decode(MeshRoomEvent.self, from: legacyData)
        let chat = MeshRoomEvent(id: "chat", roomID: "room", version: MeshVersion(counter: 4, nodeID: "host"), kind: .chat, text: "hello")
        let sync = try AutomergeRoomStateSync(roomID: "room")
        #expect(try sync.ingest([add("a", 1), add("b", 2), tombstone, chat]).count == 4)
        #expect(try sync.snapshot().queue.map(\.id) == ["a", "b"])
        #expect(try sync.snapshot().chatEvents.map(\.text) == ["hello"])
    }

    @Test("New queue order encoding survives durable document reload")
    func encodedDurableOrder() throws {
        let source = try AutomergeRoomStateSync(roomID: "room")
        try source.ingest([add("a", 1), add("b", 2), order(["b", "a"], 3)])
        let target = try AutomergeRoomStateSync(roomID: "room")
        let outgoing = source.makeSession()
        let incoming = target.makeSession()
        for _ in 0..<8 {
            if let data = source.generateSyncMessage(for: outgoing) { try target.receiveSyncMessage(data, from: incoming) }
            if let data = target.generateSyncMessage(for: incoming) { try source.receiveSyncMessage(data, from: outgoing) }
        }
        #expect(try target.snapshot().queue.map(\.id) == ["b", "a"])
    }

}
