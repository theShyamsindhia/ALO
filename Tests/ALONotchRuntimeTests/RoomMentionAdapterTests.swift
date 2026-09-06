import AppKit
import SwiftUI
import XCTest
@testable import ALONotchRuntime

@MainActor
final class RoomMentionAdapterTests: XCTestCase {
    func testMentionUsesTemporaryNonRestorableActivityAndOpensALOChat() {
        var opened = false
        let snapshot = RoomMentionSnapshot(
            sender: "Luna",
            message: "@Zex this track is perfect",
            roomTitle: "Listening Room"
        )
        let content = RoomMentionNotchContent(snapshot: snapshot) { opened = true }
        XCTAssertEqual(content.id, RoomMentionNotchContent.activityID)
        XCTAssertFalse(content.isRestorable)
        XCTAssertNotNil(content.windowLink)
        content.windowLink?()
        XCTAssertTrue(opened)
    }

    func testMentionRendersOnNotchAndNotchlessDisplays() async throws {
        _ = NSApplication.shared
        let name = "RoomMentionRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsViewModel(defaults: defaults)
        let snapshot = RoomMentionSnapshot(
            sender: "Luna",
            message: "@Zex the next song is yours",
            roomTitle: "Friday listening"
        )

        for island in [false, true] {
            let notch = NotchViewModel(
                settings: settings.application,
                hideDelay: 0,
                queueDelay: 0,
                screenMetricsProvider: {
                    _ in (width: 1512, topInset: island ? 0 : 32,
                          notchSize: island ? nil : CGSize(width: 190, height: 32))
                }
            )
            let content = RoomMentionNotchContent(snapshot: snapshot) {}
            notch.send(.showTemporaryNotification(content, duration: .infinity))
            let deadline = Date().addingTimeInterval(2)
            while notch.notchModel.content == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(notch.notchModel.content?.id, RoomMentionNotchContent.activityID)

            let size = notch.presentedNotchSize
            let bounds = NSRect(x: 0, y: 0, width: size.width + 30, height: size.height + 15)
            let host = NSHostingView(
                rootView: NotchInteractiveBodyView(notchViewModel: notch, settingsViewModel: settings)
                    .defaultAppStorage(defaults)
                    .frame(width: bounds.width, height: bounds.height, alignment: .top)
                    .background(Color(red: 0.17, green: 0.18, blue: 0.20))
            )
            let window = NSWindow(
                contentRect: bounds.offsetBy(dx: -3000, dy: -3000),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1_500)
            if let directory = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let filename = island ? "room-mention-island.png" : "room-mention-notch.png"
                try png.write(to: folder.appendingPathComponent(filename))
            }
            window.close()
            notch.setActivityEventsEnabled(false)
        }
    }
}
