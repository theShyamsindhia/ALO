import XCTest
import AppKit
import CoreAudio
@testable import ALONotchRuntime

@MainActor
final class NowPlayingViewModelIntegrationTests: XCTestCase {
    func testExplicitStopIgnoresLateMediaAndAllowsRestart() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        XCTAssertEqual(service.startCalls, 0)
        viewModel.startMonitoring()
        viewModel.startMonitoring()
        XCTAssertEqual(service.startCalls, 1)
        service.publish(makeNowPlayingSnapshot())
        XCTAssertNotNil(viewModel.snapshot)
        viewModel.stopMonitoring()
        XCTAssertEqual(service.stopCalls, 1)
        XCTAssertNil(viewModel.snapshot)
        service.publish(makeNowPlayingSnapshot())
        XCTAssertNil(viewModel.snapshot)
        viewModel.startMonitoring()
        XCTAssertEqual(service.startCalls, 2)
        service.publish(makeNowPlayingSnapshot())
        XCTAssertNotNil(viewModel.snapshot)
        viewModel.stopMonitoring()
    }

    func testPublishesStartedAndStoppedEventsWhenSessionLifecycleChanges() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        XCTAssertEqual(service.startCalls, 1)
        XCTAssertNil(viewModel.snapshot)

        let snapshot = makeNowPlayingSnapshot()
        service.publish(snapshot)

        XCTAssertEqual(viewModel.snapshot, snapshot)
        XCTAssertEqual(viewModel.event, .started)
        XCTAssertTrue(viewModel.hasActiveSession)

        service.publish(nil)

        XCTAssertEqual(viewModel.snapshot, snapshot)
        XCTAssertEqual(viewModel.event, .started)
        XCTAssertTrue(viewModel.hasActiveSession)

        try? await Task.sleep(for: .milliseconds(800))

        XCTAssertNil(viewModel.snapshot)
        XCTAssertEqual(viewModel.event, .stopped)
        XCTAssertFalse(viewModel.hasActiveSession)
    }

    func testPlaybackControlsSendCommandsToService() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        viewModel.previousTrack()
        viewModel.togglePlayPause()
        viewModel.nextTrack()

        XCTAssertEqual(
            service.commands,
            [.previousTrack, .togglePlayPause, .nextTrack]
        )
    }

    func testOpenPlaybackSourceDelegatesToSourceOpener() async {
        let service = FakeNowPlayingService()
        let source = NowPlayingPlaybackSource(
            bundleIdentifier: "com.spotify.client",
            parentBundleIdentifier: nil,
            processIdentifier: 3659
        )
        let sourceOpener = FakePlaybackSourceOpener()
        let viewModel = makeIsolatedViewModel(
            service: service,
            playbackSourceOpener: sourceOpener
        )
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(makeNowPlayingSnapshot(playbackSource: source))
        viewModel.openPlaybackSource()

        XCTAssertEqual(sourceOpener.openedSources, [source])
        XCTAssertTrue(viewModel.canOpenPlaybackSource)
    }

    func testOpenPlaybackSourceDoesNothingWithoutSource() async {
        let service = FakeNowPlayingService()
        let sourceOpener = FakePlaybackSourceOpener()
        let viewModel = makeIsolatedViewModel(
            service: service,
            playbackSourceOpener: sourceOpener
        )
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(makeNowPlayingSnapshot(playbackSource: nil))
        viewModel.openPlaybackSource()

        XCTAssertTrue(sourceOpener.openedSources.isEmpty)
        XCTAssertFalse(viewModel.canOpenPlaybackSource)
    }

    func testTogglePlayPauseUpdatesCurrentSnapshotImmediately() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(makeNowPlayingSnapshot(elapsedTime: 42, playbackRate: 1))

        viewModel.togglePlayPause()

        XCTAssertEqual(service.commands, [.pause])
        XCTAssertEqual(viewModel.snapshot?.playbackRate, 0)
        XCTAssertFalse(viewModel.snapshot?.isPlaying ?? true)
    }

    func testTogglePlayPauseSendsExplicitPlayWhenPaused() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(makeNowPlayingSnapshot(elapsedTime: 42, playbackRate: 0))

        viewModel.togglePlayPause()

        XCTAssertEqual(service.commands, [.play])
        XCTAssertEqual(viewModel.snapshot?.playbackRate, 1)
        XCTAssertTrue(viewModel.snapshot?.isPlaying ?? false)
    }

    func testPlaybackStateChangesPublishPlaybackStateEvent() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(makeNowPlayingSnapshot(playbackRate: 1))
        XCTAssertEqual(viewModel.event, .started)

        service.publish(makeNowPlayingSnapshot(playbackRate: 0))
        XCTAssertEqual(viewModel.event, .playbackStateChanged(isPlaying: false))

        service.publish(makeNowPlayingSnapshot(playbackRate: 1))
        XCTAssertEqual(viewModel.event, .playbackStateChanged(isPlaying: true))
    }

    func testSeekUpdatesCurrentSnapshotImmediately() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(makeNowPlayingSnapshot(duration: 243, elapsedTime: 42, playbackRate: 1))

        viewModel.seek(to: 120)

        XCTAssertEqual(service.commands, [.seek(120)])
        XCTAssertEqual(viewModel.snapshot?.elapsedTime, 120)
        XCTAssertEqual(viewModel.snapshot?.duration, 243)
        XCTAssertEqual(viewModel.snapshot?.playbackRate, 1)
    }

    func testSeekIgnoresStaleServiceSnapshotsDuringGracePeriod() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(makeNowPlayingSnapshot(duration: 243, elapsedTime: 42, playbackRate: 1))

        viewModel.seek(to: 120)
        XCTAssertEqual(viewModel.snapshot?.elapsedTime, 120)

        // Simulate stale service snapshot arriving during seek grace period
        service.publish(makeNowPlayingSnapshot(duration: 243, elapsedTime: 42.5, playbackRate: 1))

        // Snapshot should maintain the target seek position, preventing UI jump-backs
        XCTAssertGreaterThanOrEqual(viewModel.snapshot?.elapsedTime ?? 0, 119.5)
    }

    func testTogglePlayPauseIgnoresStaleServiceSnapshotsDuringGracePeriod() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(makeNowPlayingSnapshot(duration: 243, elapsedTime: 42, playbackRate: 1))

        viewModel.togglePlayPause()
        XCTAssertEqual(viewModel.snapshot?.playbackRate, 0)
        XCTAssertFalse(viewModel.snapshot?.isPlaying ?? true)

        // Simulate stale service snapshot arriving during playback toggle grace period
        service.publish(makeNowPlayingSnapshot(duration: 243, elapsedTime: 42, playbackRate: 1))

        // Snapshot should maintain the target paused state, preventing double animation
        XCTAssertEqual(viewModel.snapshot?.playbackRate, 0)
        XCTAssertFalse(viewModel.snapshot?.isPlaying ?? true)
    }

    func testSourceFilterRetainsLastValidSnapshotWhenUnallowedSourceEmitsSnapshot() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service, sourceFilter: .appleMusic)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        let appleMusicSource = NowPlayingPlaybackSource(bundleIdentifier: "com.apple.Music", parentBundleIdentifier: nil, processIdentifier: 100)
        let safariSource = NowPlayingPlaybackSource(bundleIdentifier: "com.apple.Safari", parentBundleIdentifier: nil, processIdentifier: 200)

        // 1. Publish Apple Music snapshot (matches filter)
        let appleMusicSnapshot = makeNowPlayingSnapshot(title: "Apple Music Track", playbackSource: appleMusicSource)
        service.publish(appleMusicSnapshot)

        XCTAssertEqual(viewModel.snapshot?.title, "Apple Music Track")

        // 2. Publish Safari snapshot (web video played, doesn't match filter)
        let safariSnapshot = makeNowPlayingSnapshot(title: "Web Video", playbackSource: safariSource)
        service.publish(safariSnapshot)

        // 3. Apple Music snapshot should be retained instead of clearing to nil
        XCTAssertEqual(viewModel.snapshot?.title, "Apple Music Track")
    }

    func testAdvancedPlaybackControlsUpdateSnapshotAndSendCommands() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(
            makeNowPlayingSnapshot(
                isShuffled: false,
                repeatMode: .off,
                volume: 0.25,
                supportsVolumeControl: true
            )
        )

        viewModel.toggleShuffle()
        viewModel.toggleRepeat()
        viewModel.setVolume(1.3)

        XCTAssertEqual(
            service.commands,
            [.setShuffle(true), .setRepeatMode(.all), .setVolume(1)]
        )
        XCTAssertEqual(viewModel.snapshot?.isShuffled, true)
        XCTAssertEqual(viewModel.snapshot?.repeatMode, .all)
        XCTAssertEqual(viewModel.snapshot?.volume, 1)
    }

    func testRemoteFavoriteSendsFavoriteCommandWhenSourceSupportsIt() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(
            makeNowPlayingSnapshot(
                isFavorite: false,
                supportsFavorite: true
            )
        )

        viewModel.toggleFavorite()

        XCTAssertEqual(service.commands, [.setFavorite(true)])
        XCTAssertTrue(viewModel.isCurrentTrackFavorite)
        XCTAssertEqual(viewModel.snapshot?.isFavorite, true)
    }

    func testArtworkPaletteUpdatesFromArtworkData() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(
            makeNowPlayingSnapshot(
                artworkData: makeArtworkData(color: NSColor(calibratedRed: 0.98, green: 0.49, blue: 0.12, alpha: 1))
            )
        )

        let components = rgbaComponents(from: viewModel.artworkPalette.equalizerBaseColor)
        XCTAssertGreaterThan(components.red, components.green)
        XCTAssertGreaterThan(components.green, components.blue)
        XCTAssertNotEqual(viewModel.artworkPalette, .fallback)
    }

    func testArtworkPersistsWhileActiveSnapshotTemporarilyLosesArtwork() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(makeNowPlayingSnapshot(artworkData: makeArtworkData(color: .systemBlue)))
        XCTAssertNotNil(viewModel.artworkImage)
        XCTAssertNotEqual(viewModel.artworkPalette, .fallback)

        service.publish(makeNowPlayingSnapshot(artworkData: nil))

        XCTAssertNotNil(viewModel.artworkImage)
        XCTAssertNotEqual(viewModel.artworkPalette, .fallback)
    }

    func testArtworkClearsWhenSessionStops() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(makeNowPlayingSnapshot(artworkData: makeArtworkData(color: .systemBlue)))
        XCTAssertNotNil(viewModel.artworkImage)
        XCTAssertNotEqual(viewModel.artworkPalette, .fallback)

        service.publish(nil)

        XCTAssertNotNil(viewModel.artworkImage)
        XCTAssertNotEqual(viewModel.artworkPalette, .fallback)

        try? await Task.sleep(for: .milliseconds(800))

        XCTAssertNil(viewModel.artworkImage)
        XCTAssertEqual(viewModel.artworkPalette, .fallback)
    }

    func testTrackChangeTriggersArtworkFlipAndDelaysArtworkSwap() async throws {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)
        viewModel.startMonitoring()

        service.publish(
            makeNowPlayingSnapshot(
                title: "Midnight Echoes",
                artist: "Debug Ensemble",
                album: "Preview Mode",
                artworkData: makeArtworkData(color: .systemRed)
            )
        )

        let firstArtworkImage = try XCTUnwrap(viewModel.artworkImage)
        XCTAssertEqual(viewModel.artworkFlipAngle, 0)

        service.publish(nil)

        XCTAssertEqual(viewModel.snapshot?.title, "Midnight Echoes")
        XCTAssertTrue(viewModel.artworkImage === firstArtworkImage)

        service.publish(
            makeNowPlayingSnapshot(
                title: "Second Signal",
                artist: "Debug Ensemble",
                album: "Preview Mode",
                artworkData: makeArtworkData(color: .systemBlue)
            )
        )

        XCTAssertEqual(viewModel.artworkFlipAngle, 180)
        XCTAssertTrue(viewModel.artworkImage === firstArtworkImage)

        try? await Task.sleep(nanoseconds: 550_000_000)
        await Task.yield()

        XCTAssertFalse(viewModel.artworkImage === firstArtworkImage)
        XCTAssertNotEqual(viewModel.artworkPalette, .fallback)
    }

    func testAudioOutputRoutesLoadFromRoutingService() async {
        let service = FakeNowPlayingService()
        let audioOutputRouting = FakeAudioOutputRoutingService(
            routes: [
                AudioOutputRoute(
                    id: 1,
                    name: "MacBook Pro Speakers",
                    transportType: kAudioDeviceTransportTypeBuiltIn,
                    isCurrent: true
                ),
                AudioOutputRoute(
                    id: 2,
                    name: "AirPods Pro",
                    transportType: kAudioDeviceTransportTypeBluetooth,
                    isCurrent: false
                )
            ]
        )
        let viewModel = makeIsolatedViewModel(
            service: service,
            audioOutputRouting: audioOutputRouting
        )
        TestLifetime.retain(viewModel)

        XCTAssertEqual(viewModel.audioOutputRoutes.count, 2)
        XCTAssertEqual(viewModel.currentAudioOutputRoute?.name, "MacBook Pro Speakers")
    }

    func testSwitchAudioOutputDelegatesToRoutingServiceAndRefreshesCurrentRoute() async {
        let service = FakeNowPlayingService()
        let audioOutputRouting = FakeAudioOutputRoutingService(
            routes: [
                AudioOutputRoute(
                    id: 1,
                    name: "MacBook Pro Speakers",
                    transportType: kAudioDeviceTransportTypeBuiltIn,
                    isCurrent: true
                ),
                AudioOutputRoute(
                    id: 2,
                    name: "AirPods Pro",
                    transportType: kAudioDeviceTransportTypeBluetooth,
                    isCurrent: false
                )
            ]
        )
        let viewModel = makeIsolatedViewModel(
            service: service,
            audioOutputRouting: audioOutputRouting
        )
        TestLifetime.retain(viewModel)

        let targetRoute = audioOutputRouting.routes[1]
        viewModel.switchAudioOutput(to: targetRoute)

        XCTAssertEqual(audioOutputRouting.selectedRouteIDs, [2])
        XCTAssertEqual(viewModel.currentAudioOutputRoute?.name, "AirPods Pro")
        XCTAssertEqual(viewModel.audioOutputRoutes.first(where: { $0.id == 2 })?.isCurrent, true)
    }

    func testDetailPollingIsEnabledOnlyWhileDetailedPresentationIsActive() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)

        viewModel.startMonitoring()

        XCTAssertTrue(service.detailPollingStates.isEmpty)

        viewModel.setDetailedPresentationActive(true, source: "test.expanded")
        viewModel.setDetailedPresentationActive(false, source: "test.expanded")

        XCTAssertEqual(service.detailPollingStates, [true, false])
    }

    func testClearingPresentationActivityStateDisablesDetailPolling() async {
        let service = FakeNowPlayingService()
        let viewModel = makeIsolatedViewModel(service: service)
        TestLifetime.retain(viewModel)

        viewModel.startMonitoring()
        viewModel.setDetailedPresentationActive(true, source: "test.expanded")
        viewModel.clearPresentationActivityState()

        XCTAssertEqual(service.detailPollingStates, [true, false])
    }

    func testFavoriteStatePersistsForTrackIdentity() async {
        let service = FakeNowPlayingService()
        let favoritesStore = makeFavoriteStore(named: #function)
        let viewModel = makeIsolatedViewModel(
            service: service,
            favoritesStore: favoritesStore
        )
        TestLifetime.retain(viewModel)

        let snapshot = makeNowPlayingSnapshot(
            title: "Midnight Echoes",
            artist: "Debug Ensemble",
            album: "Preview Mode"
        )
        service.publish(snapshot)

        XCTAssertFalse(viewModel.isCurrentTrackFavorite)

        viewModel.toggleFavorite()
        XCTAssertTrue(viewModel.isCurrentTrackFavorite)

        let restoredService = FakeNowPlayingService()
        let restoredViewModel = makeIsolatedViewModel(
            service: restoredService,
            favoritesStore: favoritesStore
        )
        TestLifetime.retain(restoredViewModel)
        restoredViewModel.startMonitoring()
        restoredService.publish(snapshot)

        XCTAssertTrue(restoredViewModel.isCurrentTrackFavorite)
    }

    func testFavoriteStateResetsForDifferentTrack() async {
        let service = FakeNowPlayingService()
        let favoritesStore = makeFavoriteStore(named: #function)
        let viewModel = makeIsolatedViewModel(
            service: service,
            favoritesStore: favoritesStore
        )
        TestLifetime.retain(viewModel)

        service.publish(
            makeNowPlayingSnapshot(
                title: "Midnight Echoes",
                artist: "Debug Ensemble",
                album: "Preview Mode"
            )
        )
        viewModel.toggleFavorite()
        XCTAssertTrue(viewModel.isCurrentTrackFavorite)

        service.publish(
            makeNowPlayingSnapshot(
                title: "Second Signal",
                artist: "Debug Ensemble",
                album: "Preview Mode"
            )
        )

        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(viewModel.isCurrentTrackFavorite)
    }
    private func makeIsolatedViewModel(
        service: any NowPlayingMonitoring,
        audioOutputRouting: (any AudioOutputRouting)? = nil,
        lyricsProvider: (any LyricsProviding)? = nil,
        favoritesStore: UserDefaults? = nil,
        playbackSourceOpener: (any PlaybackSourceOpening)? = nil,
        sourceFilter: NowPlayingSourceFilter = .any
    ) -> NowPlayingViewModel {
        let suite = "ALONotchMediaTests.\(UUID().uuidString)"
        let defaults = favoritesStore ?? UserDefaults(suiteName: suite)!
        if favoritesStore == nil { addTeardownBlock { defaults.removePersistentDomain(forName: suite) } }
        return NowPlayingViewModel(
            service: service,
            audioOutputRouting: audioOutputRouting ?? FakeAudioOutputRoutingService(),
            lyricsProvider: lyricsProvider ?? InactiveLyricsProvider(),
            favoritesStore: defaults,
            playbackSourceOpener: playbackSourceOpener ?? FakePlaybackSourceOpener(),
            sourceFilter: sourceFilter
        )
    }

}

private func makeArtworkData(
    color: NSColor,
    size: CGSize = CGSize(width: 20, height: 20)
) -> Data {
    let width = Int(size.width)
    let height = Int(size.height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

private func rgbaComponents(from color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    let resolvedColor = color.usingColorSpace(.sRGB) ?? color
    return (
        resolvedColor.redComponent,
        resolvedColor.greenComponent,
        resolvedColor.blueComponent,
        resolvedColor.alphaComponent
    )
}

private func makeFavoriteStore(named name: String) -> UserDefaults {
    let suiteName = "DynamicNotchTests.\(name)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
