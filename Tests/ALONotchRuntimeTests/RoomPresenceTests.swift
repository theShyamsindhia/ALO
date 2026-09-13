import AppKit
import SwiftUI
import XCTest
@testable import ALONotchRuntime

@MainActor
final class RoomPresenceTests: XCTestCase {
    func testQuietRoomRestoresAfterPlaybackAndNeverTakesOverConversation() async throws {
        let engine = NotchEngine(animations: { .default }, hideDelay: 0, queueDelay: 0)
        defer { engine.setActivityEventsEnabled(false) }
        let model = RoomPresenceModel()
        model.title = "Design room"; model.people = 2
        var opened = false
        let quiet = RoomPresenceContent(model: model) { opened = true }
        engine.send(.showLiveActivity(quiet))
        try await expectContent(quiet.id, engine: engine)
        quiet.open()
        XCTAssertTrue(opened)
        XCTAssertNil(quiet.windowLink, "Room entry never opens an external window")
        let music = PresenceMusicFixture()
        engine.send(.showLiveActivity(music))
        try await expectContent(music.id, engine: engine)
        engine.send(.hideLiveActivity(id: music.id))
        try await expectContent(quiet.id, engine: engine)
        let conversation = RoomInteractionContent(model: RoomInteractionModel())
        engine.send(.showLiveActivity(conversation))
        try await expectContent(conversation.id, engine: engine)
        engine.handleActiveContentTap()
        model.people = 3
        engine.send(.showLiveActivity(quiet))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engine.notchModel.content?.id, conversation.id)
        XCTAssertTrue(engine.notchModel.isLiveActivityExpanded)
        engine.send(.hideLiveActivity(id: conversation.id))
        try await expectContent(quiet.id, engine: engine)
        engine.send(.hideLiveActivity(id: quiet.id))
        try await expectContent(nil, engine: engine)
    }

    func testQuietRoomRendersOnNotchedAndNotchlessScreens() async throws {
        _ = NSApplication.shared
        let name = "RoomPresenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsViewModel(defaults: defaults)
        for island in [false, true] {
            let notch = NotchViewModel(settings: settings.application, hideDelay: 0, queueDelay: 0,
                screenMetricsProvider: { _ in
                    (width: 1512, topInset: island ? 0 : 32, notchSize: island ? nil : CGSize(width: 190, height: 32))
                })
            defer { notch.setActivityEventsEnabled(false) }
            let model = RoomPresenceModel()
            model.title = "A room with a longer descriptive name"; model.people = island ? 1 : 8
            notch.send(.showLiveActivity(RoomPresenceContent(model: model, open: {})))
            let deadline = Date().addingTimeInterval(2)
            while notch.notchModel.content == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(notch.notchModel.content?.id, RoomPresenceContent.activityID)
            let size = notch.presentedNotchSize
            let bounds = NSRect(x: 0, y: 0, width: size.width + 30, height: size.height + 15)
            let host = NSHostingView(rootView: NotchInteractiveBodyView(notchViewModel: notch, settingsViewModel: settings)
                .defaultAppStorage(defaults).frame(width: bounds.width, height: bounds.height, alignment: .top)
                .background(Color.gray.opacity(0.3)))
            let window = NSWindow(contentRect: bounds.offsetBy(dx: -3000, dy: -3000),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1500)
            if let output = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent(island ? "room-presence-island.png" : "room-presence-notch.png"))
            }
        }
    }

    private func expectContent(_ id: String?, engine: NotchEngine) async throws {
        let deadline = Date().addingTimeInterval(2)
        while engine.notchModel.content?.id != id, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(engine.notchModel.content?.id, id)
    }
}

private struct PresenceMusicFixture: NotchContentProtocol {
    var id: String { "room-presence-test-music" }
    var priority: Int { NotchContentPriority.nowPlaying }
    func size(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize { CGSize(width: baseWidth, height: baseHeight + 40) }
    func makeView() -> AnyView { AnyView(Text("Music")) }
}
