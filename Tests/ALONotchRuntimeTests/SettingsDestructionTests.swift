import Foundation
import XCTest
@testable import ALONotchRuntime

@MainActor
final class SettingsDestructionTests: XCTestCase {
    func testSettingsHierarchyReleasesFromSynchronousMainQueueCallback() async {
        await assertRelease(on: .main)
    }

    func testSettingsHierarchyReleasesFromSynchronousBackgroundCallback() async {
        await assertRelease(on: .global(qos: .utility))
    }

    private func assertRelease(on queue: DispatchQueue) async {
        let suiteName = "SettingsDestructionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let payload = SettingsReleasePayload(SettingsViewModel(defaults: defaults))
        weak var settings = payload.object
        weak var application = settings?.application
        weak var homePage = settings?.homePage
        weak var mediaAndFiles = settings?.mediaAndFiles
        weak var connectivity = settings?.connectivity
        weak var battery = settings?.battery
        weak var hud = settings?.hud
        weak var lockScreen = settings?.lockScreen
        weak var screenRecording = settings?.screenRecording
        weak var calendar = settings?.calendar
        weak var notifications = settings?.notifications
        let released = expectation(description: "Settings hierarchy released outside a Swift task")
        queue.async {
            // Match the engine's delayed transition callback: there is no Swift
            // task here, and only ARC destruction runs outside the actor.
            payload.object = nil
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(settings)
        XCTAssertNil(application)
        XCTAssertNil(homePage)
        XCTAssertNil(mediaAndFiles)
        XCTAssertNil(connectivity)
        XCTAssertNil(battery)
        XCTAssertNil(hud)
        XCTAssertNil(lockScreen)
        XCTAssertNil(screenRecording)
        XCTAssertNil(calendar)
        XCTAssertNil(notifications)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[GeneralSettingsStorage.Keys.launchAtLogin],
                     "Destruction must not persist defaults or change login registration")
    }
}

// The only reference is handed to one callback; the test awaits completion
// before reading weak references. No actor methods execute in that callback.
nonisolated private final class SettingsReleasePayload: @unchecked Sendable {
    var object: SettingsViewModel?
    init(_ object: SettingsViewModel) { self.object = object }
}
