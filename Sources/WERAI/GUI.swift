import AppKit
import AVFoundation
import Combine
import CoreGraphics
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import WERAICore

private enum ALOAppFlavor {
    static var isDevelopment: Bool {
        Bundle.main.bundleIdentifier == "in.werai.audio.dev"
    }

    static var displayName: String { isDevelopment ? "ALO Dev" : "ALO" }
    static var statusSymbol: String { isDevelopment ? "hammer.fill" : "cat.fill" }
    static var idleStatusSymbol: String { isDevelopment ? "hammer" : "cat" }
}

@MainActor
enum GUIApplication {
    private static var appDelegate: WERAIAppDelegate?

    static func run() {
        _ = BroadcastAudioRouter().recoverStaleRoute()
        let application = NSApplication.shared
        let delegate = WERAIAppDelegate()
        appDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
func makeALOEditMenu() -> NSMenu {
    let menu = NSMenu(title: "Edit")

    func addResponderItem(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        menu.addItem(item)
    }

    addResponderItem("Undo", action: Selector(("undo:")), key: "z")
    addResponderItem("Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
    menu.addItem(.separator())
    addResponderItem("Cut", action: #selector(NSText.cut(_:)), key: "x")
    addResponderItem("Copy", action: #selector(NSText.copy(_:)), key: "c")
    addResponderItem("Paste", action: #selector(NSText.paste(_:)), key: "v")
    addResponderItem(
        "Paste and Match Style",
        action: #selector(NSTextView.pasteAsPlainText(_:)),
        key: "v",
        modifiers: [.command, .option, .shift]
    )
    addResponderItem("Delete", action: #selector(NSText.delete(_:)))
    menu.addItem(.separator())
    addResponderItem("Select All", action: #selector(NSResponder.selectAll(_:)), key: "a")
    return menu
}

@MainActor
private final class WERAIAppDelegate: NSObject, NSApplicationDelegate {
    private enum SetupWindow {
        static let width: CGFloat = 440
        static let collapseDuration: TimeInterval = 0.28

        @MainActor static func height(for model: WERAIViewModel) -> CGFloat {
            switch model.phase {
            case .idle:
                guard model.mode == .listen else { return 260 }
                let roomCount = model.roomChoices.count
                let listHeight: CGFloat
                if roomCount == 0 {
                    listHeight = 170
                } else {
                    let visibleRows = min(roomCount, 4)
                    listHeight = CGFloat(visibleRows * 58 + max(0, visibleRows - 1))
                }
                let privateKeyHeight: CGFloat = model.selectedRoomConfiguration?.isPrivate == true
                    && model.selectedRoomConfiguration?.accessKey == nil ? 52 : 0
                return 184 + listHeight + privateKeyHeight
            case .starting:
                return 270
            case .failed:
                return 330
            case .live:
                return 270
            }
        }
    }

    private let model = WERAIViewModel()
    private let updater = AppUpdater()
    private var window: NSWindow?
    private var roomBarController: FloatingRoomWindowController?
    private var walkieTalkieBarController: WalkieTalkieWindowController?
    private var fullScreenVideoController: FullScreenVideoWindowController?
    private var statusMenuController: WERAIStatusMenuController?
    private var diagnosticsController: DiagnosticsWindowController?
    private var shortcutManager: GlobalShortcutManager?
    private var shortcutMapperController: ShortcutMapperWindowController?
    private var phaseObserver: AnyCancellable?
    private var fullScreenObserver: AnyCancellable?
    private var videoPinnedObserver: AnyCancellable?
    private var videoFullScreenToggleObserver: AnyCancellable?
    private var floatingBarObserver: AnyCancellable?
    private var walkieBarObserver: AnyCancellable?
    private var setupLayoutObserver: AnyCancellable?
    private var terminationSignalSources = [DispatchSourceSignal]()
    private var setupWindowFrame: NSRect?
    private var setupTransitionGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignalHandlers()
        installMainMenu()
        shortcutManager = GlobalShortcutManager { [weak self] action, pressed in
            self?.model.handleGlobalShortcut(action, pressed: pressed)
        }
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SetupWindow.width,
                height: SetupWindow.height(for: model)
            ),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ALOAppFlavor.displayName
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: WERAIView(model: model))
        window.center()
        setupWindowFrame = window.frame
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        statusMenuController = WERAIStatusMenuController(model: model) { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if !ALOAppFlavor.isDevelopment {
            updater.updateAvailableHandler = { [weak self] version in self?.presentUpdate(version: version) }
            updater.messageHandler = { [weak self] message in self?.presentUpdateMessage(message) }
            model.peerVersionHandler = { [weak updater] version in updater?.observePeerVersion(version) }
            updater.start()
        }

        phaseObserver = model.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                DispatchQueue.main.async { self?.updateWindows(for: phase) }
            }

        fullScreenObserver = model.$videoFullscreen
            .removeDuplicates()
            .sink { [weak self] enabled in
                DispatchQueue.main.async { self?.updateFullScreenVideo(enabled) }
            }

        videoPinnedObserver = model.$videoViewerPinned
            .removeDuplicates()
            .sink { [weak self] pinned in
                DispatchQueue.main.async { self?.fullScreenVideoController?.setPinned(pinned) }
            }

        videoFullScreenToggleObserver = model.$videoFullScreenToggle
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.fullScreenVideoController?.toggleFullScreen() }
            }

        floatingBarObserver = model.$floatingBarHidden
            .removeDuplicates()
            .sink { [weak self] hidden in
                DispatchQueue.main.async { self?.updateFloatingBar(hidden: hidden) }
            }

        walkieBarObserver = model.$walkieBarHidden
            .removeDuplicates()
            .sink { [weak self] hidden in
                DispatchQueue.main.async { self?.updateWalkieBar(hidden: hidden) }
            }

        setupLayoutObserver = Publishers.CombineLatest4(
            model.$mode.removeDuplicates(),
            model.$savedRooms,
            model.$nearbyRooms,
            model.$selectedRoomID.removeDuplicates()
        )
        .dropFirst()
        .sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeSetupWindow(animated: true) }
        }

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model.phase == .live {
            if model.videoFullscreen {
                fullScreenVideoController?.show()
            } else if model.floatingBarHidden {
                statusMenuController?.showPopover()
            } else {
                roomBarController?.show()
            }
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopImmediately()
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.model.stopImmediately()
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    private func updateWindows(for phase: WERAIViewModel.Phase) {
        guard phase == model.phase else { return }
        setupTransitionGeneration &+= 1
        if phase == .live {
            collapseSetupWindowIntoMenuBar(generation: setupTransitionGeneration)
        } else {
            statusMenuController?.closePopover()
            fullScreenVideoController?.close()
            fullScreenVideoController = nil
            roomBarController?.close()
            roomBarController = nil
            walkieTalkieBarController?.close()
            walkieTalkieBarController = nil
            restoreSetupWindow()
            resizeSetupWindow(animated: window?.isVisible == true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    private func collapseSetupWindowIntoMenuBar(generation: Int) {
        guard let window else { return }
        let finish = { [weak self] in
            guard let self, generation == self.setupTransitionGeneration, self.model.phase == .live else { return }
            window.orderOut(nil)
            self.restoreSetupWindow()
            self.updateFloatingBar(hidden: self.model.floatingBarHidden)
            self.updateWalkieBar(hidden: self.model.walkieBarHidden)
        }
        guard window.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let statusFrame = statusMenuController?.statusItemFrameOnScreen
        else {
            finish()
            return
        }

        setupWindowFrame = window.frame
        let targetSize = NSSize(width: 28, height: 22)
        let targetFrame = NSRect(
            x: statusFrame.midX - targetSize.width / 2,
            y: statusFrame.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SetupWindow.collapseDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.2, 1.0)
            window.animator().alphaValue = 0.08
            window.animator().setFrame(targetFrame, display: true)
        } completionHandler: {
            finish()
        }
    }

    private func restoreSetupWindow() {
        guard let window else { return }
        if let setupWindowFrame { window.setFrame(setupWindowFrame, display: false) }
        window.alphaValue = 1
    }

    private func resizeSetupWindow(animated: Bool) {
        guard model.phase != .live, let window else { return }
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: SetupWindow.width,
            height: SetupWindow.height(for: model)
        )
        var targetFrame = window.frameRect(forContentRect: contentRect)
        targetFrame.origin.x = window.frame.midX - targetFrame.width / 2
        targetFrame.origin.y = window.frame.maxY - targetFrame.height
        guard abs(window.frame.height - targetFrame.height) > 0.5 else {
            setupWindowFrame = targetFrame
            return
        }
        setupWindowFrame = targetFrame
        guard animated,
              window.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            window.setFrame(targetFrame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.2, 1.0)
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    private func updateFullScreenVideo(_ enabled: Bool) {
        guard enabled, model.phase == .live, model.roomHasVideo else {
            fullScreenVideoController?.close()
            fullScreenVideoController = nil
            if model.phase == .live, !model.floatingBarHidden { roomBarController?.show() }
            return
        }

        if fullScreenVideoController == nil {
            fullScreenVideoController = FullScreenVideoWindowController(model: model) { [weak model] in
                model?.exitVideoFullscreen()
            }
        }
        fullScreenVideoController?.setPinned(model.videoViewerPinned)
        fullScreenVideoController?.show()
    }

    private func updateFloatingBar(hidden: Bool) {
        guard model.phase == .live else { return }
        if hidden {
            roomBarController?.close()
            roomBarController = nil
        } else if !model.videoFullscreen {
            if roomBarController == nil {
                roomBarController = FloatingRoomWindowController(model: model)
            }
            roomBarController?.show()
        }
    }

    private func updateWalkieBar(hidden: Bool) {
        guard model.phase == .live else { return }
        if hidden {
            walkieTalkieBarController?.close()
            walkieTalkieBarController = nil
        } else {
            if walkieTalkieBarController == nil {
                walkieTalkieBarController = WalkieTalkieWindowController(model: model)
            }
            walkieTalkieBarController?.show()
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About ALO",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let updateItem = appMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        let diagnosticsItem = appMenu.addItem(
            withTitle: "Diagnostics…",
            action: #selector(showDiagnostics(_:)),
            keyEquivalent: "d"
        )
        diagnosticsItem.keyEquivalentModifierMask = [.command, .shift]
        diagnosticsItem.target = self
        let shortcutsItem = appMenu.addItem(
            withTitle: "Shortcut Mapper…",
            action: #selector(showShortcutMapper(_:)),
            keyEquivalent: ","
        )
        shortcutsItem.keyEquivalentModifierMask = [.command]
        shortcutsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit ALO",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        editMenuItem.submenu = makeALOEditMenu()

        NSApp.mainMenu = mainMenu
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates(userInitiated: true)
    }

    @objc func showDiagnostics(_ sender: Any?) {
        if diagnosticsController == nil {
            diagnosticsController = DiagnosticsWindowController(model: model)
        }
        diagnosticsController?.show()
    }

    @objc func showShortcutMapper(_ sender: Any?) {
        guard let shortcutManager else { return }
        if shortcutMapperController == nil {
            shortcutMapperController = ShortcutMapperWindowController(manager: shortcutManager, model: model)
        }
        shortcutMapperController?.show()
    }

    private func presentUpdate(version: String) {
        let alert = NSAlert()
        alert.messageText = "ALO \(version) is available"
        alert.informativeText = "ALO will download only the GitHub release and verify its checksum, Developer ID signature, and notarization before installation."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "View Release")
        switch alert.runModal() {
        case .alertFirstButtonReturn: updater.installAvailableUpdate()
        case .alertThirdButtonReturn: updater.openReleasePage()
        default: break
        }
    }

    private func presentUpdateMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ALO Updates"
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
private final class WERAIStatusMenuController: NSObject, NSPopoverDelegate {
    private let model: WERAIViewModel
    private let openMainWindow: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let badgeView = StatusUnreadBadgeView()
    private var observers = Set<AnyCancellable>()

    init(model: WERAIViewModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: ALOAppFlavor.statusSymbol,
            accessibilityDescription: ALOAppFlavor.displayName
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = ALOAppFlavor.displayName
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            badgeView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(badgeView)
            NSLayoutConstraint.activate([
                badgeView.widthAnchor.constraint(equalToConstant: 8),
                badgeView.heightAnchor.constraint(equalToConstant: 8),
                badgeView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                badgeView.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
            ])
        }

        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentSize = panelSize
        let popoverController = NSHostingController(
            rootView: VStack(spacing: 0) {
                FloatingRoomView(model: model, presentation: .menuBar)
                Divider()
                WalkieTalkieBar(model: model, showsCloseButton: false)
            }
            .background(Palette.opaqueSurface)
        )
        popoverController.view.wantsLayer = true
        popoverController.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        popover.contentViewController = popoverController

        model.$unreadMessageCount
            .removeDuplicates()
            .sink { [weak self] count in self?.updateBadge(count: count) }
            .store(in: &observers)
        model.$phase
            .removeDuplicates()
            .sink { [weak self] phase in self?.updatePhase(phase) }
            .store(in: &observers)
        Publishers.CombineLatest4(
            model.$walkieTalking.removeDuplicates(),
            model.$walkieStarting.removeDuplicates(),
            model.$openLineState.removeDuplicates(),
            model.$incomingWalkieSpeakerIDs.removeDuplicates()
        )
        .sink { [weak self] talking, starting, lineState, incoming in
            self?.updateVoiceIndicator(
                transmitting: talking || starting || lineState.isSendingMicrophone,
                receiving: !incoming.isEmpty
            )
        }
        .store(in: &observers)
        model.$floatingBarHidden
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in self?.closePopover() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: .aloWillPresentScreenPicker)
            .sink { [weak self] _ in self?.closePopover() }
            .store(in: &observers)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in self?.syncMotionPreference() }
            .store(in: &observers)
        Publishers.CombineLatest4(
            model.$floatingSection.removeDuplicates(),
            model.$permissionNotice.removeDuplicates(),
            model.$participants.map(\.count).removeDuplicates(),
            model.$incomingMessagePreview.map { $0?.id }.removeDuplicates()
        )
        .dropFirst()
        .sink { [weak self] _ in self?.resizePopover() }
        .store(in: &observers)
    }

    func showPopover() {
        guard model.phase == .live,
              let button = statusItem.button,
              !popover.isShown
        else { return }
        popover.contentSize = panelSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        model.setMenuBarPopoverVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    var statusItemFrameOnScreen: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func popoverDidClose(_ notification: Notification) {
        model.setMenuBarPopoverVisible(false)
    }

    @objc private func togglePopover() {
        guard model.phase == .live else {
            openMainWindow()
            return
        }
        popover.isShown ? closePopover() : showPopover()
    }

    private var panelSize: NSSize {
        NSSize(
            width: FloatingMetrics.width,
            height: model.floatingPanelHeight
                + FloatingMetrics.menuBarMediaHeight
                - FloatingMetrics.barHeight
                + FloatingMetrics.walkieBarHeight
                + FloatingMetrics.separatorHeight
        )
    }

    private func resizePopover() {
        guard popover.contentSize != panelSize else { return }
        popover.contentSize = panelSize
    }

    private func syncMotionPreference() {
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updateBadge(count: Int) {
        badgeView.isHidden = count == 0
        let detail = count == 0
            ? ALOAppFlavor.displayName
            : "\(ALOAppFlavor.displayName) · \(count) unread message\(count == 1 ? "" : "s")"
        statusItem.button?.toolTip = detail
        statusItem.button?.setAccessibilityLabel(detail)
    }

    private func updatePhase(_ phase: WERAIViewModel.Phase) {
        if phase != .live { closePopover() }
        statusItem.button?.image = NSImage(
            systemSymbolName: phase == .live ? ALOAppFlavor.statusSymbol : ALOAppFlavor.idleStatusSymbol,
            accessibilityDescription: ALOAppFlavor.displayName
        )
        statusItem.button?.image?.isTemplate = true
    }

    private func updateVoiceIndicator(transmitting: Bool, receiving: Bool) {
        statusItem.button?.contentTintColor = transmitting
            ? .systemOrange
            : receiving ? .systemGreen : nil
    }
}

private final class StatusUnreadBadgeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.cgColor
        layer?.cornerRadius = 4
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct RoomMessage: Identifiable, Equatable {
    let id = UUID()
    let senderID: String
    let sender: String
    let text: String
    let sentNanos: UInt64
}

private enum ChatScrollTarget: Hashable {
    case bottom
}

private enum FloatingMetrics {
    static let width: CGFloat = 560
    static let barHeight: CGFloat = 58
    static let menuBarMediaHeight: CGFloat = 88
    static let cornerRadius: CGFloat = 22
    static let windowInset: CGFloat = 4
    static var windowWidth: CGFloat { width + windowInset * 2 }
    static let separatorHeight: CGFloat = 1
    static let expansionDuration: TimeInterval = 0.24
    static let messagePreviewHeight: CGFloat = 116
    static let chatHeight: CGFloat = 380
    static let queueHeight: CGFloat = 392
    static let videoHeight: CGFloat = 476
    static let permissionHeight: CGFloat = 244
    static let walkieBarHeight: CGFloat = 50
    static let walkieDragHandleHeight: CGFloat = 16
    static let walkieBarMinWidth: CGFloat = 220
    static let walkieBarMaxWidth: CGFloat = 720

    static func walkieBarWidth(participantCount: Int) -> CGFloat {
        min(walkieBarMaxWidth, max(walkieBarMinWidth, CGFloat(participantCount) * 40 + 204))
    }

    static func windowHeight(for contentHeight: CGFloat) -> CGFloat {
        contentHeight + windowInset * 2
    }

    static func peopleHeight(count: Int) -> CGFloat {
        min(420, max(268, CGFloat(count * 64 + 148)))
    }
}

@MainActor
private final class DeviceIdentityEditorController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let saveAction: (String, String, String, Data?) -> Void
    private let closeAction: () -> Void

    init(
        name: String,
        icon: String,
        colorHex: String,
        profileImageData: Data?,
        saveAction: @escaping (String, String, String, Data?) -> Void,
        closeAction: @escaping () -> Void
    ) {
        self.saveAction = saveAction
        self.closeAction = closeAction
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Customize this Mac"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: DeviceIdentityEditorView(
                initialName: name,
                initialIcon: icon,
                initialColorHex: colorHex,
                initialProfileImageData: profileImageData,
                onSave: { [weak self] name, icon, color, photo in
                    self?.saveAction(name, icon, color, photo)
                    self?.panel.close()
                },
                onCancel: { [weak self] in self?.panel.close() }
            )
        )
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        closeAction()
    }
}

private struct DeviceIdentityEditorView: View {
    @State private var name: String
    @State private var icon: String
    @State private var colorHex: String
    @State private var profileImageData: Data?
    @State private var choosesPhoto = false
    @State private var photoError: String?
    @State private var nameError: String?
    @FocusState private var nameFocused: Bool

