import XCTest
@testable import ALONotchRuntime

@MainActor
final class WifiViewModelIntegrationTests: XCTestCase {
    func testExplicitStartAndStopControlMonitoring() async {
        let monitor = FakeWifiMonitor()
        let viewModel = makeViewModel(monitor: monitor, startMonitoring: false)
        XCTAssertEqual(monitor.startCalls, 0)
        viewModel.startMonitoring()
        viewModel.startMonitoring()
        XCTAssertEqual(monitor.startCalls, 1)
        viewModel.stopMonitoring()
        XCTAssertEqual(monitor.stopCalls, 1)
        XCTAssertFalse(viewModel.isMonitoring)
    }

    func testInitialHotspotStateProducesHotspotEvent() async {
        let monitor = FakeWifiMonitor()
        let viewModel = makeViewModel(monitor: monitor)

        monitor.send(wifi: false, hotspot: true, vpn: false)

        XCTAssertEqual(viewModel.wifiEvent, .hotspotActive)
        XCTAssertTrue(viewModel.hotspotActive)
    }

    func testNetworkTransitionsProduceExpectedEvents() async {
        let monitor = FakeWifiMonitor()
        let viewModel = makeViewModel(monitor: monitor)

        monitor.send(wifi: false, hotspot: false, vpn: false)

        viewModel.wifiEvent = nil
        monitor.send(wifi: true, hotspot: false, vpn: false)
        XCTAssertEqual(viewModel.wifiEvent, .wifiConnected)

        viewModel.wifiEvent = nil
        monitor.send(wifi: false, hotspot: true, vpn: false)
        XCTAssertEqual(viewModel.wifiEvent, .hotspotActive)

        viewModel.wifiEvent = nil
        monitor.send(wifi: false, hotspot: false, vpn: false)
        XCTAssertEqual(viewModel.wifiEvent, .hotspotHide)
    }

    func testSwitchingFromHotspotToWifiProducesHotspotHideThenWifiConnected() async {
        let monitor = FakeWifiMonitor()
        let viewModel = makeViewModel(monitor: monitor)

        monitor.send(wifi: false, hotspot: true, vpn: false)
        XCTAssertEqual(viewModel.wifiEvent, .hotspotActive)
        XCTAssertTrue(viewModel.hotspotActive)
        XCTAssertFalse(viewModel.wifiConnected)

        viewModel.wifiEvent = nil
        monitor.send(wifi: true, hotspot: false, vpn: false, wifiName: "Home Wi-Fi")

        XCTAssertEqual(viewModel.wifiEvent, .hotspotHide)
        XCTAssertFalse(viewModel.hotspotActive)
        XCTAssertTrue(viewModel.wifiConnected)
        XCTAssertEqual(viewModel.wifiName, "Home Wi-Fi")

        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(viewModel.wifiEvent, .wifiConnected)
    }

    func testConnectedNetworkNamesAreUpdatedFromMonitor() async {
        let monitor = FakeWifiMonitor()
        let viewModel = makeViewModel(monitor: monitor)

        monitor.send(wifi: false, hotspot: false, vpn: false)
        monitor.send(
            wifi: true,
            hotspot: false,
            vpn: false,
            wifiName: "Office Wi-Fi"
        )

        XCTAssertEqual(viewModel.wifiName, "Office Wi-Fi")

        monitor.send(wifi: false, hotspot: false, vpn: false)

        XCTAssertEqual(viewModel.wifiName, "")
    }

    func testInternetBecomingUnavailableProducesNoInternetEvent() async {
        let monitor = FakeWifiMonitor()
        let viewModel = makeViewModel(monitor: monitor)

        monitor.send(wifi: true, hotspot: false, vpn: false, internetAvailable: true)

        viewModel.wifiEvent = nil
        monitor.send(wifi: false, hotspot: false, vpn: false, internetAvailable: false)

        XCTAssertEqual(viewModel.wifiEvent, .noInternetConnection)
        XCTAssertFalse(viewModel.isInternetAvailable)
        XCTAssertFalse(viewModel.wifiConnected)
        XCTAssertFalse(viewModel.hotspotActive)
    }

    func testInitialUnavailableInternetUpdatesStateWithoutShowingNotification() async {
        let monitor = FakeWifiMonitor()
        let viewModel = makeViewModel(monitor: monitor)

        monitor.send(wifi: false, hotspot: false, vpn: false, internetAvailable: false)

        XCTAssertNil(viewModel.wifiEvent)
        XCTAssertFalse(viewModel.isInternetAvailable)
    }
}

private extension WifiViewModelIntegrationTests {
    func makeViewModel(monitor: FakeWifiMonitor, startMonitoring: Bool = true) -> WifiViewModel {
        let suiteName = "WifiViewModelIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = ConnectivitySettingsStore(defaults: defaults)

        let viewModel = WifiViewModel(
            monitor: monitor,
            settings: settings
        )
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        if startMonitoring { viewModel.startMonitoring() }
        return viewModel
    }
}
