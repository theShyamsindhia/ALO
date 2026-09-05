import XCTest
@testable import ALONotchRuntime

@MainActor
final class VpnViewModelIntegrationTests: XCTestCase {
    func testExplicitStartAndStopControlMonitoring() {
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

    func testVPNConnectionStateProducesVpnEvent() {
        let monitor = FakeWifiMonitor()
        let viewModel = makeViewModel(monitor: monitor)

        monitor.send(wifi: false, hotspot: false, vpn: false)
        XCTAssertFalse(viewModel.vpnConnected)

        viewModel.vpnEvent = nil
        monitor.send(wifi: false, hotspot: false, vpn: true)

        XCTAssertEqual(viewModel.vpnEvent, .vpnConnected)
        XCTAssertTrue(viewModel.vpnConnected)
    }

    func testVPNConnectionStartDateTracksTunnelLifecycle() {
        let monitor = FakeWifiMonitor()
        let viewModel = makeViewModel(monitor: monitor)

        monitor.send(wifi: false, hotspot: false, vpn: false)
        XCTAssertNil(viewModel.vpnConnectedAt)

        monitor.send(wifi: false, hotspot: false, vpn: true)
        let initialConnectionDate = viewModel.vpnConnectedAt

        XCTAssertNotNil(initialConnectionDate)

        monitor.send(wifi: false, hotspot: false, vpn: true)
        XCTAssertEqual(viewModel.vpnConnectedAt, initialConnectionDate)

        monitor.send(wifi: false, hotspot: false, vpn: false)
        XCTAssertNil(viewModel.vpnConnectedAt)
    }

    func testVPNDisconnectionStateProducesVpnEvent() {
        let monitor = FakeWifiMonitor()
        let viewModel = makeViewModel(monitor: monitor)

        monitor.send(wifi: false, hotspot: false, vpn: true)
        XCTAssertTrue(viewModel.vpnConnected)

        viewModel.vpnEvent = nil
        monitor.send(wifi: false, hotspot: false, vpn: false)

        XCTAssertEqual(viewModel.vpnEvent, .vpnDisconnected)
        XCTAssertFalse(viewModel.vpnConnected)
    }
}

private extension VpnViewModelIntegrationTests {
    func makeViewModel(monitor: FakeWifiMonitor, startMonitoring: Bool = true) -> VpnViewModel {
        let suiteName = "VpnViewModelIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = ConnectivitySettingsStore(defaults: defaults)

        let viewModel = VpnViewModel(
            monitor: monitor,
            settings: settings
        )
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        if startMonitoring { viewModel.startMonitoring() }
        return viewModel
    }
}