    let onSave: (String, String, String, Data?) -> Void
    let onCancel: () -> Void

    init(
        initialName: String,
        initialIcon: String,
        initialColorHex: String,
        initialProfileImageData: Data?,
        onSave: @escaping (String, String, String, Data?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _name = State(initialValue: initialName)
        _icon = State(initialValue: initialIcon)
        _colorHex = State(initialValue: initialColorHex)
        _profileImageData = State(initialValue: initialProfileImageData)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var normalizedName: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                DeviceAvatar(
                    emoji: icon,
                    colorHex: colorHex,
                    profileImageData: profileImageData,
                    size: 58
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(normalizedName.isEmpty ? "This Mac" : normalizedName)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text("This profile appears to everyone in your rooms.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Device name")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(name.count)/40")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                }
                TextField("e.g. Studio Mac", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Palette.composer)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(nameError == nil ? Palette.strokeStrong : Palette.red, lineWidth: 1)
                    )
                    .focused($nameFocused)
                    .accessibilityLabel("Device name")
                    .onChange(of: name) { _, newValue in
                        if newValue.count > 40 { name = String(newValue.prefix(40)) }
                        if !normalizedName.isEmpty { nameError = nil }
                    }
                if let nameError {
                    Text(nameError)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.red)
                }
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Emoji")
                        .font(.system(size: 11, weight: .semibold))
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(30), spacing: 5), count: 8),
                        spacing: 5
                    ) {
                        ForEach(DeviceAppearance.icons, id: \.self) { emoji in
                            Button { icon = emoji } label: {
                                Text(emoji)
                                    .font(.system(size: 16))
                                    .frame(width: 30, height: 30)
                                    .background(icon == emoji ? Palette.controlAccent.opacity(0.18) : Palette.messageSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(
                                                icon == emoji ? Palette.controlAccent : Palette.stroke,
                                                lineWidth: icon == emoji ? 2 : 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Device emoji \(emoji)")
                            .accessibilityValue(icon == emoji ? "Selected" : "")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Color")
                        .font(.system(size: 11, weight: .semibold))
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(29), spacing: 5), count: 4),
                        spacing: 5
                    ) {
                        ForEach(Array(DeviceAppearance.colors.enumerated()), id: \.element) { index, color in
                            Button { colorHex = color } label: {
                                Circle()
                                    .fill(Color.deviceIdentity(color))
                                    .frame(width: 21, height: 21)
                                    .overlay(
                                        Circle().stroke(
                                            colorHex == color ? Palette.ink : Palette.strokeStrong,
                                            lineWidth: colorHex == color ? 2 : 1
                                        )
                                    )
                                    .padding(3)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Profile color \(index + 1)")
                            .accessibilityValue(colorHex == color ? "Selected" : "")
                        }
                    }
                    .frame(width: 131)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Profile photo · optional")
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 10) {
                    Button(profileImageData == nil ? "Choose photo…" : "Change photo…") {
                        choosesPhoto = true
                    }
                    .buttonStyle(PillButtonStyle(filled: false))
                    if profileImageData != nil {
                        Button("Remove photo") {
                            profileImageData = nil
                            photoError = nil
                        }
                        .buttonStyle(PillButtonStyle(filled: false))
                    }
                    Spacer()
                    Text("Square crop · up to 128 px")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                }
                if let photoError {
                    Text(photoError)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.red)
                        .accessibilityLabel("Photo error: \(photoError)")
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle(filled: false))
                    .keyboardShortcut(.cancelAction)
                Button("Save changes") {
                    guard !normalizedName.isEmpty else {
                        nameError = "Enter a device name."
                        nameFocused = true
                        return
                    }
                    onSave(normalizedName, icon, colorHex, profileImageData)
                }
                .buttonStyle(PillButtonStyle(filled: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 44)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(width: 480, height: 430)
        .background(AmbientBackground(isLive: false))
        .tint(Palette.controlAccent)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { nameFocused = true }
        }
        .fileImporter(isPresented: $choosesPhoto, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                profileImageData = try DeviceProfileImage.normalizedData(from: Data(contentsOf: url))
                photoError = nil
            } catch is CancellationError {
                return
            } catch {
                photoError = error.localizedDescription
            }
        }
    }
}

@MainActor
final class WERAIViewModel: ObservableObject {
    var peerVersionHandler: (String) -> Void = { _ in }
    enum Mode: String, CaseIterable {
        case share = "Create Room"
        case listen = "Rooms"
    }

    enum Phase: Equatable {
        case idle
        case starting
        case live
        case failed
    }

    enum Experience: String {
        case audio
        case video
    }

    enum FloatingSection: Equatable {
        case collapsed
        case queue
        case chat
        case people
        case video
    }

    enum VideoControlIntent: Equatable {
        case unavailable
        case toggleViewer
        case showViewer
        case enableVideo
        case beginAudioAndVideoBroadcast
    }

    @Published var mode: Mode = .listen
    @Published var phase: Phase = .idle
    @Published var roomName = "My Room"
    @Published var nearbyRooms = [NearbyRoom]()
    @Published var savedRooms = [RoomConfiguration]()
    @Published var selectedRoomID: String?
    @Published var createPrivateRoom = false
    @Published var privateRoomKey = ""
    @Published var statusText = "Ready"
    @Published var errorMessage: String?
    @Published var errorIsPermissionRelated = false
    @Published var participants = [RoomParticipant]()
    @Published var messages = [RoomMessage]()
    @Published var draftMessage = ""
    @Published var unreadMessageCount = 0
    @Published private(set) var firstUnreadMessageID: UUID?
    @Published private(set) var incomingMessagePreview: RoomMessage?
    @Published var mediaQueue = [RoomQueueItem]()
    @Published var queueURL = ""
    @Published var queueNotice: String?
    @Published var videoFrame: CGImage?
    @Published var videoFullscreen = false
    @Published var videoViewerPinned = false
    @Published var videoFullScreenToggle = 0
    @Published var currentUserName = "This Mac"
    @Published var currentDeviceIcon = DeviceAppearance.icons[0]
    @Published var currentDeviceColorHex = DeviceAppearance.colors[0]
    @Published var currentDeviceProfileImageData: Data?
    @Published var currentParticipantID: String?
    /// Menu-bar selections remain live until they are clicked again. The
    /// floating bar keeps a separate, momentary push-to-talk selection.
    @Published private(set) var latchedTalkTargetIDs = Set<String>()
    @Published private(set) var pushToTalkTargetIDs = Set<String>()
    @Published private(set) var walkieTalking = false
    @Published private(set) var walkieStarting = false
    @Published private(set) var incomingWalkieSpeakerIDs = Set<String>()
    @Published private(set) var openLineState: OpenLineState = .idle
    @Published private(set) var voiceInputDevices = [VoiceInputDevice]()
    @Published var selectedVoiceInputUID: String?
    @Published var walkieBarHidden: Bool
    @Published var incomingMediaMuted: Bool
    @Published var incomingCallsMuted: Bool
    @Published var roomHasVideo = false
    @Published var nowPlaying = NowPlayingMedia()
    @Published private(set) var roomAccentHex: String?
    @Published var localNowPlaying = NowPlayingMedia()
    @Published private(set) var audioIsRendering = false
    @Published var experience: Experience = .audio
    @Published var mediaSwitchBusy = false
    @Published var permissionNotice = false
    @Published private(set) var recordingRestartRequired = false
    @Published var floatingSection: FloatingSection = .collapsed
    @Published var floatingBarHidden: Bool
    @Published private(set) var menuBarPopoverVisible = false

