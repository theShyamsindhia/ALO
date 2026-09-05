import Foundation
import Combine
internal import EventKit
internal import AppKit

/// Owns all background work. Saved feature choices are never overwritten by
/// the host's master switch; construction and disabled settings stay inert.
@MainActor
final class FeatureActivation {
    private let container: AppContainer
    private var observation: AnyCancellable?
    private var activationObservation: AnyCancellable?
    private(set) var isEnabled = false
    private(set) var running: Set<String> = []
    private var mediaPanel: LockScreenPanelManager?
    private var lockActivityPanel: LockScreenLiveActivityWindowManager?

    init(container: AppContainer) {
        self.container = container
        observation = container.settingsViewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
        activationObservation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isEnabled else { return }
                let notifications = self.container.settingsViewModel.notifications
                if FullDiskAccessAuthorization.hasPermission() {
                    if notifications.isAppleMailNotificationsPermissionPending {
                        notifications.isAppleMailNotificationsPermissionPending = false
                        notifications.isAppleMailNotificationsEnabled = true
                    }
                    if notifications.isMessagesNotificationsPermissionPending {
                        notifications.isMessagesNotificationsPermissionPending = false
                        notifications.isMessagesNotificationsEnabled = true
                    }
                }
                if self.running.contains("calendar") {
                    self.container.calendarViewModel.refreshAuthorization()
                }
                self.reconcile()
            }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        reconcile()
    }

    private func transition(_ key: String, _ requested: Bool, start: () -> Void, stop: () -> Void) {
        let enabled = isEnabled && requested
        guard enabled != running.contains(key) else { return }
        if enabled { running.insert(key); start() }
        else { running.remove(key); stop() }
    }

    private func reconcile() {
        let c = container
        let s = c.settingsViewModel
        let network = s.connectivity
        let files = s.mediaAndFiles
        let pages = s.homePage
        let capture = s.screenRecording
        transition("battery", s.battery.isChargerTemporaryActivityEnabled || s.battery.isLowPowerTemporaryActivityEnabled || s.battery.isFullPowerTemporaryActivityEnabled,
                   start: { c.powerService.startMonitoring() }, stop: { c.powerService.stopMonitoring() })
        transition("bluetooth", network.isBluetoothTemporaryActivityEnabled,
                   start: { BluetoothService.shared.startMonitoring() }, stop: { BluetoothService.shared.stopMonitoring() })
        transition("focus", network.isFocusLiveActivityEnabled || network.isFocusOffTemporaryActivityEnabled,
                   start: { c.focusViewModel.startMonitoring() }, stop: { c.focusViewModel.stopMonitoring() })
        transition("wifi", network.isWifiTemporaryActivityEnabled || network.isHotspotLiveActivityEnabled || network.isNoInternetTemporaryActivityEnabled,
                   start: { c.wifiViewModel.startMonitoring() }, stop: { c.wifiViewModel.stopMonitoring() })
        transition("vpn", network.isVpnTemporaryActivityEnabled || network.isVpnDisconnectedTemporaryActivityEnabled,
                   start: { c.vpnViewModel.startMonitoring() }, stop: { c.vpnViewModel.stopMonitoring() })
        if !isEnabled || !network.isHotspotLiveActivityEnabled { HotspotBatteryMonitor.shared.stopBrowsing() }
        c.nowPlayingViewModel.updateSourceFilter(files.nowPlayingSourceFilter)
        transition("music", files.isNowPlayingLiveActivityEnabled || s.lockScreen.isLockScreenMediaPanelEnabled,
                   start: { c.nowPlayingViewModel.startMonitoring() }, stop: { c.nowPlayingViewModel.stopMonitoring() })
        transition("downloads", files.isDownloadsLiveActivityEnabled,
                   start: { c.downloadViewModel.startMonitoring() }, stop: { c.downloadViewModel.stopMonitoring() })
        transition("timer", files.isTimerLiveActivityEnabled,
                   start: { c.timerViewModel.startMonitoring() }, stop: { c.timerViewModel.stopMonitoring() })
        if !isEnabled || !pages.isHomePageLiveActivityEnabled || pages.homePageDisabled.contains(.localTimer) {
            c.localTimerViewModel.stop()
        }
        transition("calendar", s.calendar.isCalendarLiveActivityEnabled,
                   start: {
                       c.calendarViewModel.startAutoRefresh()
                       if c.calendarViewModel.authorizationStatus == .notDetermined { c.calendarViewModel.requestAccess() }
                   }, stop: { c.calendarViewModel.stopAutoRefresh() })
        transition("recording", capture.isScreenRecordingLiveActivityEnabled,
                   start: { c.screenRecordingViewModel.startMonitoring() }, stop: { c.screenRecordingViewModel.stopMonitoring() })
        transition("capture", capture.isScreenshotActivityEnabled || capture.isScreenRecordingLiveActivityEnabled,
                   start: { c.screenshotViewModel.startMonitoring(disableSystemThumbnail: capture.isScreenshotActivityEnabled && capture.isScreenshotDisableSystemThumbnailEnabled) },
                   stop: { c.screenshotViewModel.stopMonitoring() })
        // Keep thumbnail configuration synchronized without adding duplicate watchers.
        if running.contains("capture") {
            c.screenshotViewModel.startMonitoring(disableSystemThumbnail: capture.isScreenshotActivityEnabled && capture.isScreenshotDisableSystemThumbnailEnabled)
        }
        let hud = s.hud
        c.hardwareHUDMonitor.updateConfiguration(interceptVolume: isEnabled && hud.isVolumeHUDEnabled,
                                                 interceptBrightness: isEnabled && hud.isBrightnessHUDEnabled)
        transition("hud", hud.isVolumeHUDEnabled || hud.isBrightnessHUDEnabled || hud.isKeyboardHUDEnabled,
                   start: { c.hardwareHUDMonitor.startMonitoring() }, stop: { c.hardwareHUDMonitor.stopMonitoring() })
        let notifications = s.notifications
        transition("mail", notifications.isAppleMailNotificationsEnabled && FullDiskAccessAuthorization.hasPermission(),
                   start: { c.mailManager.startMonitoring() }, stop: { c.mailManager.stopMonitoring() })
        transition("messages", notifications.isMessagesNotificationsEnabled && FullDiskAccessAuthorization.hasPermission(),
                   start: { c.messagesManager.startMonitoring() }, stop: { c.messagesManager.stopMonitoring() })
        c.externalDrivesMonitor.includeDiskImages = notifications.isExternalDrivesIncludeDiskImagesEnabled
        transition("drives", notifications.isExternalDrivesNotificationsEnabled,
                   start: { c.externalDrivesMonitor.startMonitoring() }, stop: { c.externalDrivesMonitor.stopMonitoring() })
        transition("tray", files.isTrayLiveActivityEnabled,
                   start: { c.fileTrayViewModel.activate() }, stop: {})
        let lock = s.lockScreen
        transition("lock", lock.isLockScreenLiveActivityEnabled || lock.isLockScreenMediaPanelEnabled || lock.isLockScreenSoundEnabled,
                   start: { c.lockScreenManager.startMonitoring() }, stop: { c.lockScreenManager.stopMonitoring() })
        transition("lockMediaPanel", lock.isLockScreenMediaPanelEnabled, start: {
            mediaPanel = LockScreenPanelManager(nowPlayingViewModel: c.nowPlayingViewModel, lockScreenManager: c.lockScreenManager, settingsViewModel: s)
        }, stop: { mediaPanel?.invalidate(); mediaPanel = nil })
        transition("lockActivityPanel", lock.isLockScreenLiveActivityEnabled, start: {
            lockActivityPanel = LockScreenLiveActivityWindowManager(notchViewModel: c.notchViewModel, lockScreenManager: c.lockScreenManager, settingsViewModel: s, airDropViewModel: c.airDropViewModel, airDropController: c.airDropController)
        }, stop: { lockActivityPanel?.invalidate(); lockActivityPanel = nil })
    }
}
