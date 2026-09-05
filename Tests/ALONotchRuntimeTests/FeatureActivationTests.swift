import AppKit
import XCTest
@testable import ALONotchRuntime

@MainActor
final class FeatureActivationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        // The lifecycle fixture includes AppKit services. Initialize the host on
        // MainActor before constructing them, including on headless CI runners.
        await MainActor.run { _ = NSApplication.shared }
    }

    func testMasterSwitchStopsAndRestoresOnlyExplicitlyEnabledFeatures() async {
        let name = "ALONotchRuntimeTests.Activation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let container = AppContainer(isRunningUITests: true, defaults: defaults)
        container.settingsViewModel.mediaAndFiles.isDownloadsLiveActivityEnabled = true
        let activation = FeatureActivation(container: container)
        defer { activation.setEnabled(false) }

        activation.setEnabled(false)
        XCTAssertTrue(activation.running.isEmpty)
        XCTAssertFalse(container.downloadViewModel.hasStartedMonitoring)

        activation.setEnabled(true)
        XCTAssertEqual(activation.running, ["downloads"])
        XCTAssertTrue(container.downloadViewModel.hasStartedMonitoring)
        XCTAssertFalse(container.powerService.isMonitoring)
        XCTAssertFalse(container.calendarViewModel.isMonitoring)

        activation.setEnabled(true)
        XCTAssertEqual(activation.running, ["downloads"])
        activation.setEnabled(false)
        XCTAssertTrue(activation.running.isEmpty)
        XCTAssertFalse(container.downloadViewModel.hasStartedMonitoring)
        XCTAssertTrue(container.settingsViewModel.mediaAndFiles.isDownloadsLiveActivityEnabled)

        activation.setEnabled(true)
        XCTAssertTrue(container.downloadViewModel.hasStartedMonitoring)
        container.settingsViewModel.mediaAndFiles.isDownloadsLiveActivityEnabled = false
        activation.setEnabled(true)
        XCTAssertTrue(activation.running.isEmpty)
        XCTAssertFalse(container.downloadViewModel.hasStartedMonitoring)
    }

    func testFeaturePreferenceAutomaticallyStartsAndStopsWhileMasterIsEnabled() async {
        let name = "ALONotchAutomaticActivationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let container = AppContainer(isRunningUITests: true, defaults: defaults)
        let settings = container.settingsViewModel
        XCTAssertTrue(settings.objectWillChange === settings.objectWillChange)
        let activation = FeatureActivation(container: container)
        defer { activation.setEnabled(false) }
        activation.setEnabled(true)
        XCTAssertFalse(container.downloadViewModel.hasStartedMonitoring)

        settings.mediaAndFiles.isDownloadsLiveActivityEnabled = true
        let startDeadline = Date().addingTimeInterval(2)
        while !container.downloadViewModel.hasStartedMonitoring && Date() < startDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(container.downloadViewModel.hasStartedMonitoring)
        XCTAssertEqual(activation.running, ["downloads"])

        settings.mediaAndFiles.isDownloadsLiveActivityEnabled = false
        let stopDeadline = Date().addingTimeInterval(2)
        while container.downloadViewModel.hasStartedMonitoring && Date() < stopDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(container.downloadViewModel.hasStartedMonitoring)
        XCTAssertTrue(activation.running.isEmpty)

        activation.setEnabled(false)
        settings.mediaAndFiles.isDownloadsLiveActivityEnabled = true
        // Let the queued settings notification reconcile while master is off.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(container.downloadViewModel.hasStartedMonitoring)
        XCTAssertTrue(activation.running.isEmpty)
    }

    func testAllActivitiesDefaultOffAndAllPagesOptIn() async {
        let name = "ALONotchRuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsViewModel(defaults: defaults)
        let keys = GeneralSettingsStorage.defaultValues.keys.filter {
            $0.hasPrefix("settings.live.") && !$0.contains("defaultStroke") ||
            $0.hasPrefix("settings.temporary.") && !$0.contains("Duration") && !$0.contains("duration") ||
            $0.hasSuffix(".liveActivity") ||
            $0.hasPrefix("settings.notifications.") && $0.hasSuffix(".enabled") ||
            ["settings.hud.volume", "settings.hud.keyboard", "settings.hud.brightness", LockScreenSettings.liveActivityKey, LockScreenSettings.mediaPanelKey, LockScreenSettings.soundKey].contains($0)
        }
        for key in keys where GeneralSettingsStorage.defaultValues[key] is Bool {
            XCTAssertFalse(defaults.bool(forKey: key), "Unexpected enabled default: \(key)")
        }
        XCTAssertEqual(settings.homePage.homePageDisabled, Set(HomePages.allCases))
        settings.homePage.resetHomePage()
        XCTAssertFalse(settings.homePage.isHomePageLiveActivityEnabled)
        XCTAssertEqual(settings.homePage.homePageDisabled, Set(HomePages.allCases))
    }

    func testMonitorConstructionIsInert() async {
        XCTAssertFalse(PowerService().isMonitoring)
        XCTAssertFalse(BluetoothService.shared.isMonitoring)
        XCTAssertFalse(CalendarViewModel().isMonitoring)
        let wifi = WifiViewModel()
        let vpn = VpnViewModel()
        XCTAssertFalse(wifi.isMonitoring)
        XCTAssertFalse(vpn.isMonitoring)
        let camera = CameraViewModel()
        XCTAssertFalse(camera.session.isRunning)
        XCTAssertTrue(camera.session.inputs.isEmpty)
    }

    func testFeaturePreferenceSurvivesSettingsRecreation() async {
        let name = "ALONotchRuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        SettingsViewModel(defaults: defaults).mediaAndFiles.isDownloadsLiveActivityEnabled = true
        let restored = SettingsViewModel(defaults: defaults)
        XCTAssertTrue(restored.mediaAndFiles.isDownloadsLiveActivityEnabled)
        XCTAssertFalse(restored.mediaAndFiles.isNowPlayingLiveActivityEnabled)
    }
}

