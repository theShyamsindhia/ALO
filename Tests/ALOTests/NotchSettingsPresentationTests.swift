import Testing
import AppKit
import SwiftUI
@testable import ALO

@Suite(.serialized) @MainActor
struct NotchSettingsPresentationTests {
    @Test func nativeFeatureOverviewRendersInMenuBarPopover() async throws {
        _ = NSApplication.shared
        let model = ALOViewModel(discoverRooms: false)
        model.phase = .live
        model.roomName = "Offline layout preview"
        model.nowPlaying = .init(title: "Your music", artist: "Room playback", isPlaying: false)
        model.notchSettingsVisible = true
        let preferences = ALONotchPreferences.shared
        let wasEnabled = preferences.enabled
        preferences.enabled = true
        let bridge = ALONotchFeatureBridge.shared
        bridge.configure(model: model)
        bridge.setEnabled(true)
        defer { preferences.enabled = wasEnabled; bridge.setEnabled(false) }
        let size = NSSize(width: 568, height: 552)
        let view = NSHostingView(rootView: ALOStatusPopoverContent(model: model)
            .environment(\.controlActiveState, .active)
            .environment(\.colorScheme, .dark).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        try await Task.sleep(nanoseconds: 250_000_000)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 568)
        if let path = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("notch-settings-menu-bar.png"))
        }
    }

    @Test func openingFromMenuKeepsSettingsWithPlayerAndCollapsesUpperContent() {
        let model = ALOViewModel(discoverRooms: false)
        model.setMenuBarPopoverVisible(true)
        model.floatingBarHidden = true
        model.floatingSection = .chat
        model.prepareNotchSettingsForMenuBar()
        #expect(model.notchSettingsVisible)
        #expect(model.notchSettingsHeight == 430)
        #expect(model.floatingSection == .collapsed)
        #expect(model.floatingBarHidden, "Opening inline must not move a menu-bar player into another window")
        model.notchSettingsVisible = false
        #expect(model.notchSettingsHeight == 0)
    }

    @Test func openingNotchSettingsDoesNotRevealTheFloatingMediaBar() {
        let model = ALOViewModel(discoverRooms: false)
        model.floatingBarHidden = true
        model.prepareNotchSettingsForMenuBar()
        #expect(model.notchSettingsVisible)
        #expect(model.floatingBarHidden)
        #expect(model.nowPlaying.isEmpty)
    }
}
