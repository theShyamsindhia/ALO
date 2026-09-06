import AppKit
import AVFoundation
import Contacts
import Darwin
import SwiftUI
import XCTest
@testable import ALONotchRuntime

@MainActor
final class RuntimePresentationTests: XCTestCase {
    func testOriginalSettingsAndToolsRenderWithoutActivatingFeatures() async throws {
        _ = NSApplication.shared
        let name = "ALONotchPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let container = AppContainer(isRunningUITests: true, defaults: defaults)
        _ = container.notchEventCoordinator
        let activation = FeatureActivation(container: container)
        activation.setEnabled(true)
        defer { activation.setEnabled(false) }
        let cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        let contactsAuthorization = CNContactStore.authorizationStatus(for: .contacts)
        let settings = container.settingsViewModel
        XCTAssertEqual(settings.homePage.homePageDisabled, Set(HomePages.allCases))
        XCTAssertTrue(activation.running.isEmpty)

        let pages: [(String, AnyView, CGSize)] = [
            ("settings-root", AnyView(SettingsRootView(container: container)), CGSize(width: 760, height: 590)),
            ("settings-embedded-root", AnyView(SettingsRootView(container: container, embedded: true)), CGSize(width: 560, height: 430)),
            ("settings-battery", AnyView(BatterySettingsView(batterySettings: settings.battery, appearanceSettings: settings.application)), CGSize(width: 550, height: 650)),
            ("settings-home-pages", AnyView(HomePageSettingsView(homePageSettings: settings.homePage, applicationSettings: settings.application)), CGSize(width: 550, height: 650)),
            ("settings-converter", AnyView(FileConverterSettingsView(mediaSettings: settings.mediaAndFiles)), CGSize(width: 550, height: 650)),
            ("tool-converter", AnyView(FileConverterHomePageView(fileConverterViewModel: container.fileConverterViewModel).background(Color.black)), CGSize(width: 460, height: 160)),
            ("tool-local-timer", AnyView(LocalTimerSetupNotchView(localTimerViewModel: container.localTimerViewModel).background(Color.black)), CGSize(width: 460, height: 170))
        ]
        for (name, page, size) in pages {
            try await render(page.defaultAppStorage(defaults).environment(\.locale, Locale(identifier: "en")).environment(\.colorScheme, .dark), name: name, size: size)
        }
        XCTAssertTrue(activation.running.isEmpty, "Rendering settings must not opt into a feature")
        XCTAssertNil(container.notchViewModel.notchModel.content)
        XCTAssertEqual(container.localTimerViewModel.state, .stopped)
        XCTAssertFalse(settings.mediaAndFiles.isFileConverterLiveActivityEnabled)
        XCTAssertFalse(settings.battery.isChargerTemporaryActivityEnabled)
        XCTAssertFalse(settings.homePage.isHomePageLiveActivityEnabled)
        XCTAssertEqual(AVCaptureDevice.authorizationStatus(for: .video), cameraAuthorization)
        XCTAssertEqual(CNContactStore.authorizationStatus(for: .contacts), contactsAuthorization)
    }

    func testPackagedLocalizationImagesSoundsAndMediaAdapterResolve() async throws {
        let bundle = NotchResources.bundle
        for key in ["settings.title", "settings.battery.charging.title", "settings.homePage.liveActivity.title", "settings.fileConverter.activity.title"] {
            let label = L10n.string(key, locale: Locale(identifier: "en"))
            XCTAssertFalse(label.isEmpty)
            XCTAssertNotEqual(label, key, "Missing translated label: \(key)")
        }
        for name in ["backgroundLight", "backgroundDark", "logo", "appleMail", "messages"] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "png"), "Missing native image: \(name)")
            XCTAssertNotNil(NSImage(contentsOf: url))
        }
        XCTAssertNotNil(bundle.url(forResource: "LowBatterySound", withExtension: "mp3"))
        let adapter = try XCTUnwrap(MediaRemoteAdapterResources.resolve(bundle: bundle))
        let resourceRoot = try XCTUnwrap(bundle.resourceURL).standardizedFileURL.path
        XCTAssertTrue(adapter.scriptURL.standardizedFileURL.path.hasPrefix(resourceRoot), "Must resolve packaged adapter, not source-tree fallback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: adapter.frameworkURL.appendingPathComponent("MediaRemoteAdapter").path))
    }

    func testEnabledMasterWithEveryFeatureOffHasNoBackgroundWork() async throws {
        let name = "ALONotchIdleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let container = AppContainer(isRunningUITests: true, defaults: defaults)
        _ = container.notchEventCoordinator
        let activation = FeatureActivation(container: container)
        activation.setEnabled(true)
        defer { activation.setEnabled(false) }
        // Let initial Combine deliveries settle before measuring idle work.
        try await Task.sleep(nanoseconds: 100_000_000)
        let before = usage()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = usage()
        let cpuSeconds = after.cpu - before.cpu
        print("Notch idle benchmark: 2s wall, \(cpuSeconds)s process CPU, peak RSS delta \(after.rss - before.rss) bytes")
        XCTAssertTrue(activation.running.isEmpty)
        XCTAssertFalse(container.powerService.isMonitoring)
        XCTAssertFalse(BluetoothService.shared.isMonitoring)
        XCTAssertFalse(container.wifiViewModel.isMonitoring)
        XCTAssertFalse(container.vpnViewModel.isMonitoring)
        XCTAssertFalse(container.calendarViewModel.isMonitoring)
        XCTAssertFalse(container.hardwareHUDMonitor.isMonitoring)
        XCTAssertFalse(container.downloadViewModel.hasStartedMonitoring)
        XCTAssertNil(container.notchViewModel.notchModel.content)
        // A loose ceiling catches a polling spin while allowing shared CI load.
        XCTAssertLessThan(cpuSeconds, 1.0, "Disabled feature engine should not consume half a CPU core")
    }

    private func usage() -> (cpu: Double, rss: Int64) {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        return (cpu, Int64(value.ru_maxrss))
    }

    private func render<V: View>(_ view: V, name: String, size: CGSize) async throws {
        let frame = NSRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12)))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 120_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: frame))
        host.cacheDisplay(in: frame, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        // A nonempty PNG is insufficient: reject blank/solid renders by checking
        // sampled color diversity across the actual rendered view.
        var colors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert(Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255))
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 12, "\(name) rendered blank or without meaningful UI content")
        if let directory = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name + ".png"))
        }
    }
}
