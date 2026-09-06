import Foundation

/// SwiftPM's generated accessor searches the app root, but macOS packages put
/// resource bundles in Contents/Resources. Never use its fatal fallback here.
enum GameResources {
    private final class Anchor {}

    static func concreteURL() -> URL? {
        let main = Bundle.main
        let owner = Bundle(for: Anchor.self)
        return concreteURL(searchDirectories: [
            main.resourceURL, main.bundleURL,
            main.executableURL?.deletingLastPathComponent(),
            owner.resourceURL, owner.bundleURL,
            owner.bundleURL.deletingLastPathComponent()
        ].compactMap { $0 })
    }

    static func concreteURL(searchDirectories: [URL]) -> URL? {
        for directory in searchDirectories {
            let url = directory.appendingPathComponent("ALO_ALO.bundle/Breach/concrete.png")
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
