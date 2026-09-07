import XCTest
@testable import ALONotchRuntime

@MainActor
final class NotchPowerEventsHandlerTests: XCTestCase {

    private func makeHandler() -> (NotchPowerEventsHandler, NotchViewModel, SettingsViewModel, PowerService, FakePowerEventSoundPlayer) {
        let suiteName = "NotchPowerEventsHandlerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settingsViewModel = SettingsViewModel(defaults: defaults)
        let notchViewModel = NotchViewModel(
            settings: settingsViewModel.application,
            hideDelay: 0.01,
            queueDelay: 0
        )
        let powerService = PowerService(startMonitoring: false)
        let soundPlayer = FakePowerEventSoundPlayer()

        let handler = NotchPowerEventsHandler(
            notchViewModel: notchViewModel,
            powerService: powerService,
            settingsViewModel: settingsViewModel,
            soundPlayer: soundPlayer
        )

        return (handler, notchViewModel, settingsViewModel, powerService, soundPlayer)
    }

    func testChargerEventPresentsChargerNotificationWhenEnabled() async {
        let (handler, notchViewModel, settingsViewModel, _, _) = makeHandler()
        settingsViewModel.battery.isChargerTemporaryActivityEnabled = true

        handler.handle(.charger)

        await assertEventually {
            await MainActor.run {
                notchViewModel.notchModel.temporaryNotificationContent?.id == NotchContentRegistry.Power.charger.id
            }
        }
    }

    func testChargerEventSuppressedWhenDisabledInSettings() async {
        let (handler, notchViewModel, settingsViewModel, _, _) = makeHandler()
        settingsViewModel.battery.isChargerTemporaryActivityEnabled = false

        handler.handle(.charger)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(notchViewModel.notchModel.temporaryNotificationContent)
    }

    func testLowPowerEventPresentsLowPowerNotificationWhenEnabled() async {
        let (handler, notchViewModel, settingsViewModel, _, soundPlayer) = makeHandler()
        settingsViewModel.battery.isLowPowerTemporaryActivityEnabled = true

        handler.handle(.lowPower)

        XCTAssertEqual(soundPlayer.playedEvents, [.lowPower])

        await assertEventually {
            await MainActor.run {
                notchViewModel.notchModel.temporaryNotificationContent?.id == NotchContentRegistry.Power.lowPower.id
            }
        }
    }

    func testLowPowerEventSuppressedWhenDisabledInSettings() async {
        let (handler, notchViewModel, settingsViewModel, _, _) = makeHandler()
        settingsViewModel.battery.isLowPowerTemporaryActivityEnabled = false

        handler.handle(.lowPower)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(notchViewModel.notchModel.temporaryNotificationContent)
    }

    func testFullPowerEventPresentsFullPowerNotificationWhenEnabled() async {
        let (handler, notchViewModel, settingsViewModel, _, soundPlayer) = makeHandler()
        settingsViewModel.battery.isFullPowerTemporaryActivityEnabled = true

        handler.handle(.fullPower)

        XCTAssertEqual(soundPlayer.playedEvents, [.fullPower])

        await assertEventually {
            await MainActor.run {
                notchViewModel.notchModel.temporaryNotificationContent?.id == NotchContentRegistry.Power.fullPower.id
            }
        }
    }

    func testFullPowerEventSuppressedWhenDisabledInSettings() async {
        let (handler, notchViewModel, settingsViewModel, _, _) = makeHandler()
        settingsViewModel.battery.isFullPowerTemporaryActivityEnabled = false

        handler.handle(.fullPower)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(notchViewModel.notchModel.temporaryNotificationContent)
    }
}

@MainActor
private final class FakePowerEventSoundPlayer: PowerEventSoundPlaying {
    private(set) var playedEvents: [PowerEvent] = []

    func play(_ event: PowerEvent) {
        playedEvents.append(event)
    }
}
