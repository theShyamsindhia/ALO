import Foundation
import XCTest
@testable import ALONotchRuntime

@MainActor
final class LockScreenPresentationTests: XCTestCase {
    func testLockPresentationRequiresEnabledPanelAndCurrentSong() async {
        let playing = song(rate: 1)
        let paused = song(rate: 0)
        let cases: [(Bool, Bool, NowPlayingSnapshot?, Bool)] = [
            (false, true, playing, false), // Unlock always removes the overlay.
            (true, false, playing, false), // User opt-out always wins.
            (true, true, nil, false), // No old song retained indefinitely.
            (true, true, playing, true),
            (true, true, paused, true), // Paused media keeps resumable controls.
            (false, false, nil, false)
        ]
        for (locked, enabled, snapshot, expected) in cases {
            XCTAssertEqual(LockScreenPanelManager.shouldPresent(isLockPresentation: locked,
                mediaEnabled: enabled, snapshot: snapshot), expected)
        }
    }

    func testPausedSongWithoutArtworkKeepsFrozenProgress() async {
        let service = LockFixtureMusicService()
        let model = NowPlayingViewModel(service: service, lyricsProvider: InactiveLyricsProvider())
        model.startMonitoring()
        defer { model.stopMonitoring() }
        let paused = song(rate: 0)
        service.onSnapshotChange?(paused)
        XCTAssertNil(model.artworkImage)
        XCTAssertEqual(model.elapsedTime(at: paused.refreshedAt.addingTimeInterval(300)), 81)
        XCTAssertTrue(LockScreenPanelManager.shouldPresent(isLockPresentation: true,
            mediaEnabled: true, snapshot: model.snapshot))
    }

    func testInvalidatedPanelCannotBeRecreatedByQueuedChanges() async throws {
        let name = "ALOLockPresentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsViewModel(defaults: defaults)
        let service = LockFixtureMusicService()
        let model = NowPlayingViewModel(service: service, lyricsProvider: InactiveLyricsProvider())
        let lockService = FakeLockScreenMonitoringService()
        let lock = LockScreenManager(service: lockService, soundPlayer: FakeLockScreenSoundPlayer(), defaults: defaults)
        let panel = LockScreenPanelManager(nowPlayingViewModel: model, lockScreenManager: lock, settingsViewModel: settings)
        panel.invalidate()
        model.startMonitoring()
        lock.startMonitoring()
        defer { model.stopMonitoring(); lock.stopMonitoring() }
        settings.lockScreen.isLockScreenMediaPanelEnabled = true
        service.onSnapshotChange?(song(rate: 1))
        lockService.publish(isLocked: true)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(panel.isInvalidated)
        XCTAssertFalse(panel.hasPanel, "Queued setting/playback/lock notifications cannot revive an invalidated overlay")
    }

