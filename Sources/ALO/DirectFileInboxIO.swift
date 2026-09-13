import Foundation

protocol DirectFileInboxIO: Sendable {
    func export(_ source: URL, to destination: URL) async throws
    func remove(_ directory: URL) async throws
}

/// Disk work stays off the UI executor. The controller lends owned files to
/// save/preview operations and delays room-exit cleanup until those finish.
actor LocalDirectFileInboxIO: DirectFileInboxIO {
    func export(_ source: URL, to destination: URL) throws {
        try Data(contentsOf: source, options: .mappedIfSafe).write(to: destination, options: .atomic)
    }

    func remove(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
