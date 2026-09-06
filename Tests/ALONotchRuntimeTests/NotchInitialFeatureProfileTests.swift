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
        XCTAssertTrue(settings.lockScreen.isLockScreenMediaPanelEnabled)
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

    func testLockScreenProfileMigratesExistingFirstEnableAndPreservesLaterChoices() throws {
        let suite = "NotchLockProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: NotchInitialFeatureProfile.appliedKey)
        let settings = SettingsViewModel(defaults: defaults)
        settings.lockScreen.isLockScreenSoundEnabled = false
        XCTAssertTrue(NotchInitialFeatureProfile.apply(defaults: defaults, domainName: suite, settings: settings))
        XCTAssertTrue(settings.lockScreen.isLockScreenLiveActivityEnabled)
        XCTAssertTrue(settings.lockScreen.isLockScreenMediaPanelEnabled)
        XCTAssertTrue(settings.lockScreen.isLockScreenLyricsEnabled)
        XCTAssertTrue(settings.lockScreen.isLockScreenArtworkExpanded)
        XCTAssertFalse(settings.lockScreen.isLockScreenSoundEnabled)
        settings.lockScreen.isLockScreenLyricsEnabled = false
        settings.lockScreen.isLockScreenArtworkExpanded = false
        XCTAssertFalse(NotchInitialFeatureProfile.apply(defaults: defaults, domainName: suite, settings: settings))
        XCTAssertFalse(settings.lockScreen.isLockScreenLyricsEnabled)
        XCTAssertFalse(settings.lockScreen.isLockScreenArtworkExpanded)
    }

}