    func testLyricsWaitForVisiblePresentationAndRetryAfterCancelledUnlock() async throws {
        let provider = LockFixtureLyricsProvider()
        let service = LockFixtureMusicService()
        let model = NowPlayingViewModel(service: service, lyricsProvider: provider)
        model.startMonitoring()
        defer { model.stopMonitoring(); provider.finishAll() }
        model.setLyricsPresentationActive(true)
        await Task.yield()
        XCTAssertEqual(provider.requests, 0, "No song means no lyrics request")
        model.setLyricsPresentationActive(false)
        service.onSnapshotChange?(song(rate: 1))
        await Task.yield()
        XCTAssertEqual(provider.requests, 0, "Playback alone must not fetch lyrics")
        model.setLyricsPresentationActive(true)
        try await waitForRequests(1, provider: provider)
        model.setLyricsPresentationActive(false) // Unlock or hide expanded artwork.
        provider.finishFirst(.success(nil))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.lyricsState, .idle)
        model.setLyricsPresentationActive(true) // Same track on relock.
        try await waitForRequests(2, provider: provider)
        let key = try XCTUnwrap(model.snapshot?.lyricsLookupKey)
        provider.finishFirst(.success(TrackLyrics(trackKey: key, lines: [], isSynced: false)))
        try await Task.sleep(nanoseconds: 20_000_000)
        guard case .loaded = model.lyricsState else { return XCTFail("Relocking should finish the new lookup") }
        model.stopMonitoring() // Master disabled.
        XCTAssertEqual(model.lyricsState, .idle)
    }

    func testMissingAndFailedLyricsRemainDistinctAndLateResultsCannotReviveStoppedMedia() async throws {
        let provider = LockFixtureLyricsProvider()
        let service = LockFixtureMusicService()
        let model = NowPlayingViewModel(service: service, lyricsProvider: provider)
        model.startMonitoring()
        defer { model.stopMonitoring(); provider.finishAll() }
        service.onSnapshotChange?(song(rate: 1))
        model.setLyricsPresentationActive(true)
        try await waitForRequests(1, provider: provider)
        let firstKey = try XCTUnwrap(model.snapshot?.lyricsLookupKey)
        provider.finishFirst(.success(nil))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.lyricsState, .notFound(trackKey: firstKey))
        service.onSnapshotChange?(song(rate: 1, title: "Second song"))
        try await waitForRequests(2, provider: provider)
        let secondKey = try XCTUnwrap(model.snapshot?.lyricsLookupKey)
        provider.finishFirst(.failure(LockFixtureError.unavailable))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.lyricsState, .failed(trackKey: secondKey))
        service.onSnapshotChange?(song(rate: 1, title: "Third song"))
        try await waitForRequests(3, provider: provider)
        model.stopMonitoring()
        provider.finishFirst(.success(TrackLyrics(trackKey: "late", lines: [], isSynced: false)))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.lyricsState, .idle)
    }

    func testSharedRoomLyricsNeverFetchAndRejectPreviousTrack() async throws {
        let provider = LockFixtureLyricsProvider()
        let service = LockFixtureMusicService()
        let model = NowPlayingViewModel(service: service, lyricsProvider: provider)
        var demand: [Bool] = []
        model.configureExternalLyrics { demand.append($0) }
        model.startMonitoring()
        service.onSnapshotChange?(song(rate: 0))
        model.setLyricsPresentationActive(true)
        let payload = RoomLyricsPayload(title: "Fixture Song", artist: "Fixture Artist", state: .ready,
            lines: [.init(seconds: 0, text: "First"), .init(seconds: 80, text: "Current")], hasPlaybackClock: true)
        model.applyRoomLyrics(payload)
        guard case .loaded(let lyrics) = model.lyricsState else { return XCTFail("Expected shared lyrics") }
        XCTAssertEqual(lyrics.activeLineIndex(at: model.elapsedTime(at: .now.addingTimeInterval(50))), 1)
        XCTAssertTrue(lyrics.isSynced)
        await Task.yield()
        XCTAssertEqual(provider.requests, 0)
        service.onSnapshotChange?(song(rate: 0, title: "Different Song"))
        for _ in 0..<100 where model.snapshot?.title != "Different Song" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.snapshot?.title, "Different Song")
        model.applyRoomLyrics(payload)
        XCTAssertEqual(model.lyricsState, .idle)
        model.applyRoomLyrics(.init(title: "Different Song", artist: "Fixture Artist", state: .ready,
            lines: [.init(seconds: 0, text: "Unclocked")], hasPlaybackClock: false))
        guard case .loaded(let unclocked) = model.lyricsState else { return XCTFail("Expected text") }
        XCTAssertFalse(unclocked.isSynced)
        model.stopMonitoring()
        XCTAssertEqual(demand, [false, true, false])
        model.applyRoomLyrics(payload)
        XCTAssertEqual(model.lyricsState, .idle)
    }

    private func waitForRequests(_ count: Int, provider: LockFixtureLyricsProvider) async throws {
        for _ in 0..<100 where provider.requests < count { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(provider.requests, count)
    }

    private func song(rate: Double, title: String = "Fixture Song") -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: title, artist: "Fixture Artist", album: "Fixture Album", duration: 214,
                           elapsedTime: 81, playbackRate: rate, artworkData: nil, refreshedAt: .now)
    }
}

@MainActor
private final class LockFixtureMusicService: NowPlayingMonitoring {
    var onSnapshotChange: ((NowPlayingSnapshot?) -> Void)?
    func startMonitoring() {}
    func stopMonitoring() {}
    func send(_ command: NowPlayingCommand) {}
}

private enum LockFixtureError: Error { case unavailable }

@MainActor
private final class LockFixtureLyricsProvider: LyricsProviding {
    var requests = 0
    private var pending: [CheckedContinuation<TrackLyrics?, Error>] = []
    func lyrics(for snapshot: NowPlayingSnapshot) async throws -> TrackLyrics? {
        requests += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finishFirst(_ result: Result<TrackLyrics?, Error>) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(with: result)
    }
    func finishAll() {
        while !pending.isEmpty { finishFirst(.failure(CancellationError())) }
    }
}
