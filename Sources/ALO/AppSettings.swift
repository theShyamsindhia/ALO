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

    private static let sourceRevision = "b874762506abcc54cdd2c8ae7fd2e7db5e41c228"

    static let all: [Self] = [
        .init(id: "original", name: "Original · Default", bytes: nil, sha256: nil),
        .init(id: "midnight", name: "Midnight", bytes: 815_215, sha256: "34a907f23ae931945b49475aa62a7ebeff0900f91e657270897e88901f03dbac"),
        .init(id: "coral", name: "Coral", bytes: 739_285, sha256: "f82b7627936a4db5dc497c05ffc4d0ff5a6b8f4da9fee9b4c0b6b0ef2b4b88e5"),
        .init(id: "cobalt", name: "Cobalt", bytes: 767_290, sha256: "cb4900d91533792a7cc63982d9d40ae52c5d7be0789520d70e946c39512c1904"),
        .init(id: "pearl-color", name: "Pearl Color", bytes: 711_424, sha256: "4a024bd12fdd2366e62fcb318415b1989d6404d2cef7b46a7ca4ae6bf038e3d6"),
        .init(id: "graphite-keycap", name: "Graphite Keycap", bytes: 943_068, sha256: "4c14c441526e15b91c0bef18198c99cd04d71dfa1ef480a66951afd6f64e091b"),
        .init(id: "layered-white", name: "Layered White", bytes: 718_472, sha256: "47e408ba5e7cd894448f4db88406f6876648098336a259f834cd804b35f3f60c"),
        .init(id: "aurora-pearl", name: "Aurora Pearl", bytes: 881_786, sha256: "0c2f021d812104166813e35ec37dafb37379a0e32e5896244a3e189342aef43b"),
        .init(id: "spectrum-ink", name: "Spectrum Ink", bytes: 723_398, sha256: "3838e978ebf708f93afea8ecfc337fdd0b4923d5ff69e37992327674a38d83c8"),
        .init(id: "frosted-ice", name: "Frosted Ice", bytes: 1_115_725, sha256: "0dcc551514afab02e01b0ce823fdcd0be1a876b42eb5c66044f217271915a611"),
        .init(id: "violet-chrome", name: "Violet Chrome", bytes: 1_145_968, sha256: "ceada00570f57c33f9372bd00eec02aa4958a1b6a50f6e88ff307d16687684ea"),
        .init(id: "milk-glass", name: "Milk Glass", bytes: 689_757, sha256: "c2d9e4f706533e33761ed4caa539f40ab8f0584133eb24c27ea92bffc5ac972c"),
        .init(id: "ink-and-lime", name: "Ink and Lime", bytes: 753_015, sha256: "a273bdfb74ad68fa3e18dfc5debdfd6bf684ca693c0c373e7238029cc49c2238"),
        .init(id: "sunset-gel", name: "Sunset Gel", bytes: 792_797, sha256: "f6c50eae61359d3ad5e98cdda7e434e18d2959af6aecb832fd9cd0d92fd7a79f"),
        .init(id: "electric-mint", name: "Electric Mint", bytes: 834_831, sha256: "b9f6a4d3bee9a71a3832ffafbc91d2246ef854abc0ac904bbe51aa5b5e91ef1e"),
        .init(id: "frosted-orange", name: "Frosted Orange", bytes: 696_721, sha256: "07f2156cba41f0f749aec16f31fde75463690937eb02ca5be5d2be3885430930")
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
            .appendingPathComponent("ALO/AppIcons/v3", isDirectory: true)
        self.fetcher = fetcher ?? { url, limit in try await Self.fetch(url, limit: limit) }
        selectedID = AppIconOption.resolvedID(defaults.string(forKey: Self.defaultsKey))
        installedIDs = Set(AppIconOption.all.dropFirst().compactMap { option in
            let url = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ALO/AppIcons/v3", isDirectory: true))
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
                    VStack(spacing: 12) {
                        Text("Notch settings open below the media player.")
                        Button("Open notch settings") {
                            ALONotchFeatureBridge.shared.showSettings()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection) { _, section in
            if section == .notch {
                NSApp.keyWindow?.close()
                ALONotchFeatureBridge.shared.showSettings()
                selection = .appearance
            }
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
