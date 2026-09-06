import AppKit
import SwiftUI
import Testing
import ALOCore
import ALOIdentity
import ALORooms
import ALOAppModel
@testable import ALO

// All native presentation fixtures share NSApplication's layout machinery.
@Suite(.serialized) @MainActor
struct NativePresentationTests {}

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct NetworksPresentationTests {
        @Test("Networks and identity screens render without joining or creating keys",
              arguments: [false, true], ["identity", "recovery", "empty", "main", "channels"])
        func presentation(dark: Bool, state: String) async throws {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-network-ui-\(UUID().uuidString)")
            let suite = "alo-network-ui-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
            let storage = PresentationKeyStorage()
            let account = NetworkAccountModel(defaults: defaults,
                repository: NetworkRepository(directoryURL: directory), identityStore: UserIdentityStore(storage: storage))
            account.displayName = "Test user"
            if state != "identity" { try account.createIdentity() }
            if state != "identity" && state != "recovery" { try account.completeIdentitySetup() }
            if state == "main" || state == "channels" {
                let network = try account.createNetwork(name: "Studio network")
                if state == "channels" {
                    try account.createChannel(name: "Music", networkID: network.id, isPrivate: false, allowedUserIDs: [])
                    try account.createChannel(name: "Private conversation", networkID: network.id, isPrivate: true, allowedUserIDs: [])
                }
            }
            let model = ALOViewModel(discoverRooms: false, account: account)
            let originalIdentity = account.identity?.publicIdentity
            let insertCount = storage.insertCount
            let networkCount = account.networks.count
            let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 800, height: 640),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: ALOView(model: model)
                .environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = hosting
            defer { window.close() }
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.bounds.width == 800)
            #expect(hosting.bounds.height == 640)
            #expect(model.phase == .idle)
            #expect(account.identity?.publicIdentity == originalIdentity)
            #expect(storage.insertCount == insertCount)
            #expect(account.networks.count == networkCount)
            if state == "identity" { #expect(storage.loadCount == 0) }
            if state == "channels" { #expect(account.channels.count == 3) }
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1000)
            if let path = ProcessInfo.processInfo.environment["ALO_NETWORKS_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Recovery is never revealed. These screenshots contain public
                // test identities only, not raw credentials or installed data.
                try png.write(to: folder.appendingPathComponent("\(state)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

private final class PresentationKeyStorage: UserIdentityKeyStorage {
    private var data: Data?
    private(set) var insertCount = 0
    private(set) var loadCount = 0
    func loadPrivateKey() throws -> Data? { loadCount += 1; return data }
    func insertPrivateKeyIfAbsent(_ bytes: Data) throws -> Bool {
        guard data == nil else { return false }; data = bytes; insertCount += 1; return true
    }
}
