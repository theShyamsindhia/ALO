import AppKit
import SwiftUI
import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct ALONotchTests {
    @Test func preferencesPersistWithoutChangingOtherPresentations() throws {
        let name = "alo-notch-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "floatingBarHidden")
        let settings = ALONotchPreferences(defaults: defaults)
        #expect(!settings.enabled)
        #expect(settings.hoverToExpand)
        settings.enabled = true
        settings.hoverToExpand = false
        settings.animation = "relaxed"
        settings.island = true
        settings.builtInDisplay = false
        let restored = ALONotchPreferences(defaults: defaults)
        #expect(restored.enabled && restored.island)
        #expect(!restored.hoverToExpand && !restored.builtInDisplay)
        #expect(restored.preset == .relaxed)
        #expect(defaults.bool(forKey: "floatingBarHidden"))
        restored.animation = "unknown future preset"
        #expect(restored.preset == .balanced)
    }

    @Test func originalTransitionKeepsContentTopAnchored() {
        #expect(NotchTransitionMetrics.verticalCompensationOffset(for: 200, baseHeight: 32) == -84)
        #expect(NotchTransitionMetrics.verticalCompensationOffset(for: 20, baseHeight: 32) == 0)
        let presets = NotchAnimationPreset.allCases.map(NotchAnimations.preset)
        #expect(presets.map(\.hideShowDelay) == [0.28, 0.31, 0.34, 0.37, 0.40])
    }

    @Test func closingPopoverPreservesVisibleNotchChat() {
        let model = ALOViewModel(discoverRooms: false)
        model.floatingBarHidden = true
        model.floatingSection = .chat
        model.notchExpandedVisible = true
        model.setMenuBarPopoverVisible(false)
        #expect(model.floatingSection == .chat)
        model.notchExpandedVisible = false
        model.setMenuBarPopoverVisible(false)
        #expect(model.floatingSection == .collapsed)
    }

    @Test func popoverHoldsRemainUntilEveryNotchPopoverCloses() {
        let model = ALOViewModel(discoverRooms: false)
        let lyrics = UUID(), settings = UUID()
        #expect(!model.notchHasOpenPopover)
        model.setNotchPopoverPresented(true, owner: lyrics)
        model.setNotchPopoverPresented(true, owner: settings)
        model.setNotchPopoverPresented(true, owner: lyrics)
        #expect(model.notchPopoverHolds.count == 2)
        model.setNotchPopoverPresented(false, owner: lyrics)
        #expect(model.notchHasOpenPopover)
        // Repeated teardown of one view must not release another view's hold.
        model.setNotchPopoverPresented(false, owner: lyrics)
        #expect(model.notchHasOpenPopover)
        model.setNotchPopoverPresented(false, owner: settings)
        #expect(!model.notchHasOpenPopover)
    }

    @Test("Notch renders compact, room and chat states", arguments: ["compact", "room", "chat", "island"])
    func render(stateName: String) async throws {
        _ = NSApplication.shared
        let suite = "alo-notch-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ALONotchPreferences(defaults: defaults)
        preferences.island = stateName == "island"
        let model = ALOViewModel(discoverRooms: false)
        model.roomName = "Listening room"
        model.phase = .live
        model.floatingSection = stateName == "chat" ? .chat : .collapsed
        let state = ALONotchPresentation()
        state.expanded = stateName != "compact"
        model.notchExpandedVisible = state.expanded
        let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 620, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        let hosting = NSHostingView(rootView: ALONotchView(model: model, preferences: preferences, state: state)
            .background(Color.gray.opacity(0.4)))
        hosting.sizingOptions = []
        window.contentView = hosting
        defer { window.close() }
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(700))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        #expect(model.phase == .live)
        if let directory = ProcessInfo.processInfo.environment["ALO_NOTCH_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("notch-\(stateName).png"))
        }
    }
}
