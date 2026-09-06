import AppKit
import XCTest
@testable import ALONotchRuntime

@MainActor
final class EmbeddedSettingsRoutingTests: XCTestCase {
    func testRuntimeSettingsRequestUsesHostWhileNotchIsDisabled() async {
        withRuntime { runtime in
            var requests = 0
            runtime.onSettingsRequested = { requests += 1 }
            XCTAssertFalse(runtime.isEnabled)
            runtime.showSettings()
            XCTAssertEqual(requests, 1)
            XCTAssertNil(runtime.requestedSettingsDestination())
        }
    }

    func testOriginalSettingsActionsRouteToHostWithoutPresentingStandaloneWindow() async {
        withRuntime { runtime in
            let controller = SettingsWindowController.shared
            let originalWindow = controller.window
            let wasVisible = originalWindow?.isVisible ?? false
            let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
            var requests = 0
            runtime.onSettingsRequested = { requests += 1 }
            controller.showWindow()
            controller.showWindow(selecting: SettingsRootViewModel.Section.vpn)
            controller.showWindow(selecting: SettingsSubPage.fileConverter)
            XCTAssertEqual(requests, 3)
            XCTAssertTrue(controller.window === originalWindow)
            XCTAssertEqual(originalWindow?.isVisible ?? false, wasVisible)
            XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windowsBefore)
        }
    }

    func testDestinationSurvivesHiddenAndVisibleHostReadsAndPlainRequestClearsIt() async {
        withRuntime { runtime in
            runtime.onSettingsRequested = {}
            let controller = SettingsWindowController.shared
            controller.showWindow(selecting: SettingsRootViewModel.Section.vpn)
            for _ in 0..<2 {
                guard case .section(let section) = runtime.requestedSettingsDestination() else {
                    return XCTFail("Both mounted hosts must receive the section destination")
                }
                XCTAssertEqual(section, .vpn)
            }
            controller.showWindow(selecting: SettingsSubPage.fileConverter)
            for _ in 0..<2 {
                guard case .subPage(let page) = runtime.requestedSettingsDestination() else {
                    return XCTFail("Both mounted hosts must receive the subpage destination")
                }
                XCTAssertEqual(page, .fileConverter)
            }
            controller.showWindow()
            XCTAssertNil(runtime.requestedSettingsDestination())
        }
    }

    func testDismissalClearsThePendingDestination() async {
        withRuntime { runtime in
            runtime.onSettingsRequested = {}
            XCTAssertTrue(runtime.requestEmbeddedSettings(.subPage(.notch)))
            XCTAssertNotNil(runtime.requestedSettingsDestination())

            runtime.resetEmbeddedSettingsNavigation()

            XCTAssertNil(runtime.requestedSettingsDestination())
        }
    }

    func testMissingHostCallbackDeclinesRoutingWithoutChangingPendingDestination() async {
        withRuntime { runtime in
            XCTAssertFalse(runtime.requestEmbeddedSettings(.section(.vpn)))
            XCTAssertNil(runtime.requestedSettingsDestination())
            runtime.onSettingsRequested = {}
            XCTAssertTrue(runtime.requestEmbeddedSettings(.subPage(.fileConverter)))
            runtime.onSettingsRequested = nil
            XCTAssertFalse(runtime.requestEmbeddedSettings(.section(.vpn)),
                           "Standalone fallback must remain available when no host callback exists")
            guard case .subPage(let page) = runtime.requestedSettingsDestination() else {
                return XCTFail("Declined routing must not mutate the previous destination")
            }
            XCTAssertEqual(page, .fileConverter)
        }
    }

    func testOpenActivityNeverFallsBackToSettings() async {
        withRuntime { runtime in
            var settingsRequests = 0
            runtime.onSettingsRequested = { settingsRequests += 1 }

            XCTAssertFalse(runtime.openActivity())
            XCTAssertEqual(settingsRequests, 0)
        }
    }

    func testOpenActivityPrefersCurrentContentThenConfiguredHomePage() async {
        XCTAssertEqual(
            EmbeddedNotchRuntime.activityOpeningTarget(
                isEnabled: true,
                hasCurrentActivity: true,
                isHomePageEnabled: false,
                hasEnabledHomePageItem: false
            ),
            .currentActivity
        )
        XCTAssertEqual(
            EmbeddedNotchRuntime.activityOpeningTarget(
                isEnabled: true,
                hasCurrentActivity: false,
                isHomePageEnabled: true,
                hasEnabledHomePageItem: true
            ),
            .homePage
        )
        XCTAssertEqual(
            EmbeddedNotchRuntime.activityOpeningTarget(
                isEnabled: true,
                hasCurrentActivity: false,
                isHomePageEnabled: false,
                hasEnabledHomePageItem: true
            ),
            .unavailable
        )
    }

    private func withRuntime(_ body: (EmbeddedNotchRuntime) -> Void) {
        _ = NSApplication.shared
        let previousRuntime = EmbeddedNotchRuntime.activeInstance
        let previousDelegate = AppDelegate.embeddedInstance
        let runtime = EmbeddedNotchRuntime()
        defer {
            runtime.onSettingsRequested = nil
            EmbeddedNotchRuntime.activeInstance = previousRuntime
            AppDelegate.embeddedInstance = previousDelegate
        }
        body(runtime)
    }
}
