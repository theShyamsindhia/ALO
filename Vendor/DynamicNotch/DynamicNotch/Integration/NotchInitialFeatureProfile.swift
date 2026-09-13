import Foundation

/// Applied on first enable, never on settings construction. Explicit choices,
/// including an intentionally empty home page selection, remain authoritative.
@MainActor
enum NotchInitialFeatureProfile {
    static let appliedKey = "alo.notch.initialFeatureProfile.v1"
    static let sharedRoomTrayAppliedKey = "alo.notch.sharedRoomTrayProfile.v1"

    static func apply(defaults: UserDefaults, domainName: String, settings: SettingsViewModel) -> Bool {
        let updatedRoomTrayDefaults = applySharedRoomTrayDefaults(
            defaults: defaults, domainName: domainName, settings: settings)
        guard !defaults.bool(forKey: appliedKey) else {
            return updatedRoomTrayDefaults
        }
        // Registered upstream defaults are not user choices. Inspect only the
        // persistent suite so inherited false defaults can acquire this profile.
        let saved = defaults.persistentDomain(forName: domainName) ?? [:]
        // Room playback has its own source. Do not start local media, system
        // notifications, a second home page or lock-screen activity by default.
        if saved[LockScreenSettings.widgetAppearanceStyleKey] == nil {
            settings.lockScreen.widgetAppearanceStyle = .liquidGlass
        }
        defaults.set(true, forKey: appliedKey)
        return true
    }

    private static func applySharedRoomTrayDefaults(
        defaults: UserDefaults,
        domainName: String,
        settings: SettingsViewModel
    ) -> Bool {
        guard !defaults.bool(forKey: sharedRoomTrayAppliedKey) else { return false }
        let saved = defaults.persistentDomain(forName: domainName) ?? [:]
        if saved[GeneralSettingsStorage.Keys.dragAndDropLiveActivityEnabled] == nil {
            settings.mediaAndFiles.isDragAndDropLiveActivityEnabled = true
        }
        if saved[GeneralSettingsStorage.Keys.trayLiveActivityEnabled] == nil {
            settings.mediaAndFiles.isTrayLiveActivityEnabled = true
        }
        if saved[GeneralSettingsStorage.Keys.dragAndDropActivityMode] == nil {
            settings.mediaAndFiles.dragAndDropActivityMode = .combined
        }
        defaults.set(true, forKey: sharedRoomTrayAppliedKey)
        return true
    }

}
