import AppKit
import SwiftUI
import XCTest
@testable import ALONotchRuntime

/// Offscreen native renders of the original settings and panel views.
/// This never asks macOS to lock or delegates a window to the lock screen.
@MainActor
final class LockScreenNativePreviewTests: XCTestCase {
    func testOriginalLockScreenSettingsAndArtworkLyricsPanelRender() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("Native panel rendering requires an attached display")
        }
        let name = "ALOLockNativePreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsViewModel(defaults: defaults)
        settings.lockScreen.isLockScreenMediaPanelEnabled = true
        settings.lockScreen.isLockScreenArtworkExpanded = true
        settings.lockScreen.isLockScreenLyricsEnabled = true
        settings.lockScreen.mediaPanelBackgroundStyle = .staticArtwork

        let artworkURL = try XCTUnwrap(NotchResources.bundle.url(forResource: "backgroundLight", withExtension: "png"))
        let artworkData = try Data(contentsOf: artworkURL)
        let artwork = try XCTUnwrap(NSImage(data: artworkData))
        let snapshot = NowPlayingSnapshot(title: "Night in the City", artist: "Preview Ensemble", album: "Native View Fixture",
            duration: 214, elapsedTime: 81, playbackRate: 0, artworkData: artworkData, refreshedAt: .now)
        let provider = PreviewLockLyricsProvider()
        let service = PreviewLockMusicService(snapshot: snapshot)
        let model = NowPlayingViewModel(service: service, audioOutputRouting: InactiveAudioOutputRoutingService(),
                                       lyricsProvider: provider, favoritesStore: defaults)
        model.startMonitoring()
        model.setLyricsPresentationActive(true)
        defer { model.stopMonitoring() }
        for _ in 0..<100 {
            if case .loaded = model.lyricsState, model.artworkImage != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .loaded(let lyrics) = model.lyricsState else { return XCTFail("Fixture lyrics must resolve without network access") }
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.activeLineIndex(at: 81), 2)
        XCTAssertEqual(provider.requests, 1)
        XCTAssertNotNil(model.artworkImage)

        let manager = LockScreenManager(service: InactiveLockScreenMonitoringService(), soundPlayer: InactiveLockScreenSoundPlayer(), defaults: defaults)
        let animator = LockScreenPanelAnimator()
        animator.isPresented = true
        let panel = LockScreenNowPlayingPanelView(snapshot: snapshot, artworkImage: artwork, screen: screen,
            settingsViewModel: settings, nowPlayingViewModel: model, lockScreenManager: manager, animator: animator)
        try await render(panel.defaultAppStorage(defaults), name: "original-lock-screen-artwork-lyrics", size: CGSize(width: 1512, height: 982))
        let settingsView = LockScreenSettingsView(settings: settings.lockScreen, applicationSettings: settings.application)
        try await render(settingsView.defaultAppStorage(defaults), name: "original-lock-screen-settings", size: CGSize(width: 650, height: 1900))
        XCTAssertFalse(manager.isLocked, "Native view preview must not lock the machine")
        XCTAssertTrue(settings.lockScreen.isLockScreenArtworkExpanded)
        XCTAssertTrue(settings.lockScreen.isLockScreenLyricsEnabled)
    }

    private func render<V: View>(_ view: V, name: String, size: CGSize) async throws {
        let frame = NSRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12)))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: frame))
        host.cacheDisplay(in: frame, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        var colors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert(Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255))
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 30, "Original lock screen UI must contain meaningful rendered content")
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALO_NOTCH_LOCKSCREEN_SNAPSHOT_DIR"] ?? "/tmp/alo-notch-lockscreen-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}

@MainActor
private final class PreviewLockMusicService: NowPlayingMonitoring {
    let snapshot: NowPlayingSnapshot
    var onSnapshotChange: ((NowPlayingSnapshot?) -> Void)?
    init(snapshot: NowPlayingSnapshot) { self.snapshot = snapshot }
    func startMonitoring() { onSnapshotChange?(snapshot) }
    func stopMonitoring() {}
    func send(_ command: NowPlayingCommand) {}
}

@MainActor
private final class PreviewLockLyricsProvider: LyricsProviding {
    private(set) var requests = 0
    func lyrics(for snapshot: NowPlayingSnapshot) async throws -> TrackLyrics? {
        requests += 1
        return TrackLyrics(trackKey: snapshot.lyricsLookupKey ?? "fixture", lines: [
            LyricLine(id: 0, startTime: 0, text: "Night settles over the city"),
            LyricLine(id: 1, startTime: 30, text: "Windows glow along the street"),
            LyricLine(id: 2, startTime: 70, text: "We carry the quiet with us"),
            LyricLine(id: 3, startTime: 110, text: "And find our way back home"),
            LyricLine(id: 4, startTime: 150, text: "Morning waits beyond the lights")
        ], isSynced: true)
    }
}
