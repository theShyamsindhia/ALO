import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite("Saved room management")
struct RoomStoreTests {
    @Test("Renaming a room preserves its identity and metadata")
    func renamePreservesRoom() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("werai-room-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RoomStore(fileURL: directory.appendingPathComponent("rooms.json"))
        let joinedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let room = RoomConfiguration(
            id: "room-id",
            name: "Before",
            creatorPeerID: "creator-id",
            joinedAt: joinedAt,
            icon: RoomIcon(symbol: "headphones", version: MeshVersion(counter: 1, nodeID: "a"))
        )
        try store.save(room)

        #expect(try store.rename(roomID: room.id, to: "After"))
        let renamed = try #require(store.load().first)
        #expect(renamed.id == room.id)
        #expect(renamed.name == "After")
        #expect(renamed.creatorPeerID == room.creatorPeerID)
        #expect(renamed.joinedAt == joinedAt)
        #expect(renamed.isPrivate == room.isPrivate)
        #expect(renamed.icon == room.icon)
        let next = RoomIcon(symbol: "film.fill", version: MeshVersion(counter: 2, nodeID: "b"))
        #expect(try store.mergeIcon(next, roomID: room.id))
        #expect(try !store.mergeIcon(room.icon!, roomID: room.id))
        #expect(store.load().first?.icon == next)
        #expect(store.load().first?.name == "After")
    }

    @Test func olderRoomsDecodeWithoutAnIcon() throws {
        let data = Data(#"{"id":"old","name":"Music","creatorPeerID":"a","isPrivate":false,"joinedAt":0}"#.utf8)
        #expect(try JSONDecoder().decode(RoomConfiguration.self, from: data).icon == nil)
        let invalid = RoomIcon(symbol: "not-a-symbol", version: MeshVersion(counter: 3, nodeID: "a"))
        #expect(!invalid.supersedes(nil))
        let a = RoomIcon(symbol: "headphones", version: MeshVersion(counter: 2, nodeID: "a"))
        let b = RoomIcon(symbol: "film.fill", version: MeshVersion(counter: 2, nodeID: "b"))
        #expect(b.supersedes(a))
        #expect(!a.supersedes(b))
        #expect(!b.supersedes(b))
    }
}
