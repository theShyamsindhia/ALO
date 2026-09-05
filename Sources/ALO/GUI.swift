import AppKit
import AVFoundation
import Combine
import CoreGraphics
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import ALOCore
import os

private enum ALOAppFlavor {
    static var isDevelopment: Bool {
        Bundle.main.bundleIdentifier == "in.werai.audio.dev"
    }

    static var displayName: String { isDevelopment ? "ALO Dev" : "ALO" }
}

enum ALOMenuBarRecord {
    struct TrackIdentity: Equatable {
        let title: String?
        let artist: String?
        let album: String?
        let sourceURL: String?
    }

    static let statusItemWidth: CGFloat = 32
    static let recordSize = NSSize(width: 27, height: 27)

    static func trackIdentity(for media: NowPlayingMedia) -> TrackIdentity? {
        func cleaned(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }

        let identity = TrackIdentity(
            title: cleaned(media.title),
            artist: cleaned(media.artist),
            album: cleaned(media.album),
            sourceURL: cleaned(media.sourceURL)
        )
        guard identity.title != nil
                || identity.artist != nil
                || identity.album != nil
                || identity.sourceURL != nil
        else { return nil }
        return identity
    }

    static func shouldFlip(from previous: TrackIdentity?, to next: TrackIdentity?) -> Bool {
        guard let previous, let next else { return false }
        return previous != next
    }

