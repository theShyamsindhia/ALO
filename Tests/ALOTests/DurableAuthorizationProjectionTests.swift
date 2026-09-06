import Foundation
import Automerge
import Testing
@testable import ALOCore

@Suite("Durable provenance is not authorization", .serialized)
struct DurableAuthorizationProjectionTests {
    private let room = "projection-test"
    private func event(_ id: String, _ counter: UInt64, revoked: Bool = false,
                       kind: MeshRoomEventKind = .chat, item: String? = nil) -> MeshRoomEvent {
        MeshRoomEvent(id: id, roomID: room,
            version: MeshVersion(counter: counter, nodeID: revoked ? "revoked" : "allowed"),
            kind: kind, text: kind == .chat ? id : nil,
            queueItem: kind == .queueAdd ? RoomQueueItem(id: item ?? id, title: id, url: "https://example.com/track") : nil,
            queueItemID: kind == .queueRemove ? item : nil)
    }

    private func rawDocument(_ events: [MeshRoomEvent]) throws -> Data {
        let document = Document()
        for event in events {
            try document.put(obj: ObjId.ROOT, key: "event:" + event.id,
                             value: .Bytes(try JSONEncoder().encode(event)))
        }
        return document.save()
    }

    private func receiver(_ events: [MeshRoomEvent]) throws -> AutomergeRoomStateSync {
        try AutomergeRoomStateSync(roomID: room, savedDocument: rawDocument(events),
            eventValidator: { _ in true }, eventProjector: { $0.version.nodeID == "allowed" })
    }

    @Test func unseenRevokedTombstoneCannotRemoveAnAuthorizedQueueItem() throws {
        let add = event("good-add", 1, kind: .queueAdd, item: "song")
        let remove = event("bad-remove", 2, revoked: true, kind: .queueRemove, item: "song")
        let sync = try receiver([add, remove])
        #expect(try sync.snapshot().queue.map(\.id) == ["song"])
        #expect(try sync.snapshot().events.map(\.id) == [add.id])
        #expect(Set(try sync.snapshot().retainedEvents.map(\.id)) == [add.id, remove.id])
    }

    @Test func inertChatCannotEvictAuthorizedHistoryOrAdvanceItsCounter() throws {
        let good = event("good", 1)
        let inert = (2...503).map { event("inert-\($0)", UInt64($0), revoked: true) }
        let sync = try receiver([good] + inert)
        #expect(try sync.snapshot().chatEvents.map(\.id) == [good.id])
        var projected = MeshRoomReplica(events: try sync.snapshot().events)
        #expect(projected.nextVersion(nodeID: "allowed").counter == 2)
        #expect(try sync.snapshot().retainedEvents.count == 503)
        let restored = try AutomergeRoomStateSync(roomID: room, savedDocument: sync.save(),
            eventProjector: { $0.version.nodeID == "allowed" })
        #expect(try restored.snapshot().chatEvents.map(\.id) == [good.id])
    }

    @Test func validLaterOperationsRemainEffectiveBesideInertRecords() throws {
        let add = event("good-add", 1, kind: .queueAdd, item: "song")
        let remove = event("bad-remove", 50, revoked: true, kind: .queueRemove, item: "song")
        let sync = try receiver([add, remove])
        let fresh = event("fresh", 3)
        let goodRemove = event("good-remove", 4, kind: .queueRemove, item: "song")
        #expect(try sync.ingest([fresh, goodRemove]).count == 2)
        #expect(try sync.snapshot().queue.isEmpty)
        #expect(try sync.snapshot().chatEvents.map(\.id) == [fresh.id])
        #expect(try sync.snapshot().retainedEvents.contains(remove))
    }
}
