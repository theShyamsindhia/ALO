import Foundation
import ALOCore

enum ChatAttachmentStore {
    private static let maximumCacheBytes = 128 * 1_024 * 1_024

    static func save(_ payload: RoomChatAttachmentPayload, roomID: String) throws -> URL {
        let manager = FileManager.default
        let directory = try cacheDirectory(roomID: roomID)
        let fileExtension = URL(fileURLWithPath: payload.attachment.fileName).pathExtension
        let diskName = payload.attachment.id + (fileExtension.isEmpty ? "" : "." + String(fileExtension.prefix(24)))
        let url = directory.appendingPathComponent(diskName)
        try payload.data.write(to: url, options: [.atomic])
        try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        prune(directory: directory, preserving: url)
        return url
    }

    private static func cacheDirectory(roomID: String) throws -> URL {
        let manager = FileManager.default
        let root = try manager.url(for: .cachesDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
            .appendingPathComponent("ALO", isDirectory: true)
            .appendingPathComponent("Chat Attachments", isDirectory: true)
        let safeRoomID = "room-" + roomID.replacingOccurrences(of: "/", with: "-")
        let directory = root.appendingPathComponent(safeRoomID, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func prune(directory: URL, preserving kept: URL) {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let files = urls.compactMap { url -> (URL, Date, Int)? in
            guard url != kept, let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = files.reduce(0) { $0 + $1.2 }
            + ((try? kept.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        for file in files where total > maximumCacheBytes {
            try? manager.removeItem(at: file.0)
            total -= file.2
        }
    }
}
