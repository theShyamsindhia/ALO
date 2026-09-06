import AppKit
import Combine

enum ALOMenuBarControl: String, CaseIterable, Identifiable {
    case record, playback, next, chat, people, screen, sync, mute

    var id: String { rawValue }
    var title: String {
        switch self {
        case .record: "Record disc"
        case .playback: "Play / pause"
        case .next: "Next song"
        case .chat: "Chat"
        case .people: "People"
        case .screen: "Screen sharing"
        case .sync: "Sync all"
        case .mute: "Mute room media"
        }
    }
    var symbol: String {
        switch self {
        case .record: "opticaldisc"
        case .playback: "play.fill"
        case .next: "forward.end.fill"
        case .chat: "bubble.left.and.text.bubble.right"
        case .people: "person.2"
        case .screen: "rectangle.on.rectangle"
        case .sync: "arrow.triangle.2.circlepath"
        case .mute: "speaker.wave.2"
        }
    }
}

@MainActor
final class ALOMenuBarPreferences: ObservableObject {
    static let shared = ALOMenuBarPreferences()
    static let storageKey = "alo.menuBar.pinnedControls"
    @Published private(set) var controls: Set<ALOMenuBarControl>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: Self.storageKey) {
            controls = Set(saved.compactMap(ALOMenuBarControl.init(rawValue:)))
        } else {
            controls = [.record]
        }
    }

    func setPinned(_ control: ALOMenuBarControl, _ pinned: Bool) {
        var updated = controls
        if pinned { updated.insert(control) } else { updated.remove(control) }
        guard controls != updated else { return }
        controls = updated
        defaults.set(ALOMenuBarControl.allCases.filter(updated.contains).map(\.rawValue), forKey: Self.storageKey)
    }
}

struct ALOMenuBarControlState: Equatable {
    var live: Bool
    var playbackAvailable: Bool
    var playing: Bool
    var broadcaster: Bool
    var busy: Bool
    var videoAvailable: Bool
    var hasVideo: Bool
    var muted: Bool
    var unread: Int

    func enabled(_ control: ALOMenuBarControl) -> Bool {
        if control == .record { return true }
        guard live else { return false }
        switch control {
        case .playback, .next: return playbackAvailable && !busy
        case .sync: return broadcaster && !busy
        case .screen: return videoAvailable
        case .chat, .people, .mute: return true
        case .record: return true
        }
    }

    func symbol(_ control: ALOMenuBarControl) -> String {
        switch control {
        case .playback: return playing ? "pause.fill" : "play.fill"
        case .mute: return muted ? "speaker.slash.fill" : "speaker.wave.2"
        default: return control.symbol
        }
    }

    func help(_ control: ALOMenuBarControl) -> String {
        guard enabled(control) else { return "ALO · \(control.title) · unavailable right now" }
        switch control {
        case .playback: return playing ? "ALO · Pause everywhere" : "ALO · Play everywhere"
        case .mute: return muted ? "ALO · Unmute room media on this Mac" : "ALO · Mute room media on this Mac"
        case .sync: return "ALO · Sync all · request fresh timing for everyone"
        case .screen: return busy ? "ALO · Cancel screen selection" : hasVideo ? "ALO · View shared video" : "ALO · Share screen and audio"
        case .chat: return "ALO · Chat" + (unread > 0 ? " · \(unread) unread" : "")
        default: return "ALO · \(control.title)"
        }
    }
}

/// The existing record stays separate. Optional SF Symbols take their tint from the artwork.
enum ALOMenuBarControlImage {
    static func tint(palette: ArtworkPalette?, appearance: NSAppearance) -> NSColor {
        var result = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            guard let palette else { result = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor; return }
            let accent = NSColor.deviceIdentity(palette.accentHex)
            let background = NSColor.windowBackgroundColor
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let endpoint: NSColor = dark ? .white : .black
            result = accent
            // Preserve the artwork hue, adjusting only as far as legibility requires.
            for step in 0...20 {
                let candidate = accent.blended(withFraction: CGFloat(step) / 20, of: endpoint) ?? endpoint
                result = candidate
                if contrast(candidate, background) >= 4.5 { break }
            }
        }
        return result
    }

    static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func make(symbol name: String, palette: ArtworkPalette?, appearance: NSAppearance, unread: Bool = false) -> NSImage {
        let foreground = tint(palette: palette, appearance: appearance)
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { bounds in
            appearance.performAsCurrentDrawingAppearance {
                guard let source = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) else { return }
                let glyph = NSImage(size: source.size, flipped: false) { rect in
                    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                    guard let context = NSGraphicsContext.current?.cgContext else { return false }
                    context.setBlendMode(.sourceIn)
                    context.setFillColor(foreground.cgColor)
                    context.fill(rect)
                    return true
                }
                let scale = min(16 / glyph.size.width, 16 / glyph.size.height)
                let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
                glyph.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                      width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1)
                if unread {
                    NSColor.systemRed.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 18, y: 18, width: 5, height: 5)).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

