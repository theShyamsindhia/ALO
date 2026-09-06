import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

struct AppIconOption: Identifiable, Equatable {
    let id: String
    let name: String
    let bytes: Int?
    let sha256: String?

    private static let sourceRevision = "e1a93551329e1ef7f61462be33abb07f0230e7dc"

    static let all: [Self] = [
        .init(id: "original", name: "Original · Default", bytes: nil, sha256: nil),
        .init(id: "midnight", name: "Midnight", bytes: 979_363, sha256: "fa704d7c3e75e8bfb738ec5a002e4eb15004e544cd9d3a7d2bf9efc2bf565119"),
        .init(id: "coral", name: "Coral", bytes: 867_408, sha256: "84498aedd109a20d2695ab31e850e94c6dc056db1262e29826059d38d5386b82"),
        .init(id: "cobalt", name: "Cobalt", bytes: 763_253, sha256: "32280377f3f968b7e025de2d79535885d7a4e134a78b6e455658faf8ac88728a"),
        .init(id: "pearl-color", name: "Pearl Color", bytes: 776_404, sha256: "60fb96fd76834d3728a1289d5c115bd65dee7f0a4d38fbc168373f2ec229b298"),
        .init(id: "graphite-keycap", name: "Graphite Keycap", bytes: 1_130_044, sha256: "09287e368d02723f83716ff7d6d6fdde8f1f29c557a3a8d7c17ce23f7a3710fc"),
        .init(id: "layered-white", name: "Layered White", bytes: 791_296, sha256: "639a8b5b5c581360eae43529f9bf727bb4b7b9af8e53100e2de6f39827a41f01"),
        .init(id: "aurora-pearl", name: "Aurora Pearl", bytes: 950_132, sha256: "b4327e25a4a9e0b64c2198ef361e5dcc9f7b1ccebaf0065103b9c43fce1d9a2d"),
        .init(id: "spectrum-ink", name: "Spectrum Ink", bytes: 806_893, sha256: "640ea6a47ebca7d55ce47c7a945bbd040d28967d12f37d546102b3a92dee33fa"),
        .init(id: "frosted-ice", name: "Frosted Ice", bytes: 1_338_280, sha256: "87261736c62ea7eb712c52392b52f77fd8b81bac3a57b3b90dc1cd9fc4918559"),
        .init(id: "violet-chrome", name: "Violet Chrome", bytes: 1_289_023, sha256: "87e24e486d8835207bc71eb2a5ddf830dbae62a6ccd0e4b564e7cba504fc7f45"),
        .init(id: "milk-glass", name: "Milk Glass", bytes: 732_988, sha256: "8144d84b26dd9cf2c23b33b45aca664590a2f8b53e0accc1d1f51a0e600ecb7f"),
        .init(id: "ink-and-lime", name: "Ink and Lime", bytes: 830_785, sha256: "c35811542c2fc29bbd182de22107df133365e97952e507d49648fb87ef6c5519"),
        .init(id: "sunset-gel", name: "Sunset Gel", bytes: 881_954, sha256: "2c32badd15ad14466438366d19ff600ca23fdb741489dc5436ccf686c3de7159"),
        .init(id: "electric-mint", name: "Electric Mint", bytes: 931_499, sha256: "30d3c993df93d75320f0689282e50b0ba00fdf8bcb7b69606f9ec43c792195d6"),
        .init(id: "frosted-orange", name: "Frosted Orange", bytes: 811_672, sha256: "bef86975bae7800348d50115b5d266ed25b9c27b32eb5eb911a4bae20b6dca0d")
    ]

    static func resolvedID(_ value: String?) -> String {
        guard let value, all.contains(where: { $0.id == value }) else { return "original" }
        return value
    }

    var downloadURL: URL? {
        guard bytes != nil else { return nil }
        return URL(string: "https://raw.githubusercontent.com/theShyamsindhia/ALO/\(Self.sourceRevision)/Sources/ALO/Resources/AppIcons/\(id).png")
    }

    var formattedSize: String? {
        bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    func validate(_ data: Data) throws -> NSImage {
        guard let bytes, let sha256, data.count == bytes else { throw AppIconDownloadError.sizeMismatch }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw AppIconDownloadError.checksumMismatch }
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 1_024,
              properties[kCGImagePropertyPixelHeight] as? Int == 1_024,
              let image = NSImage(data: data), image.isValid else { throw AppIconDownloadError.invalidImage }
        return image
    }
}

