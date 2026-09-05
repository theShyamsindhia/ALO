import Foundation
import Security
import ALOCore

protocol RoomSecretStoring {
    func read(roomID: String) -> String?
    func write(_ value: String, roomID: String) throws
    func remove(roomID: String)
}

final class RoomStore {
    private struct StoredRoom: Codable {
        let id: String
        let name: String
        let creatorPeerID: String
        let isPrivate: Bool
        let joinedAt: Date
        let transportPolicy: RoomTransportPolicy?
    }

    private let fileURL: URL
    private let secrets: any RoomSecretStoring
    private let roomStateIOQueue = DispatchQueue(label: "in.werai.room-state.persistence", qos: .utility)
    private struct PendingWrite {
        var events: [MeshRoomEvent]?
        var document: Data?
    }
    private let pendingLock = NSLock()
    private var pendingWrites = [String: PendingWrite]()
    private var writeScheduled = false
    private var forgottenRoomIDs = Set<String>()

    init(fileURL: URL? = nil, secretStore: (any RoomSecretStoring)? = nil) {
        self.secrets = secretStore ?? RoomSecretStore()
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent(Self.storageDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.fileURL = root.appendingPathComponent("rooms.json")
        }
    }

    private static var storageDirectoryName: String {
        Bundle.main.bundleIdentifier == "in.werai.audio.dev" ? "WERAI-Dev" : "WERAI"
    }

    func load() -> [RoomConfiguration] {
        guard let records = try? storedRecords() else { return [] }
        return records.compactMap { record in
            let key = record.isPrivate ? secrets.read(roomID: record.id) : nil
            guard !record.isPrivate || key != nil else { return nil }
            let room = RoomConfiguration(
                id: record.id,
                name: record.name,
                creatorPeerID: record.creatorPeerID,
                isPrivate: record.isPrivate,
                accessKey: key,
                joinedAt: record.joinedAt,
                transportPolicy: record.transportPolicy ?? .legacyOnly
            )
            guard room.transportPolicy != .secureV2 || !room.isPrivate || room.secureJoinSecret != nil else { return nil }
            return room
        }.sorted { $0.joinedAt > $1.joinedAt }
    }

    func save(_ room: RoomConfiguration) throws {
        try save(room, permitsPolicyChange: false)
    }

    private func save(_ room: RoomConfiguration, permitsPolicyChange: Bool) throws {
        if room.transportPolicy == .secureV2 { try room.validateForJoining() }
        // Read metadata independently of credential availability. A missing or
        // malformed Keychain item must not silently authorize a policy downgrade.
        if !permitsPolicyChange, let previous = try storedRecords().first(where: { $0.id == room.id }),
           (previous.transportPolicy ?? .legacyOnly) != room.transportPolicy {
            throw RoomSecurityPolicyError.explicitMigrationRequired
        }
        var rooms = load().filter { $0.id != room.id }
        rooms.insert(room, at: 0)
        if room.isPrivate, let key = room.accessKey {
            try secrets.write(key, roomID: room.id)
        }
        try persist(rooms)
        roomStateIOQueue.async { [self] in forgottenRoomIDs.remove(room.id) }
    }

    /// Explicit migration entry point. Normal saves and renames cannot change policy.
    @discardableResult
    func migrate(roomID: String, to policy: RoomTransportPolicy) throws -> RoomConfiguration? {
        guard let previous = load().first(where: { $0.id == roomID }) else { return nil }
        let migrated = previous.migrated(to: policy)
        try save(migrated, permitsPolicyChange: true)
        return migrated
    }

