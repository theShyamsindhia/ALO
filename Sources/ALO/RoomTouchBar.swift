import AppKit
import Combine

/// Native room controls for Macs with a Touch Bar. Retain alongside the window
/// controller and attach to its NSWindow or NSHostingController responder.
@MainActor
final class RoomTouchBarController: NSObject, NSTouchBarDelegate {
    enum Action: Int, CaseIterable { case playback, mute, syncThisMac, chat, people, games }
    struct Availability: Equatable {
        var live: Bool
        var playback: Bool
        var broadcaster: Bool
        var localIdentity: Bool
        var busy: Bool
        var games: Bool
        func enabled(_ action: Action) -> Bool {
            guard live else { return false }
            switch action {
            case .playback: return playback && !busy
            case .syncThisMac: return broadcaster && localIdentity && !busy
            case .games: return games
            case .mute, .chat, .people: return true
            }
        }
    }
    private struct Snapshot: Equatable {
        let availability: Availability
        let playing: Bool
        let muted: Bool
    }
    private let model: ALOViewModel
    private let presentation: RoomControlsPresentation
    private let onGames: (() -> Void)?
    private var observer: AnyCancellable?
    private var previous: Snapshot?
    private var buttons: [Action: NSButton] = [:]
    private var moreItem: NSPopoverTouchBarItem?
    private(set) var touchBar: NSTouchBar!
    private static let moreID = NSTouchBarItem.Identifier("app.alo.room.more")
    private static func identifier(_ action: Action) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("app.alo.room.action.\(action.rawValue)")
    }

    init(model: ALOViewModel, presentation: RoomControlsPresentation = .floating, onGames: (() -> Void)? = nil) {
        self.model = model; self.onGames = onGames
        self.presentation = presentation
        super.init()
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.identifier(.playback), Self.identifier(.mute), Self.identifier(.syncThisMac), .flexibleSpace, Self.moreID]
        touchBar = bar
        observer = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func attach(to responder: NSResponder) { responder.touchBar = touchBar }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier == Self.moreID {
            let item = NSPopoverTouchBarItem(identifier: identifier)
            item.collapsedRepresentationLabel = "More"
            item.collapsedRepresentationImage = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More room controls")
            item.customizationLabel = "More room controls"
            let navigation = NSTouchBar()
            navigation.delegate = self
            navigation.defaultItemIdentifiers = [Action.chat, .people, .games].map(Self.identifier)
            item.popoverTouchBar = navigation
            moreItem = item
            return item
        }
        guard let action = Action.allCases.first(where: { Self.identifier($0) == identifier }) else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = NSButton(title: "", target: self, action: #selector(pressed(_:)))
        button.tag = action.rawValue
        button.imagePosition = .imageLeading
        buttons[action] = button
        configure(button, action: action, snapshot: snapshot)
        item.view = button
        item.customizationLabel = label(for: action, snapshot: snapshot)
        return item
    }

    private var snapshot: Snapshot {
        Snapshot(availability: Availability(live: model.phase == .live,
            playback: model.canControlRoomPlayback, broadcaster: model.hasBroadcaster,
            localIdentity: model.currentParticipantID?.isEmpty == false,
            busy: model.mediaSwitchBusy, games: onGames != nil), playing: model.roomIsPlaying,
            muted: model.incomingMediaMuted && model.incomingCallsMuted)
    }
    private func refresh() {
        let current = snapshot
        guard previous != current else { return }
        previous = current
        for (action, button) in buttons { configure(button, action: action, snapshot: current) }
    }
    private func label(for action: Action, snapshot: Snapshot) -> String {
        switch action {
        case .playback: return snapshot.playing ? "Pause" : "Play"
        case .mute: return snapshot.muted ? "Unmute room" : "Mute room"
        case .syncThisMac: return "Sync this Mac"
        case .chat: return "Chat"
        case .people: return "People"
        case .games: return "Games"
        }
    }
    private func configure(_ button: NSButton, action: Action, snapshot: Snapshot) {
        let title = label(for: action, snapshot: snapshot)
        let icon: String
        let accessibility: String
        switch action {
        case .playback:
            icon = snapshot.playing ? "pause.fill" : "play.fill"
            accessibility = snapshot.playing ? "Pause room playback" : "Play room playback"
        case .mute:
            icon = snapshot.muted ? "speaker.wave.2.fill" : "speaker.slash.fill"
            accessibility = snapshot.muted ? "Unmute incoming room audio on this Mac" : "Mute incoming room audio on this Mac"
        case .syncThisMac:
            icon = "arrow.triangle.2.circlepath"; accessibility = "Sync this Mac only"
        case .chat: icon = "bubble.left"; accessibility = "Open room chat"
        case .people: icon = "person.2"; accessibility = "Open room people"
        case .games: icon = "gamecontroller"; accessibility = "Open games library"
        }
        button.title = title
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: accessibility)
        button.isEnabled = snapshot.availability.enabled(action)
        button.setAccessibilityLabel(accessibility)
        button.toolTip = accessibility
    }
    @objc private func pressed(_ sender: NSButton) {
        guard let action = Action(rawValue: sender.tag), snapshot.availability.enabled(action) else { return }
        switch action {
        case .playback: model.toggleRoomPlayback()
        case .mute: model.toggleAllIncomingAudio()
        case .syncThisMac: model.syncThisMac()
        case .chat: model.toggleSection(.chat, in: presentation); moreItem?.dismissPopover(nil)
        case .people: model.toggleSection(.people, in: presentation); moreItem?.dismissPopover(nil)
        case .games: onGames?(); moreItem?.dismissPopover(nil)
        }
        refresh()
    }
}
