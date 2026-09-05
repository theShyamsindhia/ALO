import AppKit
import SwiftUI

private final class AppIconBundleToken: NSObject {}

struct AppIconOption: Identifiable, Equatable {
    let id: String
    let name: String

    static let all: [Self] = [
        .init(id: "original", name: "Original · Default"),
        .init(id: "midnight", name: "Midnight"),
        .init(id: "coral", name: "Coral"),
        .init(id: "cobalt", name: "Cobalt"),
        .init(id: "pearl-color", name: "Pearl Color"),
        .init(id: "graphite-keycap", name: "Graphite Keycap"),
        .init(id: "layered-white", name: "Layered White"),
        .init(id: "aurora-pearl", name: "Aurora Pearl"),
        .init(id: "spectrum-ink", name: "Spectrum Ink"),
        .init(id: "frosted-ice", name: "Frosted Ice"),
        .init(id: "violet-chrome", name: "Violet Chrome"),
        .init(id: "milk-glass", name: "Milk Glass"),
        .init(id: "ink-and-lime", name: "Ink and Lime"),
        .init(id: "sunset-gel", name: "Sunset Gel"),
        .init(id: "electric-mint", name: "Electric Mint"),
        .init(id: "frosted-orange", name: "Frosted Orange")
    ]

    static func resolvedID(_ value: String?) -> String {
        guard let value, all.contains(where: { $0.id == value }) else { return "original" }
        return value
    }

    @MainActor private static let imageCache = NSCache<NSString, NSImage>()

    @MainActor var image: NSImage? {
        if let cached = Self.imageCache.object(forKey: id as NSString) { return cached }
        let containingDirectory = Bundle(for: AppIconBundleToken.self).bundleURL
            .deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("ALO_ALO.bundle", isDirectory: true),
            containingDirectory.appendingPathComponent("ALO_ALO.bundle", isDirectory: true),
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("ALO_ALO.bundle", isDirectory: true)
        ]
        guard let resourceBundleURL = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { return nil }
        let url = resourceBundleURL
            .appendingPathComponent("AppIcons", isDirectory: true)
            .appendingPathComponent("\(id).png", isDirectory: false)
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        Self.imageCache.setObject(image, forKey: id as NSString)
        return image
    }
}

@MainActor
final class AppIconPreferences: ObservableObject {
    static let shared = AppIconPreferences()
    static let defaultsKey = "ALO.selectedAppIcon"
    @Published private(set) var selectedID: String
    @Published private(set) var error: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedID = AppIconOption.resolvedID(defaults.string(forKey: Self.defaultsKey))
    }

    func applySavedIcon() {
        guard defaults.string(forKey: Self.defaultsKey) != nil else { return }
        select(selectedID)
    }

    func select(_ id: String) {
        let resolved = AppIconOption.resolvedID(id)
        if resolved == "original" {
            NSApplication.shared.applicationIconImage = nil
            selectedID = resolved
            defaults.removeObject(forKey: Self.defaultsKey)
            error = nil
            return
        }
        guard let option = AppIconOption.all.first(where: { $0.id == resolved }),
              let image = option.image, image.isValid else {
            error = "This icon could not be loaded. Please choose another icon."
            return
        }
        NSApplication.shared.applicationIconImage = image
        selectedID = resolved
        defaults.set(resolved, forKey: Self.defaultsKey)
        error = nil
    }
}

@MainActor
final class AppSettingsWindowController {
    private let window: NSWindow

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "ALO Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 600)
        window.contentView = NSHostingView(rootView: AppSettingsView())
        let autosaveName = "ALO.AppSettings"
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AppSettingsView: View {
    var body: some View {
        TabView {
            AppAppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ALONotchFeatureSettings(features: .shared)
                .tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
                .accessibilityIdentifier("ALO.Settings.Notch")
        }
        .padding(12)
    }
}

private struct AppAppearanceSettingsView: View {
    @ObservedObject private var preferences = AppIconPreferences.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("App icon").font(.title2.bold())
                    Text("Choose how ALO looks in your Dock. Your choice is saved on this Mac.")
                        .foregroundStyle(.secondary)
                    Text("Finder keeps the default app icon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(AppIconOption.all) { option in
                        let selected = option.id == preferences.selectedID
                        Button { preferences.select(option.id) } label: {
                            VStack(spacing: 6) {
                                if let image = option.image {
                                    Image(nsImage: image).resizable().interpolation(.high)
                                        .scaledToFit().frame(width: 88, height: 88)
                                } else {
                                    Image(systemName: "photo").frame(width: 88, height: 88)
                                }
                                Text(option.name).font(.caption).lineLimit(2)
                                    .multilineTextAlignment(.center)
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                            }
                            .frame(maxWidth: .infinity, minHeight: 142)
                            .padding(6)
                            .background(selected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.025),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.name)
                        .accessibilityValue(selected ? "Selected" : "Not selected")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityHint("Use this icon in the Dock")
                    }
                }
                if let error = preferences.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityLabel("App icon error: \(error)")
                }
                Button("Restore Default") { preferences.select("original") }
                    .disabled(preferences.selectedID == "original")
            }
            .padding(24)
        }
    }
}
