import Foundation

/// A clean namespace rather than an unsafe recursive migration. Legacy Spaces,
/// keys and history are ignored. Downloaded files and recovery exports are never
/// touched. Keeping the old namespace inert also makes upgrade failure recoverable.
enum NetworkChannelStorage {
    static var fileURL: URL {
        let flavor = Bundle.main.bundleIdentifier == "in.werai.audio.dev" ? "ALO-Dev" : "ALO"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(flavor, isDirectory: true)
            .appendingPathComponent("channels-v1", isDirectory: true)
            .appendingPathComponent("channels.json")
    }
}
