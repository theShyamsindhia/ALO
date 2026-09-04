import Automerge
import Foundation
import Testing
@testable import ALOCore

struct RoomStatePendingDependencyTests {
    @Test("A pending dependency survives local edits and a restart")
    func dependencySurvivesRestart() throws {
        let roomID = "pending-dependency"
        let source = Document()
        try putEvent("parent", counter: 1, roomID: roomID, in: source)
        let parentHeads = source.heads()
        let parent = try source.encodeChangesSince(heads: [])
        try putEvent("child", counter: 2, roomID: roomID, in: source)
        let child = try source.encodeChangesSince(heads: parentHeads)

        let receiver = try AutomergeRoomStateSync(roomID: roomID)
        let emptySize = receiver.save().count
        _ = try receiver.receiveSyncMessage(syncFrame(child), from: receiver.makeSession())
        #expect(try receiver.snapshot().events.isEmpty, "Child is not causally ready")
        #expect(receiver.save().count > emptySize, "Pending change was discarded")
        _ = try receiver.ingest([event("local", counter: 3, roomID: roomID)])
        let restored = try AutomergeRoomStateSync(roomID: roomID, savedDocument: receiver.save())
        _ = try restored.receiveSyncMessage(syncFrame(parent), from: restored.makeSession())
        #expect(Set(try restored.snapshot().chatEvents.map(\.id)) == ["parent", "child", "local"])
    }

    @Test("A deferred invalid event is rejected when its dependency arrives")
    func validatesDeferredChanges() throws {
        let roomID = "pending-invalid"
        let source = Document()
        try putEvent("parent", counter: 1, roomID: roomID, in: source)
        let parentHeads = source.heads()
        let parent = try source.encodeChangesSince(heads: [])
        try source.put(obj: .ROOT, key: "not-an-event", value: .String("invalid"))
        let child = try source.encodeChangesSince(heads: parentHeads)
        let receiver = try AutomergeRoomStateSync(roomID: roomID)
        let session = receiver.makeSession()
        _ = try receiver.receiveSyncMessage(syncFrame(child), from: session)
        let before = receiver.save()
        #expect(throws: RoomStateSyncError.invalidDocument) {
            try receiver.receiveSyncMessage(syncFrame(parent), from: session)
        }
        #expect(try receiver.snapshot().events.isEmpty)
        #expect(receiver.save() == before, "Rejected transaction changed durable state")
    }

    @Test("Invisible pending changes cannot exceed the document budget")
    func boundsPendingChanges() throws {
        let source = Document()
        try source.put(obj: .ROOT, key: "withheld-parent", value: .Int(1))
        var previousHeads = source.heads()
        let receiver = try AutomergeRoomStateSync(roomID: "pending-budget")
        let session = receiver.makeSession()
        var random: UInt64 = 57
        var rejected = false
        // Incompressible bytes ensure the serialized orphan queue exceeds the
        // budget. No root change is delivered, so visible history stays empty.
        for index in 0..<70 {
            let bytes = Data((0..<100_000).map { _ -> UInt8 in
                random = random &* 6_364_136_223_846_793_005 &+ 1
                return UInt8(truncatingIfNeeded: random >> 32)
            })
            try source.put(obj: .ROOT, key: "pending-\(index)", value: .Bytes(bytes))
            let change = try source.encodeChangesSince(heads: previousHeads)
            previousHeads = source.heads()
            let before = receiver.save()
            do {
                _ = try receiver.receiveSyncMessage(syncFrame(change), from: session)
            } catch RoomStateSyncError.documentTooLarge {
                #expect(receiver.save() == before)
                rejected = true
                break
            }
            #expect(receiver.save().count <= AutomergeRoomStateSync.maximumDocumentBytes)
        }
        #expect(rejected, "Accumulating unresolved changes bypassed the memory/storage budget")
        #expect(try receiver.snapshot().events.isEmpty)
    }

    private func event(_ id: String, counter: UInt64, roomID: String) -> MeshRoomEvent {
        MeshRoomEvent(id: id, roomID: roomID, version: MeshVersion(counter: counter, nodeID: "source"),
                      kind: .chat, senderID: "source", sender: "Source", text: id)
    }

    private func putEvent(_ id: String, counter: UInt64, roomID: String, in document: Document) throws {
        let bytes = try JSONEncoder().encode(event(id, counter: counter, roomID: roomID))
        try document.put(obj: .ROOT, key: "event:" + id, value: .Bytes(bytes))
    }

    /// Automerge v1 sync wire fixture: no heads/need/have, one length-prefixed
    /// encoded change. This intentionally withholds the causal parent, which
    /// normal Bloom-filter sync can do without violating TCP ordering.
    private func syncFrame(_ change: Data) -> Data {
        var frame = Data([0x42, 0, 0, 0, 1])
        var length = change.count
        repeat {
            let byte = UInt8(length & 0x7f)
            length >>= 7
            frame.append(length == 0 ? byte : byte | 0x80)
        } while length != 0
        frame.append(change)
        return frame
    }
}