extension FeatureActivationTests {
    func testMasterSwitchLeavesEveryMonitorIdleUntilOptIn() async {
        let name = "ALONotchRuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let container = AppContainer(isRunningUITests: true, defaults: defaults)
        _ = container.notchEventCoordinator
        let activation = FeatureActivation(container: container)
        activation.setEnabled(true)
        XCTAssertTrue(activation.running.isEmpty)
        XCTAssertFalse(container.powerService.isMonitoring)
        XCTAssertFalse(BluetoothService.shared.isMonitoring)
        XCTAssertFalse(container.wifiViewModel.isMonitoring)
        XCTAssertFalse(container.vpnViewModel.isMonitoring)
        XCTAssertFalse(container.calendarViewModel.isMonitoring)
        XCTAssertFalse(container.hardwareHUDMonitor.isMonitoring)
        XCTAssertEqual(container.localTimerViewModel.state, .stopped)
        activation.setEnabled(false)
        XCTAssertTrue(activation.running.isEmpty)
    }

    func testMasterStopsAndRestartsExplicitFeatureWithoutChangingPreference() async {
        let name = "ALONotchRuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let container = AppContainer(isRunningUITests: true, defaults: defaults)
        let activation = FeatureActivation(container: container)
        // InactiveDownloadMonitor exercises the real view model lifecycle without
        // observing Downloads or touching the user's file system.
        container.settingsViewModel.mediaAndFiles.isDownloadsLiveActivityEnabled = true
        activation.setEnabled(false)
        XCTAssertTrue(activation.running.isEmpty)
        activation.setEnabled(true)
        XCTAssertEqual(activation.running, ["downloads"])
        XCTAssertTrue(container.downloadViewModel.hasStartedMonitoring)
        activation.setEnabled(false)
        XCTAssertTrue(activation.running.isEmpty)
        XCTAssertFalse(container.downloadViewModel.hasStartedMonitoring)
        XCTAssertTrue(container.settingsViewModel.mediaAndFiles.isDownloadsLiveActivityEnabled)
        activation.setEnabled(true)
        XCTAssertEqual(activation.running, ["downloads"])
        XCTAssertTrue(container.downloadViewModel.hasStartedMonitoring)
        container.settingsViewModel.mediaAndFiles.isDownloadsLiveActivityEnabled = false
        activation.setEnabled(true)
        XCTAssertTrue(activation.running.isEmpty)
        activation.setEnabled(false)
    }

    func testCameraCannotStartAfterPageWasDisabled() async {
        let camera = CameraViewModel()
        camera.stopSession()
        camera.startSession()
        XCTAssertFalse(camera.isPageVisible)
        XCTAssertFalse(camera.session.isRunning)
        XCTAssertTrue(camera.session.inputs.isEmpty)
    }
}
