import Foundation
import Testing
import WERAICore
@testable import WERAI

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
            joinedAt: joinedAt
        )
        try store.save(room)

        #expect(try store.rename(roomID: room.id, to: "After"))
        let renamed = try #require(store.load().first)
        #expect(renamed.id == room.id)
        #expect(renamed.name == "After")
        #expect(renamed.creatorPeerID == room.creatorPeerID)
        #expect(renamed.joinedAt == joinedAt)
        #expect(renamed.isPrivate == room.isPrivate)
    }
}
