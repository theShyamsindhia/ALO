import CryptoKit
import Foundation
import Testing
@testable import ALO

struct RoomTrayStoreTests {
    @Test("Import copies a regular file and preserves its safe display name")
    func importCopiesAndPreservesName() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("Concert notes.txt")
        let bytes = Data("shared with the room".utf8)
        try bytes.write(to: source)

        let itemID = UUID()
        let imported = try fixture.store.importFile(at: source, roomID: "room/a", itemID: itemID)

        #expect(imported.descriptor.itemID == itemID)
        #expect(imported.descriptor.fileName == "Concert notes.txt")
        #expect(imported.descriptor.byteCount == bytes.count)
        #expect(imported.descriptor.sha256 == Data(SHA256.hash(data: bytes)))
        #expect(imported.url.lastPathComponent == "Concert notes.txt")
        #expect(try Data(contentsOf: imported.url) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(imported.url.standardizedFileURL != source.standardizedFileURL)
        #expect(fixture.store.fileURL(itemID: itemID, roomID: "room/a") == imported.url)
    }

    @Test("Incoming bytes require exact size and SHA-256")
    func incomingIntegrity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let data = Data("verified".utf8)
        let itemID = UUID()
        let descriptor = try #require(RoomTrayFileDescriptor(
            itemID: itemID,
            fileName: "report.txt",
            byteCount: data.count,
            sha256: Data(SHA256.hash(data: data))
        ))

        #expect(throws: RoomTrayStoreError.integrityMismatch) {
            try fixture.store.storeIncoming(data + Data([0]), descriptor: descriptor, roomID: "r")
        }
        var corrupt = data
        corrupt[corrupt.startIndex] ^= 1
        #expect(throws: RoomTrayStoreError.integrityMismatch) {
            try fixture.store.storeIncoming(corrupt, descriptor: descriptor, roomID: "r")
        }
        #expect(fixture.store.fileURL(itemID: itemID, roomID: "r") == nil)

        let stored = try fixture.store.storeIncoming(data, descriptor: descriptor, roomID: "r")
        #expect(try Data(contentsOf: stored) == data)
    }

    @Test("Names, empty files, directories, symlinks and oversized files are rejected")
    func rejectsInvalidSources() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let digest = Data(SHA256.hash(data: Data([1])))
        #expect(RoomTrayFileDescriptor(itemID: UUID(), fileName: "../escape", byteCount: 1, sha256: digest) == nil)
        #expect(RoomTrayFileDescriptor(itemID: UUID(), fileName: "bad/name", byteCount: 1, sha256: digest) == nil)
        #expect(RoomTrayFileDescriptor(itemID: UUID(), fileName: "bad\u{0}name", byteCount: 1, sha256: digest) == nil)
        #expect(RoomTrayFileDescriptor(itemID: UUID(), fileName: "file", byteCount: 0, sha256: digest) == nil)
        #expect(RoomTrayFileDescriptor(itemID: UUID(), fileName: "file", byteCount: RoomTrayFileDescriptor.maximumBytes + 1, sha256: digest) == nil)

        let empty = fixture.source.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(throws: RoomTrayStoreError.invalidSource) {
            try fixture.store.importFile(at: empty, roomID: "r")
        }
        let directory = fixture.source.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(throws: RoomTrayStoreError.invalidSource) {
            try fixture.store.importFile(at: directory, roomID: "r")
        }
        let original = fixture.source.appendingPathComponent("original")
        try Data([1]).write(to: original)
        let link = fixture.source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(throws: RoomTrayStoreError.invalidSource) {
            try fixture.store.importFile(at: link, roomID: "r")
        }

        let oversized = fixture.source.appendingPathComponent("oversized")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(RoomTrayFileDescriptor.maximumBytes + 1))
        try handle.close()
        #expect(throws: RoomTrayStoreError.fileTooLarge) {
            try fixture.store.importFile(at: oversized, roomID: "r")
        }
    }

    @Test("An item identity cannot be replaced with different contents")
    func preventsIdentityReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let itemID = UUID()
        let original = try descriptor(itemID: itemID, name: "one.txt", data: Data("one".utf8))
        let stored = try fixture.store.storeIncoming(Data("one".utf8), descriptor: original, roomID: "r")
        let replacement = try descriptor(itemID: itemID, name: "two.txt", data: Data("two".utf8))

        #expect(throws: RoomTrayStoreError.identityCollision) {
            try fixture.store.storeIncoming(Data("two".utf8), descriptor: replacement, roomID: "r")
        }
        #expect(try Data(contentsOf: stored) == Data("one".utf8))
        #expect(fixture.store.fileURL(itemID: itemID, roomID: "r") == stored)
    }

    @Test("Per-room pruning removes the least recently used managed item")
    func boundedPruning() throws {
        let fixture = try Fixture(cacheLimit: 8)
        defer { fixture.cleanup() }
        let firstID = UUID(), secondID = UUID(), thirdID = UUID()
        let first = try descriptor(itemID: firstID, name: "first", data: Data(repeating: 1, count: 4))
        let firstURL = try fixture.store.storeIncoming(Data(repeating: 1, count: 4), descriptor: first, roomID: "r")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: firstURL.deletingLastPathComponent().path
        )
        let second = try descriptor(itemID: secondID, name: "second", data: Data(repeating: 2, count: 4))
        _ = try fixture.store.storeIncoming(Data(repeating: 2, count: 4), descriptor: second, roomID: "r")
        let third = try descriptor(itemID: thirdID, name: "third", data: Data(repeating: 3, count: 4))
        _ = try fixture.store.storeIncoming(Data(repeating: 3, count: 4), descriptor: third, roomID: "r")

        #expect(fixture.store.fileURL(itemID: firstID, roomID: "r") == nil)
        #expect(fixture.store.fileURL(itemID: secondID, roomID: "r") != nil)
        #expect(fixture.store.fileURL(itemID: thirdID, roomID: "r") != nil)
    }

    @Test("Export and removal never modify source or exported copies")
    func exportAndSafeRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("photo.dat")
        let data = Data("original bytes".utf8)
        try data.write(to: source)
        let imported = try fixture.store.importFile(at: source, roomID: "r")
        let firstDestination = fixture.exports.appendingPathComponent("photo.dat")
        let secondDestination = fixture.exports.appendingPathComponent("renamed.dat")
        let firstExport = try fixture.store.export(
            itemID: imported.descriptor.itemID,
            roomID: "r",
            to: firstDestination
        )
        try Data("replace me".utf8).write(to: secondDestination)
        let secondExport = try fixture.store.export(
            itemID: imported.descriptor.itemID,
            roomID: "r",
            to: secondDestination
        )
        #expect(firstExport == firstDestination)
        #expect(secondExport == secondDestination)

        try fixture.store.remove(itemID: imported.descriptor.itemID, roomID: "r")
        #expect(fixture.store.fileURL(itemID: imported.descriptor.itemID, roomID: "r") == nil)
        #expect(try Data(contentsOf: source) == data)
        #expect(try Data(contentsOf: firstExport) == data)
        #expect(try Data(contentsOf: secondExport) == data)
    }

    @Test("Managed-path symlinks cannot expose or delete external files")
    func rejectsManagedSymlinkEscape() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("outside.txt")
        let data = Data("must survive".utf8)
        try data.write(to: source)
        let imported = try fixture.store.importFile(at: source, roomID: "r")
        let itemDirectory = imported.url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: itemDirectory)
        try FileManager.default.createSymbolicLink(
            at: itemDirectory,
            withDestinationURL: fixture.source
        )

        #expect(fixture.store.fileURL(itemID: imported.descriptor.itemID, roomID: "r") == nil)
        #expect(throws: RoomTrayStoreError.invalidSource) {
            try fixture.store.remove(itemID: imported.descriptor.itemID, roomID: "r")
        }
        #expect(try Data(contentsOf: source) == data)
    }

    private func descriptor(itemID: UUID, name: String, data: Data) throws -> RoomTrayFileDescriptor {
        try #require(RoomTrayFileDescriptor(
            itemID: itemID,
            fileName: name,
            byteCount: data.count,
            sha256: Data(SHA256.hash(data: data))
        ))
    }
}

private struct Fixture {
    let root: URL
    let source: URL
    let exports: URL
    let store: RoomTrayStore

    init(cacheLimit: Int = RoomTrayStore.maximumCacheBytes) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("alo-room-tray-\(UUID().uuidString)")
        source = root.appendingPathComponent("sources", isDirectory: true)
        exports = root.appendingPathComponent("exports", isDirectory: true)
        let cache = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        store = RoomTrayStore(rootURL: cache, maximumCacheBytes: cacheLimit)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
