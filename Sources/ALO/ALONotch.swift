import AppKit
import Combine
import SwiftUI
import ALONotchRuntime

/// ALO's adapter; geometry and spring/transition implementations live in DynamicNotch/.
@MainActor
final class ALONotchPreferences: ObservableObject {
    static let shared = ALONotchPreferences()
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { save(enabled, "enabled") } }
    @Published var hoverToExpand: Bool { didSet { save(hoverToExpand, "hover") } }
    @Published var island: Bool { didSet { save(island, "island") } }
    @Published var builtInDisplay: Bool { didSet { save(builtInDisplay, "builtIn") } }
    @Published var animation: String { didSet { save(animation, "animation") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "alo.notch.enabled")
        hoverToExpand = defaults.object(forKey: "alo.notch.hover") as? Bool ?? true
        island = defaults.bool(forKey: "alo.notch.island")
        builtInDisplay = defaults.object(forKey: "alo.notch.builtIn") as? Bool ?? true
        animation = defaults.string(forKey: "alo.notch.animation") ?? "balanced"
    }
    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: "alo.notch." + key) }
    var preset: NotchAnimationPreset { NotchAnimationPreset(rawValue: animation) ?? .balanced }
}

struct ALONotchSettingsMenu: View {
    @ObservedObject private var preferences = ALONotchPreferences.shared
    var body: some View {
        Menu("Notch") {
            Toggle("Enable notch", isOn: $preferences.enabled)
            if preferences.enabled {
                Button("Feature settings…") { ALONotchFeatureBridge.shared.showSettings() }
                Button("Open activities") { ALONotchFeatureBridge.shared.openActivities() }
                Divider()
            Toggle("Expand on hover", isOn: $preferences.hoverToExpand)
            Toggle("Floating island style", isOn: $preferences.island)
            Toggle("Prefer built-in display", isOn: $preferences.builtInDisplay)
            Picker("Motion", selection: $preferences.animation) {
                ForEach(NotchAnimationPreset.allCases, id: \.rawValue) { preset in
                    Text(preset.rawValue.capitalized).tag(preset.rawValue)
                }
            }
            }
        }
    }
}

@MainActor
final class ALONotchPresentation: ObservableObject {
    @Published var expanded = false
    @Published var safeTop: CGFloat = 32
    @Published var compactWidth: CGFloat = 280
    @Published var availableHeight: CGFloat = 700
}

private final class ALONotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ALONotchWindowController {
    private let model: ALOViewModel
    private let preferences: ALONotchPreferences
    private let state = ALONotchPresentation()
    private let panel: ALONotchPanel
    private var observers = Set<AnyCancellable>()
    private var timer: Timer?
    private var outsideSince: Date?
    private var menuTracking = false
    private var pointerWasInside = false
    private let features = ALONotchFeatureBridge.shared
    private let canvasWidth: CGFloat = 1000

    init(model: ALOViewModel, preferences: ALONotchPreferences? = nil) {
        self.model = model
        let preferences = preferences ?? .shared
        self.preferences = preferences
        panel = ALONotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: ALONotchHostView(model: model, preferences: preferences, state: state, features: features))
        hosting.sizingOptions = []
        panel.contentView = hosting
        Publishers.CombineLatest(model.$phase, preferences.$enabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateVisibility() }.store(in: &observers)
        features.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }.store(in: &observers)
        state.$expanded.receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                guard let self else { return }
                self.model.notchExpandedVisible = expanded && self.preferences.enabled && self.model.phase == .live && !self.features.showingActivities
            }.store(in: &observers)
        preferences.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in self?.layout() }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.menuTracking = true }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in self?.menuTracking = false }.store(in: &observers)
        updateVisibility()
    }

    deinit { timer?.invalidate() }

    private func updateVisibility() {
        features.setEnabled(preferences.enabled)
        features.runtime?.attachHostWindow(panel)
        model.notchExpandedVisible = preferences.enabled && state.expanded && model.phase == .live && !features.showingActivities
        guard preferences.enabled, features.runtime?.isLocked != true, features.runtime?.shouldHideInFullscreen != true else {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
            model.notchExpandedVisible = false
            state.expanded = false
            outsideSince = nil
            pointerWasInside = false
            return
        }
        if timer == nil {
            // Poll only while the overlay is enabled; disabled startup has no timer.
            let tracking = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackPointer() }
            }
            RunLoop.main.add(tracking, forMode: .common)
            timer = tracking
        }
        layout()
        panel.orderFrontRegardless()
        trackPointer()
    }

    private func layout() {
        let screens = NSScreen.screens
        let builtIn = screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(id.uint32Value) != 0
        }
        let roomScreen = (preferences.builtInDisplay ? builtIn : nil) ?? screens.first
        guard let screen = features.showingActivities ? features.runtime?.preferredScreen ?? roomScreen : roomScreen else { return }
        state.safeTop = max(24, screen.safeAreaInsets.top)
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.compactWidth = max(280, right.minX - left.maxX + 110)
        } else { state.compactWidth = 280 }
        state.availableHeight = min(900, screen.frame.height - 60)
        panel.setFrame(OverlayWindowLayout.topAnchoredFrame(on: screen,
            size: CGSize(width: canvasWidth, height: state.availableHeight), yOffset: 0), display: true)
    }

    private func trackPointer() {
        guard panel.isVisible else { return }
        if features.showingActivities, let runtime = features.runtime {
            let size = runtime.hitTestSize
            let rect = NSRect(x: panel.frame.midX - max(220, size.width) / 2 - 16,
                              y: panel.frame.maxY - size.height - 98,
                              width: max(220, size.width) + 32, height: size.height + 98)
            panel.ignoresMouseEvents = !rect.contains(NSEvent.mouseLocation)
            return
        }
        let topInset: CGFloat = preferences.island ? state.safeTop + 6 : 0
        let height = state.expanded ? min(state.availableHeight - topInset, model.floatingPanelHeight + 87 + state.safeTop + 36) : state.safeTop + 8
        let width: CGFloat = state.expanded ? 592 : state.compactWidth
        let visibleRect = NSRect(x: panel.frame.midX - width / 2,
                                 y: panel.frame.maxY - topInset - height,
                                 width: width, height: height)
        let inside = visibleRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        let justEntered = inside && !pointerWasInside
        pointerWasInside = inside
        if inside {
            outsideSince = nil
            if preferences.hoverToExpand && justEntered { state.expanded = true }
        } else if model.notchHasOpenPopover {
            // Popovers use a separate native window; leaving the surface to
            // interact with them must not unmount their anchor after 0.65s.
            outsideSince = nil
        } else if !menuTracking && !panel.isKeyWindow && model.floatingSection == .collapsed {
            if outsideSince == nil { outsideSince = Date() }
            if preferences.hoverToExpand, Date().timeIntervalSince(outsideSince!) > 0.65 {
                state.expanded = false
            }
        }
    }
}

