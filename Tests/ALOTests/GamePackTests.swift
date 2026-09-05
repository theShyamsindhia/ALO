import CryptoKit
import Foundation
import Testing
@testable import ALO
@testable import ALOCore

struct GamePackTests {
    private func fixture(version: Int = 1, engine: String = "rift-arena-v1", platform: String? = nil) throws -> (GamePackDescriptor, Data) {
        let pack = GamePackContent(id: "rift-arena", engine: engine, version: version, arenaName: "The Hollow", subtitle: "Play together", accentHex: "A2ADBE", platformImageBase64: platform)
        let data = try JSONEncoder().encode(pack)
        return (GamePackDescriptor(id: "rift-arena", engine: engine, title: "Rift Arena", summary: "A duel", version: version,
                                   url: URL(string: "https://raw.githubusercontent.com/theShyamsindhia/ALO/main/GamePacks/rift-arena/1/pack.json")!,
                                   sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: data.count), data)
    }
    @Test("Packs are pinned to exact size and SHA256")
    func integrity() throws {
        let (descriptor, data) = try fixture()
        #expect(try GamePackContent.verify(data, descriptor: descriptor).arenaName == "The Hollow")
        var changed = data; changed[changed.startIndex] ^= 1
        #expect(throws: GamePackError.self) { try GamePackContent.verify(changed, descriptor: descriptor) }
        #expect(throws: GamePackError.self) { try GamePackContent.verify(data + Data([0]), descriptor: descriptor) }
    }
    @Test("Platform art rejects malformed base64 and undecodable images before installation")
    @MainActor func platformArtworkValidation() throws {
        let (invalid, data) = try fixture(platform: "invalid base64")
        #expect(throws: GamePackError.self) { try GamePackContent.verify(data, descriptor: invalid) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GameLibraryStore(directory: directory)
        let headerOnly = Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString()
        let (truncated, truncatedData) = try fixture(platform: headerOnly)
        #expect(throws: GamePackError.self) { try store.install(truncatedData, descriptor: truncated) }
        #expect(store.installed.isEmpty)
    }