    private var roomBrowser: MeshRoomBrowser!
    private var meshSession: MeshSession?
    private var requestedVideoBroadcast = false
    private var videoBroadcastTimeoutTask: Task<Void, Never>?
    private let roomStore = RoomStore()
    private let lastJoinedRoomStore = LastJoinedRoomStore()
    private let nodeID: String
    private var localNowPlayingMonitor: NowPlayingMonitor?
    private var deviceIdentityEditor: DeviceIdentityEditorController?
    private var incomingMessagePreviewTask: Task<Void, Never>?
    private var openLineInvitationTimeoutTask: Task<Void, Never>?
    private var screenRecordingRequestAttempted = false
    private var activeRoom: String?
    private var activeRoomConfiguration: RoomConfiguration?
    private var isLeavingRoom = false
    private var walkieGeneration = 0
    private var globalShortcutTalkTargets = [GlobalShortcutAction: Set<String>]()
    private static let floatingBarPreferenceKey = "floatingBarHidden"
    private static let walkieBarPreferenceKey = "walkieBarHidden"
    private static let incomingMediaMutedKey = "incomingMediaMuted"
    private static let incomingCallsMutedKey = "incomingCallsMuted"
    private static let voiceInputUIDKey = "voiceInputUID"
    private static let deviceProfileImageKey = "meshDeviceProfileImageData"

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "meshNodeID") {
            nodeID = stored
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: "meshNodeID")
            nodeID = generated
        }
        if let savedName = defaults.string(forKey: "meshDeviceDisplayName"), !savedName.isEmpty {
            currentUserName = savedName
        } else {
            let generatedName = DeviceDisplayName.generated(from: nodeID)
            defaults.set(generatedName, forKey: "meshDeviceDisplayName")
            currentUserName = generatedName
        }
        let generatedAppearance = DeviceAppearance.generated(from: nodeID)
        let savedIcon = defaults.string(forKey: "meshDeviceIcon")
        let migratedIcon = savedIcon.flatMap { DeviceAppearance.icons.contains($0) ? $0 : nil }
            ?? generatedAppearance.icon
        let savedAppearance = DeviceAppearance(
            icon: migratedIcon,
            colorHex: defaults.string(forKey: "meshDeviceColorHex") ?? generatedAppearance.colorHex
        )
        currentDeviceIcon = savedAppearance.icon
        currentDeviceColorHex = savedAppearance.colorHex
        defaults.set(savedAppearance.icon, forKey: "meshDeviceIcon")
        currentDeviceProfileImageData = defaults.data(forKey: Self.deviceProfileImageKey)
        savedRooms = roomStore.load()
        floatingBarHidden = defaults.object(forKey: Self.floatingBarPreferenceKey) == nil
            ? true
            : defaults.bool(forKey: Self.floatingBarPreferenceKey)
        walkieBarHidden = defaults.bool(forKey: Self.walkieBarPreferenceKey)
        incomingMediaMuted = defaults.bool(forKey: Self.incomingMediaMutedKey)
        incomingCallsMuted = defaults.bool(forKey: Self.incomingCallsMutedKey)
        voiceInputDevices = VoiceInputCatalog.availableDevices()
        let savedVoiceInput = defaults.string(forKey: Self.voiceInputUIDKey)
        selectedVoiceInputUID = voiceInputDevices.contains(where: {
            $0.id == savedVoiceInput && !$0.isSystemDefault
        })
            ? savedVoiceInput
            : nil
        selectedRoomID = savedRooms.first?.id
        roomBrowser = MeshRoomBrowser(
            updateHandler: { [weak self] rooms in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.nearbyRooms = rooms
                    if self.selectedRoomID == nil || !self.roomChoices.contains(where: { $0.id == self.selectedRoomID }) {
                        self.selectedRoomID = rooms.first?.id ?? self.savedRooms.first?.id
                    }
                }
            },
            errorHandler: { [weak self] message in
                DispatchQueue.main.async { self?.statusText = "Local network unavailable: \(message)" }
            }
        )
        roomBrowser.start()
        if let room = lastJoinedRoomStore.roomToRestore(from: savedRooms) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase == .idle else { return }
                self.selectedRoomID = room.id
                self.open(room, broadcastInitially: false)
            }
        }
    }

    var normalizedRoomName: String { roomName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canStartSharing: Bool { phase == .idle && !normalizedRoomName.isEmpty }
    var canJoin: Bool { phase == .idle && selectedRoomID != nil }
    var roomTitle: String { activeRoom ?? selectedRoomConfiguration?.name ?? normalizedRoomName }
    var isHost: Bool { meshSession?.isBroadcasting == true }
    var hasBroadcaster: Bool { meshSession?.hasBroadcaster == true }
    var selectedRoomConfiguration: RoomConfiguration? {
        guard let id = selectedRoomID else { return nil }
        if let saved = savedRooms.first(where: { $0.id == id }) { return saved }
        guard let nearby = nearbyRooms.first(where: { $0.id == id }) else { return nil }
        return RoomConfiguration(id: nearby.id, name: nearby.name, isPrivate: nearby.isPrivate)
    }
    var roomChoices: [RoomConfiguration] {
        var result = savedRooms
        for nearby in nearbyRooms where !result.contains(where: { $0.id == nearby.id }) {
            result.append(RoomConfiguration(id: nearby.id, name: nearby.name, isPrivate: nearby.isPrivate))
        }
        return result
    }
    var activePrivateInviteKey: String? {
        guard activeRoomConfiguration?.isPrivate == true else { return nil }
        return activeRoomConfiguration?.accessKey
    }
    var roomIsPlaying: Bool {
        Self.effectivePlaybackState(
            metadataIsPlaying: nowPlaying.isPlaying,
            audioIsRendering: audioIsRendering,
            hasMedia: !nowPlaying.isEmpty
        )
    }
    var roomAccentColor: Color {
        roomAccentHex.map(Color.deviceIdentity) ?? Palette.controlAccent
    }
    var roomSyncLabel: String {
        if !hasBroadcaster { return "No broadcaster" }
        if nowPlaying.isPlaying == false { return "Paused" }
        if isHost { return nowPlaying.isEmpty ? "Waiting for audio" : "Broadcasting" }
        if audioIsRendering { return "Synced" }
        return nowPlaying.isEmpty ? "Waiting for audio" : "Recovering audio…"
    }
    var canSelectVideo: Bool { phase == .live && meshSession != nil }
    var videoControlHelp: String {
        if mediaSwitchBusy { return "Preparing audio and video broadcast" }
        switch videoControlIntent {
        case .unavailable: return "Video is unavailable while the room opens"
        case .toggleViewer, .showViewer: return "View shared video"
        case .enableVideo: return "Broadcast video with room audio"
        case .beginAudioAndVideoBroadcast:
            return hasBroadcaster
                ? "Take over and broadcast audio and video"
                : "Broadcast audio and video"
        }
    }
    var videoControlIntent: VideoControlIntent {
        Self.videoControlIntent(
            isLive: phase == .live && meshSession != nil,
            isHost: isHost,
            roomHasVideo: roomHasVideo,
            experience: experience,
            mediaSwitchBusy: mediaSwitchBusy
        )
    }
    var floatingPanelHeight: CGFloat {
        if permissionNotice { return FloatingMetrics.permissionHeight }
        switch floatingSection {
        case .collapsed:
            return incomingMessagePreview == nil
                ? FloatingMetrics.barHeight
                : FloatingMetrics.messagePreviewHeight
        case .queue: return FloatingMetrics.queueHeight
        case .chat: return FloatingMetrics.chatHeight
        case .people: return FloatingMetrics.peopleHeight(count: participants.count)
        case .video: return FloatingMetrics.videoHeight
        }
    }

    func startSharing() {
        guard canStartSharing else { return }
        resetRoomState()
        let room = RoomConfiguration(
            name: normalizedRoomName,
            creatorPeerID: nodeID,
            isPrivate: createPrivateRoom,
            accessKey: createPrivateRoom ? UUID().uuidString : nil
        )
        do { try roomStore.save(room); savedRooms = roomStore.load() }
        catch { errorMessage = "Could not save the room: \(error.localizedDescription)"; return }
        open(room, broadcastInitially: false)
    }

    func joinSelectedRoom() {
        guard canJoin, let room = selectedRoomConfiguration else { return }
        if room.isPrivate {
            let enteredKey = privateRoomKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = room.accessKey ?? (enteredKey.isEmpty ? nil : enteredKey) else {
                errorMessage = "Enter this private room's invite key."
                return
            }
            if let advertisedProof = nearbyRooms.first(where: { $0.id == room.id })?.accessProof,
               MeshControlPlane.makeAccessProof(roomID: room.id, accessKey: key) != advertisedProof {
                errorMessage = "That invite key does not match this private room."
                return
            }
            let unlocked = RoomConfiguration(
                id: room.id,
                name: room.name,
                creatorPeerID: room.creatorPeerID,
                isPrivate: true,
                accessKey: key
            )
            try? roomStore.save(unlocked)
            savedRooms = roomStore.load()
            open(unlocked, broadcastInitially: false)
        } else { open(room, broadcastInitially: false) }
    }

    func forgetRoom(roomID: String) {
        do {
            lastJoinedRoomStore.clear(ifMatching: roomID)
            try roomStore.forget(roomID: roomID)
            savedRooms = roomStore.load()
            if selectedRoomID == roomID {
                selectedRoomID = nearbyRooms.first?.id ?? savedRooms.first?.id
            }
        } catch {
            errorMessage = "Could not forget the room: \(error.localizedDescription)"
        }
    }

    func copyPrivateInviteKey() {
        guard let key = activePrivateInviteKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        statusText = "Private room invite key copied"
    }

    private func open(_ room: RoomConfiguration, broadcastInitially: Bool) {
        resetRoomState()
        let session = MeshSession(
            room: room,
            nodeID: nodeID,
            displayName: currentUserName,
            deviceIcon: currentDeviceIcon,
            deviceColorHex: currentDeviceColorHex,
            profileImageData: currentDeviceProfileImageData,
            initialEvents: roomStore.loadEvents(roomID: room.id),
            statusHandler: { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.statusText = status
                    if let rendering = Self.renderingState(for: status) {
                        self.audioIsRendering = rendering
                    }
                    if self.phase == .starting, !self.isLeavingRoom { self.phase = .live }
                    self.updateLocalNowPlayingMonitor()
                }
            },
            identityHandler: identityCallback,
            participantsHandler: participantCallback,
            mediaStateHandler: mediaStateCallback,
            nowPlayingHandler: nowPlayingCallback,
            chatHandler: chatCallback,
            queueHandler: queueCallback,
            videoHandler: videoCallback,
            peerVersionHandler: { [weak self] version in self?.peerVersionHandler(version) },
            errorHandler: { [weak self] error in
                guard let self else { return }
                let permissionRelated = self.isPermissionError(error)
                self.errorIsPermissionRelated = permissionRelated
                self.phase = .live
                self.audioIsRendering = false
                self.mediaSwitchBusy = false
                self.requestedVideoBroadcast = false
                self.videoBroadcastTimeoutTask?.cancel()
                self.videoBroadcastTimeoutTask = nil
                self.permissionNotice = permissionRelated
                self.errorMessage = permissionRelated ? nil : self.readable(error)
                self.statusText = permissionRelated
                    ? "Recording access is needed to broadcast"
                    : "Broadcast could not start: \(self.readable(error))"
                self.updateLocalNowPlayingMonitor()
            },
            walkieTalkieStateHandler: { [weak self] senderID, senderName, active in
                guard let self else { return }
                guard !self.incomingCallsMuted else {
                    self.incomingWalkieSpeakerIDs.removeAll()
                    return
                }
                if active {
                    self.incomingWalkieSpeakerIDs.insert(senderID)
                    self.statusText = "\(senderName) is talking to you"
                } else {
                    self.incomingWalkieSpeakerIDs.remove(senderID)
                    if self.incomingWalkieSpeakerIDs.isEmpty { self.statusText = "Talk is off" }
                }
            },
            walkieTalkieTransmissionEndedHandler: { [weak self] error in
                guard let self else { return }
                self.walkieGeneration += 1
                self.walkieTalking = false
                self.walkieStarting = false
                self.latchedTalkTargetIDs.removeAll()
                self.pushToTalkTargetIDs.removeAll()
                self.globalShortcutTalkTargets.removeAll()
                self.errorMessage = self.readable(error)
                self.statusText = "Talk stopped"
            },
            incomingOpenLineInvitationHandler: { [weak self] invitation in
                guard let self else { return }
                self.statusText = "\(invitation.callerName) invited you to open a line"
            },
            openLineStateHandler: { [weak self] state in
                guard let self else { return }
                self.openLineState = state
                self.openLineInvitationTimeoutTask?.cancel()
                self.openLineInvitationTimeoutTask = nil
                switch state {
                case .idle:
                    if self.incomingWalkieSpeakerIDs.isEmpty { self.statusText = "Talk is off" }
                case .inviting(let invitation):
                    self.statusText = "Waiting for \(self.openLinePeerName(invitation)) to join the line"
                    self.scheduleOpenLineInvitationTimeout(invitation, incoming: false)
                case .connected(let invitation):
                    self.statusText = "Line open with \(self.openLinePeerName(invitation))"
                case .invited(let invitation):
                    self.scheduleOpenLineInvitationTimeout(invitation, incoming: true)
                }
            },
            replicaPersistenceHandler: { [weak self] replica in
                self?.roomStore.saveEvents(replica.events, roomID: room.id)
            }
        )
        activeRoom = room.name
        activeRoomConfiguration = room
        phase = .starting
        statusText = "Opening \(room.name)"
        roomBrowser.stop()
        meshSession = session
        session.setIncomingMediaMuted(incomingMediaMuted)
        session.setIncomingWalkieTalkieMuted(incomingCallsMuted)
        do {
            try session.start(broadcastInitially: broadcastInitially)
            try? roomStore.save(room)
            lastJoinedRoomStore.markJoined(room)
            savedRooms = roomStore.load()
            phase = .live
            statusText = broadcastInitially ? "Starting this Mac's broadcast" : "Room open"
            updateLocalNowPlayingMonitor()
        } catch {
            meshSession = nil
            phase = .failed
            errorMessage = readable(error)
            statusText = "Could not open the room"
            roomBrowser.start()
        }
    }

    func selectExperience(_ selection: Experience) {
        guard selection != experience, !mediaSwitchBusy else { return }
        if !isHost {
            guard selection == .audio || roomHasVideo else { return }
            experience = selection
            floatingSection = selection == .video ? .video : .collapsed
            return
        }

        if selection == .video, !ensureScreenRecordingPermission() { return }
        mediaSwitchBusy = true
        if selection == .video { statusText = "Choose a display or window to share" }
        Task {
            do {
                try await meshSession?.setVideoEnabled(selection == .video)
                experience = selection
                floatingSection = selection == .video ? .video : .collapsed
                statusText = selection == .video
                    ? "The selected display or window is live"
                    : "Audio room active"
            } catch is CancellationError {
                statusText = "Video sharing cancelled"
            } catch {
                errorMessage = readable(error)
                permissionNotice = isPermissionError(error)
                statusText = permissionNotice
                    ? "Recording access is needed to broadcast video"
                    : "Video broadcast could not start: \(readable(error))"
            }
            mediaSwitchBusy = false
        }
    }

    static func videoControlIntent(
        isLive: Bool,
        isHost: Bool,
        roomHasVideo: Bool,
        experience: Experience,
        mediaSwitchBusy: Bool
    ) -> VideoControlIntent {
        guard isLive, !mediaSwitchBusy else { return .unavailable }
        if roomHasVideo { return experience == .video ? .toggleViewer : .showViewer }
        return isHost ? .enableVideo : .beginAudioAndVideoBroadcast
    }

    private func beginAudioAndVideoBroadcast() {
        guard !mediaSwitchBusy, ensureScreenRecordingPermission(), let meshSession else { return }
        mediaSwitchBusy = true
        requestedVideoBroadcast = true
        audioIsRendering = false
        stopLocalNowPlayingMonitor()
        statusText = hasBroadcaster
            ? "Taking over room audio and preparing full-screen sharing"
            : "Starting audio and video broadcast"
        meshSession.beginBroadcasting(videoEnabled: true)
        videoBroadcastTimeoutTask?.cancel()
        videoBroadcastTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.requestedVideoBroadcast else { return }
            self.requestedVideoBroadcast = false
            self.mediaSwitchBusy = false
            self.statusText = "Video broadcast did not start · try again"
            self.errorMessage = "ALO could not finish taking over audio and starting full-screen sharing."
            self.videoBroadcastTimeoutTask = nil
            Task { try? await self.meshSession?.setVideoEnabled(false) }
        }
    }

    func setParticipantVolume(_ participant: RoomParticipant, volume: Double) {
        updateParticipant(participant.id, volume: volume, muted: participant.isMuted)
        if isHost {
            meshSession?.setParticipantLevel(id: participant.id, volume: volume, muted: participant.isMuted)
        } else if participant.id == currentParticipantID {
            meshSession?.setLocalLevel(volume: volume, muted: participant.isMuted)
        }
    }

    func toggleParticipantMute(_ participant: RoomParticipant) {
        let muted = !participant.isMuted
        updateParticipant(participant.id, volume: participant.volume, muted: muted)
        if isHost {
            meshSession?.setParticipantLevel(id: participant.id, volume: participant.volume, muted: muted)
        } else if participant.id == currentParticipantID {
            meshSession?.setLocalLevel(volume: participant.volume, muted: muted)
        }
    }

    func toggleRoomPlayback() {
        if meshSession?.sendMediaCommand(.togglePlayPause) != true {
            statusText = "Wait for the broadcaster connection, then try again"
        }
    }

    func toggleBroadcasting() {
        guard !mediaSwitchBusy else { return }
        if isHost { meshSession?.stopBroadcasting() }
        else {
            guard ensureScreenRecordingPermission() else { return }
            audioIsRendering = false
            stopLocalNowPlayingMonitor()
            meshSession?.beginBroadcasting()
        }
    }

    func sendRoomMediaCommand(_ command: RoomMediaCommand) {
        _ = meshSession?.sendMediaCommand(command)
    }

    func syncParticipant(_ participant: RoomParticipant) {
        if meshSession?.requestResync(participantID: participant.id) == true {
            statusText = "Syncing \(participant.id == currentParticipantID ? "this Mac" : participant.name)"
        } else {
            statusText = "Wait for the audio connection, then try syncing again"
        }
    }

    func syncAllDevices() {
        if meshSession?.requestResync() == true {
            statusText = "Syncing listeners to the broadcaster"
        } else {
            statusText = "Wait for the audio connection, then try syncing again"
        }
    }

    func globalShortcutAvailability(_ action: GlobalShortcutAction) -> GlobalShortcutAvailability {
        guard phase == .live, meshSession != nil else {
            return .unavailable("Available while a room is open")
        }
        switch action.kind {
        case .talkToEveryone:
            return currentRemoteParticipantIDs.isEmpty
                ? .unavailable("No other device is in the room")
                : .ready
        case .talkToDevice:
            guard let participantID = action.participantID,
                  currentRemoteParticipantIDs.contains(participantID)
            else { return .unavailable("This device is not currently in the room") }
            return .ready
        case .shareScreen:
            if mediaSwitchBusy { return .unavailable("Screen sharing is already changing") }
            if roomHasVideo { return .unavailable(isHost ? "Your screen is already shared" : "Another device is sharing") }
            return .ready
        case .broadcastAudio:
            if mediaSwitchBusy { return .unavailable("The broadcast is already changing") }
            return isHost ? .unavailable("This Mac is already broadcasting") : .ready
        case .stopAudioBroadcast:
            return isHost ? .ready : .unavailable("This Mac is not broadcasting")
        case .stopScreenShare:
            return isHost && roomHasVideo ? .ready : .unavailable("This Mac is not sharing a screen")
        case .syncMyDevice:
            if isHost { return .unavailable("The broadcaster is the sync source") }
            return hasBroadcaster ? .ready : .unavailable("No broadcaster is connected")
        case .syncAllDevices:
            return hasBroadcaster ? .ready : .unavailable("No broadcaster is connected")
        }
    }

    func handleGlobalShortcut(_ action: GlobalShortcutAction, pressed: Bool) {
        if action.kind == .talkToEveryone || action.kind == .talkToDevice {
            if !pressed {
                globalShortcutTalkTargets.removeValue(forKey: action)
                reconcileTalkTargets()
                return
            }
            let availability = globalShortcutAvailability(action)
            guard availability.available else {
                statusText = availability.reason ?? "That shortcut is not available right now"
                return
            }
            if let participantID = action.participantID {
                globalShortcutTalkTargets[action] = [participantID]
            } else {
                globalShortcutTalkTargets[action] = currentRemoteParticipantIDs
            }
            reconcileTalkTargets()
            return
        }

        guard pressed else { return }
        let availability = globalShortcutAvailability(action)
        guard availability.available else {
            statusText = availability.reason ?? "That shortcut is not available right now"
            return
        }
        switch action.kind {
        case .talkToEveryone, .talkToDevice:
            break
        case .shareScreen:
            if isHost { selectExperience(.video) }
            else { beginAudioAndVideoBroadcast() }
        case .broadcastAudio:
            toggleBroadcasting()
        case .stopAudioBroadcast:
            meshSession?.stopBroadcasting()
            statusText = "Stopping this Mac's audio broadcast"
        case .stopScreenShare:
            selectExperience(.audio)
        case .syncMyDevice:
            guard let currentParticipantID,
                  let participant = participants.first(where: { $0.id == currentParticipantID })
            else {
                statusText = "This Mac is still joining the room"
                return
            }
            syncParticipant(participant)
        case .syncAllDevices:
            syncAllDevices()
        }
    }

    func isTalkTargetSelected(_ targetID: String?) -> Bool {
        let remoteIDs = currentRemoteParticipantIDs
        guard !remoteIDs.isEmpty else { return false }
        if let targetID { return latchedTalkTargetIDs.contains(targetID) }
        return remoteIDs.isSubset(of: latchedTalkTargetIDs)
    }

    /// Menu-bar behavior: click once to keep talking to a device, and click
    /// again to stop. "Everyone" captures the devices that are present now.
    func toggleTalkTarget(_ targetID: String?) {
        let remoteIDs = currentRemoteParticipantIDs
        guard !remoteIDs.isEmpty else {
            statusText = "No other device is available for Talk"
            return
        }
        latchedTalkTargetIDs = Self.toggledTalkTargets(
            latchedTalkTargetIDs,
            targetID: targetID,
            currentlyPresent: remoteIDs
        )
        reconcileTalkTargets()
    }

    static func toggledTalkTargets(
        _ selected: Set<String>,
        targetID: String?,
        currentlyPresent: Set<String>
    ) -> Set<String> {
        var result = selected.intersection(currentlyPresent)
        if let targetID {
            guard currentlyPresent.contains(targetID) else { return result }
            if result.remove(targetID) == nil { result.insert(targetID) }
        } else if currentlyPresent.isSubset(of: result) {
            result.subtract(currentlyPresent)
        } else {
            result.formUnion(currentlyPresent)
        }
        return result
    }

    /// Floating-bar behavior: the selected recipients exist only while the
    /// pointer is held down. It never changes menu-bar selections.
    func setPushToTalkPressed(_ pressed: Bool, targetID: String?) {
        if pressed {
            let remoteIDs = currentRemoteParticipantIDs
            guard !remoteIDs.isEmpty else {
                statusText = "No other device is available for Talk"
                return
            }
            if let targetID {
                guard remoteIDs.contains(targetID) else { return }
                pushToTalkTargetIDs = [targetID]
            } else {
                pushToTalkTargetIDs = remoteIDs
            }
        } else {
            pushToTalkTargetIDs.removeAll()
        }
        reconcileTalkTargets()
    }

    func inviteToOpenLine(_ targetID: String) {
        guard currentRemoteParticipantIDs.contains(targetID), let meshSession else { return }
        walkieGeneration += 1
        let generation = walkieGeneration
        Task {
            do {
                _ = try await meshSession.sendOpenLineInvitation(
                    to: targetID,
                    generation: generation,
                    inputDeviceUID: selectedVoiceInputUID
                )
            } catch is CancellationError {
                return
            } catch {
                guard generation == walkieGeneration else { return }
                errorMessage = readable(error)
                statusText = "Unable to open the line"
            }
        }
    }

    func respondToOpenLine(_ invitation: OpenLineInvitation, accept: Bool) {
        guard let meshSession else { return }
        walkieGeneration += 1
        let generation = walkieGeneration
        Task {
            do {
                try await meshSession.respondToOpenLine(
                    invitationID: invitation.id,
                    accept: accept,
                    generation: generation,
                    inputDeviceUID: selectedVoiceInputUID
                )
                statusText = accept
                    ? "Line open with \(invitation.callerName)"
                    : "Open line invitation declined"
            } catch is CancellationError {
                return
            } catch {
                guard generation == walkieGeneration else { return }
                errorMessage = readable(error)
                statusText = accept ? "Unable to join the line" : "Unable to decline the invitation"
            }
        }
    }

    func endOpenLine() {
        meshSession?.endOpenLine()
        statusText = "Line closed"
    }

    func openLinePeerName(_ invitation: OpenLineInvitation) -> String {
        let peerID = invitation.callerID == currentParticipantID
            ? invitation.inviteeID
            : invitation.callerID
        return participants.first(where: { $0.id == peerID })?.name
            ?? (invitation.callerID == peerID ? invitation.callerName : "the other Mac")
    }

    var incomingOpenLineInvitation: OpenLineInvitation? {
        guard case .invited(let invitation) = openLineState else { return nil }
        return invitation
    }

    func isOpenLinePeer(_ participantID: String) -> Bool {
        guard let invitation = openLineState.invitation else { return false }
        return invitation.callerID == participantID || invitation.inviteeID == participantID
    }

    private func scheduleOpenLineInvitationTimeout(
        _ invitation: OpenLineInvitation,
        incoming: Bool
    ) {
        openLineInvitationTimeoutTask?.cancel()
        openLineInvitationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            if incoming,
               case .invited(let current) = self.openLineState,
               current.id == invitation.id {
                self.respondToOpenLine(invitation, accept: false)
            } else if !incoming,
                      case .inviting(let current) = self.openLineState,
                      current.id == invitation.id {
                self.endOpenLine()
                self.statusText = "No answer from \(self.openLinePeerName(invitation))"
            }
        }
    }

    func refreshVoiceInputs() {
        voiceInputDevices = VoiceInputCatalog.availableDevices()
        guard let selectedVoiceInputUID else { return }
        if voiceInputDevices.contains(where: { $0.id == selectedVoiceInputUID }) {
            return
        }
        self.selectedVoiceInputUID = nil
        UserDefaults.standard.removeObject(forKey: Self.voiceInputUIDKey)
    }

    func selectVoiceInput(_ uid: String?) {
        guard uid == nil || voiceInputDevices.contains(where: { $0.id == uid }) else { return }
        guard selectedVoiceInputUID != uid else { return }
        selectedVoiceInputUID = uid
        if let uid { UserDefaults.standard.set(uid, forKey: Self.voiceInputUIDKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.voiceInputUIDKey) }
        if !effectiveTalkTargetIDs.isEmpty || openLineState.isSendingMicrophone {
            reconfigureVoiceInput()
        }
    }

    private func reconfigureVoiceInput() {
        guard phase == .live, let meshSession else { return }
        let talkTargets = effectiveTalkTargetIDs.intersection(currentRemoteParticipantIDs)
        guard !talkTargets.isEmpty || openLineState.isSendingMicrophone else { return }
        walkieGeneration += 1
        let generation = walkieGeneration
        walkieStarting = true
        statusText = "Changing microphone for Talk/Open Line"
        Task {
            do {
                _ = try await meshSession.reconfigureVoiceInput(
                    generation: generation,
                    inputDeviceUID: selectedVoiceInputUID
                )
                guard generation == walkieGeneration else { return }
                walkieStarting = false
                walkieTalking = !talkTargets.isEmpty
                if case .inviting(let invitation) = openLineState {
                    statusText = "Waiting for \(openLinePeerName(invitation)) to join the line"
                } else if case .connected(let invitation) = openLineState {
                    statusText = "Line open with \(openLinePeerName(invitation))"
                } else {
                    let names = participants.filter { talkTargets.contains($0.id) }.map(\.name)
                    statusText = talkTargets == currentRemoteParticipantIDs
                        ? "Talking to everyone"
                        : "Talking to \(ListFormatter.localizedString(byJoining: names))"
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == walkieGeneration else { return }
                walkieStarting = false
                walkieTalking = false
                errorMessage = readable(error)
                statusText = "Unable to change the Talk/Open Line microphone"
            }
        }
    }

    private var currentRemoteParticipantIDs: Set<String> {
        Set(participants.lazy.filter { $0.id != self.currentParticipantID }.map(\.id))
    }

    private var effectiveTalkTargetIDs: Set<String> {
        globalShortcutTalkTargets.values.reduce(
            latchedTalkTargetIDs.union(pushToTalkTargetIDs),
            { $0.union($1) }
        )
    }

    private func reconcileTalkTargets() {
        guard phase == .live, let meshSession else { return }
        let targets = effectiveTalkTargetIDs.intersection(currentRemoteParticipantIDs)
        walkieGeneration += 1
        let generation = walkieGeneration
        if targets.isEmpty {
            walkieStarting = false
            walkieTalking = false
            meshSession.endWalkieTalkie()
            if incomingWalkieSpeakerIDs.isEmpty, case .idle = openLineState {
                statusText = "Talk is off"
            }
            return
        }
        if !walkieTalking {
            walkieStarting = true
            statusText = "Starting Talk"
        }
        Task {
            let microphoneAllowed = await WalkieTalkieMicrophone.requestAccess()
            guard generation == walkieGeneration else { return }
            guard microphoneAllowed else {
                walkieStarting = false
                walkieTalking = false
                latchedTalkTargetIDs.removeAll()
                pushToTalkTargetIDs.removeAll()
                globalShortcutTalkTargets.removeAll()
                presentMicrophoneAccessHelp()
                return
            }
            do {
                _ = try await meshSession.updateWalkieTalkieTargets(
                    targets,
                    generation: generation,
                    inputDeviceUID: selectedVoiceInputUID
                )
                guard generation == walkieGeneration else { return }
                walkieStarting = false
                walkieTalking = true
                let names = participants
                    .filter { targets.contains($0.id) }
                    .map(\.name)
                statusText = targets == currentRemoteParticipantIDs
                    ? "Talking to everyone"
                    : "Talking to \(ListFormatter.localizedString(byJoining: names))"
            } catch is CancellationError {
                return
            } catch {
                guard generation == walkieGeneration else { return }
                walkieStarting = false
                walkieTalking = false
                latchedTalkTargetIDs.removeAll()
                pushToTalkTargetIDs.removeAll()
                globalShortcutTalkTargets.removeAll()
                errorMessage = readable(error)
                statusText = "Unable to start Talk"
            }
        }
    }

    private func presentMicrophoneAccessHelp() {
        statusText = "Microphone access is off"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Talk and Open Line need microphone access"
        alert.informativeText = "Allow ALO in Privacy & Security → Microphone to use Talk or Open Line. Listening to rooms does not require this permission."
        alert.addButton(withTitle: "Open Microphone Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func stopWalkieTalkie() {
        walkieGeneration += 1
        walkieStarting = false
        walkieTalking = false
        latchedTalkTargetIDs.removeAll()
        pushToTalkTargetIDs.removeAll()
        globalShortcutTalkTargets.removeAll()
        meshSession?.endWalkieTalkie()
        if incomingWalkieSpeakerIDs.isEmpty { statusText = "Talk is off" }
    }

    func editDeviceIdentity() {
        if let deviceIdentityEditor {
            deviceIdentityEditor.show()
            return
        }
        let editor = DeviceIdentityEditorController(
            name: currentUserName,
            icon: currentDeviceIcon,
            colorHex: currentDeviceColorHex,
            profileImageData: currentDeviceProfileImageData,
            saveAction: { [weak self] name, icon, colorHex, photo in
                self?.saveDeviceIdentity(
                    name: name,
                    icon: icon,
                    colorHex: colorHex,
                    profileImageData: photo
                )
            },
            closeAction: { [weak self] in self?.deviceIdentityEditor = nil }
        )
        deviceIdentityEditor = editor
        editor.show()
    }

    private func saveDeviceIdentity(
        name: String,
        icon: String,
        colorHex: String,
        profileImageData: Data?
    ) {
        guard !name.isEmpty else { return }
        let appearance = DeviceAppearance(
            icon: icon,
            colorHex: colorHex
        )
        currentUserName = name
        currentDeviceIcon = appearance.icon
        currentDeviceColorHex = appearance.colorHex
        currentDeviceProfileImageData = profileImageData
        let defaults = UserDefaults.standard
        defaults.set(name, forKey: "meshDeviceDisplayName")
        defaults.set(appearance.icon, forKey: "meshDeviceIcon")
        defaults.set(appearance.colorHex, forKey: "meshDeviceColorHex")
        if let profileImageData { defaults.set(profileImageData, forKey: Self.deviceProfileImageKey) }
        else { defaults.removeObject(forKey: Self.deviceProfileImageKey) }
        meshSession?.updateIdentity(
            name: name,
            icon: appearance.icon,
            colorHex: appearance.colorHex,
            profileImageData: profileImageData
        )
    }

    func hideFloatingBar() {
        floatingSection = .collapsed
        floatingBarHidden = true
        UserDefaults.standard.set(true, forKey: Self.floatingBarPreferenceKey)
    }

    func hideWalkieBar() {
        walkieBarHidden = true
        UserDefaults.standard.set(true, forKey: Self.walkieBarPreferenceKey)
    }

    func showWalkieBar() {
        walkieBarHidden = false
        UserDefaults.standard.set(false, forKey: Self.walkieBarPreferenceKey)
    }

    func toggleAllIncomingAudio() {
        let mute = !(incomingMediaMuted && incomingCallsMuted)
        setIncomingMediaMuted(mute)
        setIncomingCallsMuted(mute)
    }

    func toggleIncomingMediaMute() { setIncomingMediaMuted(!incomingMediaMuted) }
    func toggleIncomingCallsMute() { setIncomingCallsMuted(!incomingCallsMuted) }

    private func setIncomingMediaMuted(_ muted: Bool) {
        incomingMediaMuted = muted
        UserDefaults.standard.set(muted, forKey: Self.incomingMediaMutedKey)
        meshSession?.setIncomingMediaMuted(muted)
    }

    private func setIncomingCallsMuted(_ muted: Bool) {
        incomingCallsMuted = muted
        UserDefaults.standard.set(muted, forKey: Self.incomingCallsMutedKey)
        meshSession?.setIncomingWalkieTalkieMuted(muted)
        if muted { incomingWalkieSpeakerIDs.removeAll() }
    }

    func showFloatingBar() {
        videoFullscreen = false
        floatingBarHidden = false
        UserDefaults.standard.set(false, forKey: Self.floatingBarPreferenceKey)
    }

    func showChatInFloatingBar() {
        dismissIncomingMessagePreview()
        showFloatingBar()
        floatingSection = .chat
        unreadMessageCount = 0
    }

    func showPeopleInFloatingBar() {
        dismissIncomingMessagePreview()
        showFloatingBar()
        floatingSection = .people
    }

    func setMenuBarPopoverVisible(_ visible: Bool) {
        menuBarPopoverVisible = visible
        if visible, floatingSection == .chat {
            unreadMessageCount = 0
        } else if !visible, floatingBarHidden {
            floatingSection = .collapsed
        }
    }

    func canControl(_ participant: RoomParticipant) -> Bool {
        isHost || participant.id == currentParticipantID
    }

    func sendMessage() {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        meshSession?.sendChat(text)
        draftMessage = ""
    }

    var canQueueCurrentTrack: Bool {
        let media = isHost ? nowPlaying : localNowPlaying
        return media.title != nil && validMediaURL(media.sourceURL) != nil
    }

    func showQueue() {
        dismissIncomingMessagePreview()
        floatingSection = floatingSection == .queue ? .collapsed : .queue
        queueNotice = nil
    }

    func addQueueLink() {
        let value = queueURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = validMediaURL(value) else {
            queueNotice = "Paste a complete http or https media link."
            return
        }
        addQueueItem(RoomQueueItem(
            title: queueTitle(for: url),
            subtitle: url.host?.replacingOccurrences(of: "www.", with: ""),
            url: url.absoluteString
        ))
        queueURL = ""
        queueNotice = "Added to the room queue."
    }

    func addCurrentTrackToQueue() {
        let media = isHost ? nowPlaying : localNowPlaying
        guard let url = validMediaURL(media.sourceURL), let title = media.title else {
            queueNotice = "This player did not expose a shareable link. Paste one instead."
            return
        }
        addQueueItem(RoomQueueItem(
            title: title,
            subtitle: media.artist ?? media.album,
            url: url.absoluteString
        ))
        queueNotice = "Added \(title) to the room queue."
    }

    func removeQueueItem(_ item: RoomQueueItem) {
        guard canRemoveQueueItem(item) else { return }
        meshSession?.removeQueueItem(item.id)
    }

    func canRemoveQueueItem(_ item: RoomQueueItem) -> Bool {
        isHost || item.addedByID == currentParticipantID
    }

    func playQueueItem(_ item: RoomQueueItem) {
        guard let url = validMediaURL(item.url) else { return }
        if !isHost {
            guard ensureScreenRecordingPermission() else { return }
            stopLocalNowPlayingMonitor()
            meshSession?.beginBroadcasting()
        }
        if NSWorkspace.shared.open(url) {
            meshSession?.removeQueueItem(item.id)
            queueNotice = "Opened \(item.title) on this Mac."
        } else {
            queueNotice = "Could not open that media link."
        }
    }

    func showPeople() {
        dismissIncomingMessagePreview()
        floatingSection = floatingSection == .people ? .collapsed : .people
    }

    func showChat() {
        dismissIncomingMessagePreview()
        if floatingSection == .chat {
            floatingSection = .collapsed
        } else {
            floatingSection = .chat
            unreadMessageCount = 0
        }
    }

    func markChatPresented() {
        unreadMessageCount = 0
        firstUnreadMessageID = nil
    }

    func toggleFloatingVideo() {
        guard roomHasVideo else { return }
        dismissIncomingMessagePreview()
        floatingSection = floatingSection == .video ? .collapsed : .video
    }

    func toggleVideoFromFloatingBar() {
        if mediaSwitchBusy {
            statusText = "Cancelling screen selection"
            Task { try? await meshSession?.setVideoEnabled(false) }
            return
        }
        switch videoControlIntent {
        case .toggleViewer:
            toggleFloatingVideo()
        case .showViewer, .enableVideo:
            selectExperience(.video)
        case .beginAudioAndVideoBroadcast:
            beginAudioAndVideoBroadcast()
        case .unavailable:
            break
        }
    }

    func collapseFloatingBar() {
        dismissIncomingMessagePreview()
        floatingSection = .collapsed
    }

    func enterVideoFullscreen() {
        guard roomHasVideo else { return }
        videoFullscreen = true
    }

    func toggleVideoViewerPinned() {
        videoViewerPinned.toggle()
    }

    func toggleVideoWindowFullScreen() {
        guard videoFullscreen else { return }
        videoFullScreenToggle &+= 1
    }

    func exitVideoFullscreen() {
        videoFullscreen = false
    }

    func stop() {
        isLeavingRoom = true
        lastJoinedRoomStore.clear(ifMatching: activeRoomConfiguration?.id)
        phase = .starting
        statusText = "Leaving the room"
        stopLocalNowPlayingMonitor()
        Task {
            await meshSession?.stop()
            meshSession = nil
            finishStopping()
        }
    }

    func tryAgain() {
        errorMessage = nil
        errorIsPermissionRelated = false
        phase = .idle
        statusText = "Ready"
        roomBrowser.restart()
    }

    func refreshRooms() {
        statusText = "Looking for rooms"
        roomBrowser.restart()
    }

    func dismissPermissionNotice() {
        permissionNotice = false
    }

    var recordingPermissionTitle: String {
        recordingRestartRequired ? "Restart ALO to finish setup" : "Allow screen and audio recording"
    }

    var recordingPermissionGuidance: String {
        if recordingRestartRequired {
            return "Access was granted. Restart ALO before broadcasting your screen or system audio."
        }
        return "Open Recording Settings, turn on ALO under Screen & System Audio Recording, then restart ALO."
    }

    func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func restartApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.errorMessage = "Could not restart ALO: \(error.localizedDescription)"
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func stopImmediately() {
        isLeavingRoom = true
        stopLocalNowPlayingMonitor()
        meshSession?.stopImmediately()
    }

    func diagnosticRoomContext() -> DiagnosticRoomContext {
        let active = phase == .live && meshSession != nil
        let remotePeerCount = participants.filter { $0.id != currentParticipantID }.count
        return DiagnosticRoomContext(
            isActive: active,
            role: active ? (isHost ? .broadcaster : .listener) : .none,
            participantCount: participants.count,
            remotePeerCount: remotePeerCount,
            syncLabel: roomSyncLabel,
            audioIsRendering: audioIsRendering,
            hasBroadcaster: hasBroadcaster,
            timing: meshSession?.diagnosticsSnapshot()
        )
    }

    private func ensureScreenRecordingPermission() -> Bool {
        switch RecordingErrorPresentation.accessStep(
            preflightGranted: CGPreflightScreenCaptureAccess(),
            requestedThisLaunch: screenRecordingRequestAttempted
        ) {
        case .proceed:
            permissionNotice = false
            recordingRestartRequired = false
            return true
        case .requestSystemAccess:
            screenRecordingRequestAttempted = true
            let granted = CGRequestScreenCaptureAccess()
            recordingRestartRequired = granted
            permissionNotice = true
            statusText = granted
                ? "Restart ALO to finish recording access"
                : "Allow ALO under Screen & System Audio Recording"
            // Apple documents that ScreenCaptureKit capture needs a fresh app
            // process after the first grant. Do not immediately start a stream
            // that will fail and look like the permission was ignored.
            return false
        case .restartRequired:
            recordingRestartRequired = true
            permissionNotice = true
            statusText = "Restart ALO to finish recording access"
            return false
        case .showSettings:
            permissionNotice = true
            statusText = recordingRestartRequired
                ? "Restart ALO to finish recording access"
                : "Allow ALO under Screen & System Audio Recording"
            return false
        }
    }

    private var identityCallback: (String, String) -> Void {
        { [weak self] id, name in
            DispatchQueue.main.async {
                self?.currentParticipantID = id
                self?.currentUserName = name
            }
        }
    }

    private var participantCallback: ([RoomParticipant]) -> Void {
        { [weak self] participants in
            DispatchQueue.main.async {
                guard let self else { return }
                self.participants = Self.mergingParticipants(participants, preserving: self.participants)
                let liveIDs = Set(participants.map(\.id))
                self.incomingWalkieSpeakerIDs.formIntersection(liveIDs)
                let previousTargets = self.effectiveTalkTargetIDs
                self.latchedTalkTargetIDs.formIntersection(liveIDs)
                self.pushToTalkTargetIDs.formIntersection(liveIDs)
                for action in Array(self.globalShortcutTalkTargets.keys) {
                    self.globalShortcutTalkTargets[action]?.formIntersection(liveIDs)
                }
                if self.effectiveTalkTargetIDs != previousTargets {
                    self.reconcileTalkTargets()
                }
                if let invitation = self.openLineState.invitation {
                    let peerID = invitation.callerID == self.currentParticipantID
                        ? invitation.inviteeID
                        : invitation.callerID
                    if !liveIDs.contains(peerID) { self.endOpenLine() }
                }
            }
        }
    }

    private var mediaStateCallback: (Bool) -> Void {
        { [weak self] enabled in
            DispatchQueue.main.async {
                guard let self else { return }
                self.roomHasVideo = enabled
                if enabled, self.requestedVideoBroadcast {
                    self.requestedVideoBroadcast = false
                    self.mediaSwitchBusy = false
                    self.videoBroadcastTimeoutTask?.cancel()
                    self.videoBroadcastTimeoutTask = nil
                    self.experience = .video
                    self.floatingSection = .video
                    self.statusText = "Audio and the selected display or window are live"
                }
                if !enabled {
                    self.videoFullscreen = false
                    self.videoFrame = nil
                    if !self.isHost || self.experience == .video {
                        self.experience = .audio
                    }
                    if self.floatingSection == .video {
                        self.floatingSection = .collapsed
                    }
                }
            }
        }
    }

    private var chatCallback: (String, String, String, UInt64) -> Void {
        { [weak self] senderID, sender, text, sentNanos in
            DispatchQueue.main.async {
                guard let self else { return }
                self.messages.append(RoomMessage(
                    senderID: senderID,
                    sender: sender,
                    text: text,
                    sentNanos: sentNanos
                ))
                let chatIsVisible = self.floatingSection == .chat
                    && (!self.floatingBarHidden || self.menuBarPopoverVisible)
                if senderID != self.currentParticipantID, !chatIsVisible {
                    if self.firstUnreadMessageID == nil {
                        self.firstUnreadMessageID = self.messages[self.messages.count - 1].id
                    }
                    self.unreadMessageCount += 1
                    if self.floatingSection == .collapsed {
                        self.presentIncomingMessagePreview(self.messages[self.messages.count - 1])
                    }
                }
            }
        }
    }

    private var queueCallback: ([RoomQueueItem]) -> Void {
        { [weak self] queue in
            DispatchQueue.main.async { self?.mediaQueue = queue }
        }
    }

    private var nowPlayingCallback: (NowPlayingMedia) -> Void {
        { [weak self] media in
            let accentHex = ArtworkTheme.accentHex(from: media.artworkData)
            DispatchQueue.main.async {
                guard let self else { return }
                let sameTrack = self.nowPlaying.title == media.title
                    && self.nowPlaying.artist == media.artist
                    && self.nowPlaying.album == media.album
                self.nowPlaying = media
                if media.artworkData != nil || !sameTrack {
                    self.roomAccentHex = accentHex
                }
            }
        }
    }

    private var videoCallback: (CGImage) -> Void {
        { [weak self] image in
            DispatchQueue.main.async { self?.videoFrame = image }
        }
    }

    private func handle(_ status: ReceiverStatus) {
        switch status {
        case .searching: statusText = "Looking for \(activeRoom ?? "the room")"
        case .connected:
            audioIsRendering = false
            statusText = "Aligning this Mac with the room"
        case .playing:
            phase = .live
            audioIsRendering = true
            statusText = "Audio is in sync"
        case .silent:
            phase = .live
            audioIsRendering = false
            statusText = "Connected · waiting for audio"
        case .failed(let message):
            phase = .failed
            audioIsRendering = false
            errorMessage = message
            statusText = "Connection lost"
        }
    }

    private func updateParticipant(_ id: String, volume: Double, muted: Bool) {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { return }
        let current = participants[index]
        participants[index] = RoomParticipant(
            id: current.id,
            name: current.name,
            volume: volume,
            isMuted: muted,
            icon: current.icon,
            colorHex: current.colorHex,
            profileImageData: current.profileImageData
        )
    }

    private func resetRoomState() {
        stopLocalNowPlayingMonitor()
        isLeavingRoom = false
        errorMessage = nil
        errorIsPermissionRelated = false
        permissionNotice = false
        walkieGeneration += 1
        walkieStarting = false
        walkieTalking = false
        openLineInvitationTimeoutTask?.cancel()
        openLineInvitationTimeoutTask = nil
        openLineState = .idle
        incomingWalkieSpeakerIDs.removeAll()
        latchedTalkTargetIDs.removeAll()
        pushToTalkTargetIDs.removeAll()
        globalShortcutTalkTargets.removeAll()
        participants = []
        messages = []
        unreadMessageCount = 0
        firstUnreadMessageID = nil
        dismissIncomingMessagePreview()
        mediaQueue = []
        queueURL = ""
        queueNotice = nil
        videoFrame = nil
        videoFullscreen = false
        roomHasVideo = false
        requestedVideoBroadcast = false
        mediaSwitchBusy = false
        videoBroadcastTimeoutTask?.cancel()
        videoBroadcastTimeoutTask = nil
        nowPlaying = NowPlayingMedia()
        roomAccentHex = nil
        localNowPlaying = NowPlayingMedia()
        audioIsRendering = false
        experience = .audio
        draftMessage = ""
        floatingSection = .collapsed
    }

    private func presentIncomingMessagePreview(_ message: RoomMessage) {
        incomingMessagePreviewTask?.cancel()
        incomingMessagePreview = message
        incomingMessagePreviewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            self?.incomingMessagePreview = nil
            self?.incomingMessagePreviewTask = nil
        }
    }

    private func dismissIncomingMessagePreview() {
        incomingMessagePreviewTask?.cancel()
        incomingMessagePreviewTask = nil
        incomingMessagePreview = nil
    }

    private func finishStopping() {
        activeRoom = nil
        activeRoomConfiguration = nil
        resetRoomState()
        phase = .idle
        statusText = "Ready"
        roomBrowser.restart()
    }

    private func startLocalNowPlayingMonitor() {
        guard localNowPlayingMonitor == nil else { return }
        let monitor = NowPlayingMonitor { [weak self] media in
            DispatchQueue.main.async { self?.localNowPlaying = media }
        }
        monitor.start()
        localNowPlayingMonitor = monitor
    }

    private func stopLocalNowPlayingMonitor() {
        localNowPlayingMonitor?.stop()
        localNowPlayingMonitor = nil
    }

    private func updateLocalNowPlayingMonitor() {
        guard phase == .live, !isLeavingRoom, meshSession != nil, !isHost else {
            stopLocalNowPlayingMonitor()
            return
        }
        startLocalNowPlayingMonitor()
    }

    private func addQueueItem(_ item: RoomQueueItem) {
        meshSession?.addQueueItem(item)
    }

    private func validMediaURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else { return nil }
        return url
    }

    private func queueTitle(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("spotify") { return "Spotify item" }
        if host.contains("music.apple") { return "Apple Music item" }
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube item" }
        return url.host?.replacingOccurrences(of: "www.", with: "") ?? "Shared media"
    }

    private func readable(_ error: Error) -> String {
        RecordingErrorPresentation.message(for: error)
    }

    private func isPermissionError(_ error: Error) -> Bool {
        RecordingErrorPresentation.isPermissionFailure(error)
    }

    static func renderingState(for status: String) -> Bool? {
        if ["This Mac is playing in sync", "Listening in sync", "Audio is in sync"].contains(status) {
            return true
        }
        if status.contains("waiting for audio")
            || status.hasPrefix("Connecting")
            || status.hasPrefix("Room open")
            || status.hasPrefix("Taking over") {
            return false
        }
        return nil
    }

    static func effectivePlaybackState(
        metadataIsPlaying: Bool?,
        audioIsRendering: Bool,
        hasMedia: Bool
    ) -> Bool {
        guard hasMedia else { return false }
        return metadataIsPlaying ?? audioIsRendering
    }

    nonisolated static func mergingParticipants(
        _ participants: [RoomParticipant],
        preserving prior: [RoomParticipant]
    ) -> [RoomParticipant] {
        let previousByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) })
        return participants.map { participant in
            guard let existing = previousByID[participant.id] else { return participant }
            return RoomParticipant(
                id: participant.id,
                name: participant.name,
                volume: existing.volume,
                isMuted: existing.isMuted,
                icon: participant.icon,
                colorHex: participant.colorHex,
                profileImageData: participant.profileImageData
            )
        }
    }
}

