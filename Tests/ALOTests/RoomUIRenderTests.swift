import AppKit
import SwiftUI
import Testing
import ALOCore
@testable import ALO

@Suite(.serialized) @MainActor
struct RoomUIRenderTests {
    @Test func exportNativeRenders() async throws {
        guard let path = ProcessInfo.processInfo.environment["ALO_UI_RENDER_DIR"] else { return }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let artworkURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/ALOSetupSlide-3.jpg")
        let artwork = try Data(contentsOf: artworkURL)
        let model = ALOViewModel(discoverRooms: false)
        model.lyrics.enabled = false
        model.phase = .live
        model.roomName = "Studio"
        model.currentParticipantID = "preview-local"
        model.currentUserName = "You"
        model.participants = [
            RoomParticipant(id: "preview-local", name: "You", icon: "🌊", colorHex: "328EAA"),
            RoomParticipant(id: "preview-peer-a", name: "Listener A", icon: "🦊", colorHex: "9474AF"),
            RoomParticipant(id: "preview-peer-b", name: "Listener B", icon: "🦕", colorHex: "739E87")
        ]
        model.nowPlayingCallback(NowPlayingMedia(title: "Quiet afternoon", artist: "Sample artwork",
            artworkData: artwork, isPlaying: false, elapsedTime: 72, duration: 240))
        try await Task.sleep(for: .milliseconds(150))
        model.setMenuBarPopoverVisible(true)

        try await capture(ALOStatusPopoverContent(model: model), size: NSSize(width: 560, height: 145),
                          name: "01-player", folder: folder)
        model.setSection(.people, in: .menuBar)
        try await capture(ALOStatusPopoverContent(model: model),
                          size: NSSize(width: 560, height: model.panelHeight(for: .menuBar) + 87),
                          name: "02-people", folder: folder)

        let palette = ArtworkTheme.palette(from: artwork)
        let cover = try #require(NSImage(data: artwork))
        let controls: [ALOMenuBarControl] = [.playback, .next, .chat, .people, .screen, .sync, .mute]
        let row = HStack(spacing: 14) {
            Image(nsImage: ALOMenuBarRecord.image(active: true, artwork: cover, palette: palette))
                .frame(width: 27, height: 27)
            ForEach(controls) { control in
                Image(nsImage: ALOMenuBarControlImage.make(symbol: control.symbol, palette: palette,
                    appearance: NSAppearance(named: .darkAqua)!))
                    .frame(width: 24, height: 24)
            }
        }.padding(.horizontal, 22).frame(height: 50)
        try await capture(row, size: NSSize(width: 350, height: 50), name: "03-menu-bar", folder: folder)
    }

    private func capture<V: View>(_ content: V, size: NSSize, name: String, folder: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -2000, y: 0), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: content
            .environment(\.colorScheme, .dark)
            .environment(\.controlActiveState, .active)
            .transaction { $0.disablesAnimations = true }
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = view
        defer { window.close() }
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