    @Test("Catalog rejects untrusted URLs, duplicate entries, traversal IDs and excessive downloads")
    func catalogSafety() throws {
        let (valid, _) = try fixture()
        #expect(!GameCatalog.isTrustedURL(URL(string: "https://evil.example/GamePacks/game.json")!))
        #expect(!GameCatalog.isTrustedURL(URL(string: "http://raw.githubusercontent.com/theShyamsindhia/ALO/main/GamePacks/game.json")!))
        #expect(!GameCatalog.isTrustedURL(URL(string: "https://raw.githubusercontent.com/theShyamsindhia/OTHER/main/GamePacks/game.json")!))
        #expect(!GamePackDescriptor.validID("../outside"))
        #expect(throws: GamePackError.self) { try GameCatalog.decode(JSONEncoder().encode(GameCatalog(games: [valid, valid]))) }
        #expect(throws: GamePackError.self) { try GameCatalog.decode(Data(repeating: 0, count: GameCatalog.maximumBytes + 1)) }
    }
    @Test("A downloaded catalog cannot enable an arbitrary engine")
    func unsupportedEngine() throws {
        let (descriptor, data) = try fixture(engine: "downloaded-native-code")
        #expect(!descriptor.supported)
        #expect(throws: GamePackError.self) { try GamePackContent.verify(data, descriptor: descriptor) }
    }
    @Test("Atomic install, reload, rejected update and removal preserve local state")
    @MainActor func installLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GameLibraryStore(directory: directory)
        let (v1, data1) = try fixture()
        try store.install(data1, descriptor: v1)
        #expect(store.installed["rift-arena"]?.descriptor.version == 1)
        let before = try Data(contentsOf: directory.appendingPathComponent("rift-arena.json"))
        let (v2, data2) = try fixture(version: 2)
        #expect(throws: GamePackError.self) { try store.install(data2 + Data([0]), descriptor: v2) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("rift-arena.json")) == before)
        try store.install(data2, descriptor: v2)
        let reloaded = GameLibraryStore(directory: directory)
        #expect(reloaded.installed["rift-arena"]?.descriptor.version == 2)
        reloaded.remove("../outside")
        #expect(reloaded.installed["rift-arena"] != nil)
        reloaded.remove("rift-arena")
        #expect(reloaded.installed["rift-arena"] == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("rift-arena.json").path))
    }
    @Test("Repository catalog pins real content packs")
    func repositoryPacks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try GameCatalog.decode(Data(contentsOf: root.appendingPathComponent("GamePacks/catalog.json")))
        #expect(Set(catalog.games.map(\.id)) == ["rift-arena", "fourfold"])
        for descriptor in catalog.games {
            let data = try Data(contentsOf: root.appendingPathComponent("GamePacks/\(descriptor.id)/\(descriptor.version)/pack.json"))
            let content = try GamePackContent.verify(data, descriptor: descriptor)
            #expect(content.id == descriptor.id)
            if descriptor.id == "rift-arena", descriptor.version >= 3 {
                #expect(content.platformImageData != nil)
                if descriptor.version >= 4 { #expect(content.expandedFighterImageData != nil) }
            }
        }
    }
    @Test("Pack downloads are explicit; canceled responses cannot replace an immediate retry")
    @MainActor func cancelAndRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = PackDownloadProbe()
        let store = GameLibraryStore(directory: directory, fetcher: { url, limit, progress in
            try await transport.fetch()
        })
        #expect(await transport.count == 0)
        let (old, oldData) = try fixture()
        let (new, newData) = try fixture(version: 2)
        try store.install(oldData, descriptor: old)
        store.download(new)
        await waitFor { await transport.count == 1 }
        store.cancel(new.id)
        #expect(store.states[new.id] == .idle)
        #expect(store.installed[new.id]?.descriptor.version == 1)
        store.download(new)
        await waitFor { await transport.count == 2 }
        await transport.succeed(1, data: newData)
        await waitFor { store.installed[new.id]?.descriptor.version == 2 }
        await transport.succeed(0, data: oldData)
        await Task.yield()
        #expect(store.installed[new.id]?.descriptor.version == 2)
        #expect(store.states[new.id] == .idle)
    }

    @Test("Failed download can retry and catalog refresh keeps installed offline entries")
    @MainActor func failureAndCatalogRetention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = PackDownloadProbe()
        let store = GameLibraryStore(directory: directory, fetcher: { _, _, _ in try await transport.fetch() })
        let (descriptor, data) = try fixture()
        store.download(descriptor)
        await waitFor { await transport.count == 1 }
        await transport.fail(0)
        await waitFor {
            if case .failed? = store.states[descriptor.id] { return true }
            return false
        }
        store.download(descriptor)
        await waitFor { await transport.count == 2 }
        await transport.succeed(1, data: data)
        await waitFor { store.installed[descriptor.id] != nil }
        store.refresh()
        await waitFor { await transport.count == 3 }
        await transport.succeed(2, data: try JSONEncoder().encode(GameCatalog(games: [])))
        await waitFor { !store.refreshing }
        #expect(store.games.map(\.id) == [descriptor.id])
    }

    @Test("Redirects are refused before a redirected request is sent")
    func redirectPolicy() throws {
        let original = GameCatalog.url
        let task = URLSession.shared.dataTask(with: original)
        defer { task.cancel() }
        let redirect = try #require(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        var called = false
        GamePackRedirectPolicy().urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: "https://example.com/untrusted")!)) { request in
                called = true
                #expect(request == nil)
            }
        #expect(called)
    }

    @MainActor private func waitFor(_ predicate: () async -> Bool) async {
        for _ in 0..<100 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Download state did not settle")
    }

}


private actor PackDownloadProbe {
    private(set) var count = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    func fetch() async throws -> Data {
        let id = count; count += 1
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func succeed(_ id: Int, data: Data) { pending.removeValue(forKey: id)?.resume(returning: data) }
    func fail(_ id: Int) { pending.removeValue(forKey: id)?.resume(throwing: GamePackError.http(503)) }
}