    @discardableResult
    func rename(roomID: String, to name: String) throws -> Bool {
        var rooms = load()
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return false }
        let room = rooms[index]
        rooms[index] = RoomConfiguration(
            id: room.id,
            name: name,
            creatorPeerID: room.creatorPeerID,
            isPrivate: room.isPrivate,
            accessKey: room.accessKey,
            joinedAt: room.joinedAt,
            transportPolicy: room.transportPolicy
        )
        try persist(rooms)
        return true
    }

    func forget(roomID: String) throws {
        try persist(load().filter { $0.id != roomID }, removingRoomIDs: [roomID])
        roomStateIOQueue.sync { [self] in
            forgottenRoomIDs.insert(roomID)
            pendingLock.withLock { _ = pendingWrites.removeValue(forKey: roomID) }
            try? FileManager.default.removeItem(at: eventsURL(roomID: roomID))
            try? FileManager.default.removeItem(at: roomStateURL(roomID: roomID))
        }
        secrets.remove(roomID: roomID)
    }

    func loadEvents(roomID: String) -> [MeshRoomEvent] {
        roomStateIOQueue.sync {
            drainPendingWrites()
            guard let data = try? Data(contentsOf: eventsURL(roomID: roomID)) else { return [] }
            return (try? JSONDecoder().decode([MeshRoomEvent].self, from: data)) ?? []
        }
    }

    func saveEvents(_ events: [MeshRoomEvent], roomID: String) {
        enqueue(roomID: roomID) { $0.events = events }
    }

    private func writeEvents(_ events: [MeshRoomEvent], roomID: String) {
        let chats = events.filter { $0.kind == .chat }.suffix(500)
        let latestPlayback = events.filter { $0.kind == .playback }.max { $0.version < $1.version }
        let latestVideo = events.filter { $0.kind == .video }.max { $0.version < $1.version }
        var queueAdds = [String: MeshRoomEvent]()
        var queueRemoves = [String: MeshRoomEvent]()
        for event in events where event.kind == .queueAdd || event.kind == .queueRemove {
            guard let id = event.queueItem?.id ?? event.queueItemID else { continue }
            if event.kind == .queueRemove {
                if queueRemoves[id].map({ $0.version < event.version }) ?? true { queueRemoves[id] = event }
            } else if queueAdds[id].map({ $0.version < event.version }) ?? true {
                queueAdds[id] = event
            }
        }
        let queueIDs = Set(queueAdds.keys).union(queueRemoves.keys)
        let queueState = queueIDs.compactMap { id in
            queueRemoves[id] ?? queueAdds[id]
        }
        let compacted = queueState.sorted { $0.version < $1.version }
            + [latestPlayback, latestVideo].compactMap { $0 }
            + Array(chats)
        guard let data = try? JSONEncoder().encode(compacted) else { return }
        try? data.write(to: eventsURL(roomID: roomID), options: .atomic)
    }

    func loadRoomStateDocument(roomID: String) -> Data? {
        roomStateIOQueue.sync {
            drainPendingWrites()
            return try? Data(contentsOf: roomStateURL(roomID: roomID))
        }
    }

    func saveRoomStateDocument(_ document: Data, roomID: String) {
        guard !document.isEmpty else { return }
        enqueue(roomID: roomID) { $0.document = document }
    }

    private func enqueue(roomID: String, update: (inout PendingWrite) -> Void) {
        pendingLock.withLock {
            update(&pendingWrites[roomID, default: PendingWrite()])
            guard !writeScheduled else { return }
            writeScheduled = true
            roomStateIOQueue.async { [self] in drainPendingWrites() }
        }
    }

    private func drainPendingWrites() {
        let writes = pendingLock.withLock {
            let writes = pendingWrites
            pendingWrites.removeAll()
            writeScheduled = false
            return writes
        }
        for (roomID, write) in writes where !forgottenRoomIDs.contains(roomID) {
            if let events = write.events { writeEvents(events, roomID: roomID) }
            if let document = write.document {
                try? document.write(to: roomStateURL(roomID: roomID), options: .atomic)
            }
        }
    }

    private func persist(_ rooms: [RoomConfiguration], removingRoomIDs: Set<String> = []) throws {
        var records = rooms.map {
            StoredRoom(
                id: $0.id,
                name: $0.name,
                creatorPeerID: $0.creatorPeerID,
                isPrivate: $0.isPrivate,
                joinedAt: $0.joinedAt,
                transportPolicy: $0.transportPolicy
            )
        }
        // Credential availability must not erase a saved policy during an
        // unrelated save/rename. Only an explicit forget removes such metadata.
        let updatedIDs = Set(rooms.map(\.id))
        records += try storedRecords().filter { !updatedIDs.contains($0.id) && !removingRoomIDs.contains($0.id) }
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
    }

    private func storedRecords() throws -> [StoredRoom] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([StoredRoom].self, from: Data(contentsOf: fileURL))
    }

    private func eventsURL(roomID: String) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("room-\(roomID).events.json")
    }

    private func roomStateURL(roomID: String) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("room-\(roomID).state.automerge")
    }
}

final class RoomSecretStore: RoomSecretStoring {
    private let service = Bundle.main.bundleIdentifier == "in.werai.audio.dev"
        ? "in.werai.audio.dev.room"
        : "in.werai.audio.room"

    func read(roomID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private let update: (CFDictionary, CFDictionary) -> OSStatus
    private let add: (CFDictionary) -> OSStatus

    init(update: @escaping (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
         add: @escaping (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }) {
        self.update = update
        self.add = add
    }

    func write(_ value: String, roomID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomID,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = update(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = add(query.merging(attributes) { _, new in new } as CFDictionary)
            // Another writer may have inserted the item after our lookup.
            if status == errSecDuplicateItem {
                status = update(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func remove(roomID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomID,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