private struct WERAIView: View {
    @ObservedObject var model: WERAIViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var roomNameFocused: Bool
    @FocusState private var privateKeyFocused: Bool

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return ALOAppFlavor.isDevelopment
            ? "DEV · V\(version ?? "LOCAL")"
            : "V\(version ?? "DEV")"
    }

    var body: some View {
        ZStack {
            if model.phase == .idle {
                SetupBackground()
            } else {
                Palette.canvas
                    .ignoresSafeArea()
            }
            switch model.phase {
            case .idle: idleView
            case .starting: progressView
            case .live: EmptyView()
            case .failed: errorView
            }
            if model.permissionNotice { permissionOverlay }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Palette.controlAccent)
    }

    private var idleView: some View {
        setupConsole
            .padding(.top, 34)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
    }

    private var setupConsole: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.mode == .share ? "New room" : "Rooms")
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .tracking(-0.7)
                        Text(versionLabel)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .opacity(0.62)
                    }
                    Text(model.mode == .share
                        ? "Choose a name, then invite your people."
                        : "Saved here and live on your Wi-Fi.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .opacity(0.72)
                }
                .foregroundStyle(Color.white)
                Spacer()
                if model.mode == .listen {
                    Button(action: model.refreshRooms) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(SetupIconButtonStyle(onImage: true))
                    .help("Refresh nearby rooms")
                    .accessibilityLabel("Refresh nearby rooms")
                }
                Button(action: model.editDeviceIdentity) {
                    DeviceAvatar(
                        emoji: model.currentDeviceIcon,
                        colorHex: model.currentDeviceColorHex,
                        profileImageData: model.currentDeviceProfileImageData,
                        size: 28
                    )
                }
                .buttonStyle(SetupIconButtonStyle(onImage: true))
                .help("Edit \(model.currentUserName)")
                .accessibilityLabel("Edit this Mac's room identity")
            }

            if model.mode == .share {
                createRoomPanel
            } else {
                roomList
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var createRoomPanel: some View {
        VStack(spacing: 12) {
            TextField("Room name", text: $model.roomName)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(SetupPalette.ink)
                .focused($roomNameFocused)
                .onSubmit(model.startSharing)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(SetupPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(roomNameFocused ? Palette.controlAccent : SetupPalette.stroke, lineWidth: roomNameFocused ? 2 : 1)
                )

            HStack(spacing: 8) {
                Button {
                    model.createPrivateRoom.toggle()
                } label: {
                    Label(
                        model.createPrivateRoom ? "Private" : "Public",
                        systemImage: model.createPrivateRoom ? "lock.fill" : "person.3.fill"
                    )
                }
                .buttonStyle(SetupActionButtonStyle(active: model.createPrivateRoom))
                .help(model.createPrivateRoom ? "Private room" : "Public room")
                .accessibilityLabel(model.createPrivateRoom ? "Make room public" : "Make room private")
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86)) {
                        model.mode = .listen
                    }
                } label: {
                    Label("Rooms", systemImage: "chevron.left")
                }
                .buttonStyle(SetupActionButtonStyle())
                .help("Back to rooms")
                .accessibilityLabel("Back to rooms")
                Button(action: model.startSharing) {
                    Label("Create", systemImage: "arrow.right")
                }
                .buttonStyle(SetupActionButtonStyle(filled: true))
                .disabled(!model.canStartSharing)
                .help("Create and open room")
                .accessibilityLabel("Create and open room")
            }
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { roomNameFocused = true }
        }
    }

    private var roomList: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if model.roomChoices.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Palette.accent)
                            Text("Looking for rooms")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(SetupPalette.ink)
                            Text("Keep ALO open on nearby Macs.")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(SetupPalette.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 170)
                        .help("Looking for rooms on your network")
                        .accessibilityLabel("Looking for rooms on your network")
                    } else {
                        ForEach(model.roomChoices) { room in
                            roomCard(room)
                            if room.id != model.roomChoices.last?.id {
                                Divider()
                                    .overlay(SetupPalette.stroke)
                                    .padding(.leading, 58)
                            }
                        }
                    }
                }
            }
            .frame(height: setupRoomListHeight)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(SetupPalette.surface)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.72), lineWidth: 1)
            )

            if model.selectedRoomConfiguration?.isPrivate == true,
               model.selectedRoomConfiguration?.accessKey == nil {
                TextField("Private room invite key", text: $model.privateRoomKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(SetupPalette.ink)
                    .focused($privateKeyFocused)
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(SetupPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onAppear {
                        NSApp.activate(ignoringOtherApps: true)
                        DispatchQueue.main.async { privateKeyFocused = true }
                    }
            }
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86)) {
                        model.mode = .share
                    }
                } label: {
                    Label("New room", systemImage: "plus")
                }
                .buttonStyle(SetupActionButtonStyle())
                .help("Create room")
                .accessibilityLabel("Create room")
                Spacer()
                Button(action: model.joinSelectedRoom) {
                    Label("Open room", systemImage: "arrow.right")
                }
                .buttonStyle(SetupActionButtonStyle(filled: true))
                .disabled(!model.canJoin)
                .help("Open selected room")
                .accessibilityLabel("Open selected room")
            }
        }
    }

    private var setupRoomListHeight: CGFloat {
        guard !model.roomChoices.isEmpty else { return 170 }
        let visibleRows = min(model.roomChoices.count, 4)
        return CGFloat(visibleRows * 58 + max(0, visibleRows - 1))
    }

    private func roomCard(_ room: RoomConfiguration) -> some View {
        let nearby = model.nearbyRooms.first(where: { $0.id == room.id })
        let saved = model.savedRooms.contains(where: { $0.id == room.id })
        let selected = model.selectedRoomID == room.id
        return HStack(spacing: 8) {
            Button {
                model.selectedRoomID = room.id
                model.privateRoomKey = ""
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: room.isPrivate ? "lock.fill" : "person.3.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Palette.selectedControlText : Palette.accent)
                        .frame(width: 36, height: 36)
                        .background(selected ? Palette.controlAccent : Palette.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.name)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(SetupPalette.ink)
                        Text(nearby.map { "Nearby · \($0.peerCount) \($0.peerCount == 1 ? "person" : "people")" } ?? "Saved on this Mac")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(nearby == nil ? SetupPalette.secondary : Palette.accentText)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Palette.controlAccent : SetupPalette.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if saved {
                Button { model.forgetRoom(roomID: room.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SetupPalette.secondary)
                        .frame(width: 30, height: 34)
                }
                .buttonStyle(FlatToolButtonStyle(active: false))
                .help("Forget this room on this Mac")
                .accessibilityLabel("Forget \(room.name)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(selected ? Palette.controlAccent.opacity(0.12) : Color.clear)
    }

    private var progressView: some View {
        VStack(spacing: 18) {
            WaveformGlyph(active: true).frame(width: 84, height: 48)
            Text(model.statusText)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
            Text("Building the room around one shared clock.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Palette.secondary)
        }
        .padding(34)
        .glass(cornerRadius: 28)
    }

    private var permissionOverlay: some View {
        ZStack {
            Color.black.opacity(0.16).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "rectangle.on.rectangle.badge.person.crop")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Palette.accentDark)
                    Spacer()
                    Button(action: model.dismissPermissionNotice) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.muted)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.recordingPermissionTitle)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                    Text(model.recordingPermissionGuidance)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                        .lineSpacing(3)
                }
                HStack(spacing: 9) {
                    if model.recordingRestartRequired {
                        Button("Restart ALO", action: model.restartApplication)
                            .buttonStyle(PillButtonStyle(filled: true))
                        Button("Open settings", action: model.openPrivacySettings)
                            .buttonStyle(PillButtonStyle(filled: false))
                    } else {
                        Button("Open settings", action: model.openPrivacySettings)
                            .buttonStyle(PillButtonStyle(filled: true))
                        Button("Restart ALO", action: model.restartApplication)
                            .buttonStyle(PillButtonStyle(filled: false))
                    }
                }
            }
            .padding(24)
            .frame(width: 392)
            .glass(cornerRadius: 26)
        }
        .transition(.opacity)
    }

    private var errorView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.red)
            VStack(alignment: .leading, spacing: 7) {
                Text("The room couldn’t start")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text(model.errorMessage ?? "Something interrupted ALO.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: 336, alignment: .leading)
            }
            HStack(spacing: 9) {
                Button(action: model.tryAgain) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SetupIconButtonStyle(filled: true))
                .help("Try again")
                .accessibilityLabel("Try again")
                if model.errorIsPermissionRelated {
                    Button(action: model.openPrivacySettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(SetupIconButtonStyle())
                    .help("Open Recording Settings")
                    .accessibilityLabel("Open Recording Settings")
                }
            }
        }
        .padding(28)
        .frame(width: 392, alignment: .leading)
        .glass(cornerRadius: 26)
    }
}

