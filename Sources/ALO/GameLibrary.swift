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
        for data in [content.backgroundImageData, content.fighterImageData, content.gardenImageData, content.midgroundImageData, content.platformImageData, content.expandedFighterImageData].compactMap({ $0 }) {
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
    @ObservedObject var stickFight: StickFightSession
    @ObservedObject var breach: BreachRoomSession
    var onPlayStickFight: () -> Void
    @ObservedObject var records = ArenaRecordStore.shared
    var lobbies: [ArenaSession.Lobby]
    var names: [String: String]
    var onPlay: (InstalledGamePack) -> Void
    var onJoin: (ArenaSession.Lobby, Bool) -> Void
    @State private var showsLeaderboard = false
    private let ink = Color.white.opacity(0.9)
    private let secondary = Color.white.opacity(0.5)
    private let accent = Color(red: 0.53, green: 0.58, blue: 0.69)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    tab("Library", systemImage: "square.grid.2x2", selected: !showsLeaderboard) {
                        showsLeaderboard = false
                    }
                    tab("Leaderboard", systemImage: "trophy", selected: showsLeaderboard) {
                        showsLeaderboard = true
                    }
                }
                .padding(3)
                .background(.white.opacity(0.035), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.07), lineWidth: 0.7).allowsHitTesting(false))
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                        .rotationEffect(.degrees(store.refreshing ? 360 : 0))
                        .animation(store.refreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                                   value: store.refreshing)
                }
                .buttonStyle(.plain)
                .disabled(store.refreshing)
                .help("Refresh game library")
                Menu {
                    Text("Game packs install once and work offline. New game engines require an ALO update.")
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Library options")
            }.padding(.horizontal, 14).frame(height: 46)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if showsLeaderboard { leaderboard }
                    else {
                        if !lobbies.isEmpty { liveArenas }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Choose a game")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Installed locally. Room members can join when they have the same game.")
                                .font(.system(size: 10)).foregroundStyle(secondary)
                        }
                        LazyVGrid(columns: [
                            GridItem(.flexible(minimum: 240), spacing: 12, alignment: .top),
                            GridItem(.flexible(minimum: 240), spacing: 12, alignment: .top)
                        ], alignment: .leading, spacing: 12) {
                            stickFightCard
                            breachCard
                            ForEach(store.games.filter { $0.id != "fourfold" }) { game in card(game) }
                        }
                        if !store.catalogNotice.isEmpty {
                            Text(store.catalogNotice).font(.system(size: 10)).foregroundStyle(secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(.horizontal, 14).padding(.bottom, 18)
            }
        }
        .foregroundStyle(ink)
        .background(Color(red: 0.15, green: 0.155, blue: 0.17))
        .task { store.refresh() }
    }

    // Decorative layers must not intercept buttons, including in adjacent grid cells.
    // Clipping the artwork alone does not constrain its pointer hit area.
    private var stickFightCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                StickFightLibraryArtwork()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text("2–4 FIGHTERS · PHYSICS BRAWLER")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("STICK FIGHT").font(.system(size: 30, weight: .black, design: .rounded)).italic()
                }.padding(16)
            }.frame(height: 176).clipped().allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 10) {
                Text("Tiny fighters. Big trouble.")
                    .font(.system(size: 12, weight: .semibold))
                Text("Scramble for weapons, knock friends into the spikes, and survive the next arena. First to five rounds wins.")
                    .font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: onPlayStickFight) {
                        Label("Play", systemImage: "play.fill").padding(.horizontal, 10)
                    }.buttonStyle(.borderedProminent).tint(Color(red: 0.72, green: 0.18, blue: 0.28))
                    Text("Built in · Offline practice").font(.system(size: 10)).foregroundStyle(secondary)
                    Spacer(minLength: 0)
                }.controlSize(.small)
                if !stickFight.lobbies.isEmpty {
                    Button(action: onPlayStickFight) {
                        Label("Live in this room · \(stickFight.lobbies.count) match\(stickFight.lobbies.count == 1 ? "" : "es")", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                    }.buttonStyle(.plain)
                }
            }.padding(12)
        }
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.7).allowsHitTesting(false))
    }

    private var breachCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(red: 0.22, green: 0.30, blue: 0.32), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "scope").font(.system(size: 66, weight: .ultraLight))
                    .foregroundStyle(.orange.opacity(0.3)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(20)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TACTICAL FPS").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(.orange)
                    Text("BREACH").font(.system(size: 28, weight: .black)).tracking(3)
                    Text("Foundry · 2v2 demolition").font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }.frame(height: 138).clipped().allowsHitTesting(false)
            HStack {
                Button { BreachWindowController.shared.show(session: breach) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Text("Room play + bots").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right").help("Opens in a dedicated window")
            }.padding(.horizontal, 12)
            ForEach(breach.lobbies) { lobby in
                HStack {
                    Text(breach.names[lobby.peerID] ?? "Room match").font(.caption).lineLimit(1)
                    Spacer()
                    Button(lobby.availableSlots > 0 ? "Join" : "Watch") {
                        breach.join(lobby, spectate: lobby.availableSlots == 0)
                        BreachWindowController.shared.show(session: breach)
                    }.buttonStyle(.bordered)
                }.padding(.horizontal,12)
            }
            Spacer().frame(height: 4)
        }.background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)).allowsHitTesting(false))
    }

    private var liveArenas: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Live in this room", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(lobbies.count) arena\(lobbies.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(secondary)
            }
            ForEach(lobbies.sorted {
                if $0.started != $1.started { return $0.started && !$1.started }
                return $0.seen > $1.seen
            }.prefix(8)) { lobby in
                HStack(spacing: 10) {
                    Circle().fill(lobby.started ? Color.green : accent).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(names[lobby.peerID] ?? "Room member").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(lobby.started
                             ? "Playing \(lobby.map.title) · \(lobby.humanCount) player\(lobby.humanCount == 1 ? "" : "s")"
                             : "Waiting in \(lobby.map.title) · \(lobby.humanCount)/4 joined")
                            .font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if store.installed["rift-arena"] != nil {
                        if lobby.availableSlots > 0 {
                            Button(lobby.started ? "Join match" : "Join") { onJoin(lobby, false) }
                                .buttonStyle(.borderedProminent).tint(accent.opacity(0.85))
                        }
                        Button("Watch") { onJoin(lobby, true) }.buttonStyle(.bordered)
                    } else {
                        Text("Download Rift Arena to join").font(.system(size: 9)).foregroundStyle(secondary)
                    }
                }.controlSize(.small).padding(10)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
        }.padding(12)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.22), lineWidth: 0.8).allowsHitTesting(false))
    }

    private func tab(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? ink : secondary)
                .padding(.horizontal, 10).frame(height: 28)
                .background(selected ? accent.opacity(0.24) : .clear, in: Capsule())
        }.buttonStyle(.plain)
    }

    private func card(_ game: GamePackDescriptor) -> some View {
        let installed = store.installed[game.id]
        let state = store.states[game.id] ?? .idle
        let update = installed.map { $0.descriptor.version < game.version } ?? false
        return ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                if let image = store.coverImage(for: game.id) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    coverPlaceholder(game.id).frame(width: geometry.size.width, height: geometry.size.height)
                }
            }.allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0.04), .black.opacity(0.2), .black.opacity(0.94)],
                           startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    gameStatusPill(game: game, installed: installed, update: update, state: state)
                    Spacer(minLength: 8)
                    gameOptions(game: game, installed: installed, state: state)
                }
                Spacer(minLength: 12)
                Text(game.id == "rift-arena" ? "PLATFORM FIGHTER" : "STRATEGY · BOARD GAME")
                    .font(.system(size: 8, weight: .bold)).tracking(0.7)
                    .foregroundStyle(.white.opacity(0.62))
                Text(game.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(game.summary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62)).lineLimit(2)
                    .frame(minHeight: 24, alignment: .top)
                HStack(spacing: 8) {
                    gamePrimaryAction(game: game, installed: installed, state: state)
                    if installed != nil, update {
                        Button("Update") { store.download(game) }
                            .buttonStyle(.bordered).disabled(state.busy)
                    }
                    Spacer(minLength: 0)
                    if installed != nil {
                        Label(game.id == "rift-arena" ? "Up to 4" : "1–2 players", systemImage: "person.2.fill")
                            .foregroundStyle(.white.opacity(0.58))
                    } else if !state.busy {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(game.bytes), countStyle: .file))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .font(.system(size: 10, weight: .semibold)).controlSize(.small)
                switch state {
                case .downloading(let value):
                    HStack(spacing: 8) {
                        ProgressView(value: value).tint(accent)
                        Text("\(Int(value * 100))%").monospacedDigit()
                        Button("Cancel") { store.cancel(game.id) }.buttonStyle(.plain)
                    }.font(.system(size: 9)).padding(.top, 8)
                case .verifying: stateLabel("Verifying download…")
                case .installing: stateLabel("Installing…")
                case .failed(let error): stateLabel(error)
                case .idle: EmptyView()
                }
            }
            .padding(14)
        }
        .frame(height: 205)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.white.opacity(0.11), lineWidth: 0.8).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    private func gameOptions(game: GamePackDescriptor, installed: InstalledGamePack?,
                             state: GameLibraryStore.DownloadState) -> some View {
        Menu {
            Text(game.summary)
            if installed != nil {
                Button("Remove download", systemImage: "trash") { store.remove(game.id) }.disabled(state.busy)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 28)
                .background(.black.opacity(0.36), in: Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More options for \(game.title)").accessibilityLabel("More options for \(game.title)")
    }

    @ViewBuilder
    private func gamePrimaryAction(game: GamePackDescriptor, installed: InstalledGamePack?,
                                   state: GameLibraryStore.DownloadState) -> some View {
        if !game.supported {
            Label("ALO update needed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.white.opacity(0.58))
        } else if let installed {
            Button { onPlay(installed) } label: {
                Label("Play", systemImage: "play.fill").frame(minWidth: 74)
            }
            .buttonStyle(.borderedProminent).tint(accent)
            .help("Open game options. A match starts only when you choose to play.")
        } else {
            Button { store.download(game) } label: {
                Label(state.busy ? "Downloading" : state.isFailure ? "Retry" : "Get",
                      systemImage: state.isFailure ? "arrow.clockwise" : "arrow.down")
                    .frame(minWidth: 74)
            }
            .buttonStyle(.borderedProminent).tint(accent).disabled(state.busy)
        }
    }

    private func gameStatusPill(game: GamePackDescriptor, installed: InstalledGamePack?, update: Bool,
                                state: GameLibraryStore.DownloadState) -> some View {
        let label: String
        if !game.supported { label = "Requires update" }
        else if state.busy { label = "Installing" }
        else if state.isFailure { label = "Download failed" }
        else if update { label = "Update available" }
        else if installed != nil { label = "Installed" }
        else { label = "Available" }
        return HStack(spacing: 5) {
            Circle().fill(installed != nil && !update ? Color.green : accent).frame(width: 5, height: 5)
            Text(label)
        }
        .font(.system(size: 9, weight: .semibold))
        .padding(.horizontal, 8).frame(height: 24)
        .background(.black.opacity(0.38), in: Capsule())
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
        Text(text).font(.system(size: 9)).foregroundStyle(.white.opacity(0.62)).lineLimit(2).padding(.top, 7)
    }

    private var leaderboard: some View {
        let standings = records.standings()
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Rift Arena").font(.system(size: 15, weight: .semibold))
                Spacer()
                let matchCount = records.results.filter { $0.gameID == "rift-arena" }.count
                Text(matchCount == 0 ? "On this Mac" : "\(matchCount) match\(matchCount == 1 ? "" : "es") · On this Mac")
                    .font(.system(size: 10)).foregroundStyle(secondary)
            }
            if standings.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "trophy").font(.system(size: 26, weight: .light)).foregroundStyle(accent)
                    Text("No ranked room matches yet").font(.system(size: 13, weight: .medium))
                    Text("The leaderboard updates after a match finishes with at least two real room members. Practice and bot-only matches stay unranked.")
                        .font(.system(size: 11)).foregroundStyle(secondary).multilineTextAlignment(.center)
                    Label("Results are stored only on this Mac", systemImage: "internaldrive")
                        .font(.system(size: 9)).foregroundStyle(secondary)
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

/// Original vector cover stays crisp and ships without a content download.
private struct StickFightLibraryArtwork: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 480, sy = size.height / 176
            context.scaleBy(x: sx, y: sy)
            context.fill(Path(CGRect(x: 0, y: 0, width: 480, height: 176)), with: .color(Color(red: 0.27, green: 0.29, blue: 0.25)))
            for index in 0..<5 {
                let x = CGFloat(index) * 120 - 65
                var mountain = Path()
                mountain.move(to: CGPoint(x: x, y: 176))
                mountain.addLines([CGPoint(x: x + 90, y: CGFloat(12 + index * 9)), CGPoint(x: x + 220, y: 176)])
                context.fill(mountain, with: .color(.black.opacity(0.09)))
            }
            let platforms = [CGRect(x: 0, y: 119, width: 122, height: 70), CGRect(x: 192, y: 99, width: 106, height: 20), CGRect(x: 365, y: 120, width: 115, height: 66)]
            for rect in platforms {
                context.fill(Path(rect), with: .color(Color(red: 0.025, green: 0.04, blue: 0.12)))
                context.fill(Path(roundedRect: CGRect(x: rect.minX - 3, y: rect.minY - 3, width: rect.width + 6, height: 8), cornerRadius: 5), with: .color(Color(red: 0.68, green: 0.05, blue: 0.22)))
                for i in 0..<Int(rect.width / 19) {
                    let x = rect.minX + CGFloat(i) * 19
                    var spike = Path(); spike.move(to: CGPoint(x: x, y: rect.maxY))
                    spike.addLines([CGPoint(x: x + 8, y: rect.maxY + 14), CGPoint(x: x + 16, y: rect.maxY)])
                    context.fill(spike, with: .color(Color(red: 0.025, green: 0.04, blue: 0.12)))
                }
            }
            let colors: [Color] = [.red, .yellow, .green, .cyan]
            let positions: [CGPoint] = [CGPoint(x: 95,y: 83), CGPoint(x: 208,y: 40), CGPoint(x: 290,y: 62), CGPoint(x: 395,y: 86)]
            for (i, p) in positions.enumerated() {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 5, width: 9, height: 9)), with: .color(colors[i]))
                var body = Path(); body.move(to: CGPoint(x: p.x, y: p.y + 4))
                body.addLines([CGPoint(x: p.x + 2,y: p.y + 21), CGPoint(x: p.x - 10,y: p.y + 33)])
                body.move(to: CGPoint(x: p.x + 2,y: p.y + 21)); body.addLine(to: CGPoint(x: p.x + 17,y: p.y + 30))
                body.move(to: CGPoint(x: p.x - 12,y: p.y + 7)); body.addLines([CGPoint(x: p.x,y: p.y + 12), CGPoint(x: p.x + 19,y: p.y + 5)])
                context.stroke(body, with: .color(colors[i]), style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityHidden(true)
    }
}
