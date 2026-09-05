import AppKit
import Combine
import SwiftUI
import ALONotchRuntime

/// Lazy ownership keeps the full feature engine out of disabled startup.
@MainActor
final class ALONotchFeatureBridge: ObservableObject {
    static let shared = ALONotchFeatureBridge()
    @Published private(set) var runtime: EmbeddedNotchRuntime?
    @Published var prefersRoom = false
    private var observations = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    var showingActivities: Bool { runtime?.isEnabled == true && runtime?.activityActive == true && !prefersRoom }

    func setEnabled(_ enabled: Bool) {
        if enabled && runtime == nil {
            let runtime = EmbeddedNotchRuntime()
            runtime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
            runtime.$activityActive.removeDuplicates().dropFirst()
                .sink { [weak self] active in if active { self?.prefersRoom = false } }
                .store(in: &observations)
            self.runtime = runtime
        }
        runtime?.setEnabled(enabled)
    }

    func openActivities() {
        guard ALONotchPreferences.shared.enabled else { return }
        setEnabled(true)
        prefersRoom = false
        runtime?.openHomePage()
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 638),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "ALO Notch Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ALONotchFeatureSettings(features: self))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ALONotchFeatureSettings: View {
    @ObservedObject var features: ALONotchFeatureBridge
    @ObservedObject private var preferences = ALONotchPreferences.shared
    var body: some View {
        VStack(spacing: 0) {
            Toggle("Enable notch", isOn: $preferences.enabled)
                .toggleStyle(.switch).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if preferences.enabled, let runtime = features.runtime {
                runtime.settingsView
            } else {
                ContentUnavailableView("Notch is disabled", systemImage: "rectangle.topthird.inset.filled",
                    description: Text("Enable the notch to choose features. Every additional feature starts disabled."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 760, height: 638)
            .onAppear { features.setEnabled(preferences.enabled) }
            .onChange(of: preferences.enabled) { _, enabled in features.setEnabled(enabled) }
    }
}

struct ALONotchHostView: View {
    @ObservedObject var model: ALOViewModel
    @ObservedObject var preferences: ALONotchPreferences
    @ObservedObject var state: ALONotchPresentation
    @ObservedObject var features: ALONotchFeatureBridge

    var body: some View {
        Group {
            if features.showingActivities, let runtime = features.runtime {
                runtime.contentView
                    .overlay(alignment: .top) {
                        HStack(spacing: 16) {
                            Button("Room controls") { features.prefersRoom = true }
                            Button("Notch settings…") { features.showSettings() }
                        }
                        .font(.caption).buttonStyle(.plain)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, runtime.hitTestSize.height + 24)
                    }
            } else {
                ALONotchView(model: model, preferences: preferences, state: state)
                    .overlay(alignment: .top) {
                        if let runtime = features.runtime {
                            runtime.dragDestinationView
                                .frame(width: state.expanded ? 592 : state.compactWidth,
                                       height: state.expanded ? min(state.availableHeight - (preferences.island ? state.safeTop + 6 : 0), model.floatingPanelHeight + 87 + state.safeTop + 36) : state.safeTop + 8)
                                .padding(.top, preferences.island ? state.safeTop + 6 : 0)
                        }
                    }
            }
        }
    }
}
