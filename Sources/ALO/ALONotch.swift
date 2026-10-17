import AppKit
import Combine
import SwiftUI
import ALONotchRuntime

/// ALO owns only the master switch. Feature, display, gesture and animation
/// preferences belong to the original DynamicNotch settings module.
@MainActor
final class ALONotchPreferences: ObservableObject {
    static let shared = ALONotchPreferences()
    private let defaults: UserDefaults
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "alo.notch.enabled") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "alo.notch.enabled")
    }
}

/// Uses the repository's original panel, hosting view, sizing and content.
/// There is no room-bar wrapper, extra toolbar, or second animation system.
@MainActor
final class ALONotchWindowController {
    private let preferences: ALONotchPreferences
    private let features = ALONotchFeatureBridge.shared
    private var panel: NSPanel?
    private var observers = Set<AnyCancellable>()
    private var timer: Timer?
    private var quickLogIsPresented = false
    private var fileDragApproach = NotchFileDragApproach()

    init(model: ALOViewModel, preferences: ALONotchPreferences? = nil) {
        self.preferences = preferences ?? .shared
        features.configure(model: model)
        model.smokingLog.$isQuickLogPresented.removeDuplicates()
            .sink { [weak self] presented in
                self?.quickLogIsPresented = presented
                self?.updateVisibility()
            }.store(in: &observers)
        self.preferences.$enabled.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }.store(in: &observers)
        features.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }.store(in: &observers)
        updateVisibility()
    }

    deinit { timer?.invalidate() }

    private func updateVisibility() {
        features.setEnabled(preferences.enabled)
        guard preferences.enabled, let runtime = features.runtime else {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
            panel?.contentView = nil
            return
        }
        if panel == nil {
            let originalPanel = runtime.makeHostPanel()
            Self.mountOriginalContent(in: originalPanel, makeContent: runtime.makeHostView)
            panel = originalPanel
        }
        guard let panel else { return }
        runtime.attachHostWindow(panel)
        if panel.contentView == nil {
            Self.mountOriginalContent(in: panel, makeContent: runtime.makeHostView)
        }
        // The notch is hosted above ordinary AppKit popovers. Yield the whole
        // panel while logging, without disabling features or stopping playback.
        guard !quickLogIsPresented, !runtime.isLocked, !runtime.shouldHideInFullscreen,
              let screen = runtime.preferredScreen else {
            panel.orderOut(nil)
            timer?.invalidate()
            timer = nil
            return
        }
        let frame = runtime.hostFrame(on: screen)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if timer == nil {
            let tracking = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePointerPassThrough() }
            }
            RunLoop.main.add(tracking, forMode: .common)
            timer = tracking
        }
        updatePointerPassThrough()
    }

    /// NSPanel starts with a non-nil plain NSView. Initial mounting cannot rely
    /// on contentView == nil, which otherwise leaves a completely blank panel.
    static func mountOriginalContent(in panel: NSPanel, makeContent: () -> NSView) {
        panel.contentView = makeContent()
    }

    private func updatePointerPassThrough() {
        guard let panel, panel.isVisible, let runtime = features.runtime else { return }
        let pointer = NSEvent.mouseLocation
        let pasteboard = NSPasteboard(name: .drag)
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        if fileDragApproach.shouldReveal(mouseDown: dragging, changeCount: pasteboard.changeCount,
            hasFileURLs: pasteboard.types?.contains(.fileURL) == true, pointer: pointer,
            notch: runtime.interactiveScreenRect) {
            runtime.beginFileDragApproach()
        }
        if !dragging { runtime.endFileDragApproach() }
        panel.ignoresMouseEvents = !(runtime.interactiveScreenRect?.contains(pointer) ?? false)
    }
}

/// Reveal below the menu bar, before a file reaches macOS's Mission Control
/// hot edge. A stale drag pasteboard must never turn a window/text drag into a file drop.
struct NotchFileDragApproach {
    private var idleChangeCount: Int?
    private var revealed = false

    mutating func shouldReveal(mouseDown: Bool, changeCount: Int, hasFileURLs: Bool,
                               pointer: CGPoint, notch: CGRect?) -> Bool {
        guard mouseDown else {
            idleChangeCount = changeCount
            revealed = false
            return false
        }
        guard !revealed, let idleChangeCount, changeCount != idleChangeCount,
              hasFileURLs, let notch else { return false }
        let approach = CGRect(x: notch.minX - 24, y: notch.minY - 80,
                              width: notch.width + 48, height: notch.height + 80)
        guard approach.contains(pointer) else { return false }
        revealed = true
        return true
    }
}
