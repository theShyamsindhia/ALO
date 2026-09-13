import AppKit
import AVFoundation
import EventKit
import SwiftUI
import XCTest
@testable import ALONotchRuntime

@MainActor
final class RoomToolsTests: XCTestCase {
    func testStoppedToolOwnershipGraphReleasesFromNativeCallback() async {
        _ = NSApplication.shared
        let name = "RoomToolsOwnershipTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                weak var retainedContainer: AppContainer?
                weak var retainedActivation: FeatureActivation?
                weak var retainedFocus: FocusViewModel?
                weak var retainedHUD: HardwareHUDMonitor?
                autoreleasepool {
                    let container = AppContainer(isRunningUITests: true, defaults: defaults)
                    let activation = FeatureActivation(container: container)
                    activation.setEnabled(true)
                    activation.setEnabled(false)
                    XCTAssertTrue(activation.running.isEmpty)
                    retainedContainer = container
                    retainedActivation = activation
                    retainedFocus = container.focusViewModel
                    retainedHUD = container.hardwareHUDMonitor
                }
                XCTAssertNil(retainedActivation)
                XCTAssertNil(retainedContainer)
                XCTAssertNil(retainedFocus)
                XCTAssertNil(retainedHUD)
                continuation.resume()
            }
        }
    }

    func testEveryToolHasARouteAndOpeningItDoesNotOptIntoMonitoring() async throws {
        _ = NSApplication.shared
        let (container, defaults) = fixture()
        let activation = FeatureActivation(container: container)
        activation.setEnabled(true)
        defer { activation.setEnabled(false) }
        let cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        let calendarAuthorization = EKEventStore.authorizationStatus(for: .event)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = RoomToolStaging(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(RoomTool.allCases.count, 8)
        for width in [340.0, 540.0] {
            for selected in [nil] + RoomTool.allCases.map(Optional.some) {
                let view = RoomToolsView(container: container, staging: staging,
                    onShare: { _ in XCTFail("Rendering must not share files") },
                    onTransfers: { XCTFail("Rendering must not navigate") },
                    onStartTimer: { XCTFail("Rendering must not start a timer") }, selected: selected)
                try await render(view.defaultAppStorage(defaults),
                    name: "tools-\(selected?.id ?? "index")-\(Int(width))", width: width)
            }
        }
        XCTAssertTrue(activation.running.isEmpty)
        XCTAssertFalse(container.downloadViewModel.hasStartedMonitoring)
        XCTAssertFalse(container.calendarViewModel.isMonitoring)
        XCTAssertEqual(container.localTimerViewModel.state, .stopped)
        XCTAssertEqual(AVCaptureDevice.authorizationStatus(for: .video), cameraAuthorization)
        XCTAssertEqual(EKEventStore.authorizationStatus(for: .event), calendarAuthorization)
    }

    func testRoomCountdownSurvivesLegacyPageSettingsAndMasterOffStopsIt() throws {
        _ = NSApplication.shared
        let (container, _) = fixture()
        let activation = FeatureActivation(container: container)
        activation.setEnabled(true)
        defer { activation.setEnabled(false) }
        activation.retainRoomToolTimer()
        container.localTimerViewModel.start(hours: 0, minutes: 1, seconds: 0, repeatsCompletionSound: false)
        activation.setEnabled(true)
        XCTAssertEqual(container.localTimerViewModel.state, .running)
        XCTAssertFalse(container.settingsViewModel.homePage.isHomePageLiveActivityEnabled)
        XCTAssertFalse(container.localTimerViewModel.repeatsCompletionSound)
        container.localTimerViewModel.pause()
        activation.setEnabled(true)
        XCTAssertEqual(container.localTimerViewModel.state, .paused)
        activation.setEnabled(false)
        XCTAssertEqual(container.localTimerViewModel.state, .stopped)
        activation.setEnabled(true)
        XCTAssertEqual(container.localTimerViewModel.state, .stopped)
        XCTAssertTrue(activation.running.isEmpty)
    }

    func testRoomTimerCompletionUsesASingleChime() {
        let (container, _) = fixture()
        let sound = ToolTimerSound()
        let handler = NotchLocalTimerEventsHandler(notchViewModel: container.notchViewModel,
            localTimerViewModel: container.localTimerViewModel, timerViewModel: container.timerViewModel,
            settingsViewModel: container.settingsViewModel, timerSoundPlayer: sound)
        defer { container.notchViewModel.setActivityEventsEnabled(false); container.localTimerViewModel.stop() }
        container.localTimerViewModel.start(hours: 0, minutes: 1, seconds: 0, repeatsCompletionSound: false)
        handler.handleLocalTimerFinished()
        XCTAssertEqual(sound.loops, [false])
    }

    func testScreenshotCopiesAreBoundedAndLateWritesCannotOutliveRoomCleanup() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = RoomToolStaging(root: root)
        let data = try XCTUnwrap(sampleImage().tiffRepresentation)
        let id = UUID()
        let url = try await staging.stageTIFF(data, id: id)
        let duplicate = try await staging.stageTIFF(data, id: id)
        XCTAssertEqual(url, duplicate)
        XCTAssertNotNil(NSImage(contentsOf: url))
        for _ in 1..<32 { _ = try await staging.stageTIFF(data, id: UUID()) }
        do {
            _ = try await staging.stageTIFF(data, id: UUID())
            XCTFail("Staging must be bounded")
        } catch RoomToolStaging.StagingError.full { }
        try await staging.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        do {
            _ = try await staging.stageTIFF(data, id: UUID())
            XCTFail("Late work must not recreate a departed room’s copies")
        } catch RoomToolStaging.StagingError.ended { }
    }

    func testPreviewCopyDoesNotDismissDeleteOrConsumeTheSource() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.tiff")
        let image = sampleImage()
        let data = try XCTUnwrap(image.tiffRepresentation)
        try data.write(to: source)
        let model = ScreenshotViewModel()
        model.processNewScreenshot(image: image, fileURL: source, fileName: "source.tiff")
        let id = try XCTUnwrap(model.latestScreenshot?.id)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(model.copyPreviewImage(image, to: pasteboard))
        XCTAssertNotNil(model.activeScreenshot)
        XCTAssertFalse(model.isCopied, "Tool copy must not engage transient-preview deletion")
        XCTAssertEqual(try Data(contentsOf: source), data)
        model.activeScreenshot = nil
        XCTAssertEqual(model.latestScreenshot?.id, id, "Tools must remain useful after the preview disappears")
    }

    func testScreenshotAndConverterPopulatedStatesRender() async throws {
        let (container, defaults) = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = sampleImage()
        let source = root.appendingPathComponent("Shared concept.tiff")
        let original = try XCTUnwrap(image.tiffRepresentation)
        try original.write(to: source)
        container.screenshotViewModel.processNewScreenshot(image: image, fileURL: source, fileName: "Shared concept.tiff")
        try container.fileConverterViewModel.setFile(source)
        container.fileConverterViewModel.selectedFormat = .jpeg
        let staging = RoomToolStaging(root: root.appendingPathComponent("staging"))
        for width in [340.0, 540.0] {
            for selected in [RoomTool.screenshots, .converter] {
                let view = RoomToolsView(container: container, staging: staging, onShare: { _ in },
                    onTransfers: {}, onStartTimer: {}, selected: selected)
                try await render(view.defaultAppStorage(defaults), name: "tools-\(selected.id)-populated-\(Int(width))", width: width)
            }
        }
        var options = FileConverterConversionOptions()
        options.imageQuality = 0.75
        let output = try await FileConverterService.shared.convert(item: XCTUnwrap(container.fileConverterViewModel.item),
            to: .jpeg, options: options)
        XCTAssertNotEqual(output, source)
        XCTAssertNotNil(NSImage(contentsOf: output))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func fixture() -> (AppContainer, UserDefaults) {
        let name = "RoomToolsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (AppContainer(isRunningUITests: true, defaults: defaults), defaults)
    }

    private func sampleImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 320, height: 160))
        image.lockFocus()
        NSColor.darkGray.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 160).fill()
        ("Review the entrance" as NSString).draw(at: NSPoint(x: 20, y: 65),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.white])
        image.unlockFocus()
        return image
    }

    private func render<V: View>(_ view: V, name: String, width: CGFloat) async throws {
        let frame = NSRect(x: 0, y: 0, width: width, height: 410)
        let host = NSHostingView(rootView: view.padding(12).frame(width: width, height: frame.height)
            .environment(\.colorScheme, .dark).environment(\.locale, Locale(identifier: "en")).background(Color.black))
        let window = NSWindow(contentRect: frame.offsetBy(dx: -3000, dy: -3000),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1500)
        if let directory = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(name + ".png"))
        }
    }
}

@MainActor
private final class ToolTimerSound: TimerSoundPlaying {
    nonisolated deinit {}

    var isPlaying = false
    var loops: [Bool] = []
    func play(sound: TimerSound, isSoundEnabled: Bool, loop: Bool) { loops.append(loop); isPlaying = isSoundEnabled }
    func stop() { isPlaying = false }
}
