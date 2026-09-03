import Foundation
import Security
import WERAICore

final class RoomStore {
    private struct StoredRoom: Codable {
        let id: String
        let name: String
        let creatorPeerID: String
        let isPrivate: Bool
        let joinedAt: Date
    }

    private let fileURL: URL
    private let secrets = RoomSecretStore()

    init(fileURL: URL? = nil) {
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
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([StoredRoom].self, from: data)
        else { return [] }
        return records.compactMap { record in
            let key = record.isPrivate ? secrets.read(roomID: record.id) : nil
            guard !record.isPrivate || key != nil else { return nil }
            return RoomConfiguration(
                id: record.id,
                name: record.name,
                creatorPeerID: record.creatorPeerID,
                isPrivate: record.isPrivate,
                accessKey: key,
                joinedAt: record.joinedAt
            )
        }.sorted { $0.joinedAt > $1.joinedAt }
    }

    func save(_ room: RoomConfiguration) throws {
        var rooms = load().filter { $0.id != room.id }
        rooms.insert(room, at: 0)
        if room.isPrivate, let key = room.accessKey {
            try secrets.write(key, roomID: room.id)
        }
        try persist(rooms)
    }

    func forget(roomID: String) throws {
        try persist(load().filter { $0.id != roomID })
        try? FileManager.default.removeItem(at: eventsURL(roomID: roomID))
        secrets.remove(roomID: roomID)
    }

    func loadEvents(roomID: String) -> [MeshRoomEvent] {
        guard let data = try? Data(contentsOf: eventsURL(roomID: roomID)) else { return [] }
        return (try? JSONDecoder().decode([MeshRoomEvent].self, from: data)) ?? []
    }

    func saveEvents(_ events: [MeshRoomEvent], roomID: String) {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let cutoff = now - min(now, 7 * 86_400_000)
        let chats = events.filter {
            $0.kind == .chat && min($0.version.wallTimeMillis, now) >= cutoff
        }.suffix(500)
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

    private func persist(_ rooms: [RoomConfiguration]) throws {
        let records = rooms.map {
            StoredRoom(
                id: $0.id,
                name: $0.name,
                creatorPeerID: $0.creatorPeerID,
                isPrivate: $0.isPrivate,
                joinedAt: $0.joinedAt
            )
        }
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
    }

    private func eventsURL(roomID: String) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("room-\(roomID).events.json")
    }
}

private final class RoomSecretStore {
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

    func write(_ value: String, roomID: String) throws {
        remove(roomID: roomID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomID,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
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
