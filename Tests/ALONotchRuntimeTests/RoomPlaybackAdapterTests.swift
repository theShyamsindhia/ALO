import AppKit
import SwiftUI
import XCTest
@testable import ALONotchRuntime

@MainActor
final class RoomPlaybackAdapterTests: XCTestCase {
    func testRoomCommandsRespectAvailabilityAndStopWithMaster() async {
        let service = RoomPlaybackService()
        var commands: [RoomPlaybackCommand] = []
        service.onCommand = { commands.append($0) }
        service.update(RoomPlaybackSnapshot(title: "Room track", isPlaying: true, duration: 180,
            canTogglePlayback: true, canSkipNext: true, canSeek: true))
        service.send(.pause)
        XCTAssertTrue(commands.isEmpty)
        service.startMonitoring()
        service.send(.pause)
        service.send(.nextTrack)
        service.send(.previousTrack)
        service.send(.seek(999))
        service.send(.setShuffle(true))
        XCTAssertEqual(commands, [.togglePlayback, .next, .seek(180)])
        service.stopMonitoring()
        service.send(.nextTrack)
        XCTAssertEqual(commands.count, 3)
    }

    func testOriginalViewModelReceivesMetadataAndDisallowsOptimisticUnsupportedPlayback() async throws {
        let service = RoomPlaybackService()
        let name = "RoomPlaybackAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = NowPlayingViewModel(service: service, lyricsProvider: InactiveLyricsProvider(), favoritesStore: defaults, playbackSourceOpener: service)
        let timestamp = Date()
        service.update(RoomPlaybackSnapshot(title: "Room track", artist: "Shared artist", album: "Room album",
            isPlaying: true, elapsed: 30, duration: 180, receivedAt: timestamp))
        model.startMonitoring()
        XCTAssertEqual(model.snapshot?.title, "Room track")
        XCTAssertEqual(model.snapshot?.artist, "Shared artist")
        XCTAssertEqual(model.snapshot?.elapsedTime(at: timestamp.addingTimeInterval(2)), 32)
        model.togglePlayPause()
        model.seek(to: 90)
        XCTAssertTrue(model.snapshot?.isPlaying == true)
        XCTAssertEqual(model.snapshot?.elapsedTime, 30)
        XCTAssertFalse(model.canSend(.previousTrack))
        model.stopMonitoring()
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(service.isMonitoring)
    }

    func testRoomContentPreservesOriginalGeometryAndSurvivesSystemPlayerDisable() async throws {
        let name = "RoomPlaybackGeometryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsViewModel(defaults: defaults)
        let model = NowPlayingViewModel(service: InactiveNowPlayingService(), lyricsProvider: InactiveLyricsProvider(), favoritesStore: defaults)
        let original = NowPlayingNotchContent(nowPlayingViewModel: model, settings: settings.mediaAndFiles, applicationSettings: settings.application)
        let room = RoomNowPlayingNotchContent(original: original)
        XCTAssertEqual(room.size(baseWidth: 190, baseHeight: 32), original.size(baseWidth: 190, baseHeight: 32))
        XCTAssertEqual(room.expandedSize(baseWidth: 190, baseHeight: 32), original.expandedSize(baseWidth: 190, baseHeight: 32))
        XCTAssertEqual(room.dynamicIslandSize(baseWidth: 190, baseHeight: 32), original.dynamicIslandSize(baseWidth: 190, baseHeight: 32))
        XCTAssertEqual(room.expandedDynamicIslandSize(baseWidth: 190, baseHeight: 32), original.expandedDynamicIslandSize(baseWidth: 190, baseHeight: 32))
        XCTAssertNotEqual(room.id, original.id)
        let engine = NotchEngine(animations: { .default }, hideDelay: 0, queueDelay: 0)
        engine.send(.showLiveActivity(room))
        engine.send(.hideLiveActivity(id: original.id))
        let deadline = Date().addingTimeInterval(2)
        while engine.notchModel.content == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(engine.notchModel.content?.id, room.id)
        engine.setActivityEventsEnabled(false)
    }

    func testOriginalRoomPlayerNativePreview() async throws {
        _ = NSApplication.shared
        let name = "RoomPlaybackRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsViewModel(defaults: defaults)
        let service = RoomPlaybackService()
        let model = NowPlayingViewModel(service: service, lyricsProvider: InactiveLyricsProvider(), favoritesStore: defaults, playbackSourceOpener: service)
        let artworkURL = NotchResources.bundle.url(forResource: "backgroundDark", withExtension: "png")
        service.update(RoomPlaybackSnapshot(title: "Room playback", artist: "Shared with your room",
            artworkData: try artworkURL.map { try Data(contentsOf: $0) }, isPlaying: true, elapsed: 47, duration: 224,
            canTogglePlayback: true, canSkipNext: true, canSkipPrevious: true, canSeek: true))
        model.startMonitoring()
        defer { model.stopMonitoring() }
        for island in [false, true] {
            let notch = NotchViewModel(settings: settings.application, hideDelay: 0, queueDelay: 0,
                screenMetricsProvider: { _ in (width: 1512, topInset: island ? 0 : 32, notchSize: island ? nil : CGSize(width: 190, height: 32)) })
            let original = NowPlayingNotchContent(nowPlayingViewModel: model, settings: settings.mediaAndFiles, applicationSettings: settings.application)
            notch.send(.showLiveActivity(RoomNowPlayingNotchContent(original: original)))
            let deadline = Date().addingTimeInterval(2)
            while notch.notchModel.content == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            notch.expandActiveLiveActivity()
            try await Task.sleep(for: .milliseconds(500))
            let size = notch.presentedNotchSize
            XCTAssertLessThan(size.width, 500, "Must retain original compact player sizing")
            XCTAssertLessThan(size.height, 250)
            let bounds = NSRect(x: 0, y: 0, width: size.width + 30, height: size.height + 15)
            let host = NSHostingView(rootView: NotchInteractiveBodyView(notchViewModel: notch, settingsViewModel: settings)
                .defaultAppStorage(defaults).frame(width: bounds.width, height: bounds.height, alignment: .top)
                .background(Color(red: 0.17, green: 0.18, blue: 0.20)))
            let window = NSWindow(contentRect: bounds.offsetBy(dx: -3000, dy: -3000), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1500)
            if let directory = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent(island ? "original-room-player-island.png" : "original-room-player-notch.png"))
            }
            window.close()
            notch.setActivityEventsEnabled(false)
        }
    }
}
