import AppKit
import SwiftUI
import Testing
import ALOCore
@testable import ALONotchRuntime
@testable import ALO

@Suite("Whole notch workspace layout", .serialized) @MainActor
struct NotchWorkspaceRenderTests {
    @Test func renderOriginalRoomShelfAndPrivateShelfInTheSharedShell() async throws {
        let suite = "NotchShelfRender.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Notes.txt")
        try Data("Review notes".utf8).write(to: file)
        let tray = FileTrayViewModel(defaults: defaults)
        tray.appendLocalShelfCopies([file])
        tray.applyRoomSnapshot(.init(items: [
            .init(id: "ready", fileName: "Notes.txt", byteCount: 12, localFileURL: file, transferState: .available),
            .init(id: "remote", fileName: "Room concept.png", byteCount: 500_000, transferState: .unavailable)
        ]))
        let settings = SettingsViewModel(defaults: defaults)
        try await renderInNotch(VStack(spacing: 10) {
            Label("Room shelf", systemImage: "tray.full.fill").font(.system(size: 12, weight: .semibold))
            Text("Shared with everyone").font(.caption).foregroundStyle(.secondary)
            TrayExpandedActiveNotchView(fileTrayViewModel: tray, mediaSettings: settings.mediaAndFiles, isEmbedded: true)
                .frame(height: 144)
        }, name: "notch-room-shelf", size: CGSize(width: 480, height: 290))
        try await renderInNotch(VStack(spacing: 10) {
            Label("My shelf", systemImage: "tray").font(.system(size: 12, weight: .semibold))
            LocalFileShelfView(model: tray)
        }, name: "notch-private-shelf", size: CGSize(width: 480, height: 290))
        #expect(tray.items.map(\.id) == ["ready", "remote"])
        #expect(tray.localShelfItems.count == 1)
    }

    @Test func renderEachToolInsideTheNotchMask() async throws {
        let suite = "NotchToolRender.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = AppContainer(isRunningUITests: true, defaults: defaults)
        defer { container.notchViewModel.setActivityEventsEnabled(false) }
        let staging = RoomToolStaging(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for selected in [nil] + RoomTool.allCases.map(Optional.some) {
            let tool = RoomToolsView(container: container, staging: staging, onShare: { _ in },
                onTransfers: {}, onStartTimer: {}, selected: selected)
            try await renderInNotch(VStack(spacing: 10) {
                Label("Tools", systemImage: "square.grid.2x2.fill").font(.system(size: 12, weight: .semibold))
                tool
            }, name: "notch-tool-\(selected?.rawValue ?? "index")",
               size: (selected == nil ? RoomNotchLayout.tray : .tool).size(display: CGSize(width: 1440, height: 900)))
        }
    }

    @Test func renderWorkspaceAndRecipientFlowAtBothWidths() async throws {
        _ = NSApplication.shared
        let model = ALOViewModel(discoverRooms: false)
        model.phase = .live
        model.roomName = "Design studio / #Main"
        model.participants = [.init(id: UUID().uuidString, name: "Raj"),
                              .init(id: UUID().uuidString, name: "Sammy")]
        model.messages = [.init(senderID: "raj", sender: "Raj", text: "Can we look at the entrance together?", sentNanos: 1),
                          .init(senderID: "sammy", sender: "Sammy", text: "Yes — I’ll share the image here.", sentNanos: 2)]
        let runtime = EmbeddedNotchRuntime()
        let navigation = NotchRoomNavigation()
        let sharing = DirectFileSharingController()
        defer { sharing.stop() }
        for displayWidth in [360.0, 1440.0] {
            let display = CGSize(width: displayWidth, height: 900)
            for page in NotchRoomNavigation.Page.allCases {
                navigation.page = page
                let view = ALONotchRoomWorkspace(model: model, navigation: navigation, runtime: runtime, close: {})
                try await renderInNotch(view, name: "workspace-\(page.rawValue)-\(Int(displayWidth))",
                                        size: navigation.layout.size(display: display))
            }
            for choosing in [false, true] {
                navigation.choosingRecipient = choosing
                let view = NotchRoomFiles(model: model, sharing: sharing, navigation: navigation,
                    runtime: runtime, downloads: model.roomTrayDownloads)
                try await renderInNotch(VStack(spacing: 10) {
                    Label("Files", systemImage: "tray.full.fill").font(.system(size: 12, weight: .semibold))
                    view
                }, name: "file-flow-\(choosing)-\(Int(displayWidth))",
                   size: (choosing ? RoomNotchLayout.recipients : .files).size(display: display))
            }
        }
        navigation.fileSection = 2
        navigation.composer.chosenMentionIDs = ["raj"]
        navigation.page = .conversation
        navigation.page = .files
        #expect(navigation.fileSection == 2)
        #expect(navigation.composer.chosenMentionIDs == ["raj"])
    }
}

/// Use the production surface, engine expansion, shape and content mask. A plain
/// rectangle missed the clipped headers and controls in the previous UI pass.
@MainActor
func renderInNotch<V: View>(_ view: V, name: String, size: CGSize) async throws {
    let suite = "NotchRender.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = SettingsViewModel(defaults: defaults)
    let notch = NotchViewModel(settings: settings.application, hideDelay: 0, queueDelay: 0,
        screenMetricsProvider: { _ in (width: 1440, topInset: 32, notchSize: CGSize(width: 190, height: 32)) })
    defer { notch.setActivityEventsEnabled(false) }
    let interaction = RoomInteractionModel()
    let measured = NotchRenderedBounds()
    interaction.content = AnyView(view.background(GeometryReader { geometry in
        Color.clear.onAppear { measured.rect = geometry.frame(in: .named("NotchRender")) }
    }))
    interaction.availableSize = size
    notch.send(.showLiveActivity(RoomInteractionContent(model: interaction)))
    let deadline = Date().addingTimeInterval(2)
    while notch.displayedContent == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    notch.expandActiveLiveActivity()
    try await Task.sleep(for: .milliseconds(750))
    #expect(notch.isDisplayingExpandedLiveActivity)
    #expect(notch.presentedNotchSize == size)
    let bounds = NSRect(origin: .zero, size: size)
    let host = NSHostingView(rootView: NotchSurfaceContainerView(notchViewModel: notch, settingsViewModel: settings)
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "NotchRender")
        .environment(\.colorScheme, .dark).defaultAppStorage(defaults))
    let window = NSWindow(contentRect: bounds.offsetBy(dx: -3000, dy: -3000),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear; window.isOpaque = false
    window.contentView = host; window.orderBack(nil)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    #expect(host.bounds.size == bounds.size)
    let contentBounds = try #require(measured.rect)
    #expect(contentBounds.minX >= 41.5)
    #expect(contentBounds.maxX <= size.width - 41.5)
    let mask = NotchShape(topCornerRadius: 22, bottomCornerRadius: 32)
        .path(in: CGRect(x: 5, y: 0, width: size.width - 10, height: size.height - 3))
    for x in [contentBounds.minX, contentBounds.maxX] {
        for y in [contentBounds.minY, contentBounds.maxY] {
            #expect(mask.contains(CGPoint(x: x, y: y)), "Content corner must remain within the actual notch mask")
        }
    }
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
    host.cacheDisplay(in: bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(png.count > 1_500)
    if let directory = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("\(name).png"))
    }
}

@MainActor private final class NotchRenderedBounds { var rect: CGRect? }