private enum RoomControlsPresentation {
    case floating
    case menuBar
}

private struct FloatingRoomView: View {
    @ObservedObject var model: WERAIViewModel
    var presentation: RoomControlsPresentation = .floating
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @FocusState private var queueFocused: Bool

    private var panelTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .offset(x: 0, y: 8).combined(with: .opacity)
    }

    private var panelAnimation: Animation? {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .smooth(duration: FloatingMetrics.expansionDuration)
    }

    private var themeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 1.1)
    }

    private var roomAccent: Color {
        model.roomAccentColor
    }

    private var messageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .bottom)
                    .combined(with: .scale(scale: 0.96, anchor: .bottom))
                    .combined(with: .opacity),
                removal: .opacity
            )
    }

    private var hasExpandedContent: Bool {
        model.permissionNotice
            || model.floatingSection != .collapsed
            || model.incomingMessagePreview != nil
    }

    private var expandedContentHeight: CGFloat {
        max(0, model.floatingPanelHeight - FloatingMetrics.barHeight - FloatingMetrics.separatorHeight)
    }

    private var roomBarHeight: CGFloat {
        presentation == .menuBar ? FloatingMetrics.menuBarMediaHeight : FloatingMetrics.barHeight
    }

    private var roomContentHeight: CGFloat {
        model.floatingPanelHeight + roomBarHeight - FloatingMetrics.barHeight
    }

    private var expansionIdentity: String {
        if model.permissionNotice { return "permission" }
        if let preview = model.incomingMessagePreview,
           model.floatingSection == .collapsed {
            return "message-\(preview.id)"
        }
        switch model.floatingSection {
        case .collapsed: return "collapsed"
        case .queue: return "queue"
        case .chat: return "chat"
        case .people: return "people"
        case .video: return "video"
        }
    }

    private var hasDraft: Bool {
        !model.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var expandedContent: some View {
        if model.permissionNotice {
            permissionPanel
        } else if let preview = model.incomingMessagePreview,
                  model.floatingSection == .collapsed {
            incomingMessagePreview(preview)
        } else {
            switch model.floatingSection {
            case .collapsed:
                EmptyView()
            case .queue:
                queuePanel
            case .chat:
                chatHistory
            case .people:
                peopleMixer
            case .video:
                videoPlayer
            }
        }
    }

    var body: some View {
        return Group {
            if presentation == .floating {
                roomContent
                    .floatingSurface(cornerRadius: FloatingMetrics.cornerRadius)
                    .padding(FloatingMetrics.windowInset)
            } else {
                roomContent.background(Palette.opaqueSurface)
            }
        }
        .tint(roomAccent)
        .environment(\.roomAccent, roomAccent)
        .animation(themeAnimation, value: model.roomAccentHex)
    }

    private var roomContent: some View {
        VStack(spacing: 0) {
            if hasExpandedContent {
                expandedContent
                    .frame(width: FloatingMetrics.width, height: expandedContentHeight)
                    .id(expansionIdentity)
                    .transition(panelTransition)

                Divider()
                    .overlay(Palette.strokeStrong)
                    .frame(height: FloatingMetrics.separatorHeight)
                    .transition(.opacity)
            }

            roomBar
        }
        .frame(width: FloatingMetrics.width, height: roomContentHeight, alignment: .bottom)
        .background(
            LinearGradient(
                colors: [roomAccent.opacity(0.12), roomAccent.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .animation(panelAnimation, value: model.floatingSection)
        .animation(panelAnimation, value: model.permissionNotice)
        .animation(panelAnimation, value: model.participants.count)
        .animation(panelAnimation, value: model.incomingMessagePreview?.id)
    }

    private var roomBar: some View {
        HStack(spacing: 8) {
            roomIdentity

            roomBarButton(
                icon: model.isHost ? "dot.radiowaves.left.and.right" : "waveform.badge.mic",
                activeIcon: "dot.radiowaves.left.and.right",
                active: model.isHost,
                disabled: model.mediaSwitchBusy,
                help: model.isHost ? "Stop broadcasting" : (model.hasBroadcaster ? "Take over room audio" : "Broadcast audio")
            ) { model.toggleBroadcasting() }

            if model.hasBroadcaster || model.isHost {
                roomBarButton(
                    icon: model.roomIsPlaying ? "pause.fill" : "play.fill",
                    active: false,
                    help: model.roomIsPlaying ? "Pause everywhere" : "Play everywhere"
                ) { model.toggleRoomPlayback() }

                roomBarButton(
                    icon: "music.note.list",
                    activeIcon: "music.note.list",
                    active: model.floatingSection == .queue,
                    help: "Room queue"
                ) { model.showQueue() }
                .keyboardShortcut("4", modifiers: .command)
            }

            roomBarButton(
                icon: model.mediaSwitchBusy ? "xmark" : "rectangle.on.rectangle",
                activeIcon: "rectangle.fill.on.rectangle.fill",
                active: model.floatingSection == .video || model.experience == .video,
                disabled: !model.canSelectVideo,
                help: model.mediaSwitchBusy ? "Cancel screen selection" : model.videoControlHelp
            ) { model.toggleVideoFromFloatingBar() }
            .keyboardShortcut("3", modifiers: .command)

            if presentation == .floating {
                roomBarButton(
                    icon: "eye.slash",
                    active: false,
                    help: "Hide media controls"
                ) { model.hideFloatingBar() }
            }

            Divider().frame(height: 20)

            Button(action: model.stop) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.red)
                    .frame(width: 30, height: 32)
            }
            .buttonStyle(FlatToolButtonStyle(active: false))
            .help("Leave room")
            .accessibilityLabel("Leave room")
        }
        .padding(.horizontal, 8)
        .frame(width: FloatingMetrics.width, height: roomBarHeight)
    }

    @ViewBuilder
    private var roomIdentity: some View {
        let identity = HStack(spacing: 9) {
            artworkTile

            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlaying.title ?? model.roomTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(model.audioIsRendering ? roomAccent : Palette.secondary)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    ViewThatFits(in: .horizontal) {
                        statusLabel(compact: false)
                        statusLabel(compact: true)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        if presentation == .floating {
            identity
                .overlay(WindowDragRegion().accessibilityHidden(true))
                .help("Drag to move ALO")
        } else {
            identity
        }
    }

    private func statusLabel(compact: Bool) -> some View {
        let text: String
        if model.nowPlaying.title == nil {
            text = compact
                ? "\(model.participants.count) · \(model.roomSyncLabel)"
                : "\(model.participants.count) listening · \(model.roomSyncLabel)"
        } else {
            text = compact ? model.roomSyncLabel : "\(model.roomTitle) · \(model.roomSyncLabel)"
        }
        return Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.detailText)
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.82)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var artworkTile: some View {
        let size: CGFloat = presentation == .menuBar ? 62 : 38
        let radius: CGFloat = presentation == .menuBar ? 17 : 11
        return Group {
            if let data = model.nowPlaying.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    roomAccent.opacity(0.15)
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(roomAccent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        )
        .accessibilityLabel(model.nowPlaying.title.map { "Album artwork for \($0)" } ?? "Audio room")
    }

    private func roomBarButton(
        icon: String,
        activeIcon: String? = nil,
        active: Bool,
        badge: Int = 0,
        disabled: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: active ? (activeIcon ?? icon) : icon)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : badge)
                .foregroundStyle(active ? Palette.selectedControlText : Palette.controlIcon)
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(FlatToolButtonStyle(active: active))
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                Circle()
                    .fill(Palette.red)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Palette.opaqueSurface, lineWidth: 1))
                    .offset(x: 3, y: -7)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.35, anchor: .bottomLeading).combined(with: .opacity)
                    )
            }
        }
        .zIndex(badge > 0 ? 1 : 0)
        .disabled(disabled)
        .opacity(disabled ? 0.36 : 1)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(badge > 0 ? "\(badge) unread" : active ? "Selected" : "")
    }

    private func incomingMessagePreview(_ message: RoomMessage) -> some View {
        Button(action: model.showChat) {
            HStack(spacing: 10) {
                messageAvatar(message, size: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.sender)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(message.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.controlIcon)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Palette.messageSurface)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Palette.strokeStrong, lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("New message from \(message.sender): \(message.text)")
        .help("Open conversation")
    }

    private var queuePanel: some View {
        VStack(spacing: 0) {
            panelHeader(
                title: "Up next",
                detail: model.mediaQueue.isEmpty
                    ? "Anyone can add media"
                    : "\(model.mediaQueue.count) queued · anyone can add"
            )
            Divider().opacity(0.42)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.mediaQueue) { item in
                        queueRow(item)
                        if item.id != model.mediaQueue.last?.id {
                            Divider().opacity(0.34).padding(.leading, 54)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .overlay {
                if model.mediaQueue.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Palette.controlIcon)
                        Text("Nothing queued yet")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Text("Paste a media link from any Mac in the room.")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.secondary)
                    }
                }
            }
            Divider().opacity(0.42)
            queueComposer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueComposer: some View {
        HStack(spacing: 8) {
            Button(action: model.addCurrentTrackToQueue) {
                Image(systemName: "music.note.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.controlIcon)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(FlatToolButtonStyle(active: false))
            .disabled(!model.canQueueCurrentTrack)
            .opacity(model.canQueueCurrentTrack ? 1 : 0.38)
            .help(model.canQueueCurrentTrack ? "Add this Mac’s current track" : "Paste a media link")

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                TextField("Paste a media link", text: $model.queueURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .focused($queueFocused)
                    .onSubmit(model.addQueueLink)
                if !model.queueURL.isEmpty {
                    Button("Add", action: model.addQueueLink)
                        .buttonStyle(InlineActionButtonStyle())
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(Palette.composer)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Palette.strokeStrong, lineWidth: 1)
            )

            if let notice = model.queueNotice {
                Text(notice)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
                    .frame(width: 118, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .animation(panelAnimation, value: model.queueNotice)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { queueFocused = true }
        }
    }

    private func queueRow(_ item: RoomQueueItem) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.accentText)
                .frame(width: 32, height: 32)
                .background(Palette.artworkFallback)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text([item.subtitle, "Added by \(item.addedBy)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isHost {
                Button { model.playQueueItem(item) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(FlatToolButtonStyle(active: false))
                .help("Play on the host Mac")
            }
            if model.canRemoveQueueItem(item) {
                Button { model.removeQueueItem(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(FlatToolButtonStyle(active: false))
                .help("Remove from queue")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 58)
    }

    private var chatHistory: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider().opacity(0.42)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if model.messages.isEmpty {
                            VStack(spacing: 7) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Palette.controlIcon)
                                Text("Start the conversation")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                Text("Everyone in the room will see it.")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Palette.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 170, alignment: .center)
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            let showsSender = index == 0
                                || model.messages[index - 1].sender != message.sender
                            floatingMessage(message, showsSender: showsSender)
                                .id(message.id)
                                .transition(messageTransition)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(ChatScrollTarget.bottom)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    let firstUnread = model.firstUnreadMessageID
                    DispatchQueue.main.async {
                        if let firstUnread {
                            proxy.scrollTo(firstUnread, anchor: .top)
                        } else {
                            proxy.scrollTo(ChatScrollTarget.bottom, anchor: .bottom)
                        }
                        model.markChatPresented()
                    }
                }
                .onChange(of: model.messages.last?.id) {
                    guard model.messages.last != nil else { return }
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.04)) {
                            proxy.scrollTo(ChatScrollTarget.bottom, anchor: .bottom)
                        }
                    }
                }
            }
            Divider().opacity(0.42)
            messageComposer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.8),
            value: model.messages.count
        )
    }

    private var chatHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Room chat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("\(model.participants.count) here · live")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }

            Spacer()

            HStack(spacing: -5) {
                ForEach(Array(model.participants.prefix(3))) { participant in
                    identityAvatar(id: participant.id, name: participant.name, size: 22)
                        .overlay(Circle().stroke(Palette.opaqueSurface, lineWidth: 1.5))
                }
            }
            .accessibilityHidden(true)

            Button(action: model.collapseFloatingBar) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.controlIcon)
                    .frame(width: 32, height: 30)
            }
            .buttonStyle(FlatToolButtonStyle(active: false))
            .help("Collapse")
            .accessibilityLabel("Collapse")
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private var messageComposer: some View {
        HStack(spacing: 8) {
            identityAvatar(
                id: model.currentParticipantID,
                name: model.currentUserName,
                size: 26
            )

            TextField("Message \(model.roomTitle)", text: $model.draftMessage)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .focused($composerFocused)
                .onSubmit(model.sendMessage)

            Button(action: model.sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.selectedControlText)
                    .frame(width: 26, height: 26)
                    .background(roomAccent)
                    .clipShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(!hasDraft)
            .opacity(hasDraft ? 1 : 0.26)
            .scaleEffect(!reduceMotion && hasDraft ? 1 : 0.9)
            .help("Send message")
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Palette.composer)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    composerFocused ? roomAccent : Palette.strokeStrong,
                    lineWidth: 1
                )
        )
        .padding(10)
        .onTapGesture { composerFocused = true }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { composerFocused = true }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72),
            value: hasDraft
        )
    }

    private func floatingMessage(_ message: RoomMessage, showsSender: Bool) -> some View {
        let own = message.senderID == model.currentParticipantID
        return HStack(alignment: .bottom, spacing: 7) {
            if own {
                Spacer(minLength: 74)
            } else {
                messageAvatar(message, size: 24)
                    .opacity(showsSender ? 1 : 0)
                    .accessibilityHidden(true)
            }

            VStack(alignment: own ? .trailing : .leading, spacing: 3) {
                if showsSender, !own {
                    Text(message.sender)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .padding(.leading, 3)
                }

                Text(message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(own ? Palette.selectedControlText : Palette.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(own ? roomAccent : Palette.messageSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .textSelection(.enabled)
            }

            if !own {
                Spacer(minLength: 74)
            }
        }
        .padding(.top, showsSender ? 5 : 0)
        .frame(maxWidth: .infinity)
    }

    private func messageAvatar(_ message: RoomMessage, size: CGFloat) -> some View {
        identityAvatar(id: message.senderID, name: message.sender, size: size)
    }

    private func identityAvatar(id: String?, name: String, size: CGFloat) -> some View {
        let participant = id.flatMap { participantID in
            model.participants.first { $0.id == participantID }
        }
        let appearance = DeviceAppearance.generated(from: id ?? name)
        let isCurrentDevice = id == nil || id == model.currentParticipantID
        return DeviceAvatar(
            emoji: isCurrentDevice
                ? model.currentDeviceIcon
                : participant?.icon ?? appearance.icon,
            colorHex: isCurrentDevice
                ? model.currentDeviceColorHex
                : participant?.colorHex ?? appearance.colorHex,
            profileImageData: isCurrentDevice
                ? model.currentDeviceProfileImageData
                : participant?.profileImageData,
            size: size
        )
        .accessibilityLabel(name)
    }

    private var peopleMixer: some View {
        VStack(spacing: 0) {
            panelHeader(
                title: "People",
                detail: "Each Mac has its own level",
                syncAction: model.syncAllDevices
            )
            Divider().opacity(0.42)
            if model.activePrivateInviteKey != nil {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    Text("Private room")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Button("Copy invite key", action: model.copyPrivateInviteKey)
                        .buttonStyle(PillButtonStyle(filled: false))
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                Divider().opacity(0.42)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.participants) { participant in
                        floatingParticipant(participant)
                        if participant.id != model.participants.last?.id {
                            Divider().opacity(0.34).padding(.leading, 54)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .overlay {
                if model.participants.isEmpty {
                    Text("Waiting for listeners…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func floatingParticipant(_ participant: RoomParticipant) -> some View {
        let controllable = model.canControl(participant)
        let appearance = DeviceAppearance.generated(from: participant.id)
        return HStack(spacing: 11) {
            DeviceAvatar(
                emoji: participant.icon ?? appearance.icon,
                colorHex: participant.colorHex ?? appearance.colorHex,
                profileImageData: participant.profileImageData,
                size: 32
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.id == model.currentParticipantID ? "You" : participant.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(participant.isMuted ? "Muted" : "In sync")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(participant.isMuted ? Palette.red : Palette.accentText)
            }
            .frame(width: 122, alignment: .leading)

            Image(systemName: "speaker.fill")
                .font(.system(size: 8))
                .foregroundStyle(Palette.controlIcon)
            Slider(
                value: Binding(
                    get: { participant.volume },
                    set: { model.setParticipantVolume(participant, volume: $0) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(Palette.controlAccent)
            .disabled(!controllable)
            Text("\(Int(participant.volume * 100))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.secondary)
                .frame(width: 25, alignment: .trailing)
            Button { model.toggleParticipantMute(participant) } label: {
                Image(systemName: participant.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(participant.isMuted ? Palette.red : Palette.controlIcon)
                    .frame(width: 32, height: 30)
            }
            .buttonStyle(FlatToolButtonStyle(active: participant.isMuted))
            .disabled(!controllable)
            .help(participant.isMuted ? "Unmute \(participant.name)" : "Mute \(participant.name)")
            .accessibilityLabel(participant.isMuted ? "Unmute \(participant.name)" : "Mute \(participant.name)")
            Button { model.syncParticipant(participant) } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.controlIcon)
                    .frame(width: 32, height: 30)
            }
            .buttonStyle(FlatToolButtonStyle(active: false))
            .help("Sync \(participant.id == model.currentParticipantID ? "this Mac" : participant.name) now")
            .accessibilityLabel("Sync \(participant.id == model.currentParticipantID ? "this Mac" : participant.name) now")
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .opacity(controllable ? 1 : 0.68)
    }

    private var videoPlayer: some View {
        ZStack(alignment: .bottom) {
            Palette.video
            if let frame = model.videoFrame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Opening the shared screen")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.white.opacity(0.7))
            }

            HStack(spacing: 9) {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
                Text(model.isHost ? "YOUR SCREEN" : "LIVE SCREEN")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                Spacer()
                Button(model.isHost ? "Stop sharing" : "Audio only") {
                    model.exitVideoFullscreen()
                    model.selectExperience(.audio)
                }
                .buttonStyle(VideoOverlayButtonStyle())
                Button(action: model.enterVideoFullscreen) {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(VideoControlButtonStyle())
                .help("Open video window")
                .accessibilityLabel("Open video window")
                Button(action: model.collapseFloatingBar) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(VideoControlButtonStyle())
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(12)
            .background(.ultraThinMaterial.opacity(0.76))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionPanel: some View {
        HStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle.badge.person.crop")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.accentText)
                .frame(width: 42, height: 42)
                .background(Palette.artworkFallback)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.recordingPermissionTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(model.recordingPermissionGuidance)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            if model.recordingRestartRequired {
                Button("Restart ALO", action: model.restartApplication)
                    .buttonStyle(PillButtonStyle(filled: true))
                Button("Open settings", action: model.openPrivacySettings)
                    .buttonStyle(PillButtonStyle(filled: false))
            } else {
                Button("Open settings", action: model.openPrivacySettings)
                    .buttonStyle(PillButtonStyle(filled: true))
                Button("Restart ALO", action: model.restartApplication)
                    .buttonStyle(PillButtonStyle(filled: false))
            }
            Button(action: model.dismissPermissionNotice) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(FlatToolButtonStyle(active: false))
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func panelHeader(
        title: String,
        detail: String,
        syncAction: (() -> Void)? = nil
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            if let syncAction {
                Button(action: syncAction) {
                    Label("Sync all", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle(filled: false))
                .help("Re-align every Mac to the room clock")
                .accessibilityLabel("Sync all Macs now")
            }
            Button(action: model.collapseFloatingBar) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.controlIcon)
                    .frame(width: 32, height: 30)
            }
            .buttonStyle(FlatToolButtonStyle(active: false))
            .help("Collapse")
            .accessibilityLabel("Collapse")
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }
}

private struct RoomAccentKey: EnvironmentKey {
    static let defaultValue = Palette.controlAccent
}

private extension EnvironmentValues {
    var roomAccent: Color {
        get { self[RoomAccentKey.self] }
        set { self[RoomAccentKey.self] = newValue }
    }
}

private struct FlatToolButtonStyle: ButtonStyle {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomAccent) private var roomAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(active ? roomAccent : configuration.isPressed ? Palette.controlHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0.08), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0.04), value: active)
    }
}

private struct SetupIconButtonStyle: ButtonStyle {
    var filled = false
    var active = false
    var onImage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(filled || active ? Palette.selectedControlText : onImage ? SetupPalette.ink : Palette.controlIcon)
            .frame(width: 38, height: 38)
            .background(filled || active ? Palette.controlAccent : onImage ? SetupPalette.surface : Palette.messageSurface)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(filled || active ? Color.clear : Palette.stroke, lineWidth: 1)
            )
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.34)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private struct SetupActionButtonStyle: ButtonStyle {
    var filled = false
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(filled || active ? Palette.selectedControlText : SetupPalette.ink)
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(filled || active ? Palette.controlAccent : SetupPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(filled || active ? Color.clear : Color.white.opacity(0.62), lineWidth: 1)
            )
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.34)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.84), value: configuration.isPressed)
    }
}

private struct InlineActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomAccent) private var roomAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.selectedControlText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(roomAccent.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
    }
}

private struct VideoOverlayButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.black.opacity(configuration.isPressed ? 0.48 : 0.3))
            .clipShape(Capsule())
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
    }
}

private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

private struct BottomDragHandle: View {
    var body: some View {
        Capsule()
            .fill(Palette.controlIcon.opacity(0.34))
            .frame(width: 72, height: 4)
            .frame(width: 132, height: 16)
            .contentShape(Rectangle())
            .overlay(WindowDragRegion())
            .help("Drag to move the Talk bar")
            .accessibilityLabel("Drag the Talk bar")
    }
}

private struct DeviceAvatar: View {
    let emoji: String
    let colorHex: String
    let profileImageData: Data?
    let size: CGFloat

    var body: some View {
        ZStack {
            Color.deviceIdentity(colorHex)
            if let data = profileImageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(emoji)
                    .font(.system(size: size * 0.48))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.deviceIdentity(colorHex).opacity(0.75), lineWidth: 1.5))
    }
}

