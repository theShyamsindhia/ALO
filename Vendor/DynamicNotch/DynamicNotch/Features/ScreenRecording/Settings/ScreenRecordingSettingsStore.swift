import Combine
import Foundation

extension ScreenRecordingStyle: StoredSettingValue {}

@MainActor
final class ScreenRecordingSettingsStore: SettingsStoreBase {
    // ARC only: these settings own values, publishers and defaults, with no
    // executor-bound cleanup. Avoid isolated-deinit backdeployment on macOS 15
    // when a synchronous dispatch callback releases the last reference.
    nonisolated deinit {}

    @StoredDefault(key: GeneralSettingsStorage.Keys.screenRecordingLiveActivityEnabled, defaultValue: false)
    var isScreenRecordingLiveActivityEnabled: Bool

    @StoredDefault(key: GeneralSettingsStorage.Keys.screenRecordingDefaultStrokeEnabled, defaultValue: false)
    var isScreenRecordingDefaultStrokeEnabled: Bool

    @StoredDefault(key: GeneralSettingsStorage.Keys.screenRecordingStyle, defaultValue: .detailed)
    var screenRecordingStyle: ScreenRecordingStyle

    @StoredDefault(key: GeneralSettingsStorage.Keys.screenshotActivityEnabled, defaultValue: false)
    var isScreenshotActivityEnabled: Bool

    @StoredDefault(key: GeneralSettingsStorage.Keys.screenshotDisableSystemThumbnail, defaultValue: false)
    var isScreenshotDisableSystemThumbnailEnabled: Bool

    @StoredDefault(key: GeneralSettingsStorage.Keys.screenshotAutoHideEnabled, defaultValue: true)
    var isScreenshotAutoHideEnabled: Bool

    @StoredDefault(
        key: GeneralSettingsStorage.Keys.screenshotTemporaryActivityDuration,
        defaultValue: 4,
        transform: SettingsStoreBase.clampTemporaryActivityDuration
    )
    var screenshotTemporaryActivityDuration: Int

    @StoredDefault(key: GeneralSettingsStorage.Keys.screenshotSavePath, defaultValue: "")
    var screenshotSavePath: String

    @StoredDefault(key: GeneralSettingsStorage.Keys.screenRecordingSavePath, defaultValue: "")
    var screenRecordingSavePath: String

    override init(defaults: UserDefaults) {
        super.init(defaults: defaults)
    }

    func reset() {
        isScreenRecordingLiveActivityEnabled = defaultBool(for: GeneralSettingsStorage.Keys.screenRecordingLiveActivityEnabled)
        isScreenRecordingDefaultStrokeEnabled = defaultBool(for: GeneralSettingsStorage.Keys.screenRecordingDefaultStrokeEnabled)
        screenRecordingStyle = .detailed
        isScreenshotActivityEnabled = defaultBool(for: GeneralSettingsStorage.Keys.screenshotActivityEnabled)
        isScreenshotDisableSystemThumbnailEnabled = defaultBool(for: GeneralSettingsStorage.Keys.screenshotDisableSystemThumbnail)
        isScreenshotAutoHideEnabled = defaultBool(for: GeneralSettingsStorage.Keys.screenshotAutoHideEnabled)
        screenshotTemporaryActivityDuration = defaultInt(for: GeneralSettingsStorage.Keys.screenshotTemporaryActivityDuration)
        screenshotSavePath = defaultString(for: GeneralSettingsStorage.Keys.screenshotSavePath)
        screenRecordingSavePath = defaultString(for: GeneralSettingsStorage.Keys.screenRecordingSavePath)
    }
}
