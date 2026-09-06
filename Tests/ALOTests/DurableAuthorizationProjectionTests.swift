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

    @Test func policyChangeDuringRetentionDiscardsTheWholeCandidate() throws {
        let access = ProjectionAccess()
        let sync = try AutomergeRoomStateSync(roomID: room,
            eventProjector: { access.project($0) }, projectionRevision: { access.revision })
        let add = event("good-add", 1, kind: .queueAdd, item: "song")
        try sync.ingest([add])
        access.revokeDuringNextRemoval = true
        let remove = event("good-remove", 2, kind: .queueRemove, item: "song")
        #expect(throws: RoomStateSyncError.authorizationChanged) { try sync.ingest([remove]) }
        #expect(try sync.snapshot().retainedEvents == [add])
        #expect(try sync.snapshot().queue.map(\.id) == ["song"])
    }

    @Test func repeatedRetentionScansVerifyEachProjectionOncePerTransaction() throws {
        let access = ProjectionAccess()
        let sync = try AutomergeRoomStateSync(roomID: room, eventProjector: { access.project($0) })
        let events = (1...100).map { event("chat-\($0)", UInt64($0)) }
        try sync.ingest(events)
        #expect(access.counts.count == 100)
        #expect(access.counts.values.allSatisfy { $0 == 1 })
        _ = try sync.snapshot()
        #expect(access.counts.values.allSatisfy { $0 == 2 }) // Never cached across API calls.
    }

    @Test func excessiveInertHistoryCannotPoisonCommittedState() throws {
        let good = event("good", 1)
        let sync = try receiver([good])
        let before = sync.save()
        // A relaying member can mint arbitrary self-certified authors. Valid
        // provenance alone must not let their inert records consume the room.
        let inert = (1...1_025).map { event("inert-\($0)", UInt64($0 + 10), revoked: true) }
        #expect(throws: RoomStateSyncError.untrustedHistoryLimit) { _ = try sync.ingest(inert) }
        #expect(sync.save().elementsEqual(before))
        #expect(try sync.snapshot().retainedEvents == [good])
        #expect(!sync.requiresLifecycleCompaction())
        let next = event("next", 2)
        #expect(try sync.ingest([next]) == [next])
        #expect(try sync.snapshot().chatEvents == [good, next])
    }

    @Test func inertByteBudgetRejectsOneLargeCandidateWithoutLosingHistory() throws {
        let good = event("good", 1)
        let sync = try receiver([good])
        let before = sync.save()
        let inert = (1...140).map { index in
            MeshRoomEvent(id: "large-\(index)", roomID: room,
                version: MeshVersion(counter: UInt64(index + 10), nodeID: "revoked"),
                kind: .chat, text: String(repeating: "x", count: 8_192))
        }
        #expect(throws: RoomStateSyncError.untrustedHistoryLimit) { _ = try sync.ingest(inert) }
        #expect(sync.save().elementsEqual(before))
        #expect(try sync.snapshot().retainedEvents == [good])
    }
}

private final class ProjectionAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1
    private var checks = [String: Int]()
    // Used only by the test driver between synchronous transactions.
    var revokeDuringNextRemoval = false
    var revision: UInt64? { lock.lock(); defer { lock.unlock() }; return value }
    var counts: [String: Int] { lock.lock(); defer { lock.unlock() }; return checks }
    func project(_ event: MeshRoomEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        checks[event.id, default: 0] += 1
        if event.kind == .queueRemove {
            if revokeDuringNextRemoval { revokeDuringNextRemoval = false; value += 1; return true }
            return value == 1
        }
        return true
    }
}