private enum TalkTargetInteraction: Equatable {
    case toggle
    case hold
}

private extension OpenLineState {
    var isSendingMicrophone: Bool {
        switch self {
        case .inviting, .connected: true
        case .idle, .invited: false
        }
    }
}

private struct WalkieTalkieTargetIcon: View {
    @ObservedObject var model: WERAIViewModel
    let id: String?
    let name: String
    let icon: String
    let colorHex: String
    let profileImageData: Data?
    let interaction: TalkTargetInteraction
    @State private var isPressed = false

    var body: some View {
        let selected = interaction == .toggle ? model.isTalkTargetSelected(id) : isPushToTalkSelected
        let incoming = id.map(model.incomingWalkieSpeakerIDs.contains)
            ?? !model.incomingWalkieSpeakerIDs.isEmpty
        let outgoing = model.walkieTalking && selected
        let linePeer = id.map(model.isOpenLinePeer) ?? false
        Group {
            if interaction == .toggle {
                Button { model.toggleTalkTarget(id) } label: { avatar }
                    .buttonStyle(.plain)
            } else {
                avatar
                    .onLongPressGesture(
                        minimumDuration: .infinity,
                        maximumDistance: 18,
                        pressing: { pressed in
                            guard pressed != isPressed else { return }
                            isPressed = pressed
                            model.setPushToTalkPressed(pressed, targetID: id)
                        },
                        perform: {}
                    )
                    .onDisappear {
                        if isPressed {
                            isPressed = false
                            model.setPushToTalkPressed(false, targetID: id)
                        }
                    }
            }
        }
        .overlay {
            ZStack {
                Circle().stroke(
                    selected ? model.roomAccentColor.opacity(outgoing ? 1 : 0.55) : Color.clear,
                    lineWidth: 3
                )
                Circle()
                    .stroke(incoming ? Color.green : Color.clear, lineWidth: 3)
                    .padding(outgoing ? -4 : 0)
                Circle()
                    .stroke(linePeer ? lineColor : Color.clear, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                    .padding(-7)
            }
        }
        .shadow(color: incoming ? Color.green.opacity(0.65) : .clear, radius: 7)
        .frame(width: 40, height: 40)
        .contentShape(Circle())
        .contextMenu {
            if let id {
                if interaction == .toggle {
                    switch model.openLineState {
                    case .idle:
                        Button("Open line with \(name)") { model.inviteToOpenLine(id) }
                    case .invited(let invitation) where model.isOpenLinePeer(id):
                        Button("Join line") { model.respondToOpenLine(invitation, accept: true) }
                        Button("Decline") { model.respondToOpenLine(invitation, accept: false) }
                    case .inviting, .invited, .connected:
                        Button("Close line") { model.endOpenLine() }
                            .disabled(!model.isOpenLinePeer(id))
                    }
                    Divider()
                }
                Button("Sync \(name)") {
                    if let participant = model.participants.first(where: { $0.id == id }) {
                        model.syncParticipant(participant)
                    }
                }
            }
        }
        .help(helpText(selected: selected, incoming: incoming))
        .accessibilityLabel(interaction == .toggle ? "Talk to \(name)" : "Hold to talk to \(name)")
        .accessibilityValue(accessibilityValue(selected: selected, incoming: incoming, linePeer: linePeer))
    }

    private var avatar: some View {
        DeviceAvatar(
            emoji: icon,
            colorHex: colorHex,
            profileImageData: profileImageData,
            size: 30
        )
    }

    private var isPushToTalkSelected: Bool {
        let remoteIDs = Set(model.participants.lazy.filter { $0.id != model.currentParticipantID }.map(\.id))
        guard !remoteIDs.isEmpty else { return false }
        if let id { return model.pushToTalkTargetIDs.contains(id) }
        return remoteIDs.isSubset(of: model.pushToTalkTargetIDs)
    }

    private var lineColor: Color {
        switch model.openLineState {
        case .connected: Color.purple
        case .inviting, .invited: Color.orange
        case .idle: Color.clear
        }
    }

    private func helpText(selected: Bool, incoming: Bool) -> String {
        if incoming { return "\(name) is speaking · \(interaction == .toggle ? "Click to talk back" : "Hold to talk back")" }
        if interaction == .hold { return "Hold to talk to \(name)" }
        return selected ? "Click to stop talking to \(name)" : "Click to talk to \(name) · Right-click to open a line"
    }

    private func accessibilityValue(selected: Bool, incoming: Bool, linePeer: Bool) -> String {
        var states = [String]()
        if selected { states.append("Talking to this device") }
        if incoming { states.append("This device is speaking") }
        if linePeer { states.append("Open line participant") }
        return states.joined(separator: ", ")
    }
}

private struct WalkieTalkieBar: View {
    @ObservedObject var model: WERAIViewModel
    var showsCloseButton = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if showsCloseButton {
                VStack(spacing: 2) {
                    controls.glass(cornerRadius: 22)
                    BottomDragHandle()
                }
                .padding(.horizontal, FloatingMetrics.windowInset)
                .padding(.top, FloatingMetrics.windowInset)
            } else {
                controls.background(Palette.opaqueSurface)
            }
        }
        .onAppear(perform: model.refreshVoiceInputs)
        .environment(\.roomAccent, model.roomAccentColor)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1), value: model.roomAccentHex)
    }

    private var controls: some View {
        HStack(spacing: 8) {

                walkieTarget(id: nil, name: "Everyone", icon: "👥", colorHex: "3F86E8")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(remoteParticipants) { participant in
                        let appearance = DeviceAppearance.generated(from: participant.id)
                        walkieTarget(
                            id: participant.id,
                            name: participant.name,
                            icon: participant.icon ?? appearance.icon,
                            colorHex: participant.colorHex ?? appearance.colorHex,
                            profileImageData: participant.profileImageData
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
            .frame(maxWidth: .infinity)

            openLineControls

            communicationButton(
                icon: model.unreadMessageCount > 0 ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right",
                active: model.floatingSection == .chat,
                badge: model.unreadMessageCount,
                help: "Conversation"
            ) {
                showsCloseButton ? model.showChatInFloatingBar() : model.showChat()
            }
            .keyboardShortcut("1", modifiers: .command)

            communicationButton(
                icon: model.floatingSection == .people ? "person.2.fill" : "person.2",
                active: model.floatingSection == .people,
                help: "People and volume"
            ) {
                showsCloseButton ? model.showPeopleInFloatingBar() : model.showPeople()
            }
            .keyboardShortcut("2", modifiers: .command)

            Menu {
                    Menu("Microphone input") {
                        Button {
                            model.selectVoiceInput(nil)
                        } label: {
                            if model.selectedVoiceInputUID == nil {
                                Label(systemDefaultMicrophoneLabel, systemImage: "checkmark")
                            } else {
                                Text(systemDefaultMicrophoneLabel)
                            }
                        }
                        Divider()
                        ForEach(model.voiceInputDevices.filter { !$0.isSystemDefault }) { input in
                            Button {
                                model.selectVoiceInput(input.id)
                            } label: {
                                if input.id == model.selectedVoiceInputUID {
                                    Label(input.name, systemImage: "checkmark")
                                } else {
                                    Text(input.name)
                                }
                            }
                        }
                        Divider()
                        Button("Refresh microphones") { model.refreshVoiceInputs() }
                    }
                    Divider()
                    Button(model.incomingCallsMuted ? "Unmute incoming voice" : "Mute incoming voice") {
                        model.toggleIncomingCallsMute()
                    }
                    Button(model.incomingMediaMuted ? "Unmute incoming media" : "Mute incoming media") {
                        model.toggleIncomingMediaMute()
                    }
                    Divider()
                    Button(model.walkieBarHidden ? "Show Talk bar" : "Hide Talk bar") {
                        model.walkieBarHidden ? model.showWalkieBar() : model.hideWalkieBar()
                    }
                    Button(model.floatingBarHidden ? "Show media floating bar" : "Hide media floating bar") {
                        model.floatingBarHidden ? model.showFloatingBar() : model.hideFloatingBar()
                    }
                    Divider()
                    Button("Shortcut Mapper…") {
                        (NSApp.delegate as? WERAIAppDelegate)?.showShortcutMapper(nil)
                    }
                    Button("Diagnostics…") {
                        (NSApp.delegate as? WERAIAppDelegate)?.showDiagnostics(nil)
                    }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .help("Talk settings · \(selectedMicrophoneName)")

                if showsCloseButton {
                    Button(action: model.hideWalkieBar) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Hide Talk bar")
                    .accessibilityLabel("Hide Talk bar")
                }
        }
        .padding(.horizontal, 10)
        .frame(
            minWidth: showsCloseButton ? FloatingMetrics.walkieBarMinWidth : FloatingMetrics.width,
            maxWidth: showsCloseButton ? .infinity : FloatingMetrics.width,
            minHeight: FloatingMetrics.walkieBarHeight,
            maxHeight: FloatingMetrics.walkieBarHeight
        )
        .background(model.roomAccentColor.opacity(0.06))
    }

    private var remoteParticipants: [RoomParticipant] {
        model.participants.filter { $0.id != model.currentParticipantID }
    }

    private var selectedMicrophoneName: String {
        guard let selectedVoiceInputUID = model.selectedVoiceInputUID else {
            let defaultName = VoiceInputCatalog.systemDefaultName()
            return defaultName.map { "System Default · \($0)" } ?? "System Default"
        }
        return model.voiceInputDevices.first(where: { $0.id == selectedVoiceInputUID })?.name
            ?? "System microphone"
    }

    private var systemDefaultMicrophoneLabel: String {
        VoiceInputCatalog.systemDefaultName().map { "System Default — \($0)" }
            ?? "System Default Microphone"
    }

    @ViewBuilder
    private var openLineControls: some View {
        switch model.openLineState {
        case .idle:
            EmptyView()
        case .invited(let invitation):
            communicationButton(
                icon: "phone.fill",
                active: true,
                help: "Join line with \(invitation.callerName)"
            ) { model.respondToOpenLine(invitation, accept: true) }
            communicationButton(
                icon: "phone.down.fill",
                active: false,
                help: "Decline open line invitation"
            ) { model.respondToOpenLine(invitation, accept: false) }
        case .inviting(let invitation):
            communicationButton(
                icon: "phone.arrow.up.right.fill",
                active: true,
                help: "Waiting for \(model.openLinePeerName(invitation)) to join · Click to close"
            ) { model.endOpenLine() }
        case .connected(let invitation):
            communicationButton(
                icon: "phone.down.fill",
                active: true,
                help: "Close line with \(model.openLinePeerName(invitation))"
            ) { model.endOpenLine() }
        }
    }

    private func walkieTarget(
        id: String?,
        name: String,
        icon: String,
        colorHex: String,
        profileImageData: Data? = nil
    ) -> some View {
        WalkieTalkieTargetIcon(
            model: model,
            id: id,
            name: name,
            icon: icon,
            colorHex: colorHex,
            profileImageData: profileImageData,
            interaction: showsCloseButton ? .hold : .toggle
        )
    }

    private func communicationButton(
        icon: String,
        active: Bool,
        badge: Int = 0,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(FlatToolButtonStyle(active: active))
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                Text("\(min(badge, 99))")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 12)
                    .background(Palette.red)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Palette.opaqueSurface, lineWidth: 1))
                    .offset(x: 5, y: -9)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.35, anchor: .bottomLeading).combined(with: .opacity)
                    )
            }
        }
        .zIndex(badge > 0 ? 1 : 0)
        .help(help)
        .accessibilityLabel(help)
    }

}

