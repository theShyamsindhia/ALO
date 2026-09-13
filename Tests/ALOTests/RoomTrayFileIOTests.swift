import CryptoKit
import Foundation
import Testing
@testable import ALO

struct RoomTrayFileIOTests {
    @Test func asyncImportExportAndRemovalPreserveUserCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let exported = root.appendingPathComponent("saved.txt")
        let data = Data("Room file".utf8)
        try data.write(to: source)
        let store = RoomTrayStore(rootURL: root.appendingPathComponent("cache"))
        let io = RoomTrayFileIO(store: store)
        let (descriptor, cached) = try await io.importFile(source, roomID: "room")
        #expect(try Data(contentsOf: cached) == data)
        try await io.export(descriptor.itemID, roomID: "room", to: exported)
        try await io.remove(descriptor.itemID, roomID: "room")
        #expect(store.fileURL(itemID: descriptor.itemID, roomID: "room") == nil)
        #expect(try Data(contentsOf: source) == data)
        #expect(try Data(contentsOf: exported) == data)
    }

    @Test func actorRejectsCorruptBytesBeforeMakingThemAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoomTrayStore(rootURL: root)
        let io = RoomTrayFileIO(store: store)
        let data = Data("verified bytes".utf8)
        let descriptor = try #require(RoomTrayFileDescriptor(itemID: UUID(), fileName: "file.txt",
            byteCount: data.count, sha256: Data(SHA256.hash(data: data))))
        var corrupt = data
        corrupt[0] ^= 1
        do {
            try await io.receive(corrupt, descriptor: descriptor, roomID: "room")
            Issue.record("Corrupted bytes must not be cached")
        } catch {
            #expect(error as? RoomTrayStoreError == .integrityMismatch)
        }
        #expect(store.fileURL(itemID: descriptor.itemID, roomID: "room") == nil)
        try await io.receive(data, descriptor: descriptor, roomID: "room")
        let cached = try #require(store.fileURL(itemID: descriptor.itemID, roomID: "room"))
        #expect(try Data(contentsOf: cached) == data)
    }
}
