import AppKit
import SwiftUI
import XCTest
@testable import ALONotchRuntime

/// Native upstream views with explicit fixtures, not live media or battery data.
@MainActor
final class OriginalActivityRenderTests: XCTestCase {
    func testOriginalPlayerBatteryAndTrayRenderAtNativeGeometry() async throws {
        _ = NSApplication.shared
        let name = "ALONotchActivityFixtures.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let container = AppContainer(isRunningUITests: true, defaults: defaults)
        let settings = container.settingsViewModel
        let artworkURL = try XCTUnwrap(NotchResources.bundle.url(forResource: "logo", withExtension: "png"))
        let service = FixtureActivityMusicService(snapshot: NowPlayingSnapshot(
            title: "Midnight Echoes", artist: "Demo Ensemble", album: "Activity Preview",
            duration: 214, elapsedTime: 81, playbackRate: 1,
            artworkData: try Data(contentsOf: artworkURL), refreshedAt: .now))
        let music = NowPlayingViewModel(service: service,
            audioOutputRouting: InactiveAudioOutputRoutingService(),
            lyricsProvider: InactiveLyricsProvider(), favoritesStore: defaults)
        music.startMonitoring()
        defer { music.stopMonitoring() }
        let player = NowPlayingNotchContent(nowPlayingViewModel: music, settings: settings.mediaAndFiles,
                                          applicationSettings: settings.application)
        let power = PowerService.settingsPreview(batteryLevel: 14, isCharging: false, isLowPowerMode: false)
        settings.battery.lowPowerStyle = .standard
        let battery = LowPowerNotchContent(powerService: power, settingsViewModel: settings)

        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let urls = [fixtureDirectory.appendingPathComponent("Demo Notes.txt"), fixtureDirectory.appendingPathComponent("Checklist.md")]
        for url in urls { try Data("Harmless activity-render fixture.\n".utf8).write(to: url) }
        let tray = FileTrayViewModel(defaults: defaults)
        tray.add(urls) // References only the fixtures; does not import or clean persistent tray storage.
        let trayContent = TrayActiveNotchContent(fileTrayViewModel: tray, mediaSettings: settings.mediaAndFiles)

        let cases: [(String, any NotchContentProtocol, Bool, Bool)] = [
            ("original-player-compact", player, false, false),
            ("original-player-expanded", player, true, false),
            ("original-player-island-compact", player, false, true),
            ("original-player-island-expanded", player, true, true),
            ("original-battery-14-percent", battery, false, false),
            ("original-file-tray-expanded", trayContent, true, false)
        ]
        for (name, content, expanded, island) in cases {
            let model = NotchViewModel(settings: settings.application,
                screenMetricsProvider: { _ in
                    (width: 1440, topInset: island ? 0 : 32,
                     notchSize: island ? nil : CGSize(width: 180, height: 32))
                })
            model.setActivityEventsEnabled(true)
            model.showNotch = true
            model.send(.showLiveActivity(content))
            try await Task.sleep(nanoseconds: 150_000_000)
            if expanded { model.expandActiveLiveActivity() }
            try await Task.sleep(nanoseconds: 750_000_000)
            XCTAssertEqual(model.displayedContent?.id, content.id)
            XCTAssertEqual(model.isDynamicIsland, island)
            XCTAssertEqual(model.isDisplayingExpandedLiveActivity, expanded)
            let view = NotchView(notchEventCoordinator: container.notchEventCoordinator,
                                 notchViewModel: model, airDropViewModel: container.airDropViewModel,
                                 airDropController: container.airDropController, settingsViewModel: settings)
                .defaultAppStorage(defaults)
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.colorScheme, .dark)
            try await render(view, name: name, activitySize: model.presentedNotchSize)
            model.setActivityEventsEnabled(false)
        }
        XCTAssertFalse(power.isMonitoring)
        XCTAssertEqual(tray.count, 2)
    }

    private func render<V: View>(_ view: V, name: String, activitySize: CGSize) async throws {
        // A plain desktop-colored canvas supplies context; all activity pixels,
        // shapes, sizing, clipping and controls are the original SwiftUI views.
        let size = CGSize(width: 720, height: max(260, activitySize.height + 55))
        XCTAssertLessThan(activitySize.width, size.width)
        let frame = NSRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(red: 0.32, green: 0.38, blue: 0.43)))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: frame))
        host.cacheDisplay(in: frame, to: bitmap)
        var colors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert(Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255))
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 20, "Original activity must visibly render: \(name)")
        print("Original activity fixture \(name): native geometry \(activitySize.width)x\(activitySize.height) points")
        if let path = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}

@MainActor
private final class FixtureActivityMusicService: NowPlayingMonitoring {
    var onSnapshotChange: ((NowPlayingSnapshot?) -> Void)?
    let snapshot: NowPlayingSnapshot
    init(snapshot: NowPlayingSnapshot) { self.snapshot = snapshot }
    func startMonitoring() { onSnapshotChange?(snapshot) }
    func stopMonitoring() {}
    func send(_ command: NowPlayingCommand) {}
}