@MainActor
private final class WalkieTalkieWindowController {
    private let panel: FloatingRoomPanel
    private var hasPosition = false
    private var participantObserver: AnyCancellable?

    init(model: WERAIViewModel) {
        panel = FloatingRoomPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: FloatingMetrics.walkieBarWidth(participantCount: model.participants.count)
                    + FloatingMetrics.windowInset * 2,
                height: FloatingMetrics.windowHeight(
                    for: FloatingMetrics.walkieBarHeight + FloatingMetrics.walkieDragHandleHeight
                )
            ),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(
            width: FloatingMetrics.walkieBarMinWidth + FloatingMetrics.windowInset * 2,
            height: FloatingMetrics.windowHeight(
                for: FloatingMetrics.walkieBarHeight + FloatingMetrics.walkieDragHandleHeight
            )
        )
        panel.maxSize = NSSize(
            width: FloatingMetrics.walkieBarMaxWidth + FloatingMetrics.windowInset * 2,
            height: FloatingMetrics.windowHeight(
                for: FloatingMetrics.walkieBarHeight + FloatingMetrics.walkieDragHandleHeight
            )
        )
        let hostingView = NSHostingView(rootView: WalkieTalkieBar(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        participantObserver = model.$participants
            .map(\.count)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] count in
                DispatchQueue.main.async { self?.fitParticipants(count: count) }
            }
    }

    func show() {
        if !hasPosition, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.minY + 98
            ))
            hasPosition = true
        }
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }

    private func fitParticipants(count: Int) {
        let width = FloatingMetrics.walkieBarWidth(participantCount: count)
            + FloatingMetrics.windowInset * 2
        guard width > panel.frame.width else { return }
        var frame = panel.frame
        frame.origin.x -= (width - frame.width) / 2
        frame.size.width = width
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }
}

