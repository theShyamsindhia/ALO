import Foundation
import ALOCore

/// Serialize cache writes and hashing away from the UI and audio executors.
actor RoomTrayFileIO {
    private let store: RoomTrayStore
    init(store: RoomTrayStore = RoomTrayStore()) { self.store = store }

    func importFile(_ url: URL, roomID: String) throws -> (RoomTrayFileDescriptor, URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try store.importFile(at: url, roomID: roomID)
    }

    func receive(_ data: Data, descriptor: RoomTrayFileDescriptor, roomID: String) throws {
        try store.storeIncoming(data, descriptor: descriptor, roomID: roomID)
    }

    func payload(for item: RoomTrayItem, roomID: String) throws -> RoomChatAttachmentPayload? {
        guard let id = UUID(uuidString: item.id), let url = store.fileURL(itemID: id, roomID: roomID) else { return nil }
        return RoomChatAttachmentPayload(attachment: item.attachment, data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    func remove(_ id: UUID, roomID: String) throws { try store.remove(itemID: id, roomID: roomID) }

    func export(_ id: UUID, roomID: String, to destination: URL) throws {
        _ = try store.export(itemID: id, roomID: roomID, to: destination)
    }
}