struct ALONotchView: View {
    @ObservedObject var model: ALOViewModel
    @ObservedObject var preferences: ALONotchPreferences
    @ObservedObject var state: ALONotchPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var topInset: CGFloat { preferences.island ? state.safeTop + 6 : 0 }
    private var shape: AnyShape {
        preferences.island
            ? AnyShape(DynamicIslandShape(cornerRadius: state.expanded ? 24 : 18))
            : AnyShape(NotchShape(topCornerRadius: state.expanded ? 12 : 6, bottomCornerRadius: state.expanded ? 24 : 12))
    }
    private var motion: Animation {
        if reduceMotion { return .easeOut(duration: 0.1) }
        let animations = NotchAnimations.preset(preferences.preset)
        return state.expanded ? animations.expandLiveActivity : animations.closeLiveActivity
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(.black)
                if state.expanded {
                    VStack(spacing: 0) {
                        HStack {
                            Text("ALO").font(.caption.weight(.semibold))
                            Button("Activities") { ALONotchFeatureBridge.shared.openActivities() }
                                .buttonStyle(.plain).font(.caption)
                            Spacer()
                            Button { state.expanded = false } label: {
                                Image(systemName: "chevron.up").frame(width: 30, height: 24)
                            }.buttonStyle(.plain).help("Collapse notch")
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, preferences.island ? 8 : state.safeTop)
                        ScrollView {
                            VStack(spacing: 0) {
                                if model.phase == .live {
                                    FloatingRoomView(model: model, presentation: .notch)
                                    RoomPlaybackProgressDivider(model: model)
                                    WalkieTalkieBar(model: model, showsCloseButton: false, presentation: .notch)
                                } else {
                                    VStack(spacing: 12) {
                                        Text("Join a room to see room controls")
                                        Button("Notch feature settings…") { ALONotchFeatureBridge.shared.showSettings() }
                                    }.frame(height: 145)
                                }
                            }.frame(width: 560)
                        }.scrollBounceBehavior(.basedOnSize)
                    }
                    .transition(reduceMotion ? .opacity : .notchExpanded(notchHeight: model.floatingPanelHeight + 87, baseHeight: state.safeTop))
                } else {
                    Button { state.expanded = true } label: {
                        HStack {
                            Image(systemName: model.roomIsPlaying ? "waveform" : "headphones")
                                .foregroundStyle(.cyan)
                            Spacer(minLength: 180)
                            Text("\(model.participants.count)").font(.caption.monospacedDigit())
                        }.padding(.horizontal, 22)
                            .frame(height: state.safeTop + 8)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Expand ALO notch. \(model.nowPlaying.title ?? "Room controls")")
                        .help(model.nowPlaying.title ?? "ALO room controls")
                        .transition(reduceMotion ? .opacity : .blurAndFade)
                }
            }
            .frame(width: state.expanded ? 592 : state.compactWidth,
                   height: state.expanded ? min(state.availableHeight - topInset, model.floatingPanelHeight + 87 + state.safeTop + 36) : state.safeTop + 8)
            .clipShape(shape)
            .foregroundStyle(.white)
            .colorScheme(.dark)
            .animation(motion, value: state.expanded)
            .animation(reduceMotion ? .easeOut(duration: 0.1) : NotchAnimations.preset(preferences.preset).contentUpdate, value: model.floatingPanelHeight)
            .padding(.top, topInset)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand { state.expanded = false }
    }
}
