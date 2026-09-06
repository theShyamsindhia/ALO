import Foundation
import XCTest
@testable import ALONotchRuntime

@MainActor
final class NotchInitialFeatureProfileTests: XCTestCase {
    func testFirstEnableAddsUsefulIdleAndMediaWithoutPermissionFeatures() throws {
        let suite = "NotchInitialFeatureProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsViewModel(defaults: defaults)
        XCTAssertFalse(settings.homePage.isHomePageLiveActivityEnabled)
        XCTAssertNil(defaults.object(forKey: NotchInitialFeatureProfile.appliedKey))
        XCTAssertTrue(NotchInitialFeatureProfile.apply(defaults: defaults, domainName: suite, settings: settings))
        XCTAssertTrue(defaults.bool(forKey: NotchInitialFeatureProfile.roomMediaKey))
        XCTAssertTrue(settings.mediaAndFiles.isNowPlayingLiveActivityEnabled)
        XCTAssertTrue(settings.battery.isChargerTemporaryActivityEnabled)
        XCTAssertTrue(settings.homePage.isHomePageLiveActivityEnabled)
        XCTAssertEqual(Set(HomePages.allCases).subtracting(settings.homePage.homePageDisabled), [.localTimer])
        XCTAssertFalse(settings.calendar.isCalendarLiveActivityEnabled)
        XCTAssertFalse(settings.connectivity.isBluetoothTemporaryActivityEnabled)
        XCTAssertFalse(settings.lockScreen.isLockScreenMediaPanelEnabled)
        settings.mediaAndFiles.isNowPlayingLiveActivityEnabled = false
        settings.homePage.isHomePageLiveActivityEnabled = false
        XCTAssertFalse(NotchInitialFeatureProfile.apply(defaults: defaults, domainName: suite, settings: settings))
        XCTAssertFalse(settings.mediaAndFiles.isNowPlayingLiveActivityEnabled)
        XCTAssertFalse(settings.homePage.isHomePageLiveActivityEnabled)
    }

    func testExplicitDisabledChoicesAndEmptyHomePagesArePreserved() throws {
        let suite = "NotchInitialFeatureProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsViewModel(defaults: defaults)
        defaults.set(false, forKey: NotchInitialFeatureProfile.roomMediaKey)
        settings.mediaAndFiles.isNowPlayingLiveActivityEnabled = false
        settings.battery.isChargerTemporaryActivityEnabled = false
        settings.homePage.homePageDisabled = Set(HomePages.allCases)
        XCTAssertTrue(NotchInitialFeatureProfile.apply(defaults: defaults, domainName: suite, settings: settings))
        XCTAssertFalse(defaults.bool(forKey: NotchInitialFeatureProfile.roomMediaKey))
        XCTAssertFalse(settings.mediaAndFiles.isNowPlayingLiveActivityEnabled)
        XCTAssertFalse(settings.battery.isChargerTemporaryActivityEnabled)
        XCTAssertFalse(settings.homePage.isHomePageLiveActivityEnabled)
        XCTAssertEqual(settings.homePage.homePageDisabled, Set(HomePages.allCases))
    }
}
