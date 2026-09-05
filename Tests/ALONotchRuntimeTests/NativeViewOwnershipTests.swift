import AppKit
import SwiftUI
import XCTest
@testable import ALONotchRuntime

@MainActor
final class NativeViewOwnershipTests: XCTestCase {
    func testDispatchedPlayerOwnershipGraphReleasesNestedProviders() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                weak var releasedModel: NowPlayingViewModel?
                weak var releasedProvider: CompositeLyricsProvider?
                autoreleasepool {
                    let provider = CompositeLyricsProvider(providers: [InactiveLyricsProvider()])
                    let model = NowPlayingViewModel(service: InactiveNowPlayingService(), lyricsProvider: provider)
                    releasedModel = model
                    releasedProvider = provider
                    model.startMonitoring()
                    model.stopMonitoring()
                    XCTAssertNil(model.snapshot)
                }
                // This is deliberately a dispatched, non-task ARC boundary, matching
                // AppKit teardown on the macOS 15 backdeployment runtime.
                XCTAssertNil(releasedModel)
                XCTAssertNil(releasedProvider)
                continuation.resume()
            }
        }
    }

    func testNativePlayerRootReplacementReleasesOriginalViewOwners() async throws {
        _ = NSApplication.shared
        let suite = "NativeViewOwnershipTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                autoreleasepool {
                    let settings = SettingsViewModel(defaults: defaults)
                    let model = NowPlayingViewModel(service: InactiveNowPlayingService(), lyricsProvider: InactiveLyricsProvider(), favoritesStore: defaults)
                    let view = NowPlayingExpandedNotchView(nowPlayingViewModel: model,
                        settings: settings.mediaAndFiles, applicationSettings: settings.application,
                        onOpenPlaybackSource: {})
                    let host = NSHostingView(rootView: AnyView(view))
                    host.frame = NSRect(x: 0, y: 0, width: 440, height: 180)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.frame.width, 440)
                    model.stopMonitoring()
                    host.rootView = AnyView(EmptyView())
                    host.layoutSubtreeIfNeeded()
                }
                continuation.resume()
            }
        }
    }
}
