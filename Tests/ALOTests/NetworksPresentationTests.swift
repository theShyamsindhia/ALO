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
        @Test("Join-error states preserve native window size and account state", arguments: [false, true], [false, true])
        func joinErrorRendering(dark: Bool, long: Bool) async throws {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-error-ui-\(UUID().uuidString)")
            let suite = "alo-error-ui-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
            let storage = PresentationKeyStorage()
            let account = NetworkAccountModel(defaults: defaults,
                repository: NetworkRepository(directoryURL: directory), identityStore: UserIdentityStore(storage: storage))
            account.displayName = "Test user"
            try account.createIdentity()
            try await account.completeIdentitySetup()
            let model = ALOViewModel(discoverRooms: false, account: account)
            let message = long
                ? "The nearby connection closed before approval. Try joining again while the network owner has ALO open and both devices are connected to the same local network."
                : "The nearby connection closed. Try joining again."
            model.errorMessage = message
            let insertCount = storage.insertCount
            for size in [NSSize(width: 640, height: 440), NSSize(width: 760, height: 520)] {
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -2000, y: 0), size: size),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                NetworkSetupWindowPresentation.configure(window, identityReady: true)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let hosting = NSHostingView(rootView: ALOView(model: model)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.controlActiveState, .active)
                    .transaction { $0.disablesAnimations = true })
                window.contentView = hosting
                window.orderBack(nil)
                try await Task.sleep(for: .milliseconds(300))
                // Apply the requested size after hosting attachment. Full-size
                // content includes the transparent title bar; contentLayoutRect
                // describes the smaller title-bar-safe area, not the UI bounds.
                window.setContentSize(size)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let path = ProcessInfo.processInfo.environment["ALO_NETWORKS_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to:
                        URL(fileURLWithPath: path).appendingPathComponent("join-error-\(long ? "long" : "short")-\(dark ? "dark" : "light")-\(Int(size.width)).png"))
                }
                #expect(hosting.bounds.size == size)
                #expect(window.styleMask.contains(.fullSizeContentView))
                #expect(window.contentRect(forFrameRect: window.frame).size == size)
                #expect(window.contentLayoutRect.width == size.width)
                #expect(model.errorMessage == message)
                #expect(account.identityReady)
                #expect(model.phase == .idle)
                #expect(account.selectedNetwork == nil)
                #expect(account.networks.isEmpty)
                #expect(storage.insertCount == insertCount)
            }
        }

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
            if state != "identity" && state != "recovery" { try await account.completeIdentitySetup() }
            if state == "main" || state == "channels" {
                let network = try await account.createNetwork(name: "Studio network")
                if state == "channels" {
                    try await account.createChannel(name: "Music", networkID: network.id, isPrivate: false, allowedUserIDs: [])
                    try await account.createChannel(name: "Private conversation", networkID: network.id, isPrivate: true, allowedUserIDs: [])
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
            if account.identityReady {
                NetworkSetupWindowPresentation.configure(window, identityReady: true)
                window.setContentSize(NSSize(width: 800, height: 640))
            }
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
            if account.identityReady {
                // Exercise the actual account-backed browser at both supported
                // native sizes, not only the public-value content fixture.
                for size in [NSSize(width: 640, height: 440), NSSize(width: 760, height: 520)] {
                    window.setContentSize(size)
                    try await Task.sleep(for: .milliseconds(150))
                    hosting.layoutSubtreeIfNeeded()
                    #expect(hosting.bounds.size == size)
                    #expect(window.styleMask.contains(.resizable))
                }
                #expect(storage.insertCount == insertCount)
                #expect(account.networks.count == networkCount)
                #expect(model.phase == .idle)
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
