internal import AppKit
import Foundation

/// Owned copies keep a screenshot alive while a recipient is chosen. The
/// room host clears this directory only after its transfers have stopped.
actor RoomToolStaging {
    enum StagingError: LocalizedError {
        case invalidImage, full, ended
        var errorDescription: String? {
            switch self {
            case .invalidImage: "This image could not be prepared for sharing."
            case .full: "The room’s temporary screenshot storage is full. Save the image and share it as a file instead."
            case .ended: "You left the room before the screenshot was prepared."
            }
        }
    }
    private let directory: URL
    private var copies: [UUID: URL] = [:]
    private var bytes = 0
    private var ended = false

    init(root: URL = NotchStoragePaths.temporary.appendingPathComponent("RoomToolCopies", isDirectory: true)) {
        self.directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func stageTIFF(_ data: Data, id: UUID) throws -> URL {
        guard !ended else { throw StagingError.ended }
        if let existing = copies[id] { return existing }
        guard copies.count < 32, data.count <= 128 * 1_024 * 1_024 else { throw StagingError.full }
        guard let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw StagingError.invalidImage
        }
        guard bytes + png.count <= 128 * 1_024 * 1_024 else { throw StagingError.full }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Screenshot-\(id.uuidString).png")
        try png.write(to: url, options: .atomic)
        copies[id] = url
        bytes += png.count
        return url
    }

    func clear() throws {
        ended = true
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        copies.removeAll()
        bytes = 0
    }
}
