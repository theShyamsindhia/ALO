import Foundation
import Testing
import ALOCore
import ALORooms

@Suite("Channel storage first run")
struct RoomStoreFirstRunTests {
    private final class NoSecrets: RoomSecretStoring {
        func read(roomID: String) -> String? { nil }
        func write(_ value: String, roomID: String) throws { Issue.record("Public channel must not write secrets") }
        func remove(roomID: String) {}
    }

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("alo-first-run-\(UUID().uuidString)")
    }

    private var channel: RoomConfiguration {
        RoomConfiguration(id: "main", name: "Main", creatorPeerID: "owner",
                          joinedAt: Date(timeIntervalSince1970: 1_700_000_000), transportPolicy: .secureV2)
    }

    @Test func freshNestedStorageSavesAndReopens() throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ALO/channels-v1/channels.json")
        let store = RoomStore(fileURL: url, secretStore: NoSecrets())
        #expect(store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try store.save(channel)
        #expect(try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
        #expect(RoomStore(fileURL: url, secretStore: NoSecrets()).load() == [channel])
        try store.save(channel)
        #expect(store.load().count == 1)
    }

    @Test func eventsAndDocumentsCanBeFirstWrites() async throws {
        for documentFirst in [false, true] {
            let root = location()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = RoomStore(fileURL: root.appendingPathComponent("channels-v1/channels.json"), secretStore: NoSecrets())
            let event = MeshRoomEvent(roomID: "main", version: MeshVersion(counter: 1, nodeID: "owner"), kind: .chat, text: "Hello")
            let document = Data("durable state".utf8)
            if documentFirst {
                store.saveRoomStateDocument(document, roomID: "main")
                #expect(store.loadRoomStateDocument(roomID: "main") == document)
            } else {
                store.saveEvents([event], roomID: "main")
                #expect(store.loadEvents(roomID: "main") == [event])
            }
            store.saveEvents([event], roomID: "main")
            store.saveRoomStateDocument(document, roomID: "main")
            let restored = await store.loadChannelState(roomID: "main")
            #expect(restored.events == [event])
            #expect(restored.document == document)
        }
    }

    @Test func blockingParentThrowsWithoutReplacingItAndRetryWorks() throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let parent = root.appendingPathComponent("channels-v1")
        let original = Data("not a directory".utf8)
        try original.write(to: parent)
        let store = RoomStore(fileURL: parent.appendingPathComponent("channels.json"), secretStore: NoSecrets())
        #expect(throws: (any Error).self) { try store.save(channel) }
        #expect(try Data(contentsOf: parent) == original)
        try FileManager.default.removeItem(at: parent)
        try store.save(channel)
        #expect(store.load() == [channel])
    }

    @Test func corruptMetadataIsNotOverwritten() throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("channels.json")
        let original = Data("invalid metadata".utf8)
        try original.write(to: url)
        let store = RoomStore(fileURL: url, secretStore: NoSecrets())
        #expect(throws: (any Error).self) { try store.save(channel) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func existingMetadataDirectoryIsNotReplaced() throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("channels-v1/channels.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let marker = url.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let store = RoomStore(fileURL: url, secretStore: NoSecrets())
        #expect(throws: (any Error).self) { try store.save(channel) }
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }
}
