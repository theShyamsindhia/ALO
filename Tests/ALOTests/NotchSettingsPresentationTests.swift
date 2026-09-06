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
        try await Task.sleep(for: .milliseconds(50))
        model.prepareNotchSettingsForMenuBar()
        let frames: [(String, Duration)] = [
            ("01-first-frame", .milliseconds(16)),
            ("02-opening", .milliseconds(90)),
            ("03-settling", .milliseconds(160)),
            ("04-settled", .milliseconds(340))
        ]
        for (name, delay) in frames {
            try await Task.sleep(for: delay)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 568)
            if let path = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("notch-settings-\(name).png"))
            }
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

    @Test func popoverResizesOnlyAfterSwiftUIReconcilesOpeningSettings() async throws {
        let model = ALOViewModel(discoverRooms: false)
        model.phase = .live
        let controller = ALOStatusMenuController(
            model: model,
            toggleMainWindow: {}
        )
        if ProcessInfo.processInfo.environment["ALO_NOTCH_POPOVER_LIFECYCLE_SNAPSHOT_DIR"] != nil {
            controller.showPopover(allowWhenIdle: true)
            try await Task.sleep(for: .milliseconds(180))
        }
        defer { controller.closePopover() }
        let collapsedHeight = controller.contentSize.height
        try capturePopover(controller, name: "00-player")

        model.prepareNotchSettingsForMenuBar()

        #expect(controller.contentSize.height == collapsedHeight)
        #expect(!model.notchSettingsContentVisible)
        try capturePopover(controller, name: "01-open-requested")
        await Task.yield()
        await Task.yield()
        #expect(controller.contentSize.height == collapsedHeight + model.notchSettingsHeightWhenVisible)
        #expect(model.notchSettingsContentVisible)
        if ProcessInfo.processInfo.environment["ALO_NOTCH_POPOVER_LIFECYCLE_SNAPSHOT_DIR"] != nil {
            try await Task.sleep(for: .milliseconds(520))
        }
        try capturePopover(controller, name: "02-settings-open")
    }

    @Test func popoverWaitsForSwiftUILayoutBeforeCollapsingSettings() async throws {
        let model = ALOViewModel(discoverRooms: false)
        model.phase = .live
        let controller = ALOStatusMenuController(
            model: model,
            toggleMainWindow: {}
        )
        if ProcessInfo.processInfo.environment["ALO_NOTCH_POPOVER_LIFECYCLE_SNAPSHOT_DIR"] != nil {
            controller.showPopover(allowWhenIdle: true)
            try await Task.sleep(for: .milliseconds(180))
        }
        defer { controller.closePopover() }
        let collapsedHeight = controller.contentSize.height
        model.prepareNotchSettingsForMenuBar()
        await Task.yield()
        await Task.yield()
        let expandedHeight = controller.contentSize.height
        if ProcessInfo.processInfo.environment["ALO_NOTCH_POPOVER_LIFECYCLE_SNAPSHOT_DIR"] != nil {
            try await Task.sleep(for: .milliseconds(520))
        }
        try capturePopover(controller, name: "03-settings-before-close")

        model.notchSettingsVisible = false

        #expect(controller.contentSize.height == expandedHeight)
        #expect(!model.notchSettingsContentVisible)
        try capturePopover(controller, name: "04-close-requested")
        await Task.yield()
        await Task.yield()
        #expect(controller.contentSize.height == collapsedHeight)
        try capturePopover(controller, name: "05-player-restored")
    }

    @Test func reopeningCancelsAStaleCollapseResize() async {
        let model = ALOViewModel(discoverRooms: false)
        model.phase = .live
        let controller = ALOStatusMenuController(
            model: model,
            toggleMainWindow: {}
        )
        let collapsedHeight = controller.contentSize.height
        model.prepareNotchSettingsForMenuBar()
        await Task.yield()
        await Task.yield()
        let expandedHeight = controller.contentSize.height

        model.notchSettingsVisible = false
        model.prepareNotchSettingsForMenuBar()
        await Task.yield()
        await Task.yield()

        #expect(controller.contentSize.height == expandedHeight)
        #expect(controller.contentSize.height == collapsedHeight + model.notchSettingsHeightWhenVisible)
    }

    @Test func openingNotchSettingsDoesNotRevealTheFloatingMediaBar() {
        let model = ALOViewModel(discoverRooms: false)
        model.floatingBarHidden = true
        model.prepareNotchSettingsForMenuBar()
        #expect(model.notchSettingsVisible)
        #expect(model.floatingBarHidden)
        #expect(model.nowPlaying.isEmpty)
    }

    @Test func dismissingNotchSettingsClearsItsPresentationState() {
        let model = ALOViewModel(discoverRooms: false)
        let preferences = ALONotchPreferences.shared
        let wasEnabled = preferences.enabled
        preferences.enabled = true
        let bridge = ALONotchFeatureBridge.shared
        bridge.configure(model: model)
        bridge.setEnabled(true)
        defer { preferences.enabled = wasEnabled; bridge.setEnabled(false) }

        model.prepareNotchSettingsForMenuBar()
        #expect(model.notchSettingsVisible)

        bridge.dismissSettings()

        #expect(!model.notchSettingsVisible)
        #expect(model.notchSettingsHeight == 0)
    }

    private func capturePopover(_ controller: ALOStatusMenuController, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["ALO_NOTCH_POPOVER_LIFECYCLE_SNAPSHOT_DIR"] else {
            return
        }
        let popover = try #require(Mirror(reflecting: controller).children
            .first(where: { $0.label == "popover" })?.value as? NSPopover)
        let view = try #require(popover.contentViewController?.view)
        if !popover.isShown {
            view.frame = NSRect(origin: .zero, size: popover.contentSize)
        }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }
}
