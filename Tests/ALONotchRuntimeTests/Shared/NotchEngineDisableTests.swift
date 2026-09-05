import SwiftUI
import XCTest
@testable import ALONotchRuntime

@MainActor
final class NotchEngineDisableTests: XCTestCase {
    func testNotchViewModelReleasesWithNativeViewFromAutoreleasePool() async {
        _ = NSApplication.shared
        let suiteName = "NotchNativeDestructionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let payload = NativeModelReleasePayload(NotchViewModel(
            settings: SettingsViewModel(defaults: defaults),
            screenMetricsProvider: { _ in nil }
        ))
        weak var retainedModel = payload.model
        let released = expectation(description: "Native view drained outside a Swift task")
        DispatchQueue.main.async {
            autoreleasepool {
                let view = NativeModelOwnerView(frame: .zero)
                view.model = payload.model
                payload.model = nil
                withExtendedLifetime(view) {}
            }
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(retainedModel)
    }

    func testEngineAndCapturedSettingsReleaseWhenDispatchDisposesTransitionBlock() async {
        let suiteName = "NotchEngineDestructionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        weak var retainedEngine: NotchEngine?
        weak var retainedSettings: SettingsViewModel?
        do {
            let settings = SettingsViewModel(defaults: defaults)
            let engine = NotchEngine(
                animations: { .preset(settings.notchAnimationPreset) },
                hideDelay: 0.01,
                queueDelay: 0
            )
            retainedEngine = engine
            retainedSettings = settings
            engine.send(.showLiveActivity(RestorableTestContent()))
            // Leave the original transition block owning the only strong
            // reference, exactly as in the macOS 15 crash report.
        }
        let deadline = Date().addingTimeInterval(2)
        while retainedEngine != nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(retainedEngine)
        XCTAssertNil(retainedSettings)
    }

    func testMasterHidePreventsRestoringPreviouslyDismissedFeature() async throws {
        let engine = NotchEngine(animations: { .default }, hideDelay: 0, queueDelay: 0)
        engine.send(.showLiveActivity(RestorableTestContent()))
        let deadline = Date().addingTimeInterval(2)
        while engine.notchModel.liveActivityContent == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(engine.notchModel.liveActivityContent)
        engine.dismissActiveContent()
        XCTAssertTrue(engine.canRestoreDismissedContent)

        engine.send(.hide)
        XCTAssertFalse(engine.canRestoreDismissedContent)
        engine.restoreDismissedContent()
        let hideDeadline = Date().addingTimeInterval(2)
        while engine.notchModel.liveActivityContent != nil && Date() < hideDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(engine.notchModel.liveActivityContent)
        XCTAssertFalse(engine.canRestoreDismissedContent)
    }

    func testMasterDisableRejectsLateViewTeardownEventsUntilReenabled() async throws {
        let engine = NotchEngine(animations: { .default }, hideDelay: 0, queueDelay: 0)
        engine.setActivityEventsEnabled(false)
        // Expanded home pages previously posted this after the host unmounted
        // them, undoing master-disable cleanup and restoring stale content.
        engine.send(.showLiveActivity(RestorableTestContent()))
        engine.send(.showTemporaryNotification(RestorableTestContent(), duration: 10))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(engine.notchModel.content)
        XCTAssertFalse(engine.canRestoreDismissedContent)
        engine.setActivityEventsEnabled(true)
        engine.send(.showLiveActivity(RestorableTestContent()))
        let deadline = Date().addingTimeInterval(2)
        while engine.notchModel.liveActivityContent == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(engine.notchModel.liveActivityContent?.id, "test.restorable.feature")
        engine.setActivityEventsEnabled(false)
    }

}

private struct RestorableTestContent: NotchContentProtocol {
    let id = "test.restorable.feature"
    func size(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize {
        CGSize(width: baseWidth, height: baseHeight)
    }
    func makeView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
private final class NativeModelOwnerView: NSView {
    var model: NotchViewModel?
}

// Single transfer to a dispatch callback; only ARC runs outside actor methods.
nonisolated private final class NativeModelReleasePayload: @unchecked Sendable {
    var model: NotchViewModel?
    init(_ model: NotchViewModel) { self.model = model }
}
