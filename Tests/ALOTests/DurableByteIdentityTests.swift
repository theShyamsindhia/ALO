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
        let allowed = event(text: composed)
        let inert = event(text: decomposed)
        let allowedBytes = Data(composed.utf8)
        let retained = (1...AutomergeRoomStateSync.maximumChatEvents).map {
            event(id: "newer-\($0)", counter: UInt64($0 + 10), text: "Authorized retained history")
        }
        for variants in [[allowed, inert], [inert, allowed]] {
            let sync = try AutomergeRoomStateSync(roomID: room, legacyEvents: retained, eventValidator: { _ in true },
                eventProjector: { event in event.id != "same" || Data((event.text ?? "").utf8) == allowedBytes })
            // The old authorized variant is beyond chat retention. The other
            // exact body is inert and must use the independent inert budget.
            let inserted = try sync.ingest(variants)
            #expect(inserted.count == 1)
            #expect(try inserted.map(encoded) == [encoded(inert)])
            let snapshot = try sync.snapshot()
            #expect(snapshot.chatEvents.count == AutomergeRoomStateSync.maximumChatEvents)
            #expect(snapshot.retainedEvents.count == AutomergeRoomStateSync.maximumChatEvents + 1)
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
