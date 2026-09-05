import SwiftUI
import XCTest
@testable import ALONotchRuntime

@MainActor
final class NotchEngineDisableTests: XCTestCase {
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
