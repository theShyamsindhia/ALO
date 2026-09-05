internal import AppKit
import SwiftUI

/// Works in the packaged ALO app, the standalone CLI, and SwiftPM tests.
enum NotchResources {
    static let bundle: Bundle = {
        let name = "ALO_ALONotchRuntime.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                          Bundle.main.executableURL?.deletingLastPathComponent()]
        for directory in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: directory.appendingPathComponent(name)) { return bundle }
        }
        return Bundle.module
    }()
}

func NotchImage(_ name: String) -> Image {
    for ext in ["png", "pdf", "jpg", "jpeg", "heic", "tiff"] {
        if let url = NotchResources.bundle.url(forResource: name, withExtension: ext),
           let image = NSImage(contentsOf: url) { return Image(nsImage: image) }
    }
    return Image(name, bundle: NotchResources.bundle)
}

func NotchText(_ key: LocalizedStringKey) -> Text { Text(key, bundle: NotchResources.bundle) }
@_disfavoredOverload
func NotchText<S: StringProtocol>(_ string: S) -> Text { Text(verbatim: String(string)) }
func NotchText(verbatim string: String) -> Text { Text(verbatim: string) }

// Isolate imported feature choices from ALO and any installed DynamicNotch app.
extension UserDefaults {
    // Foundation guarantees thread-safe defaults access; workers share only
    // this immutable reference, while observable settings writes stay on main.
    nonisolated(unsafe) static let aloNotch = UserDefaults(suiteName: (Bundle.main.bundleIdentifier ?? "in.werai.audio") + ".notch.features")!
}