private final class FloatingRoomPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FloatingRoomWindowController {
    private let panel: FloatingRoomPanel
    private let model: WERAIViewModel
    private var modelObserver: AnyCancellable?
    private var pendingShrink: DispatchWorkItem?
    private var hasPosition = false

    init(model: WERAIViewModel) {
        self.model = model
        panel = FloatingRoomPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: FloatingMetrics.windowWidth,
                height: FloatingMetrics.windowHeight(for: model.floatingPanelHeight)
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: FloatingRoomView(model: model))
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.drawsAsynchronously = true
        panel.contentView = hostingView

        modelObserver = Publishers.CombineLatest4(
            model.$floatingSection.removeDuplicates(),
            model.$permissionNotice.removeDuplicates(),
            model.$participants.map(\.count).removeDuplicates(),
            model.$incomingMessagePreview.map { $0?.id }.removeDuplicates()
        )
        .dropFirst()
        .sink { [weak self] _ in
            DispatchQueue.main.async { self?.resize(animated: true) }
        }
    }

    func show() {
        resize(animated: false)
        if !hasPosition, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: visible.midX - panel.frame.width / 2,
                    y: visible.minY + 24
                )
            )
            hasPosition = true
        }
        panel.orderFrontRegardless()
    }

    func close() {
        pendingShrink?.cancel()
        pendingShrink = nil
        panel.orderOut(nil)
    }

    private func resize(animated: Bool) {
        pendingShrink?.cancel()
        pendingShrink = nil

        let height = FloatingMetrics.windowHeight(for: model.floatingPanelHeight)
        guard abs(panel.frame.height - height) > 0.5
                || abs(panel.frame.width - FloatingMetrics.windowWidth) > 0.5 else { return }
        let shouldAnimate = animated
            && panel.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if shouldAnimate, height < panel.frame.height {
            let shrink = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingShrink = nil
                self.setPanelFrame(height: height)
            }
            pendingShrink = shrink
            DispatchQueue.main.asyncAfter(
                deadline: .now() + FloatingMetrics.expansionDuration,
                execute: shrink
            )
        } else {
            setPanelFrame(height: height)
        }
    }

    private func setPanelFrame(height: CGFloat) {
        let fixedBottomEdge = panel.frame.minY
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
        var frame = panel.frame
        frame.size = NSSize(width: FloatingMetrics.windowWidth, height: height)
        frame.origin.y = fixedBottomEdge
        if let screenFrame {
            frame.origin.x = min(max(frame.origin.x, screenFrame.minX), screenFrame.maxX - frame.width)
            frame.origin.y = max(frame.origin.y, screenFrame.minY)
            frame.size.height = min(frame.height, screenFrame.maxY - frame.origin.y)
        }
        panel.setFrame(frame, display: true)
    }
}

private final class FullScreenVideoWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct FullScreenVideoView: View {
    @ObservedObject var model: WERAIViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let frame = model.videoFrame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Opening the shared screen")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.white.opacity(0.72))
            }

            HStack(spacing: 10) {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
                Text(model.isHost ? "YOUR SCREEN" : "LIVE SCREEN")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                Text("·")
                Text(model.roomTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Button(model.isHost ? "Stop sharing" : "Audio only") {
                    model.selectExperience(.audio)
                }
                .buttonStyle(VideoOverlayButtonStyle())
                Button(action: model.toggleVideoViewerPinned) {
                    Image(systemName: model.videoViewerPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(VideoControlButtonStyle())
                .help(model.videoViewerPinned ? "Unpin from desktops" : "Keep on every desktop")
                .accessibilityLabel(model.videoViewerPinned ? "Unpin video window" : "Pin video window")
                Button(action: model.toggleVideoWindowFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(VideoControlButtonStyle())
                .help("Toggle full screen")
                .accessibilityLabel("Toggle full screen")
                Button(action: model.exitVideoFullscreen) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(VideoControlButtonStyle())
                .help("Close video window")
                .accessibilityLabel("Close video window")
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 14)
            .frame(width: 520, height: 48)
            .background(.ultraThinMaterial.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .padding(.bottom, 28)
        }
        .onExitCommand(perform: model.exitVideoFullscreen)
    }
}

@MainActor
private final class FullScreenVideoWindowController: NSObject, NSWindowDelegate {
    private let window: FullScreenVideoWindow
    private let closeHandler: () -> Void

    init(model: WERAIViewModel, closeHandler: @escaping () -> Void) {
        self.closeHandler = closeHandler
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let frame = NSRect(
            x: screen.midX - 480,
            y: screen.midY - 300,
            width: 960,
            height: 600
        )
        window = FullScreenVideoWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.delegate = self
        window.title = "Shared video · \(model.roomTitle)"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 520, height: 320)
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FullScreenVideoView(model: model))
    }

    func show() {
        guard !window.isVisible else { window.makeKeyAndOrderFront(nil); return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.orderOut(nil)
    }

    func toggleFullScreen() {
        window.toggleFullScreen(nil)
    }

    func setPinned(_ pinned: Bool) {
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenPrimary]
    }

    func windowWillClose(_ notification: Notification) {
        closeHandler()
    }
}

private struct AmbientBackground: View {
    let isLive: Bool

    var body: some View {
        ZStack {
            Palette.canvas
            Circle()
                .fill(Palette.accentSoft.opacity(isLive ? 0.56 : 0.72))
                .frame(width: 620, height: 620)
                .blur(radius: 86)
                .offset(x: -330, y: 250)
            Circle()
                .fill(Palette.blueSoft.opacity(0.5))
                .frame(width: 540, height: 540)
                .blur(radius: 100)
                .offset(x: 390, y: -260)
        }
        .ignoresSafeArea()
    }
}

private struct SetupBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let url = Bundle.main.url(forResource: "ALOSetupBackground", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    AmbientBackground(isLive: false)
                }
                LinearGradient(
                    colors: [Color.black.opacity(0.42), Color.black.opacity(0.08), Color.black.opacity(0.18)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }
}

private struct WaveformGlyph: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.09, paused: !active || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<9, id: \.self) { index in
                    let wave = abs(sin(time * 2.6 + Double(index) * 0.72))
                    Capsule()
                        .fill(index == 4 ? Palette.accent : Palette.ink.opacity(0.72))
                        .frame(width: 5, height: 14 + wave * 44)
                }
            }
        }
        .accessibilityLabel("Audio playing in sync")
    }
}

private struct PillButtonStyle: ButtonStyle {
    let filled: Bool
    var destructive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomAccent) private var roomAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? Palette.selectedControlText : destructive ? Palette.red : Palette.ink)
            .padding(.horizontal, 15)
            .frame(height: 36)
            .background(filled ? roomAccent : destructive ? Palette.redSoft : Palette.messageSurface)
            .clipShape(Capsule())
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

private struct ToolButtonStyle: ButtonStyle {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(active ? Palette.selectedControlText : Palette.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(active ? Palette.controlAccent : Color.clear)
            .clipShape(Capsule())
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0.08), value: configuration.isPressed)
    }
}

private struct VideoControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(Color.black.opacity(configuration.isPressed ? 0.48 : 0.28))
            .clipShape(Circle())
    }
}

private struct AdaptiveSurface: ViewModifier {
    let cornerRadius: CGFloat
    let elevated: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Palette.opaqueSurface)
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Palette.strokeStrong, lineWidth: 1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: max(0, cornerRadius - 1), style: .continuous)
                    .stroke(Palette.glassHighlight, lineWidth: 1)
                    .padding(1)
                    .mask(
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .shadow(color: elevated ? Palette.shadow : .clear, radius: elevated ? 24 : 0, y: elevated ? 12 : 0)
    }
}

private extension View {
    func floatingSurface(cornerRadius: CGFloat) -> some View {
        modifier(AdaptiveSurface(cornerRadius: cornerRadius, elevated: false))
    }

    func glass(cornerRadius: CGFloat) -> some View {
        modifier(AdaptiveSurface(cornerRadius: cornerRadius, elevated: true))
    }
}

private enum Palette {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let ink = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let muted = Color(nsColor: .tertiaryLabelColor)
    static let controlAccent = adaptive(
        light: NSColor(red: 0.08, green: 0.34, blue: 0.70, alpha: 1),
        dark: NSColor(red: 0.29, green: 0.61, blue: 0.93, alpha: 1)
    )
    static let selectedControlText = Color(nsColor: .selectedControlTextColor)
    static let controlIcon = Color(nsColor: .labelColor)
    static let composer = Color(nsColor: .textBackgroundColor).opacity(0.9)
    static let opaqueSurface = Color(nsColor: .windowBackgroundColor)
    static let messageSurface = Color(nsColor: .controlBackgroundColor).opacity(0.82)
    static let controlHover = Color(nsColor: .quaternaryLabelColor).opacity(0.22)
    static let stroke = Color(nsColor: .separatorColor).opacity(0.72)
    static let strokeStrong = Color(nsColor: .separatorColor)
    static let glassHighlight = adaptive(
        light: NSColor(white: 1, alpha: 0.5),
        dark: NSColor(white: 1, alpha: 0.16)
    )
    static let accent = controlAccent
    static let accentText = adaptive(
        light: NSColor(red: 0.05, green: 0.25, blue: 0.58, alpha: 1),
        dark: NSColor(red: 0.68, green: 0.83, blue: 1.0, alpha: 1),
        highContrastLight: NSColor(red: 0.02, green: 0.16, blue: 0.43, alpha: 1),
        highContrastDark: NSColor(red: 0.80, green: 0.90, blue: 1.0, alpha: 1)
    )
    static let syncText = accentText
    static let detailText = adaptive(
        light: NSColor(red: 0.25, green: 0.25, blue: 0.24, alpha: 1),
        dark: NSColor(red: 0.82, green: 0.82, blue: 0.80, alpha: 1),
        highContrastLight: .black,
        highContrastDark: .white
    )
    static let accentDark = accentText
    static let accentSoft = adaptive(
        light: NSColor(red: 0.82, green: 0.88, blue: 0.97, alpha: 1),
        dark: NSColor(red: 0.08, green: 0.13, blue: 0.25, alpha: 1)
    )
    static let artworkFallback = accentSoft
    static let blueSoft = adaptive(
        light: NSColor(red: 0.72, green: 0.82, blue: 0.95, alpha: 1),
        dark: NSColor(red: 0.10, green: 0.16, blue: 0.31, alpha: 1)
    )
    static let video = Color(red: 0.055, green: 0.070, blue: 0.12)
    static let red = Color(nsColor: .systemRed)
    static let redSoft = Color(nsColor: .systemRed).opacity(0.16)
    static let shadow = Color(red: 0.025, green: 0.055, blue: 0.12).opacity(0.18)

    private static func adaptive(
        light: NSColor,
        dark: NSColor,
        highContrastLight: NSColor? = nil,
        highContrastDark: NSColor? = nil
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastAqua,
                .darkAqua,
                .aqua,
            ]) {
            case .accessibilityHighContrastDarkAqua:
                highContrastDark ?? dark
            case .accessibilityHighContrastAqua:
                highContrastLight ?? light
            case .darkAqua:
                dark
            default:
                light
            }
        })
    }
}

private enum SetupPalette {
    static let ink = Color(red: 0.055, green: 0.075, blue: 0.055)
    static let secondary = Color(red: 0.23, green: 0.28, blue: 0.22)
    static let muted = Color(red: 0.42, green: 0.46, blue: 0.40)
    static let stroke = Color.black.opacity(0.10)
    static let surface = Color.white.opacity(0.78)
}

enum ArtworkTheme {
    static func accentHex(from data: Data?) -> String? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 32,
                ] as CFDictionary
              )
        else { return nil }

        let sampleSize = 8
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drewImage = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let address = bytes.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: sampleSize,
                    height: sampleSize,
                    bitsPerComponent: 8,
                    bytesPerRow: sampleSize * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                  )
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            return true
        }
        guard drewImage else { return nil }

        var redTotal = 0.0
        var greenTotal = 0.0
        var blueTotal = 0.0
        var weightTotal = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 16 {
            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let saturation = maximum == 0 ? 0 : (maximum - minimum) / maximum
            let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
            let weight = max(0.06, saturation) * (0.45 + luminance * 0.55)
            redTotal += red * weight
            greenTotal += green * weight
            blueTotal += blue * weight
            weightTotal += weight
        }
        guard weightTotal > 0 else { return nil }

        let average = NSColor(
            srgbRed: redTotal / weightTotal,
            green: greenTotal / weightTotal,
            blue: blueTotal / weightTotal,
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        guard saturation >= 0.08 else { return nil }

        let accent = NSColor(
            calibratedHue: hue,
            saturation: min(0.68, max(0.34, saturation * 1.08)),
            brightness: min(0.70, max(0.50, brightness)),
            alpha: 1
        ).usingColorSpace(.sRGB) ?? average
        return String(
            format: "%02X%02X%02X",
            Int((accent.redComponent * 255).rounded()),
            Int((accent.greenComponent * 255).rounded()),
            Int((accent.blueComponent * 255).rounded())
        )
    }
}

private extension Color {
    static func deviceIdentity(_ hex: String) -> Color {
        let normalized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else {
            return Palette.controlAccent
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private extension NSImage {
    static func deviceAvatar(
        emoji: String,
        color: NSColor,
        profileImageData: Data?,
        size: CGFloat
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let circle = NSBezierPath(ovalIn: bounds)
        color.setFill()
        circle.fill()
        circle.addClip()
        if let data = profileImageData, let profile = NSImage(data: data) {
            profile.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        } else {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (emoji as NSString).draw(
                in: NSRect(x: 0, y: size * 0.14, width: size, height: size * 0.72),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: size * 0.52),
                    .paragraphStyle: style,
                ]
            )
        }
        image.unlockFocus()
        return image
    }
}

private extension NSColor {
    static func deviceIdentity(_ hex: String) -> NSColor {
        let normalized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else {
            return .controlAccentColor
        }
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
