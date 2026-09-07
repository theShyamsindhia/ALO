import Automerge
import Foundation
import Testing
@testable import ALOCore

@Suite("Durable events preserve exact signed bytes")
struct DurableByteIdentityTests {
    private let room = "durable-byte-identity"
    private let composed = "caf\u{00E9}"
    private let decomposed = "cafe\u{0301}"

    @Test func observedUnicodeEquivalentOverwriteCannotReplaceCommittedBytes() throws {
        let original = event(text: composed)
        let changed = event(text: decomposed)
        #expect(original == changed) // Swift equality is insufficient for signed bytes.
        #expect(try encoded(original) != encoded(changed))
        // Provenance is accepted independently here: immutable identity must
        // still reject a different body even when its author can sign both.
        let trusted = try AutomergeRoomStateSync(roomID: room, legacyEvents: [original], eventValidator: { _ in true })
        let before = trusted.save()
        let overwritten = try Document(before)
        try overwritten.put(obj: .ROOT, key: "event:" + original.id, value: .Bytes(try encoded(changed)))
        let attacker = try AutomergeRoomStateSync(roomID: room, savedDocument: overwritten.save(), eventValidator: { _ in true })
        let trustedSession = trusted.makeSession(), attackerSession = attacker.makeSession()
        var failure: RoomStateSyncError?
        for _ in 0..<10 where failure == nil {
            if let message = attacker.generateSyncMessage(for: attackerSession) {
                do { try trusted.receiveSyncMessage(message, from: trustedSession) }
                catch { failure = error as? RoomStateSyncError }
            }
            if failure == nil, let message = trusted.generateSyncMessage(for: trustedSession) {
                try attacker.receiveSyncMessage(message, from: attackerSession)
            }
        }
        #expect(failure == .immutableEventChanged)
        #expect(trusted.save() == before)
        let retained = try #require(trusted.snapshot().retainedEvents.first)
        #expect(try encoded(retained) == encoded(original))
        let restored = try AutomergeRoomStateSync(roomID: room, savedDocument: trusted.save())
        #expect(try encoded(#require(restored.snapshot().retainedEvents.first)) == encoded(original))
        let subsequent = event(id: "subsequent", counter: 2, text: "The committed state remains usable")
        #expect(try trusted.ingest([subsequent]) == [subsequent])
    }

    @Test func projectionCacheSeparatesEquivalentStringsWithinOneIngest() throws {
        let allowed = MeshRoomEvent(id: "same", roomID: room, version: .init(counter: 1, nodeID: "author"),
            kind: .queueAdd, queueItem: .init(id: "track", title: composed, url: "https://example.com/track"))
        let inert = MeshRoomEvent(id: "same", roomID: room, version: .init(counter: 1, nodeID: "author"),
            kind: .queueAdd, queueItem: .init(id: "track", title: decomposed, url: "https://example.com/track"))
        #expect(allowed == inert)
        let allowedBytes = Data(composed.utf8)
        let remove = MeshRoomEvent(id: "newer-remove", roomID: room, version: .init(counter: 2, nodeID: "author"),
            kind: .queueRemove, queueItemID: "track")
        for variants in [[allowed, inert], [inert, allowed]] {
            let sync = try AutomergeRoomStateSync(roomID: room, legacyEvents: [remove], eventValidator: { _ in true },
                eventProjector: { event in event.id != "same" || Data((event.queueItem?.title ?? "").utf8) == allowedBytes })
            // The old authorized add is superseded by the removal. The other
            // exact body is inert and must not participate in queue semantics.
            let inserted = try sync.ingest(variants)
            #expect(inserted.count == 1)
            #expect(try inserted.map(encoded) == [encoded(inert)])
            let snapshot = try sync.snapshot()
            #expect(snapshot.events == [remove])
            #expect(snapshot.queue.isEmpty)
            #expect(snapshot.retainedEvents.count == 2)
        }
    }

    @Test func concurrentUnicodeEquivalentAuthorsCannotCollapseConflictIdentity() throws {
        let first = event(text: "Same content", author: composed)
        let second = event(text: "Same content", author: decomposed)
        #expect(first.version == second.version)
        let left = Document(), right = Document()
        try left.put(obj: .ROOT, key: "event:same", value: .Bytes(try encoded(first)))
        try right.put(obj: .ROOT, key: "event:same", value: .Bytes(try encoded(second)))
        try left.merge(other: right)
        #expect(try left.getAll(obj: .ROOT, key: "event:same").count == 2)
        #expect(throws: RoomStateSyncError.invalidDocument) {
            try AutomergeRoomStateSync(roomID: room, savedDocument: left.save(), eventValidator: { _ in true })
        }
    }

    private func event(id: String = "same", counter: UInt64 = 1, text: String, author: String = "author") -> MeshRoomEvent {
        MeshRoomEvent(id: id, roomID: room, version: .init(counter: counter, nodeID: author), kind: .chat,
            senderID: author, text: text)
    }
    private func encoded(_ event: MeshRoomEvent) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event)
    }
}
