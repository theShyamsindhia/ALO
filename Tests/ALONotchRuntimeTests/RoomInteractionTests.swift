import SwiftUI
import XCTest
@testable import ALONotchRuntime

@MainActor
final class RoomInteractionTests: XCTestCase {
    func testRoomModelReleasesFromSynchronousBackgroundCallback() async {
        let payload = RoomModelReleasePayload(RoomInteractionModel())
        weak var retained = payload.object
        let released = expectation(description: "Room model released outside a Swift task")
        DispatchQueue.global(qos: .utility).async {
            payload.object = nil
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(retained)
    }

    func testQuickActionsHaveCompactBoundsAndResizeKeepsExpansion() async throws {
        let model = RoomInteractionModel()
        let display = CGSize(width: 1440, height: 900)
        let compact = RoomNotchLayout.tray.size(display: display)
        XCTAssertEqual(compact, CGSize(width: 460, height: 190))
        XCTAssertEqual(RoomNotchLayout.conversation.size(display: display), CGSize(width: 520, height: 350))
        for layout in RoomNotchLayout.allCases {
            let small = layout.size(display: CGSize(width: 360, height: 360))
            XCTAssertLessThanOrEqual(small.width, 328)
            XCTAssertLessThanOrEqual(small.height, 312)
        }
        let engine = NotchEngine(animations: { .default }, hideDelay: 0, queueDelay: 0)
        defer { engine.setActivityEventsEnabled(false) }
        engine.send(.showLiveActivity(RoomInteractionContent(model: model)))
        let deadline = Date().addingTimeInterval(2)
        while engine.notchModel.content == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        engine.handleActiveContentTap()
        model.availableSize = compact
        engine.send(.showLiveActivity(RoomInteractionContent(model: model)))
        XCTAssertTrue(engine.notchModel.isLiveActivityExpanded)
        XCTAssertEqual(engine.notchModel.size, compact)
    }

    func testNativeDialogClickDoesNotCollapseRoomWorkspace() async throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let host = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 960),
                           styleMask: .borderless, backing: .buffered, defer: false)
        delegate.hostWindow = host
        defer { delegate.notchViewModel.setActivityEventsEnabled(false) }
        delegate.notchViewModel.send(.showLiveActivity(RoomInteractionContent(model: RoomInteractionModel())))
        let deadline = Date().addingTimeInterval(2)
        while delegate.notchViewModel.displayedContent == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        delegate.notchViewModel.expandActiveLiveActivity()
        while !delegate.notchViewModel.notchModel.isLiveActivityExpanded && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(delegate.notchViewModel.notchModel.isLiveActivityExpanded)
        delegate.expansionTime = .distantPast
        delegate.handleLocalClick(from: NSOpenPanel(), atScreenLocation: NSPoint(x: -200, y: -200))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(delegate.notchViewModel.notchModel.isLiveActivityExpanded)
        delegate.handleLocalClick(from: host, atScreenLocation: NSPoint(x: -200, y: -200))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(delegate.notchViewModel.notchModel.isLiveActivityExpanded)
    }

    func testCollapsedRoomAllowsMentionPreviewAndOpensConversationOnTap() async throws {
        let model = RoomInteractionModel()
        let engine = NotchEngine(animations: { .default }, hideDelay: 0, queueDelay: 0)
        defer { engine.setActivityEventsEnabled(false) }
        engine.send(.showLiveActivity(RoomInteractionContent(model: model)))
        var deadline = Date().addingTimeInterval(2)
        while engine.notchModel.content == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(engine.notchModel.isLiveActivityExpanded)
        var opened = false
        engine.send(.showTemporaryNotification(RoomMentionNotchContent(
            snapshot: .init(sender: "Raj", message: "Take a look", roomTitle: "Room"),
            onOpen: { opened = true }), duration: 4.5))
        deadline = Date().addingTimeInterval(2)
        while engine.notchModel.temporaryNotificationContent == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let notification = try XCTUnwrap(engine.notchModel.temporaryNotificationContent as? RoomMentionNotchContent)
        XCTAssertEqual(notification.snapshot.message, "Take a look")
        notification.onOpen()
        XCTAssertTrue(opened)
    }

    func testExpandedConversationDefersAndCoalescesInterruptionsUntilClosed() async throws {
        let model = RoomInteractionModel()
        let engine = NotchEngine(animations: { .default }, hideDelay: 0, queueDelay: 0)
        defer { engine.setActivityEventsEnabled(false) }
        engine.send(.showLiveActivity(RoomInteractionContent(model: model)))
        var deadline = Date().addingTimeInterval(2)
        while engine.notchModel.content == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        engine.handleActiveContentTap()
        for sender in ["Earlier", "Latest"] {
            engine.send(.showTemporaryNotification(RoomMentionNotchContent(
                snapshot: .init(sender: sender, message: "Message", roomTitle: "Room"), onOpen: {}), duration: 4.5))
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.notchModel.content?.id, RoomInteractionContent.activityID)
        XCTAssertNil(engine.notchModel.temporaryNotificationContent)
        engine.send(.hideLiveActivity(id: RoomInteractionContent.activityID))
        deadline = Date().addingTimeInterval(2)
        while engine.notchModel.temporaryNotificationContent == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let notification = try XCTUnwrap(engine.notchModel.temporaryNotificationContent as? RoomMentionNotchContent)
        XCTAssertEqual(notification.snapshot.sender, "Latest")
    }

    func testRoomInteractionExpandsInsideEngineWithoutWindowLink() async throws {
        let model = RoomInteractionModel()
        model.content = AnyView(Text("Room conversation"))
        let content = RoomInteractionContent(model: model)
        XCTAssertTrue(content.isExpandable)
        XCTAssertFalse(content.isRestorable)
        XCTAssertNil(content.windowLink)
        let engine = NotchEngine(animations: { .default }, hideDelay: 0, queueDelay: 0)
        defer { engine.setActivityEventsEnabled(false) }
        engine.send(.showLiveActivity(content))
        let deadline = Date().addingTimeInterval(2)
        while engine.notchModel.content == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(engine.notchModel.content?.id, RoomInteractionContent.activityID)
        XCTAssertTrue(engine.canExpandActiveLiveActivity)
        engine.handleActiveContentTap()
        XCTAssertTrue(engine.notchModel.isLiveActivityExpanded)
    }

    func testCompactAndExpandedGeometryRespectAvailableDisplayWidth() {
        let model = RoomInteractionModel()
        model.availableSize = CGSize(width: 360, height: 450)
        let content = RoomInteractionContent(model: model)
        XCTAssertLessThanOrEqual(content.size(baseWidth: 300, baseHeight: 32).width, 360)
        XCTAssertEqual(content.expandedSize(baseWidth: 300, baseHeight: 32), model.availableSize)
        XCTAssertEqual(content.expandedDynamicIslandSize(baseWidth: 300, baseHeight: 32), model.availableSize)
    }
}

/// Transfer the only strong reference to a single callback, as SwiftUI/Dispatch
/// can do when disposing the content of a dismissed notch transition.
nonisolated private final class RoomModelReleasePayload: @unchecked Sendable {
    var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
}