@MainActor
final class ALOPinnedMenuBarController {
    private let model: ALOViewModel
    private let preferences: ALOMenuBarPreferences
    private let navigate: (ALOViewModel.FloatingSection) -> Void
    private var items: [ALOMenuBarControl: NSStatusItem] = [:]
    private var targets: [ALOMenuBarControl: MenuBarActionTarget] = [:]
    private var observers = Set<AnyCancellable>()
    private var lastState: ALOMenuBarControlState?
    private var lastPalette: ArtworkPalette?

    init(model: ALOViewModel, preferences: ALOMenuBarPreferences,
         navigate: @escaping (ALOViewModel.FloatingSection) -> Void) {
        self.model = model
        self.preferences = preferences
        self.navigate = navigate
        preferences.$controls.sink { [weak self] controls in self?.reconcile(controls) }.store(in: &observers)
        model.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        NSApplication.shared.publisher(for: \.effectiveAppearance)
            .sink { [weak self] _ in self?.refresh(force: true) }.store(in: &observers)
    }

    private var state: ALOMenuBarControlState {
        ALOMenuBarControlState(live: model.phase == .live,
            playbackAvailable: model.canControlRoomPlayback, playing: model.roomIsPlaying,
            broadcaster: model.hasBroadcaster, busy: model.mediaSwitchBusy,
            videoAvailable: model.canSelectVideo, hasVideo: model.roomHasVideo,
            muted: model.incomingMediaMuted, unread: model.unreadMessageCount)
    }

    deinit {
        MainActor.assumeIsolated {
            for item in items.values { NSStatusBar.system.removeStatusItem(item) }
        }
    }

    private func reconcile(_ controls: Set<ALOMenuBarControl>) {
        for control in Array(items.keys) where !controls.contains(control) {
            if let item = items.removeValue(forKey: control) { NSStatusBar.system.removeStatusItem(item) }
            targets.removeValue(forKey: control)
        }
        for control in ALOMenuBarControl.allCases where control != .record && controls.contains(control) && items[control] == nil {
            let item = NSStatusBar.system.statusItem(withLength: 28)
            item.autosaveName = "ALO.control.\(control.rawValue)"
            let target = MenuBarActionTarget { [weak self] in self?.perform(control) }
            item.button?.target = target
            item.button?.action = #selector(MenuBarActionTarget.invoke)
            target.appearanceObserver = item.button?.publisher(for: \.effectiveAppearance).dropFirst()
                .sink { [weak self] _ in self?.refresh(force: true) }
            items[control] = item
            targets[control] = target
        }
        refresh(force: true)
    }

    private func refresh(force: Bool = false) {
        let current = state
        let palette = model.roomArtworkPalette
        guard force || lastState != current || lastPalette != palette else { return }
        lastState = current
        lastPalette = palette
        for (control, item) in items {
            guard let button = item.button else { continue }
            button.image = ALOMenuBarControlImage.make(symbol: current.symbol(control), palette: palette,
                appearance: button.effectiveAppearance, unread: control == .chat && current.unread > 0)
            button.isEnabled = current.enabled(control)
            button.toolTip = current.help(control)
            button.setAccessibilityLabel(current.help(control))
        }
    }

    private func perform(_ control: ALOMenuBarControl) {
        guard state.enabled(control) else { return }
        switch control {
        case .record: break // The main status item always remains the ALO launcher.
        case .playback: model.toggleRoomPlayback()
        case .next: model.playNextRoomTrack()
        case .chat: navigate(.chat)
        case .people: navigate(.people)
        case .screen:
            if model.roomHasVideo && !model.mediaSwitchBusy { navigate(.video) }
            else { model.toggleVideoFromFloatingBar(presentation: .menuBar) }
        case .sync: model.syncAllDevices()
        case .mute: model.toggleIncomingMediaMute()
        }
        refresh()
    }
}

@MainActor
private final class MenuBarActionTarget: NSObject {
    let action: () -> Void
    var appearanceObserver: AnyCancellable?
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