enum AppIconDownloadError: Error, LocalizedError {
    case invalidResponse, http(Int), tooLarge, sizeMismatch, checksumMismatch, invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The icon download came from an unexpected location."
        case .http(let status): return "The icon download failed with HTTP status \(status)."
        case .tooLarge, .sizeMismatch: return "The icon download size did not match the expected file."
        case .checksumMismatch: return "The icon did not pass its SHA-256 integrity check."
        case .invalidImage: return "The downloaded icon is not a valid 1024 × 1024 PNG."
        }
    }
}

@MainActor
final class AppIconPreferences: ObservableObject {
    static let shared = AppIconPreferences()
    static let defaultsKey = "ALO.selectedAppIcon"
    typealias Fetch = @Sendable (URL, Int) async throws -> Data
    @Published private(set) var selectedID: String
    @Published private(set) var error: String?
    @Published private(set) var downloadingID: String?
    @Published private(set) var installedIDs: Set<String>
    private let defaults: UserDefaults
    private let directory: URL
    private let fetcher: Fetch
    private var downloadTask: Task<Void, Never>?
    private var downloadToken: UUID?
    private var previews: [String: NSImage] = [:]

    init(defaults: UserDefaults = .standard, directory: URL? = nil, fetcher: Fetch? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ALO/AppIcons/v1", isDirectory: true)
        self.fetcher = fetcher ?? { url, limit in try await Self.fetch(url, limit: limit) }
        selectedID = AppIconOption.resolvedID(defaults.string(forKey: Self.defaultsKey))
        installedIDs = Set(AppIconOption.all.dropFirst().compactMap { option in
            let url = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ALO/AppIcons/v1", isDirectory: true))
                .appendingPathComponent(option.id + ".png")
            return FileManager.default.fileExists(atPath: url.path) ? option.id : nil
        })
    }

    func applySavedIcon() {
        guard defaults.string(forKey: Self.defaultsKey) != nil else { return }
        guard selectedID != "original", applyInstalledIcon(selectedID) else {
            restoreDefault()
            error = "The selected icon is no longer installed. Choose it again to download it."
            return
        }
    }

    func select(_ id: String) {
        let resolved = AppIconOption.resolvedID(id)
        if resolved == "original" {
            cancelDownload()
            restoreDefault()
            return
        }
        guard let option = AppIconOption.all.first(where: { $0.id == resolved }) else { return }
        if applyInstalledIcon(resolved) { return }
        download(option)
    }

    func preview(for option: AppIconOption) -> NSImage? {
        if let cached = previews[option.id] { return cached }
        let image: NSImage?
        if option.id == "original" {
            image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
                ?? NSApplication.shared.applicationIconImage
        } else {
            guard let data = try? Data(contentsOf: fileURL(for: option.id)),
                  (try? option.validate(data)) != nil else { return nil }
            image = Self.thumbnail(data)
        }
        if let image { previews[option.id] = image }
        return image
    }

    func isDownloaded(_ id: String) -> Bool { installedIDs.contains(id) }

    var downloadedBytes: Int {
        AppIconOption.all.filter { installedIDs.contains($0.id) }.compactMap(\.bytes).reduce(0, +)
    }

