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
    private var coverImages: [String: NSImage] = [:]
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
            coverImages[descriptor.id] = Self.thumbnail(content.backgroundImageData)
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
        coverImages[descriptor.id] = Self.thumbnail(content.backgroundImageData)
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
            coverImages[id] = nil
            installed[id] = nil
        } catch { states[id] = .failed("Could not remove this game pack: " + error.localizedDescription) }
    }

    func coverImage(for id: String) -> NSImage? { coverImages[id] }

    private static func thumbnail(_ data: Data?) -> NSImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private static func validateImage(_ content: GamePackContent) throws {
        for data in [content.backgroundImageData, content.fighterImageData, content.gardenImageData, content.midgroundImageData, content.platformImageData].compactMap({ $0 }) {
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

@MainActor
struct GameLibraryView: View {
    @ObservedObject var store: GameLibraryStore
    @ObservedObject var records = ArenaRecordStore.shared
    var onPlay: (InstalledGamePack) -> Void
    @State private var showsLeaderboard = false
    private let ink = Color.white.opacity(0.9)
    private let secondary = Color.white.opacity(0.5)
    private let accent = Color(red: 0.53, green: 0.58, blue: 0.69)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                tab("Library", selected: !showsLeaderboard) { showsLeaderboard = false }
                tab("Leaderboard", selected: showsLeaderboard) { showsLeaderboard = true }
                Spacer()
                Menu {
                    Button("Refresh library", systemImage: "arrow.clockwise") { store.refresh() }.disabled(store.refreshing)
                    Text("Game packs install once and work offline. New game engines require an ALO update.")
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Library options")
            }.padding(.horizontal, 14).frame(height: 36)
            ScrollView {
                LazyVStack(spacing: 14) {
                    if showsLeaderboard { leaderboard }
                    else {
                        ForEach(store.games) { game in card(game) }
                        if !store.catalogNotice.isEmpty {
                            Text(store.catalogNotice).font(.system(size: 10)).foregroundStyle(secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .foregroundStyle(ink)
        .background(Color(red: 0.15, green: 0.155, blue: 0.17))
        .task { store.refresh() }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? ink : secondary)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { if selected { Capsule().fill(accent).frame(height: 2) } }
        }.buttonStyle(.plain)
    }

    private func card(_ game: GamePackDescriptor) -> some View {
        let installed = store.installed[game.id]
        let state = store.states[game.id] ?? .idle
        let update = installed.map { $0.descriptor.version < game.version } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    if let image = store.coverImage(for: game.id) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else { coverPlaceholder(game.id).frame(width: geometry.size.width, height: geometry.size.height) }
                }
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.id == "rift-arena" ? "Platform fighter" : "Strategy · Board game")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    Text(game.title).font(.system(size: 24, weight: .semibold))
                }.padding(16)
            }.frame(height: 150).clipped()
            HStack(spacing: 10) {
                if !game.supported {
                    Text("ALO update needed").font(.system(size: 11)).foregroundStyle(secondary)
                } else if let installed {
                    Button { onPlay(installed) } label: { Label("Play", systemImage: "play.fill").padding(.horizontal, 10) }
                        .buttonStyle(.borderedProminent).tint(accent.opacity(0.85))
                        .help("Open game options. A match starts only when you choose to play.")
                    if update { Button("Update") { store.download(game) }.buttonStyle(.plain).disabled(state.busy) }
                    Text("Installed").font(.system(size: 10)).foregroundStyle(secondary)
                } else {
                    Button { store.download(game) } label: {
                        Label(state.busy ? "Downloading" : state.isFailure ? "Retry download" : "Download", systemImage: "arrow.down")
                    }.buttonStyle(.borderedProminent).tint(accent.opacity(0.85)).disabled(state.busy)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(game.bytes), countStyle: .file))
                        .font(.system(size: 10)).foregroundStyle(secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Text(game.summary)
                    if installed != nil {
                        Button("Remove download", systemImage: "trash") { store.remove(game.id) }.disabled(state.busy)
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More options for \(game.title)").accessibilityLabel("More options for \(game.title)")
            }.font(.system(size: 11, weight: .medium)).controlSize(.small).padding(12)
            switch state {
            case .downloading(let value):
                HStack {
                    ProgressView(value: value).tint(accent)
                    Text("\(Int(value * 100))%").monospacedDigit()
                    Button("Cancel") { store.cancel(game.id) }.buttonStyle(.plain)
                }.font(.system(size: 10)).padding(.horizontal, 12).padding(.bottom, 12)
            case .verifying: stateLabel("Verifying download…")
            case .installing: stateLabel("Installing…")
            case .failed(let error): stateLabel(error)
            case .idle: EmptyView()
            }
        }
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.7))
    }

    private func coverPlaceholder(_ id: String) -> some View {
        ZStack {
            LinearGradient(colors: id == "rift-arena" ? [Color(red: 0.24, green: 0.29, blue: 0.38), Color(red: 0.34, green: 0.29, blue: 0.34)] : [Color(red: 0.24, green: 0.33, blue: 0.34), Color(red: 0.21, green: 0.24, blue: 0.32)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 20) {
                Spacer()
                if id == "rift-arena" {
                    Image(systemName: "figure.fencing").font(.system(size: 90, weight: .ultraLight))
                        .rotationEffect(.degrees(-12)).offset(y: 8)
                } else {
                    VStack(spacing: 8) {
                        ForEach(0..<3) { row in
                            HStack(spacing: 8) {
                                ForEach(0..<5) { column in
                                    Circle().fill((row + column).isMultiple(of: 3) ? Color.white.opacity(0.25) : Color.black.opacity(0.16)).frame(width: 20, height: 20)
                                }
                            }
                        }
                    }.rotationEffect(.degrees(-9))
                }
            }.foregroundStyle(.white.opacity(0.18)).padding(.trailing, 28)
        }
    }

    private func stateLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(secondary).padding(.horizontal, 12).padding(.bottom, 12)
    }

    private var leaderboard: some View {
        let standings = records.standings()
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Rift Arena").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("On this Mac").font(.system(size: 10)).foregroundStyle(secondary)
            }
            if standings.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "trophy").font(.system(size: 26, weight: .light)).foregroundStyle(accent)
                    Text("Your first result starts here").font(.system(size: 13, weight: .medium))
                    Text("Finish a room match with at least two people to see player wins. Practice does not count.")
                        .font(.system(size: 11)).foregroundStyle(secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("Player").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Played")
                        Text("Wins")
                        Text("Draws")
                    }.font(.system(size: 10)).foregroundStyle(secondary)
                    ForEach(Array(standings.prefix(50).enumerated()), id: \.element.id) { index, row in
                        GridRow {
                            HStack(spacing: 8) {
                                Text("\(index + 1)").foregroundStyle(secondary).frame(width: 18, alignment: .leading)
                                Text(row.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text("\(row.played)")
                            Text("\(row.wins)").foregroundStyle(accent).fontWeight(.semibold)
                            Text("\(row.draws)").foregroundStyle(secondary)
                        }.font(.system(size: 11)).monospacedDigit()
                    }
                }
                Text("Room matches with at least two people · up to 1,000 recent results on this Mac. Bots have no ranking.")
                    .font(.system(size: 9)).foregroundStyle(secondary)
            }
            if let error = records.lastError { Text(error).font(.system(size: 10)).foregroundStyle(secondary) }
        }.padding(14).background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14))
    }
}

private extension GameLibraryStore.DownloadState {
    var isFailure: Bool { if case .failed = self { return true }; return false }
}
