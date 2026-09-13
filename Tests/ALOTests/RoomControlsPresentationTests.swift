import AppKit
import SwiftUI
import Testing
import ALOCore
@testable import ALO

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct RoomControlsPresentationTests {
        @Test("ALO settings uses the product title")
        func aloSettingsTitle() async throws {
            _ = NSApplication.shared
            let model = ALOViewModel(discoverRooms: false)
            model.roomName = "Offline preview"
            let size = NSSize(width: 360, height: 430)
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -2000, y: 0), size: size),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let hosting = NSHostingView(rootView: RoomPreferencesView(model: model)
                .transaction { $0.disablesAnimations = true }
                .environment(\.colorScheme, .dark))
            window.contentView = hosting
            defer { window.close() }
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(120))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            #expect(bitmap.pixelsHigh > 0)

            if let directory = ProcessInfo.processInfo.environment["ALO_SPACES_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("alo-settings.png"))
            }
        }

        @Test("Playback progress replaces the menu popover seam")
        func playbackProgressSeam() async throws {
            _ = NSApplication.shared
            let model = ALOViewModel(discoverRooms: false)
            model.nowPlayingCallback(NowPlayingMedia(
                title: "Yesterday",
                artist: "The Marías",
                isPlaying: false,
                elapsedTime: 90,
                duration: 180
            ))
            try await Task.sleep(for: .milliseconds(30))

            let window = NSWindow(
                contentRect: NSRect(x: -2000, y: 0, width: 560, height: 145),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: VStack(spacing: 0) {
                FloatingRoomView(model: model, presentation: .menuBar)
                RoomPlaybackProgressDivider(model: model)
                WalkieTalkieBar(model: model, showsCloseButton: false)
            }
            .transaction { $0.disablesAnimations = true })
            window.contentView = hosting
            defer { window.close() }
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(120))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

            #expect(bitmap.pixelsWide > 0)
            #expect(bitmap.pixelsHigh > 0)
            #expect(try #require(model.roomPlaybackProgress(at: Date())) == 0.5)
            let position = try #require(model.roomPlaybackPosition(at: Date()))
            #expect(position >= 90 && position <= 91)

            if let directory = ProcessInfo.processInfo.environment["ALO_SPACES_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("playback-progress-seam.png"))
            }
        }

        @Test("The setup window toggles without closing or rebuilding its content")
        func setupWindowToggle() {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 306, height: 426),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let draft = NSTextField(string: "Unfinished room name")
            window.contentView = draft
            defer { window.close() }
            let frame = window.frame

            for _ in 0..<3 {
                toggleALOSetupWindow(window)
                #expect(window.isVisible)
                toggleALOSetupWindow(window)
                #expect(!window.isVisible)
                #expect(window.contentView === draft)
                #expect(draft.stringValue == "Unfinished room name")
                #expect(window.frame == frame)
            }
        }

        @Test("Translucent Talk bar keeps a complete unread badge in light and dark appearances",
              arguments: [false, true], [(0, false), (1, false), (27, false), (100, false), (27, true)])
        func talkBarBadge(dark: Bool, state: (Int, Bool)) async throws {
            _ = NSApplication.shared
            let (unread, floating) = state
            let model = ALOViewModel(discoverRooms: false)
            model.participants = [RoomParticipant(id: "peer", name: "Other Mac", volume: 1,
                                                 isMuted: false, icon: "🎧", colorHex: "7C6FF2")]
            model.unreadMessageCount = unread
            let height: CGFloat = floating ? 94 : 56
            let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: floating ? 568 : 560, height: height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: WalkieTalkieBar(model: model, showsCloseButton: floating)
                .transaction { $0.disablesAnimations = true }
                .environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = hosting
            defer { window.close() }
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / height
            let backgroundY: CGFloat = floating ? 7 : 3
            let background = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(backgroundY * scale))?
                .usingColorSpace(.deviceRGB))
            if floating {
                // With no artwork, the native material stays neutral.
                #expect(abs(background.redComponent - background.greenComponent) < 0.02)
                #expect(abs(background.greenComponent - background.blueComponent) < 0.02)
            } else {
                // The embedded strip must let its parent's material show through.
                #expect(background.alphaComponent < 0.01)
            }

            var redRows = Set<Int>()
            for y in 0..<bitmap.pixelsHigh {
                for x in (bitmap.pixelsWide * 3 / 4)..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.redComponent > 0.7 && color.greenComponent < 0.4 && color.blueComponent < 0.4 {
                        redRows.insert(y)
                    }
                }
            }
            if unread == 0 {
                #expect(redRows.isEmpty)
            } else {
                // The old dock clipping removed the badge's top half.
                let top = try #require(redRows.min())
                let bottom = try #require(redRows.max())
                #expect(CGFloat(bottom - top + 1) >= 10 * scale)
                #expect(top > 0)
                #expect(bottom < bitmap.pixelsHigh - 1)
            }
            #expect(model.phase == .idle)
            #expect(model.unreadMessageCount == unread)
            if let directory = ProcessInfo.processInfo.environment["ALO_SPACES_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("talk-bar-\(unread)-\(dark ? "dark" : "light")-\(floating ? "floating" : "menu").png"))
            }
        }

        @Test("Update banner and What's New window render as native ALO surfaces")
        func nativeUpdatePresentationRenders() async throws {
            _ = NSApplication.shared
            let previousIcon = NSApp.applicationIconImage
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if let icon = NSImage(contentsOf: repository.appendingPathComponent("Resources/ALOLogo-1024.png")) {
                NSApp.applicationIconImage = icon
            }
            defer { NSApp.applicationIconImage = previousIcon }
            let bannerSize = NSSize(width: 560, height: 82)
            let banner = NSHostingView(rootView: AppUpdateBanner(version: "0.14.12", action: {})
                .transaction { $0.disablesAnimations = true }
                .environment(\.colorScheme, .dark)
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(width: bannerSize.width, height: bannerSize.height))
            let bannerWindow = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: bannerSize),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            bannerWindow.isReleasedWhenClosed = false
            bannerWindow.appearance = NSAppearance(named: .darkAqua)
            bannerWindow.contentView = banner
            defer { bannerWindow.close() }
            bannerWindow.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            banner.layoutSubtreeIfNeeded()
            let bannerBitmap = try #require(banner.bitmapImageRepForCachingDisplay(in: banner.bounds))
            banner.cacheDisplay(in: banner.bounds, to: bannerBitmap)
            #expect(bannerBitmap.pixelsWide > 0 && bannerBitmap.pixelsHigh > 0)

            let asset = AppUpdater.Release.Asset(
                name: "ALO-macos-arm64.zip",
                browserDownloadURL: URL(string: "https://example.com/ALO.zip")!,
                digest: "sha256:" + String(repeating: "a", count: 64),
                size: 1_024
            )
            let release = AppUpdater.Release(
                tagName: "v0.14.12",
                name: "Faster rooms and clearer updates",
                body: "## Summary\nALO now keeps rooms aligned for longer.\n\n## Highlights\n- See release details before installing.\n- Get clearer update progress and errors.",
                htmlURL: URL(string: "https://example.com/release")!,
                assets: [asset]
            )
            let details = UpdateDetailsWindowController(release: release, updater: AppUpdater())
            let detailsWindow = try #require(details.window)
            detailsWindow.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            defer { detailsWindow.close() }
            detailsWindow.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            let detailsView = try #require(detailsWindow.contentView)
            detailsView.layoutSubtreeIfNeeded()
            let detailsBitmap = try #require(detailsView.bitmapImageRepForCachingDisplay(in: detailsView.bounds))
            detailsView.cacheDisplay(in: detailsView.bounds, to: detailsBitmap)
            #expect(detailsBitmap.pixelsWide > 0 && detailsBitmap.pixelsHigh > 0)

            let support = UpdateDetailsWindowController(
                release: release,
                updater: AppUpdater(),
                initialPage: .support
            )
            let supportWindow = try #require(support.window)
            supportWindow.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            defer { supportWindow.close() }
            supportWindow.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            let supportView = try #require(supportWindow.contentView)
            supportView.layoutSubtreeIfNeeded()
            let supportBitmap = try #require(supportView.bitmapImageRepForCachingDisplay(in: supportView.bounds))
            supportView.cacheDisplay(in: supportView.bounds, to: supportBitmap)
            #expect(supportBitmap.pixelsWide > 0 && supportBitmap.pixelsHigh > 0)

            if let directory = ProcessInfo.processInfo.environment["ALO_SPACES_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try #require(bannerBitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("update-banner.png"))
                try #require(detailsBitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("whats-new.png"))
                try #require(supportBitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("update-support.png"))
            }
        }
    }
}
