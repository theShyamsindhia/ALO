import Foundation

/// Applied on first enable, never on settings construction. Explicit choices,
/// including an intentionally empty home page selection, remain authoritative.
@MainActor
enum NotchInitialFeatureProfile {
    static let appliedKey = "alo.notch.initialFeatureProfile.v1"
    static let lockScreenAppliedKey = "alo.notch.lockScreenFeatureProfile.v1"
    static let roomMediaKey = "alo.roomMedia.enabled"

    static func apply(defaults: UserDefaults, domainName: String, settings: SettingsViewModel) -> Bool {
        let updatedLockDefaults = applyLockScreenDefaults(defaults: defaults, domainName: domainName, settings: settings)
        guard !defaults.bool(forKey: appliedKey) else { return updatedLockDefaults }
        // Registered upstream defaults are not user choices. Inspect only the
        // persistent suite so inherited false defaults can acquire this profile.
        let saved = defaults.persistentDomain(forName: domainName) ?? [:]
        if saved[roomMediaKey] == nil {
            defaults.set(true, forKey: roomMediaKey)
        }
        if saved[GeneralSettingsStorage.Keys.nowPlayingLiveActivityEnabled] == nil {
            settings.mediaAndFiles.isNowPlayingLiveActivityEnabled = true
        }
        if saved[GeneralSettingsStorage.Keys.chargerTemporaryActivityEnabled] == nil {
            settings.battery.isChargerTemporaryActivityEnabled = true
        }
        let homepageWasChosen = saved[GeneralSettingsStorage.Keys.homePageLiveActivity] != nil
        let pagesWereChosen = saved[GeneralSettingsStorage.Keys.homePageDisabled] != nil
        if !homepageWasChosen && !pagesWereChosen {
            // A useful idle surface with no camera permission or background polling.
            settings.homePage.homePageDisabled = Set(HomePages.allCases).subtracting([.localTimer])
            settings.homePage.isHomePageLiveActivityEnabled = true
        }
        defaults.set(true, forKey: appliedKey)
        return true
    }

    private static func applyLockScreenDefaults(defaults: UserDefaults, domainName: String, settings: SettingsViewModel) -> Bool {
        guard !defaults.bool(forKey: lockScreenAppliedKey) else { return false }
        let saved = defaults.persistentDomain(forName: domainName) ?? [:]
        let lock = settings.lockScreen
        if saved[LockScreenSettings.liveActivityKey] == nil { lock.isLockScreenLiveActivityEnabled = true }
        if saved[LockScreenSettings.mediaPanelKey] == nil { lock.isLockScreenMediaPanelEnabled = true }
        if saved[LockScreenSettings.soundKey] == nil { lock.isLockScreenSoundEnabled = true }
        if saved[LockScreenSettings.lyricsEnabledKey] == nil { lock.isLockScreenLyricsEnabled = true }
        if saved[LockScreenSettings.artworkExpandedKey] == nil { lock.isLockScreenArtworkExpanded = true }
        defaults.set(true, forKey: lockScreenAppliedKey)
        return true
    }

}
