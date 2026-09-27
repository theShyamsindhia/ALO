import AppKit
import SwiftUI
import XCTest
@testable import ALONotchRuntime

@MainActor
final class NotchMaterialTests: XCTestCase {
    func testCompactAndExpandedSurfaceUseNativeBackdropWithCurrentAccessibilityPreference() async throws {
        _ = NSApplication.shared
        for expanded in [false, true] {
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            let surface = NotchBackgroundSurface(
                topCornerRadius: 34, bottomCornerRadius: 44, isDynamicIsland: false,
                dynamicIslandCornerRadius: 16)
            let host = NSHostingView(rootView: surface)
            host.frame = NSRect(x: 0, y: 0, width: 430, height: expanded ? 192 : 32)
            host.layoutSubtreeIfNeeded()
            let effects = nativeBackdrops(in: host)
            if #available(macOS 26.0, *) {
                XCTAssertFalse(effects.contains { $0.identifier?.rawValue == "ALO.Notch.Backdrop" },
                               "Liquid Glass must not be covered by the older frosted material")
            } else {
                XCTAssertEqual(effects.count, !reduceTransparency ? 1 : 0)
            }
            if let effect = effects.first {
                XCTAssertEqual(effect.blendingMode, .behindWindow)
                XCTAssertEqual(effect.material, .popover)
                XCTAssertEqual(effect.state, .active)
                XCTAssertEqual(effect.alphaValue, 1, "Never fade blur into sharp transparency")
            }
        }
    }

    private func nativeBackdrops(in view: NSView) -> [NSVisualEffectView] {
        let own = (view as? NSVisualEffectView).map { [$0] } ?? []
        return own + view.subviews.flatMap { nativeBackdrops(in: $0) }
    }

    /// Opt-in WindowServer capture: caching an offscreen NSView cannot prove
    /// behind-window blur. Only fixture windows are shown; ALO stays untouched.
    func testNativeBackdropPreview() async throws {
        guard ProcessInfo.processInfo.environment["ALO_NOTCH_CAPTURE_BACKDROP"] == "1",
              let directory = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"],
              CGPreflightScreenCaptureAccess(), let screen = NSScreen.main else {
            throw XCTSkip("Opt-in native material capture needs an attached display and screen capture access")
        }
        let name = "NotchMaterialPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsViewModel(defaults: defaults)
        let service = RoomPlaybackService()
        let music = NowPlayingViewModel(service: service, lyricsProvider: InactiveLyricsProvider(), favoritesStore: defaults)
        let art = NotchResources.bundle.url(forResource: "backgroundDark", withExtension: "png")
        service.update(.init(title: "Todo llegará", artist: "Manu Chao",
            artworkData: try art.map { try Data(contentsOf: $0) }, isPlaying: true,
            elapsed: 47, duration: 224, canTogglePlayback: true,
            canSkipNext: true, canSkipPrevious: true, canSeek: true))
        music.startMonitoring()
        defer { music.stopMonitoring() }
        let notch = NotchViewModel(settings: settings.application, hideDelay: 0, queueDelay: 0,
            screenMetricsProvider: { _ in (width: 1512, topInset: 32, notchSize: CGSize(width: 190, height: 32)) })
        notch.showNotch = true
        let original = NowPlayingNotchContent(nowPlayingViewModel: music,
            settings: settings.mediaAndFiles, applicationSettings: settings.application)
        notch.send(.showLiveActivity(RoomNowPlayingNotchContent(original: original,
            openRoom: { XCTFail("Preview must not navigate") })))
        try await Task.sleep(for: .milliseconds(150))
        notch.expandActiveLiveActivity()
        defer { notch.setActivityEventsEnabled(false) }

        let bounds = NSRect(x: screen.frame.midX - 300, y: screen.frame.midY - 155, width: 600, height: 310)
        let backdrop = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.level = .floating
        backdrop.contentView = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [Color(red: 0.22, green: 0.38, blue: 0.48),
                                    Color(red: 0.60, green: 0.39, blue: 0.27)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 18) {
                ForEach(0..<8) { _ in
                    Text("ALO     Shared music · conversation · files     ALO")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
        })
        let panel = OverlayPanelFactory.makePanel(frame: bounds, level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
        panel.contentView = NSHostingView(rootView:
            NotchInteractiveBodyView(notchViewModel: notch, settingsViewModel: settings)
                .defaultAppStorage(defaults)
                .frame(width: bounds.width, height: bounds.height, alignment: .top))
        defer { panel.close(); backdrop.close() }
        backdrop.orderFrontRegardless()
        panel.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(700))
        let output = URL(fileURLWithPath: directory).appendingPathComponent("room-player-native-backdrop.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let desktopHeight = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        capture.arguments = ["-x", "-R\(Int(bounds.minX)),\(Int(desktopHeight - bounds.maxY)),600,310", output.path]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
        XCTAssertGreaterThan(try Data(contentsOf: output).count, 1500)
        for (label, delay, action) in [
            ("closing", 80, { notch.handleOutsideClick() }),
            ("resting", 700, {}),
            ("pressed", 80, { withAnimation(.easeOut(duration: 0.15)) { notch.pressScale = 1.08 } }),
            ("opening", 80, { notch.pressScale = 1; notch.expandActiveLiveActivity() })
        ] {
            action()
            try await Task.sleep(for: .milliseconds(delay))
            let frame = Process()
            frame.executableURL = capture.executableURL
            frame.arguments = ["-x", "-R\(Int(bounds.minX)),\(Int(desktopHeight - bounds.maxY)),600,310",
                               output.deletingLastPathComponent().appendingPathComponent("\(label).png").path]
            try frame.run()
            frame.waitUntilExit()
            XCTAssertEqual(frame.terminationStatus, 0)
            try await Task.sleep(for: .milliseconds(700))
        }
    }
}
