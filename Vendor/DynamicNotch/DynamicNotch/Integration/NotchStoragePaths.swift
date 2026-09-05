import Foundation

/// ALO-owned files must never share the upstream app's cleanup directories.
/// Resolving these paths performs no filesystem writes or migration.
enum NotchStoragePaths {
    nonisolated static var hostIdentifier: String { Bundle.main.bundleIdentifier ?? "in.werai.audio" }

    nonisolated static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(hostIdentifier, isDirectory: true)
            .appendingPathComponent("Notch", isDirectory: true)
    }

    nonisolated static var caches: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(hostIdentifier, isDirectory: true)
            .appendingPathComponent("Notch", isDirectory: true)
    }

    nonisolated static var temporary: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(hostIdentifier, isDirectory: true)
            .appendingPathComponent("Notch", isDirectory: true)
    }

    nonisolated static var fileTray: URL { applicationSupport.appendingPathComponent("FileTray", isDirectory: true) }
    nonisolated static var screenshots: URL { caches.appendingPathComponent("RawScreenshots", isDirectory: true) }
    nonisolated static var airDrop: URL { temporary.appendingPathComponent("AirDrop", isDirectory: true) }
}
