import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite("Explicit room transport policy")
struct RoomSecurityPolicyTests {
    private final class MemorySecrets: RoomSecretStoring {
        var values: [String: String] = [:]
        func read(roomID: String) -> String? { values[roomID] }
        func write(_ value: String, roomID: String) { values[roomID] = value }
        func remove(roomID: String) { values.removeValue(forKey: roomID) }
    }

    private func withStore(_ body: (RoomStore, MemorySecrets, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-room-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rooms.json")
        let secrets = MemorySecrets()
        try body(RoomStore(fileURL: file, secretStore: secrets), secrets, file)
    }

    @Test func oldJSONAndUUIDKeyRemainLegacy() throws {
        let key = UUID().uuidString
        let old = """
        {"id":"old-room","name":"Legacy","creatorPeerID":"creator","isPrivate":true,"accessKey":"\(key)","joinedAt":0}
        """
        let room = try JSONDecoder().decode(RoomConfiguration.self, from: Data(old.utf8))
        #expect(room.transportPolicy == .legacyOnly)
        #expect(room.accessKey == key)
        try room.validateForJoining()
        #expect(room.secureJoinSecret == nil)
        #expect(room.transportPolicy.permits(wireVersion: 1))
        #expect(!room.transportPolicy.permits(wireVersion: 2))
        try withStore { store, secrets, file in
            secrets.values[room.id] = key
            let oldMetadata = """
            [{"id":"old-room","name":"Legacy","creatorPeerID":"creator","isPrivate":true,"joinedAt":0}]
            """
            let bytes = Data(oldMetadata.utf8)
            try bytes.write(to: file)
            #expect(store.load().first?.transportPolicy == .legacyOnly)
            #expect(store.load().first?.accessKey == key)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func explicitSecureCreationProducesIndependent256BitSecrets() throws {
        let first = RoomConfiguration.secure(name: "Secure")
        let second = RoomConfiguration.secure(name: "Secure")
        #expect(first.transportPolicy == .secureV2)
        #expect(first.isPrivate)
        #expect(first.secureJoinSecret?.count == 32)
        #expect(first.accessKey?.count == 44)
        #expect(first.accessKey != second.accessKey)
        #expect(first.id != second.id)
        try first.validateForJoining()
        let publicRoom = RoomConfiguration.secure(name: "Public", isPrivate: false)
        #expect(publicRoom.accessKey == nil)
        try publicRoom.validateForJoining()
    }

    @Test func securePolicyRoundTripsAndRenamePreservesSecret() throws {
        let room = RoomConfiguration.secure(name: "Before", creatorPeerID: "creator", joinedAt: Date(timeIntervalSince1970: 123))
        let encoded = try JSONEncoder().encode(room)
        #expect(try JSONDecoder().decode(RoomConfiguration.self, from: encoded) == room)
        try withStore { store, secrets, file in
            try store.save(room)
            #expect(store.load() == [room])
            #expect(secrets.values[room.id] == room.accessKey)
            let json = try #require(String(data: Data(contentsOf: file), encoding: .utf8))
            #expect(json.contains("secureV2"))
            #expect(!json.contains(try #require(room.accessKey)))
            #expect(try store.rename(roomID: room.id, to: "After"))
            let renamed = try #require(store.load().first)
            #expect(renamed.name == "After")
            #expect(renamed.id == room.id)
            #expect(renamed.creatorPeerID == room.creatorPeerID)
            #expect(renamed.joinedAt == room.joinedAt)
            #expect(renamed.transportPolicy == .secureV2)
            #expect(renamed.accessKey == room.accessKey)
        }
    }

    @Test func malformedSecureCredentialsCannotJoinDecodeOrPersist() throws {
        for key in [UUID().uuidString, "not-base64", Data(repeating: 1, count: 31).base64EncodedString(),
                    Data(repeating: 1, count: 33).base64EncodedString()] {
            let room = RoomConfiguration(name: "Invalid", isPrivate: true, accessKey: key, transportPolicy: .secureV2)
            #expect(throws: RoomSecurityPolicyError.invalidSecureRoomSecret) { try room.validateForJoining() }
            let bytes = try JSONEncoder().encode(room)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(RoomConfiguration.self, from: bytes) }
            try withStore { store, secrets, file in
                #expect(throws: RoomSecurityPolicyError.invalidSecureRoomSecret) { try store.save(room) }
                #expect(secrets.values.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: file.path))
            }
        }
        let metadata = RoomConfiguration(name: "Redacted", isPrivate: true, transportPolicy: .secureV2)
        #expect(throws: RoomSecurityPolicyError.invalidSecureRoomSecret) { try metadata.validateForJoining() }
        // A public hello can describe a private room without carrying its key.
        #expect(try JSONDecoder().decode(RoomConfiguration.self, from: JSONEncoder().encode(metadata)) == metadata)
    }

    @Test func normalSaveCannotUpgradeOrDowngradeAndMigrationIsExplicit() throws {
        try withStore { store, _, _ in
            let legacy = RoomConfiguration(name: "Existing", isPrivate: true, accessKey: UUID().uuidString)
            try store.save(legacy)
            let upgrade = legacy.migrated(to: .secureV2)
            #expect(throws: RoomSecurityPolicyError.explicitMigrationRequired) { try store.save(upgrade) }
            #expect(store.load().first == legacy)
            let secure = try #require(try store.migrate(roomID: legacy.id, to: .secureV2))
            #expect(secure.id == legacy.id)
            #expect(secure.secureJoinSecret?.count == 32)
            #expect(secure.accessKey != legacy.accessKey)
            #expect(store.load().first == secure)
            #expect(throws: RoomSecurityPolicyError.explicitMigrationRequired) { try store.save(secure.migrated(to: .legacyOnly)) }
            #expect(store.load().first == secure)
            #expect(try store.migrate(roomID: secure.id, to: .legacyOnly)?.transportPolicy == .legacyOnly)
        }
    }

    @Test func migrationRequiredIsPersistedAndCannotJoinEitherWire() throws {
        let pending = RoomConfiguration(name: "Pending", transportPolicy: .migrationRequired)
        #expect(!pending.transportPolicy.permits(wireVersion: 1))
        #expect(!pending.transportPolicy.permits(wireVersion: 2))
        #expect(throws: RoomSecurityPolicyError.migrationRequired) { try pending.validateForJoining() }
        try withStore { store, _, _ in
            try store.save(pending)
            #expect(try store.rename(roomID: pending.id, to: "Still pending"))
            #expect(store.load().first?.transportPolicy == .migrationRequired)
            let migrated = try #require(try store.migrate(roomID: pending.id, to: .secureV2))
            try migrated.validateForJoining()
            #expect(store.load().first?.transportPolicy == .secureV2)
        }
    }

    @Test func missingSecretDoesNotPermitDowngrade() throws {
        try withStore { store, secrets, _ in
            let secure = RoomConfiguration.secure(name: "Secure")
            try store.save(secure)
            secrets.values.removeAll()
            #expect(store.load().isEmpty)
            try store.save(RoomConfiguration(name: "Another room"))
            #expect(throws: RoomSecurityPolicyError.explicitMigrationRequired) { try store.save(secure.migrated(to: .legacyOnly)) }
        }
    }
}
