import ALOCore
import AppKit
import Foundation
import ImageIO
import SwiftUI

@MainActor
final class GameLibraryStore: ObservableObject {
    enum DownloadState: Equatable {
        case idle, downloading(Double), verifying, installing, failed(String)
        var busy: Bool {
            switch self { case .downloading, .verifying, .installing: return true; default: return false }
        }
    }
    @Published private(set) var games = GameCatalogFallback.games
    @Published private(set) var installed: [String: InstalledGamePack] = [:]
    @Published private(set) var states: [String: DownloadState] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var catalogNotice = ""
    typealias Fetch = @Sendable (URL, Int, (@Sendable (Int) async -> Void)?) async throws -> Data
    private let fetcher: Fetch
    private let directory: URL
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]
    private var refreshTask: Task<Void, Never>?
    private struct StoredPack: Codable { let descriptor: GamePackDescriptor; let data: Data }

    init(directory: URL? = nil, fetcher: Fetch? = nil) {
        self.fetcher = fetcher ?? { url, limit, progress in
            try await Self.fetch(url, limit: limit, progress: progress)
        }
        let previewDirectory: URL?
        #if DEBUG
        if directory == nil,
           let path = Bundle.main.object(forInfoDictionaryKey: "ALOGamePackPreviewDirectory") as? String,
           path.hasPrefix("/") {
            previewDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else { previewDirectory = nil }
        #else
        previewDirectory = nil
        #endif
        self.directory = directory ?? previewDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ALO/GamePacks", isDirectory: true)
        for descriptor in games {
            let url = self.directory.appendingPathComponent(descriptor.id + ".json")
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 24 * 1_024 * 1_024,
                  let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(StoredPack.self, from: data),
                  stored.descriptor.id == descriptor.id,
                  let content = try? GamePackContent.verify(stored.data, descriptor: stored.descriptor),
                  (try? Self.validateImage(content)) != nil else { continue }
            installed[descriptor.id] = InstalledGamePack(descriptor: stored.descriptor, content: content)
        }
    }

    func refresh() {
        guard refreshTask == nil else { return }
        refreshing = true; catalogNotice = ""
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { refreshing = false; refreshTask = nil }
            do {
                let data = try await fetcher(GameCatalog.url, GameCatalog.maximumBytes, nil)
                let catalog = try GameCatalog.decode(data).games
                let currentIDs = Set(catalog.map(\.id))
                let localOnly = installed.values.map(\.descriptor).filter { !currentIDs.contains($0.id) }
                games = catalog + localOnly.sorted { $0.title < $1.title }
            } catch {
                catalogNotice = "Catalog unavailable. Installed games still work; you can retry refreshing."
            }
        }
    }

    func download(_ descriptor: GamePackDescriptor) {
        guard tasks[descriptor.id] == nil else { return }
        let token = UUID(); tokens[descriptor.id] = token
        states[descriptor.id] = .downloading(0)
        tasks[descriptor.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if tokens[descriptor.id] == token { tasks[descriptor.id] = nil; tokens[descriptor.id] = nil }
            }
            do {
                try Task.checkCancellation()
                try descriptor.validate()
                guard descriptor.supported else { throw GamePackError.unsupportedEngine }
                let data = try await fetcher(descriptor.url, descriptor.bytes, { [weak self] count in
                    await self?.reportProgress(count, total: descriptor.bytes, id: descriptor.id, token: token)
                })
                try Task.checkCancellation()
                states[descriptor.id] = .verifying
                try Task.checkCancellation()
                states[descriptor.id] = .installing
                try install(data, descriptor: descriptor)
                states[descriptor.id] = .idle
            } catch is CancellationError {
                if tokens[descriptor.id] == token { states[descriptor.id] = .idle }
            } catch {
                if tokens[descriptor.id] == token { states[descriptor.id] = .failed(error.localizedDescription) }
            }
        }
    }

    private func reportProgress(_ count: Int, total: Int, id: String, token: UUID) {
        guard tokens[id] == token else { return }
        states[id] = .downloading(Double(count) / Double(total))
    }

    /// Shared install path for downloads and deterministic disk-integrity tests.
    func install(_ data: Data, descriptor: GamePackDescriptor) throws {
        let content = try GamePackContent.verify(data, descriptor: descriptor)
        try Self.validateImage(content)
        let stored = try JSONEncoder().encode(StoredPack(descriptor: descriptor, data: data))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic replacement preserves the previous installation if verification
        // or the final disk write fails. Download cancellation is checked first.
        try stored.write(to: directory.appendingPathComponent(descriptor.id + ".json"), options: .atomic)
        installed[descriptor.id] = InstalledGamePack(descriptor: descriptor, content: content)
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil; tokens[id] = nil; states[id] = .idle
    }
    func remove(_ id: String) {
        guard GamePackDescriptor.validID(id) else { return }
        cancel(id)
        do {
            let file = directory.appendingPathComponent(id + ".json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            installed[id] = nil
        } catch { states[id] = .failed("Could not remove this game pack: " + error.localizedDescription) }
    }

    private static func validateImage(_ content: GamePackContent) throws {
        for data in [content.backgroundImageData, content.fighterImageData].compactMap({ $0 }) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096 else { throw GamePackError.invalidPack }
        }
    }

    nonisolated private static func fetch(_ url: URL, limit: Int, progress: (@Sendable (Int) async -> Void)? = nil) async throws -> Data {
        guard GameCatalog.isTrustedURL(url), limit > 0, limit <= GamePackContent.maximumBytes else { throw GamePackError.invalidManifest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await URLSession.shared.bytes(for: request, delegate: GamePackRedirectPolicy())
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url, GameCatalog.isTrustedURL(finalURL), finalURL == url else {
            throw GamePackError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard response.expectedContentLength <= Int64(limit) else { throw GamePackError.tooLarge }
        var data = Data(); data.reserveCapacity(min(limit, 1_048_576))
        for try await byte in stream {
            guard data.count < limit else { throw GamePackError.tooLarge }
            data.append(byte)
            if data.count % 65_536 == 0 {
                try Task.checkCancellation()
                await progress?(data.count)
            }
        }
        try Task.checkCancellation(); await progress?(data.count)
        return data
    }
}

/// Pack URLs are exact, pinned repository paths. Never follow a redirect to a
/// different host (or path) and only discover the mismatch after requesting it.
final class GamePackRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GameLibraryView: View {
    @ObservedObject var store: GameLibraryStore
    var onPlay: (InstalledGamePack) -> Void
    private let ink = Color.white.opacity(0.9)
    private let secondary = Color.white.opacity(0.5)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.games) { game in card(game) }
                    if !store.catalogNotice.isEmpty {
                        Text(store.catalogNotice).font(.system(size: 11)).foregroundStyle(secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Spacer()
                        Image(systemName: "info.circle")
                            .help("Content packs install once and work offline. New native game engines require an ALO update. Downloaded packs contain only images and presentation data.")
                        Button { store.refresh() } label: {
                            if store.refreshing { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.clockwise") }
                        }.buttonStyle(.plain).disabled(store.refreshing).help("Refresh game downloads and updates")
                    }.font(.system(size: 11)).foregroundStyle(secondary)
                }.padding(14)
            }
        }
        .foregroundStyle(ink)
        .background(Color(red: 0.15, green: 0.155, blue: 0.17))
        .task { store.refresh() }
    }
    private func card(_ game: GamePackDescriptor) -> some View {
        let installed = store.installed[game.id]
        let state = store.states[game.id] ?? .idle
        let update = installed.map { $0.descriptor.version < game.version } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15).fill(Color.white.opacity(0.055))
                    if let data = installed?.content.backgroundImageData, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: game.id == "rift-arena" ? "figure.fencing" : "circle.grid.3x3.fill")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(Color(red: 0.63, green: 0.68, blue: 0.76))
                    }
                }.frame(width: 75, height: 75).clipShape(RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text(game.title).font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(game.summary).font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                    Text(installed == nil ? ByteCountFormatter.string(fromByteCount: Int64(game.bytes), countStyle: .file) + " download" : "Installed · version \(installed!.descriptor.version)")
                        .font(.system(size: 10)).foregroundStyle(secondary)
                }
                Spacer(minLength: 0)
            }
            switch state {
            case .downloading(let value):
                HStack { ProgressView(value: value).tint(Color.white.opacity(0.6)); Text("\(Int(value * 100))%").font(.caption.monospacedDigit()); Button("Cancel") { store.cancel(game.id) } }
            case .verifying: Label("Verifying download…", systemImage: "checkmark.shield").font(.caption)
            case .installing: Label("Installing…", systemImage: "arrow.down.circle").font(.caption)
            case .failed(let error): Text(error).font(.system(size: 10)).foregroundStyle(Color(red: 0.9, green: 0.67, blue: 0.63))
            case .idle: EmptyView()
            }
            HStack(spacing: 10) {
                if !game.supported {
                    Text("ALO update needed").font(.caption).foregroundStyle(secondary)
                } else if let installed {
                    Button("Play") { onPlay(installed) }.buttonStyle(.borderedProminent).tint(Color(red: 0.40, green: 0.44, blue: 0.52))
                    if update { Button("Update pack") { store.download(game) }.disabled(state.busy) }
                    Spacer()
                    Button("Remove") { store.remove(game.id) }.disabled(state.busy).foregroundStyle(secondary)
                } else {
                    Button { store.download(game) } label: {
                        Label(state.busy ? "Downloading…" : state.isFailure ? "Retry download" : "Download", systemImage: "arrow.down.circle")
                    }.buttonStyle(.borderedProminent).tint(Color(red: 0.40, green: 0.44, blue: 0.52)).disabled(state.busy)
                }
            }.font(.system(size: 11, weight: .medium)).controlSize(.small)
        }
        .padding(15)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.09), lineWidth: 1))
    }
}

private extension GameLibraryStore.DownloadState {
    var isFailure: Bool { if case .failed = self { return true }; return false }
}
