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

struct ALONotchSettingsMenu: View {
    @ObservedObject private var preferences = ALONotchPreferences.shared
    var body: some View {
        Menu("Notch") {
            Toggle("Enable notch", isOn: $preferences.enabled)
            if preferences.enabled {
                Button("Notch settings…") { ALONotchFeatureBridge.shared.showSettings() }
                Button("Open activities") { ALONotchFeatureBridge.shared.openActivities() }
            }
        }
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

    init(model: ALOViewModel, preferences: ALONotchPreferences? = nil) {
        self.preferences = preferences ?? .shared
        features.configure(model: model)
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
        guard !runtime.isLocked, !runtime.shouldHideInFullscreen,
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
        panel.ignoresMouseEvents = !(runtime.interactiveScreenRect?.contains(NSEvent.mouseLocation) ?? false)
    }
}