    static func image(active: Bool, artwork: NSImage?, palette: ArtworkPalette?) -> NSImage {
        let image = NSImage(size: recordSize, flipped: false) { bounds in
            let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
            NSGraphicsContext.saveGraphicsState()
            disc.addClip()

            if let artwork, artwork.size.width > 0, artwork.size.height > 0 {
                artwork.draw(
                    in: bounds,
                    from: croppedSourceRect(for: artwork, destination: bounds),
                    operation: .sourceOver,
                    fraction: active ? 1 : 0.72,
                    respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            } else {
                (palette?.hexes.first.map(NSColor.deviceIdentity)
                    ?? NSColor(calibratedWhite: active ? 0.16 : 0.11, alpha: 1)).setFill()
                bounds.fill()
                drawSymbol(active ? "music.note" : "person.2.fill", in: bounds)
            }

            NSColor.black.withAlphaComponent(0.13).setStroke()
            for inset in [CGFloat(4.5), 8] {
                let groove = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
                groove.lineWidth = 0.5
                groove.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()

            NSColor.white.withAlphaComponent(0.3).setStroke()
            disc.lineWidth = 0.75
            disc.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = ALOAppFlavor.displayName
        return image
    }

    private static func croppedSourceRect(for image: NSImage, destination: NSRect) -> NSRect {
        let sourceAspect = image.size.width / image.size.height
        let destinationAspect = destination.width / destination.height
        var source = NSRect(origin: .zero, size: image.size)
        if sourceAspect > destinationAspect {
            source.size.width = image.size.height * destinationAspect
            source.origin.x = (image.size.width - source.width) / 2
        } else {
            source.size.height = image.size.width / destinationAspect
            source.origin.y = (image.size.height - source.height) / 2
        }
        return source
    }

    private static func drawSymbol(_ name: String, in bounds: NSRect) {
        guard let source = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) else { return }

        let symbol = NSImage(size: source.size, flipped: false) { symbolBounds in
            source.draw(in: symbolBounds, from: .zero, operation: .sourceOver, fraction: 1)
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setBlendMode(.sourceIn)
            context.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)
            context.fill(symbolBounds)
            return true
        }
        let scale = min(12 / symbol.size.width, 12 / symbol.size.height)
        let fitted = NSRect(
            x: bounds.midX - symbol.size.width * scale / 2,
            y: bounds.midY - symbol.size.height * scale / 2,
            width: symbol.size.width * scale,
            height: symbol.size.height * scale
        )
        symbol.draw(
            in: fitted,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

@MainActor
private final class ALOStatusRecordView: NSView {
    private static let spinKey = "alo-record-spin"
    private static let flipKey = "alo-record-flip"

    private let flipLayer = CALayer()
    private let artworkLayer = CALayer()
    private let edgeLayer = CALayer()
    private let spindleLayer = CALayer()
    private let badgeLayer = CALayer()
    private var lastIdentity: ALOMenuBarRecord.TrackIdentity?
    private weak var lastArtwork: NSImage?
    private var lastPalette: ArtworkPalette?
    private var lastActive = false
    private var hasImage = false
    private var isSpinning = false
    private var isWaitingForFlipSwap = false
    private var flipTargetImage: NSImage?
    private var flipGeneration = 0
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 180
        layer?.sublayerTransform = perspective

        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.masksToBounds = true
        flipLayer.addSublayer(artworkLayer)
        layer?.addSublayer(flipLayer)

        edgeLayer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        edgeLayer.borderWidth = 0.5
        layer?.addSublayer(edgeLayer)

        spindleLayer.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.9).cgColor
        spindleLayer.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        spindleLayer.borderWidth = 0.75
        layer?.addSublayer(spindleLayer)

        badgeLayer.backgroundColor = NSColor.systemRed.cgColor
        badgeLayer.borderColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        badgeLayer.borderWidth = 1
        badgeLayer.isHidden = true
        layer?.addSublayer(badgeLayer)

        installSpinAnimation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let diameter = min(ALOMenuBarRecord.recordSize.width, max(0, bounds.height - 1))
        let discFrame = NSRect(
            x: floor((bounds.width - diameter) / 2),
            y: floor((bounds.height - diameter) / 2),
            width: diameter,
            height: diameter
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flipLayer.frame = discFrame
        artworkLayer.frame = NSRect(origin: .zero, size: discFrame.size)
        artworkLayer.cornerRadius = diameter / 2
        edgeLayer.frame = discFrame
        edgeLayer.cornerRadius = diameter / 2

        let spindleSize: CGFloat = 4.5
        spindleLayer.frame = NSRect(
            x: discFrame.midX - spindleSize / 2,
            y: discFrame.midY - spindleSize / 2,
            width: spindleSize,
            height: spindleSize
        )
        spindleLayer.cornerRadius = spindleSize / 2

        let badgeSize: CGFloat = 7
        badgeLayer.frame = NSRect(
            x: discFrame.maxX - badgeSize + 1,
            y: discFrame.maxY - badgeSize + 1,
            width: badgeSize,
            height: badgeSize
        )
        badgeLayer.cornerRadius = badgeSize / 2
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(
        active: Bool,
        playing: Bool,
        unreadCount: Int,
        media: NowPlayingMedia,
        artwork: NSImage?,
        palette: ArtworkPalette?
    ) {
        let identity = ALOMenuBarRecord.trackIdentity(for: media)
        let trackChanged = active && ALOMenuBarRecord.shouldFlip(from: lastIdentity, to: identity)
        let imageChanged = !hasImage || lastActive != active || lastArtwork !== artwork || lastPalette != palette
        lastIdentity = identity
        lastActive = active
        lastArtwork = artwork
        lastPalette = palette

        if trackChanged || imageChanged {
            let image = ALOMenuBarRecord.image(active: active, artwork: artwork, palette: palette)
            if trackChanged && !reduceMotion {
                flip(to: image)
            } else if isWaitingForFlipSwap {
                flipTargetImage = image
            } else {
                setImage(image, crossfade: hasImage && !reduceMotion)
            }
            hasImage = true
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badgeLayer.isHidden = unreadCount == 0
        CATransaction.commit()
        setSpinning(active && playing && artwork != nil && !reduceMotion)
    }

    func setReduceMotion(_ enabled: Bool) {
        guard reduceMotion != enabled else { return }
        reduceMotion = enabled
        if enabled {
            flipGeneration &+= 1
            isWaitingForFlipSwap = false
            flipTargetImage = nil
            hasImage = false
            flipLayer.removeAnimation(forKey: Self.flipKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            flipLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            setSpinning(false)
        }
    }

    private func setImage(_ image: NSImage, crossfade: Bool) {
        guard let contents = cgImage(from: image) else { return }
        if crossfade {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.14
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            artworkLayer.add(transition, forKey: "alo-record-artwork")
        }
        artworkLayer.contents = contents
    }

    private func flip(to image: NSImage) {
        flipGeneration &+= 1
        let generation = flipGeneration
        isWaitingForFlipSwap = true
        flipTargetImage = image
        flipLayer.removeAnimation(forKey: Self.flipKey)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flipLayer.transform = CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
        CATransaction.commit()

        let flipOut = CABasicAnimation(keyPath: "transform.rotation.y")
        flipOut.fromValue = 0
        flipOut.toValue = CGFloat.pi / 2
        flipOut.duration = 0.16
        flipOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
        flipLayer.add(flipOut, forKey: Self.flipKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + flipOut.duration) { [weak self] in
            guard let self, self.flipGeneration == generation else { return }
            self.setImage(self.flipTargetImage ?? image, crossfade: false)
            self.flipTargetImage = nil
            self.isWaitingForFlipSwap = false

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.flipLayer.transform = CATransform3DIdentity
            CATransaction.commit()

            let flipIn = CABasicAnimation(keyPath: "transform.rotation.y")
            flipIn.fromValue = -CGFloat.pi / 2
            flipIn.toValue = 0
            flipIn.duration = 0.2
            flipIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.flipLayer.add(flipIn, forKey: Self.flipKey)
        }
    }

    private func installSpinAnimation() {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = CGFloat.pi * 2
        animation.duration = 9
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        artworkLayer.add(animation, forKey: Self.spinKey)
        artworkLayer.speed = 0
        artworkLayer.timeOffset = 0
    }

    private func setSpinning(_ spinning: Bool) {
        guard spinning != isSpinning else { return }
        isSpinning = spinning
        if spinning {
            let pausedTime = artworkLayer.timeOffset
            artworkLayer.speed = 1
            artworkLayer.timeOffset = 0
            artworkLayer.beginTime = 0
            artworkLayer.beginTime = artworkLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        } else {
            let pausedTime = artworkLayer.convertTime(CACurrentMediaTime(), from: nil)
            artworkLayer.speed = 0
            artworkLayer.timeOffset = pausedTime
        }
    }

    private func cgImage(from image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

@MainActor
enum GUIApplication {
    private static var appDelegate: ALOAppDelegate?

    static func run() {
        _ = BroadcastAudioRouter().recoverStaleRoute()
        let application = NSApplication.shared
        let delegate = ALOAppDelegate()
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
func toggleALOSetupWindow(_ window: NSWindow) {
    if window.isVisible {
        window.orderOut(nil)
    } else {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class ALOAppDelegate: NSObject, NSApplicationDelegate {
    private enum SetupWindow {
        static let width: CGFloat = 306
        static let collapseDuration: TimeInterval = 0.28

        @MainActor static func height(for model: ALOViewModel) -> CGFloat {
            switch model.phase {
            case .idle:
                return 426
            case .starting:
                return 270
            case .failed:
                return 330
            case .live:
                return 270
            }
        }
    }

    private let model = ALOViewModel()
    private let updater = AppUpdater()
    private var window: NSWindow?
    private var roomBarController: FloatingRoomWindowController?
    private var walkieTalkieBarController: WalkieTalkieWindowController?
    private var fullScreenVideoController: FullScreenVideoWindowController?
    private var statusMenuController: ALOStatusMenuController?
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
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ALOAppFlavor.displayName
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: ALOView(
            model: model,
            checkForUpdates: ALOAppFlavor.isDevelopment ? nil : { [weak self] in
                self?.updater.checkForUpdates(userInitiated: true)
            }
        ))
        window.center()
        setupWindowFrame = window.frame
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        statusMenuController = ALOStatusMenuController(model: model) { [weak self] in
            guard let window = self?.window else { return }
            toggleALOSetupWindow(window)
        }
        if !ALOAppFlavor.isDevelopment {
            updater.updateAvailabilityHandler = { [weak model] version in model?.availableUpdateVersion = version }
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

    private func updateWindows(for phase: ALOViewModel.Phase) {
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
private final class ALOStatusMenuController: NSObject, NSPopoverDelegate {
    private var roomTouchBar: RoomTouchBarController?
    private let model: ALOViewModel
    private let toggleMainWindow: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var recordView: ALOStatusRecordView?
    private var observers = Set<AnyCancellable>()
    private var isLive = false
    private var isTransmittingVoice = false
    private var isReceivingVoice = false
    private var unreadCount = 0
    private var artworkData: Data?
    private var artwork: NSImage?
    private var artworkPalette: ArtworkPalette?

    init(model: ALOViewModel, toggleMainWindow: @escaping () -> Void) {
        self.model = model
        self.toggleMainWindow = toggleMainWindow
        statusItem = NSStatusBar.system.statusItem(withLength: ALOMenuBarRecord.statusItemWidth)
        super.init()
        statusItem.button?.toolTip = ALOAppFlavor.displayName
        if let button = statusItem.button {
            button.image = nil
            button.title = ""
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp])
            button.setAccessibilityHelp("Click to show or hide ALO")
            button.wantsLayer = true
            let recordView = ALOStatusRecordView(frame: button.bounds)
            recordView.autoresizingMask = [.width, .height]
            button.addSubview(recordView)
            self.recordView = recordView
        }
        refreshStatusRecord()

        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentSize = panelSize
        let popoverController = NSHostingController(
            rootView: VStack(spacing: 0) {
                FloatingRoomView(model: model, presentation: .menuBar)
                RoomPlaybackProgressDivider(model: model)
                WalkieTalkieBar(model: model, showsCloseButton: false)
            }
            .background(Palette.opaqueSurface)
        )
        popoverController.view.wantsLayer = true
        popoverController.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        popover.contentViewController = popoverController
        let touchBar = RoomTouchBarController(model: model, onGames: { [weak model] in model?.showGamesLibrary() })
        touchBar.attach(to: popoverController)
        roomTouchBar = touchBar

        model.$unreadMessageCount
            .removeDuplicates()
            .sink { [weak self] count in self?.updateBadge(count: count) }
            .store(in: &observers)
        model.$phase
            .removeDuplicates()
            .sink { [weak self] phase in self?.updatePhase(phase) }
            .store(in: &observers)
        model.$nowPlaying
            .sink { [weak self] media in self?.updateNowPlaying(media) }
            .store(in: &observers)
        model.$roomArtworkPalette
            .removeDuplicates()
            .sink { [weak self] palette in
                self?.artworkPalette = palette
                self?.refreshStatusRecord()
            }
            .store(in: &observers)
        model.$audioIsRendering
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshStatusRecord() }
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

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard model.phase == .live else {
            toggleMainWindow()
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
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.animates = !reduceMotion
        recordView?.setReduceMotion(reduceMotion)
        refreshStatusRecord()
    }

    private func updateBadge(count: Int) {
        unreadCount = count
        refreshStatusRecord()
    }

    private func updatePhase(_ phase: ALOViewModel.Phase) {
        if phase != .live { closePopover() }
        isLive = phase == .live
        refreshStatusRecord()
    }

    private func updateNowPlaying(_ media: NowPlayingMedia) {
        if artworkData != media.artworkData {
            artworkData = media.artworkData
            artwork = media.artworkData.flatMap(NSImage.init(data:))
        }
        refreshStatusRecord()
    }

    private func updateVoiceIndicator(transmitting: Bool, receiving: Bool) {
        isTransmittingVoice = transmitting
        isReceivingVoice = receiving
        refreshStatusRecord()
    }

    private func refreshStatusRecord() {
        guard let button = statusItem.button else { return }
        let title = model.nowPlaying.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        recordView?.update(
            active: isLive,
            playing: model.roomIsPlaying,
            unreadCount: unreadCount,
            media: model.nowPlaying,
            artwork: artwork,
            palette: artworkPalette
        )
        let playbackDetail = title.flatMap { $0.isEmpty ? nil : $0 }.map {
            " · \($0) · \(model.roomIsPlaying ? "playing" : "paused")"
        } ?? ""
        let voiceDetail = isTransmittingVoice
            ? " · speaking"
            : isReceivingVoice ? " · receiving voice" : ""
        let unreadDetail = unreadCount == 0
            ? ""
            : " · \(unreadCount) unread message\(unreadCount == 1 ? "" : "s")"
        let detail = ALOAppFlavor.displayName + playbackDetail + voiceDetail + unreadDetail
        button.toolTip = detail
        button.setAccessibilityLabel(detail)
    }
}

typealias RoomMessage = RoomChatMessage

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
    static let walkieBarHeight: CGFloat = 56
    static let walkieBarHandleGap: CGFloat = 6
    static let walkieBarHandleTargetHeight: CGFloat = 24
    static let walkieBarMinWidth: CGFloat = 300
    static let walkieBarMaxWidth: CGFloat = 720

    static var walkieFloatingHeight: CGFloat {
        walkieBarHeight + walkieBarHandleGap + walkieBarHandleTargetHeight
    }

    static func walkieBarWidth(participantCount: Int) -> CGFloat {
        min(walkieBarMaxWidth, max(walkieBarMinWidth, CGFloat(participantCount) * 40 + 252))
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
final class ALOViewModel: ObservableObject {
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
    @Published var roomsRefreshing = false
    @Published var roomsRefreshError: String?
    @Published var availableUpdateVersion: String?
    @Published var createPrivateRoom = false
    @Published var privateRoomKey = ""
    @Published var statusText = "Ready"
    @Published var errorMessage: String?
    @Published var errorIsPermissionRelated = false
    @Published var participants = [RoomParticipant]()
    @Published var messages = [RoomMessage]()
    private var chatDocument = RoomChatDocument()
    @Published var chatNotificationMode = ChatNotificationMode(rawValue: UserDefaults.standard.string(forKey: "chatNotificationMode") ?? "all") ?? .all {
        didSet { UserDefaults.standard.set(chatNotificationMode.rawValue, forKey: "chatNotificationMode") }
    }
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
    /// Tracks only the audience selected from the compact menu-bar controls.
    /// The target set remains the source of truth for transport routing.
    @Published private(set) var compactTalkSelection: String?
    @Published private(set) var walkieTalking = false
    @Published private(set) var walkieStarting = false
    @Published private(set) var incomingWalkieSpeakerIDs = Set<String>()
    @Published private(set) var incomingWalkieLevels = [String: Double]()
    @Published private(set) var openLineState: OpenLineState = .idle
    @Published private(set) var voiceInputDevices = [VoiceInputDevice]()
    @Published var selectedVoiceInputUID: String?
    @Published var walkieBarHidden: Bool
    @Published var incomingMediaMuted: Bool
    @Published var incomingCallsMuted: Bool
    @Published var roomHasVideo = false
    @Published var nowPlaying = NowPlayingMedia()
    private var nowPlayingReceivedAt = Date()
    @Published private(set) var roomAccentHex: String?
    @Published private(set) var roomArtworkPalette: ArtworkPalette?
    @Published var localNowPlaying = NowPlayingMedia()
    @Published private(set) var audioIsRendering = false
    @Published private(set) var liveSyncHealth = LiveSyncHealth()
    @Published var experience: Experience = .audio
    @Published var mediaSwitchBusy = false
    @Published var permissionNotice = false
    @Published private(set) var recordingRestartRequired = false
    @Published var floatingNavigationVisible = UserDefaults.standard.object(forKey: "room.floating.navigationVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(floatingNavigationVisible, forKey: "room.floating.navigationVisible") }
    }
    var floatingNavigationHeight: CGFloat { floatingNavigationVisible ? FloatingMetrics.walkieBarHeight : 0 }
    @Published var floatingSection: FloatingSection = .collapsed
    @Published var floatingBarHidden: Bool
    @Published private(set) var menuBarPopoverVisible = false

    private var roomBrowser: MeshRoomBrowser!
    let arena = ArenaSession()
    let lyrics = LyricsController()
    @Published var roomGamesVisible = false
    @Published var activityInvitation: ArenaSession.Lobby?
    private var activityInvitationTask: Task<Void, Never>?
    @Published private(set) var localAudioTiming: ReceiverTimingDiagnostics?
    @Published private(set) var automaticAudioSync = UserDefaults.standard.object(forKey: "automaticAudioSync") as? Bool ?? true
    private var meshSession: MeshSession?
    private var liveSyncTask: Task<Void, Never>?
    private let syncHealthLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "in.werai.audio", category: "synchronization")
    private var requestedVideoBroadcast = false
    private var videoBroadcastTimeoutTask: Task<Void, Never>?
    @Published private(set) var musicDuckingEnabled = UserDefaults.standard.bool(forKey: "musicDuckingEnabled")
    @Published private var participantVoiceLevels = VoiceLevelStore().levels
    private let voiceLevelStore = VoiceLevelStore()
    private var voiceVolumesBeforeMute = [String: Double]()
    private let roomStore = RoomStore()
    private let lastJoinedRoomStore = LastJoinedRoomStore()
    private let nodeID: String
    private let audioOutput = RoomAudioOutputEngine()
    private var localNowPlayingMonitor: NowPlayingMonitor?
    private var deviceIdentityEditor: DeviceIdentityEditorController?
    private var incomingMessagePreviewTask: Task<Void, Never>?
    private var chatViewportsAtLatest = Set<UUID>()
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

    init(discoverRooms: Bool = true) {
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
            $0.id == savedVoiceInput
        })
            ? savedVoiceInput
            : nil
        selectedRoomID = nil
        roomBrowser = MeshRoomBrowser(
            updateHandler: { [weak self] rooms in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.nearbyRooms = rooms
                    if let selected = self.selectedRoomID, !self.roomChoices.contains(where: { $0.id == selected }) {
                        self.selectedRoomID = nil
                    }
                }
            },
            errorHandler: { [weak self] message in
                DispatchQueue.main.async {
                    self?.roomsRefreshing = false
                    self?.roomsRefreshError = message
                    self?.statusText = "Local network unavailable: \(message)"
                }
            },
            readyHandler: { [weak self] in
                DispatchQueue.main.async {
                    self?.roomsRefreshing = false
                    self?.roomsRefreshError = nil
                }
            }
        )
        if discoverRooms { roomBrowser.start() }
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
            hasMedia: !nowPlaying.isEmpty || audioIsRendering
        )
    }
    func roomPlaybackProgress(at date: Date) -> Double? {
        nowPlaying.playbackProgress(elapsedSinceReceipt: date.timeIntervalSince(nowPlayingReceivedAt))
    }
    var canControlRoomPlayback: Bool {
        Self.playbackControlAvailable(
            isLive: phase == .live,
            hasBroadcaster: hasBroadcaster,
            isHost: isHost,
            hasMedia: !nowPlaying.isEmpty || audioIsRendering
        )
    }
    var roomAccentColor: Color {
        roomAccentHex.map(Color.deviceIdentity) ?? Palette.controlAccent
    }
    var roomAtmosphereColors: [Color] {
        roomArtworkPalette?.hexes.map(Color.deviceIdentity)
            ?? [Palette.controlAccent, Palette.accentSoft, Palette.blueSoft]
    }
    var roomSyncLabel: String {
        if !hasBroadcaster { return "No broadcaster" }
        if nowPlaying.isPlaying == false { return "Paused" }
        if isHost {
            if nowPlaying.isEmpty { return "Waiting for audio" }
            if participants.count <= 1 { return "Broadcasting" }
            return liveSyncHealth.playbackLabel(isHost: true, now: MonotonicClock.nowNanos())
        }
        if audioIsRendering { return liveSyncHealth.playbackLabel(isHost: false, now: MonotonicClock.nowNanos()) }
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
                accessKey: key,
                icon: room.icon
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
                selectedRoomID = nil
            }
        } catch {
            errorMessage = "Could not forget the room: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func renameRoom(roomID: String, to proposedName: String) -> Bool {
        let name = String(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard phase == .idle, !name.isEmpty else { return false }
        do {
            guard try roomStore.rename(roomID: roomID, to: name) else { return false }
            savedRooms = roomStore.load()
            statusText = "Renamed space to \(name)"
            return true
        } catch {
            errorMessage = "Could not rename the space: \(error.localizedDescription)"
            return false
        }
    }

    func copyPrivateInviteKey(roomID: String) {
        guard let room = savedRooms.first(where: { $0.id == roomID }),
              room.isPrivate,
              let key = room.accessKey
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        statusText = "Private space invite key copied"
    }

    func setRoomIcon(roomID: String, symbol: String) {
        guard phase == .idle, let room = savedRooms.first(where: { $0.id == roomID }),
              RoomIcon.choices.contains(where: { $0.symbol == symbol }) else { return }
        let nearbyIcon = nearbyRooms.first(where: { $0.id == roomID })?.icon
        let counter = max(room.icon?.version.counter ?? 0, nearbyIcon?.version.counter ?? 0)
        guard counter < UInt64.max - 1 else { return }
        let icon = RoomIcon(symbol: symbol, version: MeshVersion(counter: counter + 1, nodeID: nodeID))
        do {
            try roomStore.mergeIcon(icon, roomID: roomID)
            savedRooms = roomStore.load()
        } catch {
            errorMessage = "Could not save the space icon: \(error.localizedDescription)"
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
            audioOutput: audioOutput,
            initialEvents: roomStore.loadEvents(roomID: room.id),
            initialRoomStateDocument: roomStore.loadRoomStateDocument(roomID: room.id),
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
            roomIconHandler: { [weak self] icon in
                guard let self else { return }
                do {
                    try self.roomStore.mergeIcon(icon, roomID: room.id)
                    self.savedRooms = self.roomStore.load()
                    if self.activeRoomConfiguration?.id == room.id { self.activeRoomConfiguration?.icon = icon }
                } catch {
                    self.errorMessage = "Could not save the shared space icon: \(error.localizedDescription)"
                }
            },
            arenaHandler: { [weak self] sender, data in self?.arena.receive(from: sender, data: data) },
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
            walkieTalkieStateHandler: { [weak self] senderID, senderName, active, level in
                guard let self else { return }
                guard !self.incomingCallsMuted else {
                    self.incomingWalkieSpeakerIDs.removeAll()
                    self.incomingWalkieLevels.removeAll()
                    return
                }
                let wasActive = self.incomingWalkieSpeakerIDs.contains(senderID)
                if active {
                    self.incomingWalkieSpeakerIDs.insert(senderID)
                    self.incomingWalkieLevels[senderID] = min(1, max(0, level))
                    if !wasActive { self.statusText = "\(senderName) is talking to you" }
                } else {
                    self.incomingWalkieSpeakerIDs.remove(senderID)
                    self.incomingWalkieLevels.removeValue(forKey: senderID)
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
            },
            roomStatePersistenceHandler: { [weak self] document in
                self?.roomStore.saveRoomStateDocument(document, roomID: room.id)
            }
        )
        activeRoom = room.name
        activeRoomConfiguration = room
        phase = .starting
        statusText = "Opening \(room.name)"
        roomBrowser.stop()
        meshSession = session
        arena.localName = currentUserName
        arena.localParticipantID = currentParticipantID ?? ""
        arena.onLobbyDiscovered = { [weak self] lobby in
            guard let self, !self.arena.playing else { return }
            self.activityInvitation = lobby
            self.activityInvitationTask?.cancel()
            self.activityInvitationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, self?.activityInvitation?.sessionID == lobby.sessionID else { return }
                self?.activityInvitation = nil
            }
        }
        arena.onLobbyRemoved = { [weak self] sessionID in
            if self?.activityInvitation?.sessionID == sessionID { self?.activityInvitation = nil }
        }
        arena.onMatchFinished = { result in ArenaRecordStore.shared.record(result) }
        arena.send = { [weak session] data, target in session?.sendArena(data, targetID: target) }
        session.setIncomingMediaMuted(incomingMediaMuted)
        session.setIncomingWalkieTalkieMuted(incomingCallsMuted)
        session.setMusicDuckingEnabled(musicDuckingEnabled)
        session.setAutomaticSyncEnabled(automaticAudioSync)
        for (id, level) in participantVoiceLevels { session.setVoiceVolume(level, for: id) }
        do {
            try session.start(broadcastInitially: broadcastInitially)
            try? roomStore.save(room)
            lastJoinedRoomStore.markJoined(room)
            savedRooms = roomStore.load()
            phase = .live
            statusText = broadcastInitially ? "Starting this Mac's broadcast" : "Room open"
            startLiveSyncMonitoring(session)
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

    func setMusicDuckingEnabled(_ enabled: Bool) {
        musicDuckingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "musicDuckingEnabled")
        meshSession?.setMusicDuckingEnabled(enabled)
    }

    var microphoneAudienceSummary: String {
        if walkieStarting { return "Microphone starting…" }
        var names = Set<String>()
        if walkieTalking {
            let targets = effectiveTalkTargetIDs.intersection(currentRemoteParticipantIDs)
            names.formUnion(participants.filter { targets.contains($0.id) }.map(\.name))
        }
        if openLineState.isSendingMicrophone, let invitation = openLineState.invitation {
            names.insert(openLinePeerName(invitation))
        }
        return names.isEmpty ? "Microphone off · nobody can hear you" : "Microphone live → " + names.sorted().joined(separator: ", ")
    }

    var connectionSummary: String {
        if permissionNotice || errorIsPermissionRelated { return "Audio permission needed" }
        if phase == .starting { return "Connecting to room…" }
        if phase != .live { return statusText }
        if statusText.localizedCaseInsensitiveContains("failed") || statusText.localizedCaseInsensitiveContains("lost") {
            return statusText
        }
        if statusText.hasPrefix("Reconnecting") { return "Reconnecting to room audio…" }
        if incomingMediaMuted { return "Connected · music muted on this Mac" }
        if !hasBroadcaster { return "Connected · nobody is broadcasting" }
        return audioIsRendering ? "Connected · listening" : "Connected · waiting for audio"
    }

    func voiceVolume(for participantID: String) -> Double {
        participantVoiceLevels[participantID] ?? 1
    }

    func setVoiceVolume(_ volume: Double, for participantID: String) {
        guard volume.isFinite else { return }
        let level = VoiceLevelStore.clamp(volume)
        participantVoiceLevels[participantID] = level
        voiceLevelStore.set(level, for: participantID)
        meshSession?.setVoiceVolume(level, for: participantID)
    }

    func voiceIsMuted(for participantID: String) -> Bool {
        voiceVolume(for: participantID) <= 0.001
    }

    /// Per-person voice muting is local to this Mac and restores the listener's
    /// previous level when unmuted.
    func toggleVoiceMute(for participantID: String) {
        let current = voiceVolume(for: participantID)
        if current > 0.001 {
            voiceVolumesBeforeMute[participantID] = current
            setVoiceVolume(0, for: participantID)
        } else {
            setVoiceVolume(voiceVolumesBeforeMute.removeValue(forKey: participantID) ?? 1,
                           for: participantID)
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
        guard canControlRoomPlayback else {
            statusText = hasBroadcaster
                ? "Nothing is playing yet"
                : "Wait for the broadcaster connection, then try again"
            return
        }
        let command = Self.playbackCommand(
            metadataIsPlaying: nowPlaying.isPlaying,
            audioIsRendering: audioIsRendering
        )
        if meshSession?.sendMediaCommand(command) != true {
            statusText = "Wait for the broadcaster connection, then try again"
        }
    }

    nonisolated static func playbackCommand(
        metadataIsPlaying: Bool?,
        audioIsRendering: Bool
    ) -> RoomMediaCommand {
        (metadataIsPlaying ?? audioIsRendering) ? .pause : .play
    }

    nonisolated static func playbackControlAvailable(
        isLive: Bool,
        hasBroadcaster: Bool,
        isHost: Bool,
        hasMedia: Bool
    ) -> Bool {
        isLive && (hasBroadcaster || isHost) && hasMedia
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

    /// A missing local identity must never fall through to the nil/all-devices target.
    nonisolated static func performLocalResync(currentParticipantID: String?, send: (String) -> Bool) -> Bool {
        guard let currentParticipantID, !currentParticipantID.isEmpty else { return false }
        return send(currentParticipantID)
    }

    func syncThisMac() {
        if Self.performLocalResync(currentParticipantID: currentParticipantID, send: {
            meshSession?.requestResync(participantID: $0) == true
        }) {
            statusText = "Syncing this Mac"
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
        compactTalkSelection = nil
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

    /// Compact controls intentionally allow one unambiguous audience at a
    /// time: either the whole room or exactly one person. Selecting the active
    /// audience again turns Talk off.
    func toggleCompactTalkTarget(_ targetID: String?) {
        guard compactTalkCanChangeAudience else {
            statusText = "Close the open line before changing the Talk audience"
            return
        }
        let remoteIDs = currentRemoteParticipantIDs
        guard !remoteIDs.isEmpty else {
            statusText = "No other device is available for Talk"
            return
        }
        let roomToken = Self.compactRoomTalkToken
        let requested = targetID ?? roomToken
        if compactTalkSelection == requested, !latchedTalkTargetIDs.isEmpty {
            compactTalkSelection = nil
            latchedTalkTargetIDs.removeAll()
        } else if let targetID {
            guard remoteIDs.contains(targetID) else { return }
            compactTalkSelection = targetID
            latchedTalkTargetIDs = [targetID]
        } else {
            compactTalkSelection = roomToken
            latchedTalkTargetIDs = remoteIDs
        }
        reconcileTalkTargets()
    }

    var compactRoomTalkIsSelected: Bool {
        compactTalkSelection == Self.compactRoomTalkToken
            && !latchedTalkTargetIDs.isEmpty
            && currentRemoteParticipantIDs.isSubset(of: latchedTalkTargetIDs)
    }

    var compactPrivateTalkTargetID: String? {
        guard let compactTalkSelection,
              compactTalkSelection != Self.compactRoomTalkToken,
              latchedTalkTargetIDs == [compactTalkSelection],
              currentRemoteParticipantIDs.contains(compactTalkSelection)
        else { return nil }
        return compactTalkSelection
    }

    var compactTalkCanChangeAudience: Bool {
        if case .idle = openLineState { return true }
        return false
    }

    private static let compactRoomTalkToken = "__alo_room__"

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
                    statusText = talkAudienceStatus(targets: talkTargets, names: names)
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
                statusText = talkAudienceStatus(targets: targets, names: names)
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

    private func talkAudienceStatus(targets: Set<String>, names: [String]) -> String {
        if compactPrivateTalkTargetID != nil {
            return "Talking privately to \(ListFormatter.localizedString(byJoining: names))"
        }
        return targets == currentRemoteParticipantIDs
            ? "Talking to everyone"
            : "Talking to \(ListFormatter.localizedString(byJoining: names))"
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

    func silenceMicrophone() {
        latchedTalkTargetIDs.removeAll()
        pushToTalkTargetIDs.removeAll()
        globalShortcutTalkTargets.removeAll()
        endOpenLine()
        stopWalkieTalkie()
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
        if muted {
            incomingWalkieSpeakerIDs.removeAll()
            incomingWalkieLevels.removeAll()
        }
    }

    func showFloatingBar() {
        videoFullscreen = false
        floatingBarHidden = false
        UserDefaults.standard.set(false, forKey: Self.floatingBarPreferenceKey)
    }

    func showChatInFloatingBar() {
        roomGamesVisible = false
        dismissIncomingMessagePreview()
        showFloatingBar()
        floatingSection = .chat
    }

    func showPeopleInFloatingBar() {
        dismissIncomingMessagePreview()
        showFloatingBar()
        floatingSection = .people
    }

    func setMenuBarPopoverVisible(_ visible: Bool) {
        menuBarPopoverVisible = visible
        if !visible, floatingBarHidden {
            floatingSection = .collapsed
        }
    }

    func canControl(_ participant: RoomParticipant) -> Bool {
        isHost || participant.id == currentParticipantID
    }

    func joinActivityInvitation() {
        guard let invitation = activityInvitation else { return }
        activityInvitation = nil
        showGamesLibrary()
        guard let pack = arena.library.installed["rift-arena"] else { return }
        arena.openGame(pack)
        arena.join(invitation)
    }

    func showGamesLibrary() {
        showFloatingBar()
        floatingSection = .chat; roomGamesVisible = true
        if !arena.expanded { arena.returnToLibrary() }
    }

    func setAutomaticAudioSync(_ enabled: Bool) {
        automaticAudioSync = enabled
        UserDefaults.standard.set(enabled, forKey: "automaticAudioSync")
        meshSession?.setAutomaticSyncEnabled(enabled)
    }

    func sendMessage() {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = RoomChatOperation(kind: .message, text: text)
        guard phase == .live, meshSession != nil, operation.encoded != nil else { return }
        sendChatOperation(operation)
        draftMessage = ""
    }

    @discardableResult
    func sendChatOperation(_ operation: RoomChatOperation) -> Bool {
        guard phase == .live, let meshSession, let wire = operation.encoded else { return false }
        meshSession.sendChat(wire)
        return true
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

    func moveQueueItem(_ id: String, before targetID: String) -> Bool {
        guard isHost, mediaQueue.count <= 2_000,
              id != targetID, mediaQueue.contains(where: { $0.id == id }),
              mediaQueue.contains(where: { $0.id == targetID }) else { return false }
        var order = mediaQueue.map(\.id).filter { $0 != id }
        guard let destination = order.firstIndex(of: targetID) else { return false }
        order.insert(id, at: destination)
        meshSession?.reorderQueue(order)
        queueNotice = "Queue order updated for the room."
        return true
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
        }
    }

    func setChatViewportAtLatest(_ id: UUID, _ atLatest: Bool) {
        if atLatest {
            chatViewportsAtLatest.insert(id)
            if unreadMessageCount != 0 { unreadMessageCount = 0 }
            if firstUnreadMessageID != nil { firstUnreadMessageID = nil }
        } else {
            chatViewportsAtLatest.remove(id)
        }
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
        arena.disconnect()
        isLeavingRoom = true
        stopLiveSyncMonitoring()
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
        guard phase == .idle, !roomsRefreshing else { return }
        savedRooms = roomStore.load()
        nearbyRooms = []
        roomsRefreshing = true
        roomsRefreshError = nil
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
        arena.disconnect()
        isLeavingRoom = true
        stopLiveSyncMonitoring()
        stopLocalNowPlayingMonitor()
        meshSession?.stopImmediately()
    }

    func diagnosticRoomContext() -> DiagnosticRoomContext {
        diagnosticRoomContext(timing: meshSession?.diagnosticsSnapshot())
    }

    private func diagnosticRoomContext(timing: SessionTimingDiagnostics?) -> DiagnosticRoomContext {
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
            timing: timing
        )
    }

    private func startLiveSyncMonitoring(_ session: MeshSession) {
        stopLiveSyncMonitoring()
        // Retain incidents after leaving for export; only a new room clears them.
        liveSyncHealth = LiveSyncHealth()
        liveSyncTask = Task { [weak self, weak session] in
            while !Task.isCancelled {
                guard self != nil, let session else { return }
                let started = MonotonicClock.nowNanos()
                // A stalled diagnostic read cannot leave the last healthy badge
                // latched indefinitely. This timeout does not start another read.
                let freshnessTimeout = Task { [weak self, weak session] in
                    do { try await Task.sleep(nanoseconds: 2_500_000_000) }
                    catch { return }
                    guard !Task.isCancelled, let session, self?.meshSession === session else { return }
                    self?.invalidateLiveSyncSample()
                }
                let timing = await session.sampleTimingDiagnostics()
                freshnessTimeout.cancel()
                guard !Task.isCancelled else { return }
                self?.applyLiveSyncTiming(timing, from: session, sampledAt: started)
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
        }
    }

    private func applyLiveSyncTiming(_ timing: SessionTimingDiagnostics?, from session: MeshSession, sampledAt: UInt64) {
        guard meshSession === session, phase == .live, !isLeavingRoom else { return }
        guard hasBroadcaster, nowPlaying.isPlaying != false else {
            invalidateLiveSyncSample()
            return
        }
        let now = MonotonicClock.nowNanos()
        // Snapshot collection can span separate receiver/host queues. Old values
        // must not become fresh merely because the async call finally completed.
        let freshTiming = now >= sampledAt && now - sampledAt <= 500_000_000 ? timing : nil
        guard let freshTiming else {
            invalidateLiveSyncSample()
            return
        }
        if localAudioTiming != freshTiming.receiver { localAudioTiming = freshTiming.receiver }
        let result = diagnosticRoomContext(timing: freshTiming).result
        if liveSyncHealth.recentTransitions.last?.outcome != result.outcome {
            // Anonymous, transition-only evidence; never log peer names or content.
            let detail = DiagnosticRedactor.redact(result.detail)
            syncHealthLogger.notice("Playback timing \(result.outcome.rawValue, privacy: .public): \(detail, privacy: .public)")
        }
        liveSyncHealth.observe(result, at: sampledAt)
    }

    private func stopLiveSyncMonitoring() {
        liveSyncTask?.cancel()
        liveSyncTask = nil
        invalidateLiveSyncSample()
    }

    private func invalidateLiveSyncSample() {
        if localAudioTiming != nil { localAudioTiming = nil }
        // Guard before mutating the @Published value: even an unchanged inout
        // write would otherwise redraw the whole model on every idle timer tick.
        guard liveSyncHealth.hasCurrentSample else { return }
        liveSyncHealth.invalidateCurrentSample()
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
                self?.arena.localParticipantID = id
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
                self.incomingWalkieLevels = self.incomingWalkieLevels.filter { liveIDs.contains($0.key) }
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

    private var chatCallback: (String, String, String, UInt64, MeshVersion) -> Void {
        { [weak self] senderID, sender, text, sentNanos, version in
            DispatchQueue.main.async {
                guard let self else { return }
                let isNewMessage = self.chatDocument.receive(senderID: senderID, sender: sender, text: text, sentNanos: sentNanos, version: version)
                self.messages = self.chatDocument.messages
                guard isNewMessage, let receivedMessage = self.messages.first(where: { $0.senderID == senderID && $0.sentNanos == sentNanos }) else { return }
                let chatIsVisible = self.floatingSection == .chat
                    && (!self.floatingBarHidden || self.menuBarPopoverVisible)
                let chatIsAtLatest = chatIsVisible && !self.chatViewportsAtLatest.isEmpty
                if senderID != self.currentParticipantID, !chatIsAtLatest {
                    if self.firstUnreadMessageID == nil {
                        self.firstUnreadMessageID = receivedMessage.id
                    }
                    self.unreadMessageCount += 1
                    if self.floatingSection == .collapsed, self.chatNotificationMode.shouldPreview(text: receivedMessage.text, displayName: self.currentUserName) {
                        self.presentIncomingMessagePreview(receivedMessage)
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

    var nowPlayingCallback: (NowPlayingMedia) -> Void {
        { [weak self] media in
            let artworkPalette = ArtworkTheme.palette(from: media.artworkData)
            DispatchQueue.main.async {
                guard let self else { return }
                let sameTrack = self.nowPlaying.title == media.title
                    && self.nowPlaying.artist == media.artist
                    && self.nowPlaying.album == media.album
                self.nowPlayingReceivedAt = Date()
                self.nowPlaying = media
                self.lyrics.update(media: media)
                if (media.artworkData != nil || !sameTrack), self.roomArtworkPalette != artworkPalette {
                    self.roomArtworkPalette = artworkPalette
                    self.roomAccentHex = artworkPalette?.accentHex
                }
            }
        }
    }

    private var videoCallback: (CGImage) -> Void {
        { [weak self] image in
            // Scheduled decoder presentation already runs on main; another
            // asynchronous hop would escape its bounded queue and reset gate.
            if Thread.isMainThread { self?.videoFrame = image }
            else { DispatchQueue.main.async { self?.videoFrame = image } }
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
        stopLiveSyncMonitoring()
        arena.disconnect()
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
        incomingWalkieLevels.removeAll()
        latchedTalkTargetIDs.removeAll()
        pushToTalkTargetIDs.removeAll()
        globalShortcutTalkTargets.removeAll()
        participants = []
        messages = []
        chatDocument = RoomChatDocument()
        chatViewportsAtLatest.removeAll()
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
        lyrics.cancel()
        roomGamesVisible = false
        activityInvitation = nil
        activityInvitationTask?.cancel(); activityInvitationTask = nil
        nowPlayingReceivedAt = Date()
        roomAccentHex = nil
        roomArtworkPalette = nil
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

    fileprivate func dismissIncomingMessagePreview() {
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
            || status.hasPrefix("Reconnecting")
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

struct ALOView: View {
    @ObservedObject var model: ALOViewModel
    var checkForUpdates: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var roomNameFocused: Bool
    @FocusState private var privateKeyFocused: Bool
    @FocusState private var roomRenameFocused: Bool
    @State private var editingRoomID: String?
    @State private var editedRoomName = ""
    @State private var focusedRoomID: String?

    var body: some View {
        ZStack {
            if model.phase == .idle {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .fill(Palette.canvas)
                    .padding(10)
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
        .tint(.accentColor)
    }

    private var idleView: some View {
        setupConsole
    }

    private var setupConsole: some View {
        ZStack {
            SetupBackground()

            VStack(spacing: 0) {
                setupIdentityHeader
                VStack(spacing: 0) {
                    if model.mode == .share {
                        createRoomPanel
                    } else {
                        roomList
                    }
                    setupFooter
                }
                .frame(width: 286, height: 236)
                .background(.regularMaterial, in: UnevenRoundedRectangle(
                    topLeadingRadius: 22, topTrailingRadius: 22
                ))
            }
        }
        .frame(width: 286, height: 406)
        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
        .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: model.mode)
    }

    private var setupIdentityHeader: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 22)
            Button(action: model.editDeviceIdentity) {
                DeviceAvatar(
                    emoji: model.currentDeviceIcon,
                    colorHex: model.currentDeviceColorHex,
                    profileImageData: model.currentDeviceProfileImageData,
                    size: 64
                )
                .overlay(Circle().stroke(Color.white.opacity(0.96), lineWidth: 4))
                .shadow(color: Color.black.opacity(0.26), radius: 10, y: 5)
            }
            .buttonStyle(PressScaleButtonStyle())
            .help("Edit \(model.currentUserName)")
            .accessibilityLabel("Edit this Mac's room identity")

            Button(action: model.editDeviceIdentity) {
                Label(model.currentUserName, systemImage: "pencil")
                    .font(.body)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.primary)
            .help("Edit \(model.currentUserName)")
            .accessibilityLabel("Edit this Mac's room identity")

            Spacer(minLength: 16)
        }
        .frame(height: 170)
    }

    private var setupFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                if let error = model.roomsRefreshError {
                    Image(systemName: "wifi.exclamationmark")
                        .help(error)
                        .accessibilityLabel("Nearby discovery unavailable: \(error)")
                }
                Button(action: { checkForUpdates?() }) {
                    HStack(spacing: 6) {
                        Label("ALO \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")",
                              systemImage: "arrow.down.circle")
                        if model.availableUpdateVersion != nil {
                            Circle()
                                .fill(.tint)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                            Text("Update available")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(checkForUpdates == nil)
                .help(model.availableUpdateVersion.map { "ALO \($0) is available" } ?? "Check for updates")
                .accessibilityLabel(model.availableUpdateVersion.map { "Update available: ALO \($0)" } ?? "Check for ALO updates")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 37)
    }

    private var createRoomPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                        model.mode = .listen
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help("Back to spaces")
                .accessibilityLabel("Back to spaces")

                Text("New space")
                    .font(.headline)
                Spacer()
            }

            TextField("Space name", text: $model.roomName)
                .textFieldStyle(.roundedBorder)
                .focused($roomNameFocused)
                .onSubmit(model.startSharing)

            Toggle("Private space", isOn: $model.createPrivateRoom)
                .help("Require an invite key to join this space")

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Create space", action: model.startSharing)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartSharing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 286, height: 199)
        .onAppear {
            DispatchQueue.main.async { roomNameFocused = true }
        }
    }

    private var roomList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Spaces")
                    .font(.headline)
                Spacer()
                Button(action: model.refreshRooms) {
                    ZStack {
                        if model.roomsRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(model.roomsRefreshing)
                .help(model.roomsRefreshing ? "Looking for nearby spaces…" : "Sync saved and nearby spaces")
                .accessibilityLabel("Sync spaces")
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                        model.mode = .share
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("Create a space")
                .accessibilityLabel("Create a space")
            }
            .padding(.horizontal, 14)
            .frame(height: 45)

            ScrollViewReader { proxy in
                List(selection: $focusedRoomID) {
                    if model.roomChoices.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Looking nearby")
                                .font(.body)
                            Text("Open ALO on another Mac to see its spaces.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        .help("Looking for rooms on your network")
                        .accessibilityLabel("Looking for rooms on your network")
                    } else {
                        ForEach(model.roomChoices) { room in
                            roomCard(room)
                                .tag(room.id)
                                .id(room.id)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: focusedRoomID) { _, selected in
                    if let selected { model.selectedRoomID = selected }
                }
                .onChange(of: model.selectedRoomID, initial: true) { previous, selected in
                    if previous != selected { model.privateRoomKey = "" }
                    if let selected, model.selectedRoomConfiguration?.isPrivate == true {
                        DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) }
                    }
                }
                .onKeyPress(.return) {
                    guard editingRoomID == nil, focusedRoomID != nil,
                          let room = model.selectedRoomConfiguration else { return .ignored }
                    if room.isPrivate && room.accessKey == nil {
                        privateKeyFocused = true
                    } else {
                        model.joinSelectedRoom()
                    }
                    return .handled
                }
            }
            .frame(height: setupRoomListHeight)

            if model.selectedRoomConfiguration?.isPrivate == true,
               model.selectedRoomConfiguration?.accessKey == nil {
                TextField("Private room invite key", text: $model.privateRoomKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($privateKeyFocused)
                    .onSubmit(model.joinSelectedRoom)
                    .frame(height: 36)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 7)
                    .onAppear {
                        DispatchQueue.main.async { privateKeyFocused = true }
                    }
            }
        }
        .frame(width: 286, height: 199)
        .onAppear { focusedRoomID = nil }
    }

    private var setupRoomListHeight: CGFloat {
        model.selectedRoomConfiguration?.isPrivate == true
            && model.selectedRoomConfiguration?.accessKey == nil ? 110 : 154
    }

    private func roomCard(_ room: RoomConfiguration) -> some View {
        let nearby = model.nearbyRooms.first(where: { $0.id == room.id })
        let saved = model.savedRooms.contains(where: { $0.id == room.id })
        return HStack(spacing: 8) {
            roomCardIcon(room)

            if editingRoomID == room.id {
                TextField("Space name", text: $editedRoomName)
                    .textFieldStyle(.roundedBorder)
                    .focused($roomRenameFocused)
                    .onChange(of: editedRoomName) { _, newValue in
                        if newValue.count > 40 { editedRoomName = String(newValue.prefix(40)) }
                    }
                    .onSubmit { commitRoomRename(room) }
                    .onExitCommand(perform: cancelRoomRename)

                Button(action: cancelRoomRename) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Cancel rename")
                .accessibilityLabel("Cancel rename")

                Button { commitRoomRename(room) } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(normalizedEditedRoomName.isEmpty)
                .help("Save space name")
                .accessibilityLabel("Save space name")
            } else {
                Button {
                    model.selectedRoomID = room.id
                    model.privateRoomKey = ""
                    if !room.isPrivate || room.accessKey != nil {
                        model.joinSelectedRoom()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name)
                            .font(.body)
                            .lineLimit(1)
                        Text(nearby?.detail ?? (room.isPrivate ? "Private · Saved on this Mac" : "Saved on this Mac"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(nearby?.activityHelp ?? "Saved on this Mac. Join to open the space.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .help(room.isPrivate && room.accessKey == nil ? "Enter the invite key for \(room.name)" : "Open \(room.name)")
                .accessibilityLabel("Open \(room.name)")

                if saved {
                    roomOptionsMenu(room)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 36)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: editingRoomID)
    }

    private func roomCardIcon(_ room: RoomConfiguration) -> some View {
        let nearbyIcon = model.nearbyRooms.first(where: { $0.id == room.id })?.icon
        let icon = nearbyIcon?.supersedes(room.icon) == true ? nearbyIcon : room.icon
        return Image(systemName: icon?.symbol ?? (room.isPrivate ? "lock.fill" : "person.3.fill"))
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
    }

    private func roomOptionsMenu(_ room: RoomConfiguration) -> some View {
        Menu {
            Button {
                beginRoomRename(room)
            } label: {
                Label("Rename Space", systemImage: "pencil")
            }
            Menu {
                Text("Shared when you join the space")
                ForEach(RoomIcon.choices, id: \.symbol) { choice in
                    Button { model.setRoomIcon(roomID: room.id, symbol: choice.symbol) } label: {
                        Label(choice.name, systemImage: choice.symbol)
                    }
                }
            } label: {
                Label("Shared Icon", systemImage: "square.grid.2x2")
            }
            if room.isPrivate, room.accessKey != nil {
                Button {
                    model.copyPrivateInviteKey(roomID: room.id)
                } label: {
                    Label("Copy Invite Key", systemImage: "key")
                }
            }
            Divider()
            Button(role: .destructive) {
                model.forgetRoom(roomID: room.id)
            } label: {
                Label("Forget Space", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 24)
        .help("Space options")
        .accessibilityLabel("Options for \(room.name)")
    }

    private var normalizedEditedRoomName: String {
        String(editedRoomName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    private func beginRoomRename(_ room: RoomConfiguration) {
        editedRoomName = room.name
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            editingRoomID = room.id
        }
        DispatchQueue.main.async { roomRenameFocused = true }
    }

    private func cancelRoomRename() {
        roomRenameFocused = false
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            editingRoomID = nil
        }
        editedRoomName = ""
    }

    private func commitRoomRename(_ room: RoomConfiguration) {
        guard model.renameRoom(roomID: room.id, to: normalizedEditedRoomName) else { return }
        cancelRoomRename()
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
            .frame(width: 328)
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
                    .frame(maxWidth: 272, alignment: .leading)
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
        .frame(width: 328, alignment: .leading)
        .glass(cornerRadius: 26)
    }
}

enum RoomControlsPresentation {
    case floating
    case menuBar
}

struct FloatingRoomView: View {
    @ObservedObject var model: ALOViewModel
    var presentation: RoomControlsPresentation = .floating
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @FocusState private var queueFocused: Bool
    private var showsGames: Bool {
        get { model.roomGamesVisible }
        nonmutating set { model.roomGamesVisible = newValue }
    }
    @State private var showsRoomInfo = false
    @State private var showsMediaMore = false

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

    private var navigationHeight: CGFloat {
        presentation == .floating ? model.floatingNavigationHeight : 0
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
                VStack(spacing: 0) {
                    HStack {
                        Button { model.floatingSection = .chat; showsGames = false } label: { Label("Chat", systemImage: "chevron.left") }
                        Spacer()
                        Text("People").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button { showsRoomInfo = true } label: { Image(systemName: "slider.horizontal.3") }
                    }.buttonStyle(.plain).font(.system(size: 11)).padding(14)
                    peopleMixer
                }
            case .video:
                videoPlayer
            }
        }
    }

    var body: some View {
        return Group {
            if presentation == .floating {
                GeometryReader { geometry in
                    roomContent(width: max(FloatingMetrics.width, geometry.size.width - FloatingMetrics.windowInset * 2),
                                height: max(roomBarHeight + navigationHeight, geometry.size.height - FloatingMetrics.windowInset * 2))
                        .floatingSurface(cornerRadius: FloatingMetrics.cornerRadius)
                        .padding(FloatingMetrics.windowInset)
                }
            } else {
                roomContent(width: FloatingMetrics.width, height: roomContentHeight)
                    .background(Palette.opaqueSurface)
            }
        }
        .tint(roomAccent)
        .environment(\.roomAccent, roomAccent)
        .popover(isPresented: $showsRoomInfo) {
            RoomPreferencesView(model: model)
        }
        .animation(themeAnimation, value: model.roomArtworkPalette)
    }

    private func roomContent(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if hasExpandedContent {
                VStack(spacing: 0) {
                    expandedContent
                }
                    .frame(width: width, height: max(0, height - roomBarHeight - navigationHeight - FloatingMetrics.separatorHeight))
                    .id(expansionIdentity)
                    .transition(panelTransition)

                Divider()
                    .overlay(Palette.strokeStrong)
                    .frame(height: FloatingMetrics.separatorHeight)
                    .transition(.opacity)
            }

            roomBar
            if presentation == .floating, model.floatingNavigationVisible {
                WalkieTalkieBar(model: model, showsCloseButton: false, embeddedFloating: true,
                               onRoomSettings: { showsRoomInfo = true })
                    .frame(height: navigationHeight)
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
        .background(ArtworkAtmosphere(colors: model.roomAtmosphereColors))
        .animation(panelAnimation, value: model.floatingSection)
        .animation(panelAnimation, value: model.permissionNotice)
        .animation(panelAnimation, value: model.participants.count)
        .animation(panelAnimation, value: model.incomingMessagePreview?.id)
    }

    private var videoMenuTitle: String {
        if model.mediaSwitchBusy { return "Cancel screen selection" }
        switch model.videoControlIntent {
        case .toggleViewer, .showViewer: return "View shared video"
        case .enableVideo, .beginAudioAndVideoBroadcast: return "Share screen and audio…"
        case .unavailable: return "Share screen…"
        }
    }

    private var roomBar: some View {
        HStack(spacing: 8) {
            roomIdentity

            if model.activityInvitation != nil && !hasExpandedContent {
                Button(action: model.joinActivityInvitation) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 15))
                        .frame(width: 32, height: 32)
                }.buttonStyle(FlatToolButtonStyle(active: false))
                    .help("A room game is open · Join or spectate")
                    .accessibilityLabel("Room game invitation")
            }

            roomBarButton(
                icon: model.isHost ? "dot.radiowaves.left.and.right" : "waveform.badge.mic",
                activeIcon: "dot.radiowaves.left.and.right",
                active: model.isHost,
                disabled: model.mediaSwitchBusy,
                help: model.isHost ? "Stop broadcasting" : (model.hasBroadcaster ? "Take over room audio" : "Broadcast audio")
            ) { model.toggleBroadcasting() }

            if model.hasBroadcaster || model.isHost {
                if model.canControlRoomPlayback {
                    roomBarButton(
                        icon: model.roomIsPlaying ? "pause.fill" : "play.fill",
                        active: false,
                        help: model.roomIsPlaying ? "Pause everywhere" : "Play everywhere"
                    ) { model.toggleRoomPlayback() }
                }

            }

            roomBarButton(
                icon: "arrow.triangle.2.circlepath",
                active: false,
                disabled: !model.hasBroadcaster || model.currentParticipantID == nil || model.mediaSwitchBusy,
                help: "Sync this Mac only"
            ) { model.syncThisMac() }

            Button { showsMediaMore.toggle() } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.controlIcon)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(FlatToolButtonStyle(active: showsMediaMore))
            .help("More: Chat, People, sharing and room settings")
            .accessibilityLabel("More room controls")
            .popover(isPresented: $showsMediaMore, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        showsMediaMore = false
                        if presentation == .floating { model.showChatInFloatingBar() }
                        else { model.roomGamesVisible = false; model.floatingSection = .chat }
                    } label: {
                        Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    Button {
                        showsMediaMore = false
                        if presentation == .floating { model.showPeopleInFloatingBar() }
                        else { model.floatingSection = .people }
                    } label: {
                        Label("People", systemImage: "person.2")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    Divider()
                    Button {
                        showsMediaMore = false
                        model.toggleVideoFromFloatingBar()
                    } label: {
                        Label(videoMenuTitle, systemImage: "rectangle.on.rectangle")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.disabled(!model.canSelectVideo)
                    Button {
                        showsMediaMore = false
                        model.showQueue()
                    } label: {
                        Label("Room queue", systemImage: "music.note.list")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    Button {
                        showsMediaMore = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { showsRoomInfo = true }
                    } label: {
                        Label("Room settings", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    if presentation == .floating {
                        Divider()
                        Toggle("Member and navigation strip", isOn: $model.floatingNavigationVisible)
                            .toggleStyle(.checkbox).padding(8)
                        Button {
                            showsMediaMore = false
                            model.hideFloatingBar()
                        } label: {
                            Label("Hide media controls", systemImage: "eye.slash")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .padding(8).frame(width: 220)
            }

            if presentation == .menuBar {
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
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: roomBarHeight)
        .background(alignment: .leading) {
            if presentation == .menuBar {
                menuBarArtworkBackdrop
            }
        }
        .background(ArtworkHeaderBackground(palette: model.roomArtworkPalette))
        .clipped()
    }

    @ViewBuilder
    private var roomIdentity: some View {
        let identity = HStack(spacing: 9) {
            if presentation == .menuBar {
                // The artwork itself bleeds to the row edge behind this clear
                // lane; text begins after its strongest, most legible area.
                Color.clear
                    .frame(width: 88, height: roomBarHeight)
                    .accessibilityHidden(true)
            } else {
                artworkTile
            }

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

    private var menuBarArtworkBackdrop: some View {
        Group {
            if let data = model.nowPlaying.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    roomAccent.opacity(0.18)
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(roomAccent)
                        .offset(x: -21)
                }
            }
        }
        .frame(width: 138, height: roomBarHeight)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.52),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .accessibilityHidden(true)
    }

    private func statusLabel(compact: Bool) -> some View {
        let text: String
        if model.nowPlaying.title == nil {
            text = compact
                ? "\(model.participants.count) · \(model.roomSyncLabel)"
                : "\(model.participants.count) \(model.hasBroadcaster ? "listening" : "here") · \(model.roomSyncLabel)"
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
                    ? "Anyone can add · broadcaster manages order"
                    : "\(model.mediaQueue.count) queued · broadcaster can drag to reorder"
            )
            Divider().opacity(0.42)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.mediaQueue) { item in
                        queueRow(item)
                            .onDrag {
                                NSItemProvider(object: (model.isHost ? item.id : "") as NSString)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let id = items.first else { return false }
                                return model.moveQueueItem(id, before: item.id)
                            }
                            .contextMenu {
                                if model.isHost, let first = model.mediaQueue.first, first.id != item.id {
                                    Button("Move to top") { _ = model.moveQueueItem(item.id, before: first.id) }
                                }
                            }
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
            if !showsGames, let invitation = model.activityInvitation {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller")
                    Text("\(model.participants.first(where: { $0.id == invitation.peerID })?.name ?? "A room member") opened Rift Arena")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Join", action: model.joinActivityInvitation)
                    Button { model.activityInvitation = nil } label: { Image(systemName: "xmark") }
                        .help("Dismiss invitation")
                }.font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.white.opacity(0.035))
            }
            if !showsGames { LyricsPanel(controller: model.lyrics, accent: roomAccent) }
            if showsGames {
                ArenaPanel(session: model.arena)
                    .onAppear { model.arena.names = Dictionary(uniqueKeysWithValues: model.participants.map { ($0.id, $0.name) }) }
                    .onChange(of: model.participants) { _, people in
                        model.arena.names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
                    }
            } else {
                RoomChatPanel(
                    messages: model.messages,
                    currentParticipantID: model.currentParticipantID,
                    roomTitle: model.roomTitle,
                    firstUnreadMessageID: model.firstUnreadMessageID,
                    unreadCount: model.unreadMessageCount,
                    isPresented: chatIsPresented,
                    accent: roomAccent,
                    onLatestVisibilityChanged: model.setChatViewportAtLatest,
                    send: model.sendChatOperation,
                    draft: $model.draftMessage,
                    notificationMode: $model.chatNotificationMode,
                    mentionNames: model.participants.filter { $0.id != model.currentParticipantID }.map(\.name),
                    avatar: { id, name, size in AnyView(identityAvatar(id: id, name: name, size: size)) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatIsPresented: Bool {
        !showsGames && model.phase == .live && model.floatingSection == .chat && !model.permissionNotice
            && (presentation == .menuBar
                ? model.menuBarPopoverVisible
                : !model.floatingBarHidden && !model.videoFullscreen)
    }

    private var chatHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showsGames ? "Games" : "Room chat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("\(model.participants.count) here · live")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }

            Spacer()

            Button {
                showsGames.toggle()
                if showsGames && !model.arena.expanded { model.arena.returnToLibrary() }
                composerFocused = false
                model.arena.clearInput()
            } label: {
                Image(systemName: showsGames ? "bubble.left.fill" : "gamecontroller.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.controlIcon)
                    .frame(width: 32, height: 30)
            }
            .buttonStyle(FlatToolButtonStyle(active: showsGames))
            .help(showsGames ? "Return to room chat" : "Pick a game")
            .accessibilityLabel(showsGames ? "Return to room chat" : "Pick a game")

            HStack(spacing: -5) {
                ForEach(Array(model.participants.prefix(3))) { participant in
                    identityAvatar(id: participant.id, name: participant.name, size: 22)
                        .overlay(Circle().stroke(Palette.opaqueSurface, lineWidth: 1.5))
                }
            }
            .accessibilityHidden(true)

            Menu {
                Button("Chat") { model.floatingSection = .chat; showsGames = false }
                Button("People") { model.floatingSection = .people }
                Button("Games") {
                    model.floatingSection = .chat; showsGames = true
                    if !model.arena.expanded { model.arena.returnToLibrary() }
                }
                Divider()
                Button("Room settings…") { showsRoomInfo = true }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Palette.controlIcon).frame(width: 24, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Room navigation and settings")

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
                .onSubmit(sendChatMessage)

            Button(action: sendChatMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.selectedControlText)
                    .frame(width: 26, height: 26)
                    .background(roomAccent)
                    .clipShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(!hasDraft || model.phase != .live)
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
            if chatIsPresented {
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async { composerFocused = true }
            }
        }
        .onChange(of: chatIsPresented) { _, visible in
            if visible { composerFocused = true }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72),
            value: hasDraft
        )
    }

    private func sendChatMessage() {
        model.sendMessage()
        composerFocused = true
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
                    .fixedSize(horizontal: false, vertical: true)
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

    private func participantPresence(_ participant: RoomParticipant) -> String {
        let isLocal = participant.id == model.currentParticipantID
        if model.incomingWalkieSpeakerIDs.contains(participant.id) || (isLocal && model.walkieTalking) {
            return "Talking"
        }
        if participant.isMuted { return "Audio muted" }
        if isLocal && model.audioIsRendering { return "Listening" }
        // Remote output and idle state are not advertised by this protocol.
        return "In room"
    }

    private func participantPresenceColor(_ participant: RoomParticipant) -> Color {
        let presence = participantPresence(participant)
        if presence == "Talking" { return Palette.accentText }
        if presence == "Audio muted" { return Palette.red }
        if presence == "Listening" { return Color.green.opacity(0.8) }
        return Palette.secondary.opacity(0.7)
    }

    private func floatingParticipant(_ participant: RoomParticipant) -> some View {
        let controllable = model.canControl(participant)
        let appearance = DeviceAppearance.generated(from: participant.id)
        return VStack(spacing: 0) {
          HStack(spacing: 11) {
            DeviceAvatar(
                emoji: participant.icon ?? appearance.icon,
                colorHex: participant.colorHex ?? appearance.colorHex,
                profileImageData: participant.profileImageData,
                size: 32
            )

            HStack(spacing: 6) {
                Circle()
                    .fill(participantPresenceColor(participant))
                    .frame(width: 6, height: 6)
                    .help(participantPresence(participant))
                    .accessibilityLabel(participantPresence(participant))
                Text(participant.id == model.currentParticipantID ? "You" : participant.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
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
          if participant.id != model.currentParticipantID {
            HStack(spacing: 10) {
                Label("Voice on this Mac", systemImage: "mic.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 150, alignment: .leading)
                Slider(value: Binding(
                    get: { model.voiceVolume(for: participant.id) },
                    set: { model.setVoiceVolume($0, for: participant.id) }
                ), in: 0...1)
                .controlSize(.mini)
                .accessibilityLabel("\(participant.name) voice volume on this Mac")
                Text("\(Int(model.voiceVolume(for: participant.id) * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 34)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
          }
        }
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
                    Label("Sync this Mac", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle(filled: false))
                .help("Re-align this Mac without interrupting other listeners")
                .accessibilityLabel("Sync this Mac only")
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

private struct WalkieActionButtonStyle: ButtonStyle {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomAccent) private var roomAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Palette.selectedControlText : Palette.controlIcon)
            .background(
                active
                    ? roomAccent
                    : configuration.isPressed ? Palette.controlHover : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.94 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.82),
                value: configuration.isPressed
            )
    }
}

private struct SetupIconButtonStyle: ButtonStyle {
    var filled = false
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(filled || active ? Color.white : Palette.controlIcon)
            .frame(width: 38, height: 38)
            .background(filled || active ? Palette.controlAccent : Palette.messageSurface)
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
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 9 : 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: compact ? 28 : 30)
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

extension OpenLineState {
    var isSendingMicrophone: Bool {
        switch self {
        case .inviting, .connected: true
        case .idle, .invited: false
        }
    }
}

private struct WalkieTalkieTargetIcon: View {
    @ObservedObject var model: ALOViewModel
    let id: String?
    let name: String
    let icon: String
    let colorHex: String
    let profileImageData: Data?
    let interaction: TalkTargetInteraction
    @State private var isPressed = false
    @State private var showsPersonControls = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let selected = interaction == .toggle ? model.isTalkTargetSelected(id) : isPushToTalkSelected
        let incoming = id.map(model.incomingWalkieSpeakerIDs.contains) ?? false
        let incomingLevel = id.flatMap { model.incomingWalkieLevels[$0] } ?? 0
        let outgoing = model.walkieTalking && selected
        let linePeer = id.map(model.isOpenLinePeer) ?? false
        Group {
            if interaction == .toggle {
                if id != nil {
                    Button { showsPersonControls.toggle() } label: { avatar }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showsPersonControls, arrowEdge: .bottom) {
                            personControls
                        }
                } else {
                    Button { model.toggleCompactTalkTarget(nil) } label: { avatar }
                        .buttonStyle(.plain)
                }
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
                    selected
                        ? (outgoing ? Palette.voiceBlue : Palette.voiceSelection).opacity(outgoing ? 0.86 : 0.68)
                        : Color.clear,
                    lineWidth: outgoing ? 2.25 : 1.5
                )
                Circle()
                    .stroke(
                        incoming ? Palette.voiceBlue.opacity(0.56 + incomingLevel * 0.34) : Color.clear,
                        lineWidth: 2.25
                    )
                    .padding(-3)
                    .scaleEffect(reduceMotion ? 1 : 1 + incomingLevel * 0.045)
                Circle()
                    .stroke(linePeer ? lineColor : Color.clear, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                    .padding(-7)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if incoming {
                VoiceLevelBadge(level: incomingLevel)
                    .offset(x: 3, y: 3)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.72).combined(with: .opacity))
            }
        }
        .frame(width: 40, height: 40)
        .contentShape(Circle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: incomingLevel)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: incoming)
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
        .accessibilityLabel(interaction == .toggle && id != nil ? "Open controls for \(name)" : interaction == .toggle ? "Talk to everyone" : "Hold to talk to \(name)")
        .accessibilityValue(accessibilityValue(selected: selected, incoming: incoming, linePeer: linePeer))
    }

    @ViewBuilder
    private var personControls: some View {
        if let id {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 13, weight: .semibold))
                        Text(personStatus)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 16)
                }

                HStack(spacing: 8) {
                    Image(systemName: model.voiceIsMuted(for: id) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.controlIcon)
                    Slider(value: Binding(
                        get: { model.voiceVolume(for: id) },
                        set: { model.setVoiceVolume($0, for: id) }
                    ), in: 0...1)
                    .controlSize(.mini)
                    .accessibilityLabel("\(name) voice volume on this Mac")
                    Text("\(Int(model.voiceVolume(for: id) * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 30, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Button {
                        model.toggleCompactTalkTarget(id)
                        showsPersonControls = false
                    } label: {
                        Label(model.compactPrivateTalkTargetID == id ? "Stop private talk" : "Talk privately",
                              systemImage: model.compactPrivateTalkTargetID == id ? "mic.slash.fill" : "mic.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.compactTalkCanChangeAudience)

                    Button(model.voiceIsMuted(for: id) ? "Unmute" : "Mute") {
                        model.toggleVoiceMute(for: id)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(width: 250)
            .background(Palette.opaqueSurface)
        }
    }

    private var personStatus: String {
        guard let id else { return "In room" }
        if model.incomingWalkieSpeakerIDs.contains(id) { return "Talking" }
        if model.compactPrivateTalkTargetID == id && (model.walkieTalking || model.walkieStarting) {
            return model.walkieStarting ? "Connecting private talk…" : "Private talk active"
        }
        if model.isOpenLinePeer(id) { return "Open line" }
        return "In room"
    }

    @ViewBuilder
    private var avatar: some View {
        if id == nil {
            ZStack {
                Circle().fill(model.roomAccentColor.opacity(0.16))
                Image(systemName: "person.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.roomAccentColor)
            }
            .frame(width: 30, height: 30)
            .overlay(Circle().stroke(model.roomAccentColor.opacity(0.34), lineWidth: 1))
        } else {
            DeviceAvatar(
                emoji: icon,
                colorHex: colorHex,
                profileImageData: profileImageData,
                size: 30
            )
        }
    }

    private var isPushToTalkSelected: Bool {
        let remoteIDs = Set(model.participants.lazy.filter { $0.id != model.currentParticipantID }.map(\.id))
        guard !remoteIDs.isEmpty else { return false }
        if let id { return model.pushToTalkTargetIDs.contains(id) }
        return remoteIDs.isSubset(of: model.pushToTalkTargetIDs)
    }

    private var lineColor: Color {
        switch model.openLineState {
        case .connected: model.roomAccentColor
        case .inviting, .invited: Color.orange
        case .idle: Color.clear
        }
    }

    private func helpText(selected: Bool, incoming: Bool) -> String {
        if incoming { return "\(name) is speaking · \(interaction == .toggle ? "Click for controls" : "Hold to talk back")" }
        if interaction == .hold { return "Hold to talk to \(name)" }
        if id == nil { return selected ? "Click to stop talking to the room" : "Click to talk to everyone in the room" }
        return selected ? "Private talk active · Click for controls" : "Click for \(name)'s voice controls"
    }

    private func accessibilityValue(selected: Bool, incoming: Bool, linePeer: Bool) -> String {
        var states = [String]()
        if selected { states.append("Talking to this device") }
        if incoming { states.append("This device is speaking") }
        if linePeer { states.append("Open line participant") }
        return states.joined(separator: ", ")
    }
}

private struct VoiceLevelBadge: View {
    let level: Double

    private let barProfile: [CGFloat] = [0.52, 1, 0.72, 0.9]

    var body: some View {
        HStack(alignment: .center, spacing: 1.2) {
            ForEach(Array(barProfile.enumerated()), id: \.offset) { _, profile in
                Capsule()
                    .fill(Palette.voiceBlue)
                    .frame(width: 1.6, height: 2.5 + CGFloat(level) * 5.5 * profile)
            }
        }
        .frame(width: 18, height: 13)
        .background(Palette.voiceBadgeSurface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Palette.glassHighlight.opacity(0.74), lineWidth: 0.75))
        .scaleEffect(1 + CGFloat(level) * 0.035)
        .accessibilityHidden(true)
    }
}

struct RoomPlaybackProgressDivider: View {
    @ObservedObject var model: ALOViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 15.0,
            paused: reduceMotion || model.nowPlaying.isPlaying != true
        )) { timeline in
            GeometryReader { geometry in
                let progress = model.roomPlaybackProgress(at: timeline.date)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Palette.strokeStrong.opacity(0.5))

                    if let progress {
                        Rectangle()
                            .fill(model.roomAccentColor.opacity(0.48))
                            .scaleEffect(x: max(0.001, progress), anchor: .leading)

                        playbackFlare(progress: progress, width: geometry.size.width)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback progress")
                .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Unavailable")
                .accessibilityHidden(progress == nil)
            }
        }
        .frame(height: FloatingMetrics.separatorHeight)
        .allowsHitTesting(false)
    }

    private func playbackFlare(progress: Double, width: CGFloat) -> some View {
        let flareWidth: CGFloat = 28
        let x = min(max(0, CGFloat(progress) * width - flareWidth / 2), max(0, width - flareWidth))
        return LinearGradient(
            colors: [
                .clear,
                model.roomAccentColor.opacity(0.28),
                Color.white.opacity(0.72),
                model.roomAccentColor.opacity(0.62),
                .clear
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: flareWidth, height: 3)
        .blur(radius: 0.7)
        .offset(x: x, y: -1)
        .blendMode(.screen)
        .accessibilityHidden(true)
    }
}

struct WalkieTalkieBar: View {
    @ObservedObject var model: ALOViewModel
    var showsCloseButton = true
    var embeddedFloating = false
    var onRoomSettings: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if showsCloseButton {
                VStack(spacing: FloatingMetrics.walkieBarHandleGap) {
                    controls
                        .glass(cornerRadius: 18)

                    Capsule()
                        .fill(Palette.controlIcon.opacity(0.64))
                        .frame(width: 74, height: 5)
                        .frame(height: FloatingMetrics.walkieBarHandleTargetHeight)
                        .contentShape(Rectangle())
                        .overlay { WindowDragRegion().accessibilityHidden(true) }
                        .help("Drag to move the Talk bar")
                        .accessibilityLabel("Drag handle")
                }
                .padding(FloatingMetrics.windowInset)
            } else {
                controls
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear(perform: model.refreshVoiceInputs)
        .environment(\.roomAccent, model.roomAccentColor)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1), value: model.roomArtworkPalette)
    }

    private var controls: some View {
        HStack(spacing: 7) {
            if !showsCloseButton {
                voiceState
            }
            targetDock
            actionDock
        }
        .padding(.horizontal, 8)
        .frame(
            minWidth: showsCloseButton ? FloatingMetrics.walkieBarMinWidth : FloatingMetrics.width,
            maxWidth: showsCloseButton || embeddedFloating ? .infinity : FloatingMetrics.width,
            minHeight: FloatingMetrics.walkieBarHeight,
            maxHeight: FloatingMetrics.walkieBarHeight
        )
        .background(embeddedFloating ? Palette.opaqueSurface.opacity(0.72) : Color.black)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.glassHighlight.opacity(0.72))
                .frame(height: 1)
        }
    }

    private var voiceState: some View {
        Button { model.toggleCompactTalkTarget(nil) } label: {
            ZStack {
                Circle().fill(model.compactRoomTalkIsSelected ? model.roomAccentColor.opacity(0.28) : model.roomAccentColor.opacity(0.14))
                Image(systemName: model.compactRoomTalkIsSelected ? "waveform.badge.mic" : "waveform")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(model.compactRoomTalkIsSelected ? Palette.voiceBlue : model.roomAccentColor)
            }
            .frame(width: 27, height: 27)
        }
        .buttonStyle(.plain)
        .disabled(!model.compactTalkCanChangeAudience)
        .overlay(alignment: .bottomTrailing) {
            if let targetID = model.compactPrivateTalkTargetID,
               let participant = model.participants.first(where: { $0.id == targetID }) {
                let appearance = DeviceAppearance.generated(from: participant.id)
                DeviceAvatar(
                    emoji: participant.icon ?? appearance.icon,
                    colorHex: participant.colorHex ?? appearance.colorHex,
                    profileImageData: participant.profileImageData,
                    size: 14
                )
                .overlay(Circle().stroke(Palette.voiceBlue, lineWidth: 1.5))
                .offset(x: 4, y: 4)
            } else {
                Circle()
                    .fill(voiceStateColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Palette.opaqueSurface, lineWidth: 1.5))
            }
        }
        .frame(width: 32, height: 40)
        .contentShape(Rectangle())
        .help(model.compactPrivateTalkTargetID == nil
              ? (model.compactRoomTalkIsSelected ? "Stop talking to everyone" : "Talk to everyone in the room")
              : "Private talk is active · Click to switch to everyone")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.compactRoomTalkIsSelected ? "Stop talking to everyone" : "Talk to everyone in the room")
        .accessibilityValue(voiceStateLabel)
    }

    private var targetDock: some View {
        HStack(spacing: 4) {
            if showsCloseButton {
                walkieTarget(id: nil, name: "Everyone", icon: "", colorHex: "3F86E8")
            }

            if remoteParticipants.isEmpty {
                Text("Waiting for people")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if showsCloseButton {
                    Rectangle()
                        .fill(Palette.strokeStrong.opacity(0.58))
                        .frame(width: 1, height: 20)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
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
                }
                .scrollClipDisabled()
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(Palette.messageSurface.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.glassHighlight.opacity(0.62), lineWidth: 1)
        )
    }

    private var actionDock: some View {
        HStack(spacing: 0) {
            openLineControls

            communicationButton(
                icon: model.unreadMessageCount > 0 ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right",
                active: model.floatingSection == .chat,
                badge: model.unreadMessageCount,
                help: "Conversation"
            ) {
                if showsCloseButton || embeddedFloating { model.showChatInFloatingBar() }
                else { model.roomGamesVisible = false; model.showChat() }
            }
            .keyboardShortcut("1", modifiers: .command)

            communicationButton(
                icon: model.floatingSection == .people ? "person.2.fill" : "person.2",
                active: model.floatingSection == .people,
                help: "People and volume"
            ) {
                (showsCloseButton || embeddedFloating) ? model.showPeopleInFloatingBar() : model.showPeople()
            }
            .keyboardShortcut("2", modifiers: .command)

            if let onRoomSettings {
                communicationButton(icon: "slider.horizontal.3", active: false, help: "Room settings", action: onRoomSettings)
            } else {
                settingsMenu
            }

            if showsCloseButton {
                Button(action: model.hideWalkieBar) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(WalkieActionButtonStyle(active: false))
                .help("Hide Talk bar")
                .accessibilityLabel("Hide Talk bar")
            }
        }
        .padding(3)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.messageSurface.opacity(0.76))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Palette.glassHighlight.opacity(0.62), lineWidth: 1)
                )
        }
    }

    private var settingsMenu: some View {
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
                ForEach(model.voiceInputDevices) { input in
                    Button {
                        model.selectVoiceInput(input.id)
                    } label: {
                        if input.id == model.selectedVoiceInputUID {
                            Label(input.menuName, systemImage: "checkmark")
                        } else {
                            Text(input.menuName)
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
            Button(model.incomingMediaMuted ? "Unmute room media" : "Mute room media") {
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
                (NSApp.delegate as? ALOAppDelegate)?.showShortcutMapper(nil)
            }
            Button("Diagnostics…") {
                (NSApp.delegate as? ALOAppDelegate)?.showDiagnostics(nil)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.controlIcon)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help("Talk settings · \(selectedMicrophoneName)")
        .accessibilityLabel("Talk settings")
    }

    private var voiceStateLabel: String {
        if model.walkieStarting { return "Starting" }
        if model.walkieTalking { return "Speaking" }
        if !model.incomingWalkieSpeakerIDs.isEmpty { return "Listening" }
        switch model.openLineState {
        case .invited: return "Incoming"
        case .inviting: return "Calling"
        case .connected: return "Open line"
        case .idle: return "Ready"
        }
    }

    private var voiceStateColor: Color {
        if !model.incomingWalkieSpeakerIDs.isEmpty { return Palette.voiceBlue }
        if model.walkieTalking || model.walkieStarting || model.openLineState.isSendingMicrophone {
            return Palette.voiceBlue
        }
        return Palette.muted
    }

    private var remoteParticipants: [RoomParticipant] {
        model.participants.filter { $0.id != model.currentParticipantID }
    }

    private var selectedMicrophoneName: String {
        guard let selectedVoiceInputUID = model.selectedVoiceInputUID else {
            let automaticName = VoiceInputCatalog.automaticInputName()
            return automaticName.map { "Automatic · \($0)" } ?? "Automatic"
        }
        return model.voiceInputDevices.first(where: { $0.id == selectedVoiceInputUID })?.menuName
            ?? "System microphone"
    }

    private var systemDefaultMicrophoneLabel: String {
        VoiceInputCatalog.automaticInputName().map { "Automatic — \($0)" }
            ?? "Automatic Microphone"
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
        .buttonStyle(WalkieActionButtonStyle(active: active))
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
        .accessibilityValue(badge > 0 ? "\(badge) unread messages" : "")
    }

}

@MainActor
private final class WalkieTalkieWindowController {
    private let panel: FloatingRoomPanel
    private var hasPosition = false
    private var participantObserver: AnyCancellable?

    init(model: ALOViewModel) {
        panel = FloatingRoomPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: FloatingMetrics.walkieBarWidth(participantCount: model.participants.count)
                    + FloatingMetrics.windowInset * 2,
                height: FloatingMetrics.windowHeight(
                    for: FloatingMetrics.walkieFloatingHeight
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
                for: FloatingMetrics.walkieFloatingHeight
            )
        )
        panel.maxSize = NSSize(
            width: FloatingMetrics.walkieBarMaxWidth + FloatingMetrics.windowInset * 2,
            height: FloatingMetrics.windowHeight(
                for: FloatingMetrics.walkieFloatingHeight
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
private final class FloatingRoomWindowController: NSObject, NSWindowDelegate {
    private var roomTouchBar: RoomTouchBarController?
    private let panel: FloatingRoomPanel
    private let model: ALOViewModel
    private var modelObserver: AnyCancellable?
    private var activityObserver: AnyCancellable?
    private var pendingShrink: DispatchWorkItem?
    private var hasPosition = false
    private var adjustingFrame = false
    private var preferredExpandedSize: NSSize

    init(model: ALOViewModel) {
        self.model = model
        let defaults = UserDefaults.standard
        preferredExpandedSize = NSSize(
            width: min(1800, max(FloatingMetrics.windowWidth, defaults.double(forKey: "room.expanded.width"))),
            height: min(1400, max(440, defaults.object(forKey: "room.expanded.height") == nil ? 550 : defaults.double(forKey: "room.expanded.height")))
        )
        panel = FloatingRoomPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: FloatingMetrics.windowWidth,
                height: FloatingMetrics.windowHeight(for: model.floatingPanelHeight + model.floatingNavigationHeight)
            ),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
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
        let touchBar = RoomTouchBarController(model: model, onGames: { [weak model] in model?.showGamesLibrary() })
        touchBar.attach(to: panel)
        roomTouchBar = touchBar

        activityObserver = model.arena.$expanded.removeDuplicates().sink { [weak self] detached in
            guard let self else { return }
            // A floating utility panel must never cover its own playable window.
            self.panel.level = detached ? .normal : .floating
            self.panel.isFloatingPanel = !detached
            if detached { self.panel.orderBack(nil) }
        }

        modelObserver = Publishers.CombineLatest4(
            model.$floatingSection.removeDuplicates(),
            model.$permissionNotice.removeDuplicates(),
            model.$participants.map(\.count).removeDuplicates(),
            model.$incomingMessagePreview.map { $0?.id }.removeDuplicates()
        )
        .combineLatest(model.$floatingNavigationVisible.removeDuplicates())
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

        let expanded = model.floatingSection != .collapsed && !model.permissionNotice
        let height = expanded ? preferredExpandedSize.height : FloatingMetrics.windowHeight(for: model.floatingPanelHeight + model.floatingNavigationHeight)
        let width = expanded ? preferredExpandedSize.width : FloatingMetrics.windowWidth
        panel.minSize = NSSize(width: FloatingMetrics.windowWidth, height: expanded ? 440 : height)
        panel.maxSize = expanded ? NSSize(width: 1800, height: 1400) : NSSize(width: width, height: height)
        guard abs(panel.frame.height - height) > 0.5
                || abs(panel.frame.width - width) > 0.5 else { return }
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
        let expanded = model.floatingSection != .collapsed && !model.permissionNotice
        frame.size = NSSize(width: expanded ? preferredExpandedSize.width : FloatingMetrics.windowWidth, height: height)
        frame.origin.y = fixedBottomEdge
        if let screenFrame {
            frame.size.width = min(frame.width, screenFrame.width)
            frame.origin.x = min(max(frame.origin.x, screenFrame.minX), screenFrame.maxX - frame.width)
            frame.origin.y = max(frame.origin.y, screenFrame.minY)
            frame.size.height = min(frame.height, screenFrame.maxY - frame.origin.y)
        }
        adjustingFrame = true
        panel.setFrame(frame, display: true)
        adjustingFrame = false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !adjustingFrame, model.floatingSection != .collapsed, !model.permissionNotice else { return }
        preferredExpandedSize = panel.frame.size
        UserDefaults.standard.set(preferredExpandedSize.width, forKey: "room.expanded.width")
        UserDefaults.standard.set(preferredExpandedSize.height, forKey: "room.expanded.height")
    }
}

private final class FullScreenVideoWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class VideoControlAutoHide: NSObject, ObservableObject {
    @Published private(set) var isVisible = true

    private let idleInterval: TimeInterval = 2.4
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var isPinned = false

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        if pinned {
            reveal()
        } else {
            stopTimer()
            isVisible = true
        }
    }

    func notePointerActivity() {
        lastActivity = ProcessInfo.processInfo.systemUptime
        guard isPinned else { return }
        if !isVisible { isVisible = true }
        startTimerIfNeeded()
    }

    func stop() {
        stopTimer()
    }

    private func reveal() {
        lastActivity = ProcessInfo.processInfo.systemUptime
        isVisible = true
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(checkIdleState),
            userInfo: nil,
            repeats: true
        )
        timer?.tolerance = 0.08
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func checkIdleState() {
        guard isPinned else {
            stopTimer()
            return
        }
        guard ProcessInfo.processInfo.systemUptime - lastActivity >= idleInterval else { return }
        isVisible = false
        stopTimer()
    }
}

private struct VideoPointerActivityRegion: NSViewRepresentable {
    let onActivity: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(onActivity: onActivity)
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onActivity = onActivity
    }

    final class TrackingView: NSView {
        var onActivity: () -> Void
        private var pointerTrackingArea: NSTrackingArea?

        init(onActivity: @escaping () -> Void) {
            self.onActivity = onActivity
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerTrackingArea {
                removeTrackingArea(pointerTrackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .activeAlways],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            pointerTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onActivity()
        }

        override func mouseMoved(with event: NSEvent) {
            onActivity()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

private struct FullScreenVideoView: View {
    @ObservedObject var model: ALOViewModel
    @StateObject private var controlVisibility = VideoControlAutoHide()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
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
        }
        .background {
            VideoPointerActivityRegion {
                controlVisibility.notePointerActivity()
            }
        }
        .overlay(alignment: .bottom) {
            videoControls
                .opacity(showsVideoControls ? 1 : 0)
                .offset(y: showsVideoControls ? 0 : 8)
                .allowsHitTesting(showsVideoControls)
                .accessibilityHidden(!showsVideoControls)
                .animation(
                    reduceMotion ? nil : .snappy(duration: 0.2, extraBounce: 0.04),
                    value: showsVideoControls
                )
                .padding(.bottom, 18)
        }
        .onAppear {
            controlVisibility.setPinned(model.videoViewerPinned)
        }
        .onChange(of: model.videoViewerPinned) { _, pinned in
            controlVisibility.setPinned(pinned)
        }
        .onDisappear {
            controlVisibility.stop()
        }
        .onExitCommand(perform: model.exitVideoFullscreen)
    }

    private var showsVideoControls: Bool {
        !model.videoViewerPinned || controlVisibility.isVisible
    }

    private var videoControls: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.36))
                .frame(width: 34, height: 3)
                .frame(width: 88, height: 9)
                .contentShape(Rectangle())
                .overlay(WindowDragRegion().accessibilityHidden(true))
                .help("Drag video window")

            HStack(spacing: 7) {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
                Text(model.isHost ? "YOUR SCREEN" : "LIVE SCREEN")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.35)
                Text(model.roomTitle)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Button(model.isHost ? "Stop sharing" : "Audio only") {
                    model.selectExperience(.audio)
                }
                .buttonStyle(VideoOverlayButtonStyle(compact: true))
                Button(action: model.toggleVideoViewerPinned) {
                    Image(systemName: model.videoViewerPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(VideoControlButtonStyle(size: 28))
                .help(model.videoViewerPinned ? "Unpin from desktops" : "Keep on every desktop")
                .accessibilityLabel(model.videoViewerPinned ? "Unpin video window" : "Pin video window")
                Button(action: model.toggleVideoWindowFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(VideoControlButtonStyle(size: 28))
                .help("Toggle full screen")
                .accessibilityLabel("Toggle full screen")
                Button(action: model.exitVideoFullscreen) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(VideoControlButtonStyle(size: 28))
                .help("Close video window")
                .accessibilityLabel("Close video window")
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .padding(.bottom, 5)
        .frame(width: 438, height: 44)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
    }
}

@MainActor
private final class FullScreenVideoWindowController: NSObject, NSWindowDelegate {
    private let window: FullScreenVideoWindow
    private let closeHandler: () -> Void

    init(model: ALOViewModel, closeHandler: @escaping () -> Void) {
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
        window.acceptsMouseMovedEvents = true
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

struct ArtworkHeaderBackground: View {
    let palette: ArtworkPalette?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if let palette {
                // Carry every sampled hue through the whole header, rather
                // than fading one accent into a mostly neutral surface.
                LinearGradient(colors: palette.hexes.map(Color.deviceIdentity),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if colorScheme == .dark {
                    Color.black.opacity(contrast == .increased ? 0.72 : 0.62)
                } else {
                    Color.white.opacity(contrast == .increased ? 0.90 : 0.68)
                }
            } else {
                Palette.opaqueSurface
            }
            StaticGrain().blendMode(.softLight).opacity(0.12)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ArtworkAtmosphere: View {
    let colors: [Color]
    var strength = 1.0

    var body: some View {
        let primary = colors.first ?? Palette.controlAccent
        let secondary = colors.dropFirst().first ?? Palette.accentSoft
        let tertiary = colors.dropFirst(2).first ?? Palette.blueSoft

        return GeometryReader { geometry in
            let reach = max(geometry.size.width, geometry.size.height)
            ZStack {
                Palette.opaqueSurface
                RadialGradient(
                    colors: [primary.opacity(0.34 * strength), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: reach * 0.82
                )
                RadialGradient(
                    colors: [secondary.opacity(0.28 * strength), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: reach * 0.72
                )
                RadialGradient(
                    colors: [tertiary.opacity(0.18 * strength), .clear],
                    center: UnitPoint(x: 0.76, y: 0.18),
                    startRadius: 0,
                    endRadius: reach * 0.56
                )
                Palette.opaqueSurface.opacity(0.42)
                StaticGrain()
                    .blendMode(.softLight)
                    .opacity(0.11 * strength)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct StaticGrain: View {
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let count = min(520, max(120, Int(size.width * size.height / 1_100)))
            for index in 0..<count {
                let x = unit(index, salt: 17.3) * size.width
                let y = unit(index, salt: 61.7) * size.height
                let side = 0.55 + unit(index, salt: 9.1) * 0.85
                let tone = index.isMultiple(of: 2) ? Color.white : Color.black
                let opacity = 0.18 + unit(index, salt: 42.9) * 0.34
                context.fill(
                    Path(CGRect(x: x, y: y, width: side, height: side)),
                    with: .color(tone.opacity(opacity))
                )
            }
        }
    }

    private func unit(_ index: Int, salt: Double) -> CGFloat {
        let raw = sin(Double(index) * 12.9898 + salt) * 43_758.5453
        return CGFloat(raw - floor(raw))
    }
}

private struct SetupBackground: View {
    private static let slideNames = [
        "ALOSetupSlide-1",
        "ALOSetupSlide-2",
        "ALOSetupSlide-3",
        "ALOSetupSlide-4",
    ]
    private static let slides: [NSImage] = slideNames.compactMap { name in
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedSlide = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if Self.slides.isEmpty {
                    fallbackBackground
                } else {
                    ForEach(Self.slides.indices, id: \.self) { index in
                        Image(nsImage: Self.slides[index])
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .opacity(selectedSlide == index ? 1 : 0)
                    }
                }
                LinearGradient(
                    colors: [Color.black.opacity(0.10), .clear, Color.black.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .task(id: reduceMotion) {
            guard !reduceMotion, Self.slides.count > 1 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(7))
                } catch {
                    return
                }
                withAnimation(.easeInOut(duration: 1.15)) {
                    selectedSlide = (selectedSlide + 1) % Self.slides.count
                }
            }
        }
    }

    @ViewBuilder
    private var fallbackBackground: some View {
        if let url = Bundle.main.url(forResource: "ALOSetupBackground", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            AmbientBackground(isLive: false)
        }
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
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .frame(width: size, height: size)
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
    static let voiceBlue = adaptive(
        light: NSColor(red: 0.12, green: 0.46, blue: 0.82, alpha: 1),
        dark: NSColor(red: 0.35, green: 0.68, blue: 0.96, alpha: 1)
    )
    static let voiceSelection = Color(nsColor: .tertiaryLabelColor)
    static let voiceBadgeSurface = adaptive(
        light: NSColor(white: 0.94, alpha: 0.96),
        dark: NSColor(white: 0.12, alpha: 0.96)
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

struct ArtworkPalette: Equatable {
    let accentHex: String
    let secondaryHex: String
    let tertiaryHex: String

    var hexes: [String] { [accentHex, secondaryHex, tertiaryHex] }
}

enum ArtworkTheme {
    private struct HueBucket {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var weight: CGFloat = 0

        mutating func add(red: CGFloat, green: CGFloat, blue: CGFloat, weight: CGFloat) {
            self.red += red * weight
            self.green += green * weight
            self.blue += blue * weight
            self.weight += weight
        }

        var average: NSColor? {
            guard weight > 0 else { return nil }
            return NSColor(
                srgbRed: red / weight,
                green: green / weight,
                blue: blue / weight,
                alpha: 1
            )
        }
    }

    static func accentHex(from data: Data?) -> String? {
        palette(from: data)?.accentHex
    }

    static func palette(from data: Data?) -> ArtworkPalette? {
        guard let pixels = sampledPixels(from: data) else { return nil }
        let bucketCount = 12
        var buckets = [HueBucket](repeating: HueBucket(), count: bucketCount)

        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 16 {
            let red = CGFloat(pixels[offset]) / 255
            let green = CGFloat(pixels[offset + 1]) / 255
            let blue = CGFloat(pixels[offset + 2]) / 255
            let color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation >= 0.08, brightness >= 0.06 else { continue }

            let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
            let weight = saturation * (0.42 + luminance * 0.58)
            let index = min(bucketCount - 1, Int(hue * CGFloat(bucketCount)))
            buckets[index].add(red: red, green: green, blue: blue, weight: weight)
        }

        let ranked = buckets.indices
            .filter { buckets[$0].weight > 0 }
            .sorted { buckets[$0].weight > buckets[$1].weight }
        guard let primaryIndex = ranked.first else { return nil }

        var selected = [primaryIndex]
        for index in ranked.dropFirst() {
            let isDistinct = selected.allSatisfy {
                let distance = abs(index - $0)
                return min(distance, bucketCount - distance) >= 2
            }
            if isDistinct {
                selected.append(index)
                if selected.count == 3 { break }
            }
        }
        while selected.count < 3 { selected.append(primaryIndex) }

        guard let accent = calibratedHex(from: buckets[selected[0]], role: 0),
              let secondary = calibratedHex(from: buckets[selected[1]], role: 1),
              let tertiary = calibratedHex(from: buckets[selected[2]], role: 2)
        else { return nil }
        return ArtworkPalette(accentHex: accent, secondaryHex: secondary, tertiaryHex: tertiary)
    }

    private static func sampledPixels(from data: Data?) -> [UInt8]? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 40,
                ] as CFDictionary
              )
        else { return nil }

        let sampleSize = 12
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
        return drewImage ? pixels : nil
    }

    private static func calibratedHex(from bucket: HueBucket, role: Int) -> String? {
        guard let average = bucket.average else { return nil }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        let targetSaturation: ClosedRange<CGFloat>
        let targetBrightness: ClosedRange<CGFloat>
        switch role {
        case 1:
            targetSaturation = 0.28...0.62
            targetBrightness = 0.38...0.62
        case 2:
            targetSaturation = 0.30...0.64
            targetBrightness = 0.56...0.76
        default:
            targetSaturation = 0.34...0.68
            targetBrightness = 0.50...0.70
        }

        let color = NSColor(
            calibratedHue: hue,
            saturation: min(targetSaturation.upperBound, max(targetSaturation.lowerBound, saturation * 1.06)),
            brightness: min(targetBrightness.upperBound, max(targetBrightness.lowerBound, brightness)),
            alpha: 1
        ).usingColorSpace(.sRGB) ?? average
        return String(
            format: "%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
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

#if DEBUG
/// Isolated presentation harness: no room discovery, sockets, capture or outgoing messages.
@MainActor
enum RoomPresentationPreview {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let model = ALOViewModel(discoverRooms: false)
        model.roomName = "Offline preview"
        model.phase = .live
        model.floatingSection = .chat
        model.floatingBarHidden = false
        model.currentParticipantID = "preview-local"
        model.currentUserName = "You"
        model.arena.localParticipantID = "preview-local"
        model.arena.localName = "You"
        // Explicit offline UI harness: host bots locally, never send invitations or packets.
        model.arena.send = { _, _ in }
        model.participants = [RoomParticipant(id: "preview-local", name: "You"), RoomParticipant(id: "preview-peer", name: "Luna")]
        model.messages = [
            RoomMessage(senderID: "preview-peer", sender: "Luna", text: "Music, conversation, or a quick round?", sentNanos: 1),
            RoomMessage(senderID: "preview-local", sender: "You", text: "Let’s try Rift Arena.", sentNanos: 2)
        ]
        let controller = FloatingRoomWindowController(model: model)
        controller.show()
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(controller) { app.run() }
        model.arena.disconnect()
    }
}
#endif