    func install(_ data: Data, for option: AppIconOption) throws {
        _ = try option.validate(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: option.id), options: .atomic)
        installedIDs.insert(option.id)
        previews[option.id] = Self.thumbnail(data)
    }

    func removeDownloads() {
        cancelDownload()
        restoreDefault()
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            installedIDs.removeAll()
            previews = previews.filter { $0.key == "original" }
        } catch {
            self.error = "Downloaded icons could not be removed: \(error.localizedDescription)"
        }
    }

    private func download(_ option: AppIconOption) {
        guard let url = option.downloadURL, let expectedBytes = option.bytes else { return }
        cancelDownload()
        let token = UUID()
        downloadToken = token
        downloadingID = option.id
        error = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await fetcher(url, expectedBytes)
                try Task.checkCancellation()
                guard downloadToken == token else { return }
                try install(data, for: option)
                guard downloadToken == token else { return }
                _ = applyInstalledIcon(option.id)
            } catch is CancellationError {
                // A different selection or restoring the default intentionally cancels this download.
            } catch {
                if downloadToken == token { self.error = error.localizedDescription }
            }
            if downloadToken == token {
                downloadingID = nil
                downloadToken = nil
                downloadTask = nil
            }
        }
    }

    private func applyInstalledIcon(_ id: String) -> Bool {
        guard let option = AppIconOption.all.first(where: { $0.id == id }),
              let data = try? Data(contentsOf: fileURL(for: id)),
              let image = try? option.validate(data) else {
            installedIDs.remove(id)
            return false
        }
        NSApplication.shared.applicationIconImage = image
        selectedID = id
        defaults.set(id, forKey: Self.defaultsKey)
        previews[id] = Self.thumbnail(data)
        installedIDs.insert(id)
        error = nil
        return true
    }

    private func restoreDefault() {
        NSApplication.shared.applicationIconImage = nil
        selectedID = "original"
        defaults.removeObject(forKey: Self.defaultsKey)
        error = nil
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadToken = nil
        downloadingID = nil
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(id + ".png", isDirectory: false)
    }

    private static func thumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 176,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    nonisolated private static func fetch(_ url: URL, limit: Int) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw AppIconDownloadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AppIconDownloadError.http(http.statusCode) }
        guard response.url == url else { throw AppIconDownloadError.invalidResponse }
        guard response.expectedContentLength <= Int64(limit) else { throw AppIconDownloadError.tooLarge }
        var data = Data()
        data.reserveCapacity(limit)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw AppIconDownloadError.tooLarge }
            data.append(byte)
        }
        return data
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
    private enum Section: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case notch = "Notch"

        var id: Self { self }
    }

    @State private var selection = Section.appearance

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $selection) {
                Label("Appearance", systemImage: "paintpalette")
                    .tag(Section.appearance)
                Label("Notch", systemImage: "rectangle.topthird.inset.filled")
                    .tag(Section.notch)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("ALO.Settings.SectionPicker")

            Divider()

            Group {
                switch selection {
                case .appearance:
                    AppAppearanceSettingsView()
                case .notch:
                    ALONotchFeatureSettings(features: .shared)
                        .accessibilityIdentifier("ALO.Settings.Notch")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                    Text("Alternative icons download from ALO's GitHub repository only when selected. Finder keeps the default app icon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(AppIconOption.all) { option in
                        let selected = option.id == preferences.selectedID
                        let downloading = option.id == preferences.downloadingID
                        let downloaded = option.id == "original" || preferences.isDownloaded(option.id)
                        Button { preferences.select(option.id) } label: {
                            VStack(spacing: 6) {
                                if let image = preferences.preview(for: option) {
                                    Image(nsImage: image).resizable().interpolation(.high)
                                        .scaledToFit().frame(width: 88, height: 88)
                                } else if downloading {
                                    ProgressView().controlSize(.small).frame(width: 88, height: 88)
                                } else {
                                    VStack(spacing: 6) {
                                        Image(systemName: "icloud.and.arrow.down")
                                            .font(.system(size: 28, weight: .medium))
                                        if let size = option.formattedSize {
                                            Text(size).font(.caption2)
                                        }
                                    }
                                    .foregroundStyle(.secondary)
                                    .frame(width: 88, height: 88)
                                }
                                Text(option.name).font(.caption).lineLimit(2)
                                    .multilineTextAlignment(.center)
                                Image(systemName: selected ? "checkmark.circle.fill" : (downloaded ? "circle" : "arrow.down.circle"))
                                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
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
                        .disabled(preferences.downloadingID != nil && option.id != "original")
                        .accessibilityLabel(option.name)
                        .accessibilityValue(selected ? "Selected" : (downloaded ? "Downloaded" : "Not downloaded"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityHint(downloaded ? "Use this icon in the Dock" : "Download and use this icon in the Dock")
                    }
                }
                if let error = preferences.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityLabel("App icon error: \(error)")
                }
                HStack {
                    Button("Restore Default") { preferences.select("original") }
                        .disabled(preferences.selectedID == "original")
                    if !preferences.installedIDs.isEmpty {
                        Button("Remove Downloaded Icons") { preferences.removeDownloads() }
                        Text(ByteCountFormatter.string(fromByteCount: Int64(preferences.downloadedBytes), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
    }
}
