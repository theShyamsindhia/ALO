import Foundation
import XCTest
@testable import ALONotchRuntime

@MainActor
final class NotchInitialFeatureProfileTests: XCTestCase {
    func testFirstEnableAddsFileSharingWithoutUnrelatedSystemActivities() throws {
        let suite = "NotchInitialFeatureProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsViewModel(defaults: defaults)
        XCTAssertFalse(settings.homePage.isHomePageLiveActivityEnabled)
        XCTAssertNil(defaults.object(forKey: NotchInitialFeatureProfile.appliedKey))
        XCTAssertTrue(NotchInitialFeatureProfile.apply(defaults: defaults, domainName: suite, settings: settings))
        XCTAssertFalse(settings.mediaAndFiles.isNowPlayingLiveActivityEnabled)
        XCTAssertFalse(settings.battery.isChargerTemporaryActivityEnabled)
        XCTAssertFalse(settings.connectivity.isBluetoothTemporaryActivityEnabled)
        XCTAssertFalse(settings.connectivity.isWifiTemporaryActivityEnabled)
        XCTAssertTrue(settings.mediaAndFiles.isDragAndDropLiveActivityEnabled)
        XCTAssertTrue(settings.mediaAndFiles.isTrayLiveActivityEnabled)
        XCTAssertEqual(settings.mediaAndFiles.dragAndDropActivityMode, .combined)
        XCTAssertEqual(settings.lockScreen.widgetAppearanceStyle, .liquidGlass)
        XCTAssertFalse(settings.homePage.isHomePageLiveActivityEnabled)
        XCTAssertEqual(settings.homePage.homePageDisabled, Set(HomePages.allCases))
        XCTAssertFalse(settings.calendar.isCalendarLiveActivityEnabled)
        XCTAssertFalse(settings.lockScreen.isLockScreenMediaPanelEnabled)
        XCTAssertFalse(settings.lockScreen.isLockScreenLiveActivityEnabled)
        XCTAssertFalse(settings.lockScreen.isLockScreenSoundEnabled)
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
        settings.mediaAndFiles.isNowPlayingLiveActivityEnabled = false
        settings.battery.isChargerTemporaryActivityEnabled = false
        settings.connectivity.isBluetoothTemporaryActivityEnabled = false
        settings.connectivity.isWifiTemporaryActivityEnabled = false
        settings.mediaAndFiles.isDragAndDropLiveActivityEnabled = false
        settings.mediaAndFiles.isTrayLiveActivityEnabled = false
        settings.mediaAndFiles.dragAndDropActivityMode = .airDrop
        settings.lockScreen.widgetAppearanceStyle = .ultraThickMaterial
        settings.homePage.homePageDisabled = Set(HomePages.allCases)
        XCTAssertTrue(NotchInitialFeatureProfile.apply(defaults: defaults, domainName: suite, settings: settings))
        XCTAssertFalse(settings.mediaAndFiles.isNowPlayingLiveActivityEnabled)
        XCTAssertFalse(settings.battery.isChargerTemporaryActivityEnabled)
        XCTAssertFalse(settings.connectivity.isBluetoothTemporaryActivityEnabled)
        XCTAssertFalse(settings.connectivity.isWifiTemporaryActivityEnabled)
        XCTAssertFalse(settings.mediaAndFiles.isDragAndDropLiveActivityEnabled)
        XCTAssertFalse(settings.mediaAndFiles.isTrayLiveActivityEnabled)
        XCTAssertEqual(settings.mediaAndFiles.dragAndDropActivityMode, .airDrop)
        XCTAssertEqual(settings.lockScreen.widgetAppearanceStyle, .ultraThickMaterial)
        XCTAssertFalse(settings.homePage.isHomePageLiveActivityEnabled)
        XCTAssertEqual(settings.homePage.homePageDisabled, Set(HomePages.allCases))
    }

    func testLegacyProfileDoesNotAddSystemActivitiesAndPreservesSavedChoices() throws {
        let suite = "NotchConnectivityGlassProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: NotchInitialFeatureProfile.appliedKey)
        let settings = SettingsViewModel(defaults: defaults)
        settings.mediaAndFiles.isNowPlayingLiveActivityEnabled = true
        settings.lockScreen.widgetAppearanceStyle = .ultraThinMaterial
        XCTAssertTrue(NotchInitialFeatureProfile.apply(defaults: defaults, domainName: suite, settings: settings))
        XCTAssertFalse(settings.connectivity.isBluetoothTemporaryActivityEnabled)
        XCTAssertFalse(settings.connectivity.isWifiTemporaryActivityEnabled)
        XCTAssertFalse(settings.lockScreen.isLockScreenMediaPanelEnabled)
        XCTAssertTrue(settings.mediaAndFiles.isNowPlayingLiveActivityEnabled)
        XCTAssertEqual(settings.lockScreen.widgetAppearanceStyle, .ultraThinMaterial)
        settings.connectivity.isBluetoothTemporaryActivityEnabled = true
        XCTAssertFalse(NotchInitialFeatureProfile.apply(defaults: defaults, domainName: suite, settings: settings))
        XCTAssertTrue(settings.connectivity.isBluetoothTemporaryActivityEnabled)
        XCTAssertFalse(settings.connectivity.isWifiTemporaryActivityEnabled)
        XCTAssertEqual(settings.lockScreen.widgetAppearanceStyle, .ultraThinMaterial)
    }

}
