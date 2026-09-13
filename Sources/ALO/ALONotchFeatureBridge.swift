import AppKit
import Combine
import SwiftUI
import ALOCore
import ALONotchRuntime

/// Supplies room metadata and commands to the original player, without
/// modifying its layout or waking global media monitors for room playback.
@MainActor
final class ALONotchFeatureBridge: ObservableObject {
    static let shared = ALONotchFeatureBridge()
    @Published private(set) var runtime: EmbeddedNotchRuntime?
    private weak var model: ALOViewModel?
    private var observations = Set<AnyCancellable>()
    private var roomObservations = Set<AnyCancellable>()
    private var transferObservation: AnyCancellable?
    private weak var observedSharing: DirectFileSharingController?
    private let roomNavigation = NotchRoomNavigation()

    func configure(model: ALOViewModel) {
        guard self.model !== model else { return }
        self.model?.lyrics.setExternalDemand(false)
        runtime?.dismissRoomInteraction()
        self.model?.roomFileSharing?.presentInNotch = nil
        roomNavigation.composer.reset()
        self.model = model
        roomObservations.removeAll()
        let changes: [AnyPublisher<Void, Never>] = [
            model.$nowPlaying.map { _ in () }.eraseToAnyPublisher(),
            model.$phase.map { _ in () }.eraseToAnyPublisher(),
            model.$audioIsRendering.map { _ in () }.eraseToAnyPublisher(),
            model.$statusText.map { _ in () }.eraseToAnyPublisher(),
            model.$roomName.map { _ in () }.eraseToAnyPublisher(),
            model.$participants.map { _ in () }.eraseToAnyPublisher(),
            model.$roomTrayItems.map { _ in () }.eraseToAnyPublisher(),
            model.roomTrayDownloads.$states.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateRoomPlayback() }
            .store(in: &roomObservations)
        model.lyrics.$state.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateRoomLyrics() }
            .store(in: &roomObservations)
        updateRoomPlayback()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled && runtime == nil {
            let runtime = EmbeddedNotchRuntime()
            runtime.onRoomLyricsDemandChanged = { [weak self] demand in
                self?.model?.lyrics.setExternalDemand(demand)
            }
            runtime.onSettingsRequested = { [weak self] in self?.showSettings() }
            runtime.onRoomInteractionRequested = { [weak self] in self?.openRoomInteraction(page: .home) }
            runtime.onRoomFilesDragEntered = { [weak self] in
                self?.roomNavigation.choosingRecipient = true
                self?.openRoomInteraction(page: .files)
            }
            runtime.onRoomFilesStaged = { [weak self] urls in
                self?.roomNavigation.stage(urls)
                self?.openRoomInteraction(page: .files)
            }
            runtime.onRoomTrayAddRequested = { [weak self] urls in self?.model?.addRoomTrayFiles(urls) }
            runtime.onRoomTrayRemoveRequested = { [weak self] ids in self?.model?.removeRoomTrayItems(ids) }
            runtime.onRoomTrayDownloadRequested = { [weak self] id in self?.model?.requestRoomTrayItem(id) }
            runtime.onRoomTrayExportRequested = { [weak self] id, url in self?.model?.exportRoomTrayItem(id, to: url) }
            runtime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
            self.runtime = runtime
        }
        guard runtime?.isEnabled != enabled else { return }
        if !enabled {
            model?.lyrics.setExternalDemand(false)
            model?.roomFileSharing?.presentInNotch = nil
            model?.notchChatIsPresented = false
        }
        runtime?.setEnabled(enabled)
        updateRoomPlayback()
    }

    private func updateRoomPlayback() {
        guard let runtime else { return }
        // Leaving must release owned screenshot copies even with the notch
        // disabled, but never while the session is still stopping transfers.
        if model?.phase != .live, model?.roomFileSharing == nil {
            runtime.clearRoomToolCopies()
            roomNavigation.pendingFiles = []
            roomNavigation.composer.reset()
        }
        guard runtime.isEnabled else { return }
        let snapshot = model.flatMap { model in
            Self.roomSnapshot(media: model.nowPlaying, isLive: model.phase == .live,
                audioIsRendering: model.audioIsRendering, roomName: model.roomName,
                isPlaying: model.roomIsPlaying, position: model.roomPlaybackPosition(at: Date()),
                canControl: model.canControlRoomPlayback)
        }
        runtime.updateRoomPlayback(snapshot) { [weak self] command in
            guard let model = self?.model else { return }
            switch command {
            case .togglePlayback: model.toggleRoomPlayback()
            case .next: model.playNextRoomTrack()
            case .previous: model.sendRoomMediaCommand(.previousTrack)
            case .seek: break // Room transport does not advertise seek support.
            }
        }
        updateRoomLyrics()
        updateRoomTray()
        runtime.updateRoomPresence(title: model?.phase == .live ? model?.roomTitle : nil,
                                   people: model?.participants.count ?? 0)
        if let model, model.phase == .live {
            if observedSharing !== model.roomFileSharing {
                observedSharing?.presentInNotch = nil
                observedSharing = model.roomFileSharing
                transferObservation = model.roomFileSharing?.$progress
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.refreshFilePreview() }
            }
            model.roomFileSharing?.presentInNotch = { [weak self] in
                guard let self, self.runtime?.canPresentRoomInteraction == true else { return false }
                // Do not replace a conversation while the recipient is typing.
                if self.runtime?.isRoomInteractionExpanded == true { return true }
                self.roomNavigation.fileSection = 0
                self.roomNavigation.choosingRecipient = false
                return self.openRoomInteraction(page: .files, expanded: false)
            }
        } else {
            observedSharing?.presentInNotch = nil
            observedSharing = nil
            transferObservation = nil
            roomNavigation.pendingFiles = []
            roomNavigation.composer.reset()
            runtime.dismissRoomInteraction()
        }
    }

    private func refreshFilePreview() {
        guard roomNavigation.page == .files, let model else { return }
        let transfer = model.roomFileSharing?.progress.last
        runtime?.updateRoomInteractionPreview(title: "Files · \(model.roomTitle)",
            subtitle: transfer.map { "\($0.fileName) · \($0.status)" } ?? "Share with people in this room")
    }

    private func updateRoomTray() {
        guard let runtime, runtime.isEnabled else { return }
        guard let model, model.phase == .live else {
            runtime.updateRoomTray(nil)
            return
        }
        let downloading = model.roomTrayDownloadingIDs
        runtime.updateRoomTray(RoomTraySnapshot(items: model.roomTrayItems.map { item in
            let localURL = model.roomTrayFileURL(itemID: item.id)
            let state: RoomTraySnapshot.Item.TransferState = localURL != nil
                ? .available : (downloading.contains(item.id) ? .downloading : .unavailable)
            return RoomTraySnapshot.Item(
                id: item.id,
                fileName: item.attachment.fileName,
                byteCount: item.attachment.byteCount,
                localFileURL: localURL,
                transferState: state
            )
        }))
    }

    private func updateRoomLyrics() {
        guard let model, let runtime, runtime.isEnabled else { return }
        runtime.updateRoomLyrics(Self.roomLyricsPayload(controller: model.lyrics,
            hasPlaybackClock: model.roomPlaybackPosition(at: Date()) != nil))
    }

    static func roomLyricsPayload(controller: LyricsController, hasPlaybackClock: Bool) -> RoomLyricsPayload {
        let state: RoomLyricsPayload.State
        var lines: [RoomLyricsPayload.Line] = []
        switch controller.state {
        case .disabled, .missingTrack: state = .idle
        case .loading: state = .loading
        case .unavailable: state = .unavailable
        case .failed: state = .failed
        case .ready(let result):
            state = result.instrumental ? .unavailable : .ready
            lines = result.lines.isEmpty
                ? result.plain.split(separator: "\n").map { .init(seconds: nil, text: String($0)) }
                : result.lines.map { .init(seconds: $0.seconds, text: $0.text) }
        }
        return RoomLyricsPayload(title: controller.track?.title ?? "", artist: controller.track?.artist ?? "",
            state: state, lines: lines, hasPlaybackClock: hasPlaybackClock)
    }

    static func roomSnapshot(media: NowPlayingMedia, isLive: Bool, audioIsRendering: Bool,
                             roomName: String, isPlaying: Bool, position: TimeInterval?,
                             canControl: Bool) -> RoomPlaybackSnapshot? {
        guard isLive, !media.isEmpty || audioIsRendering else { return nil }
        let duration = position != nil && media.duration?.isFinite == true ? max(0, media.duration ?? 0) : 0
        return RoomPlaybackSnapshot(title: media.title ?? "Live channel audio",
            artist: media.artist ?? roomName, album: media.album ?? "", artworkData: media.artworkData,
            isPlaying: isPlaying, elapsed: position ?? 0, duration: duration,
            canTogglePlayback: canControl, canSkipNext: canControl, canSkipPrevious: canControl,
            canSeek: false)
    }

    func openNotch() {
        guard ALONotchPreferences.shared.enabled else { return }
        setEnabled(true)
        runtime?.openActivity()
    }

    func showSettings() {
        if let delegate = NSApp.delegate as? ALOAppDelegate {
            delegate.presentNotchSettings()
        } else {
            model?.prepareNotchSettingsForMenuBar()
        }
    }

    func dismissSettings() {
        model?.notchSettingsVisible = false
        runtime?.resetEmbeddedSettingsNavigation()
    }

    func showRoomMention(sender: String, message: String, roomTitle: String) {
        guard let runtime, model != nil else { return }
        runtime.showRoomMention(
            RoomMentionSnapshot(sender: sender, message: message, roomTitle: roomTitle)
        ) { [weak self] in
            self?.openRoomInteraction(page: .conversation)
        }
    }

    @discardableResult
    func openRoomInteraction(page: NotchRoomNavigation.Page, expanded: Bool = true) -> Bool {
        guard let model, model.phase == .live, let runtime else { return false }
        roomNavigation.page = page
        let transfer = model.roomFileSharing?.progress.last
        return runtime.presentRoomInteraction(title: page == .files ? "Files · \(model.roomTitle)" : model.roomTitle,
            subtitle: page == .files ? (transfer.map { "\($0.fileName) · \($0.status)" } ?? "Share with people in this room") : page.rawValue,
            content: AnyView(ALONotchRoomWorkspace(model: model, navigation: roomNavigation, runtime: runtime,
                close: { [weak runtime] in runtime?.dismissRoomInteraction() })), expanded: expanded,
            layout: roomNavigation.layout)
    }
}

struct ALONotchFeatureSettings: View {
    @ObservedObject var features: ALONotchFeatureBridge
    @ObservedObject private var preferences = ALONotchPreferences.shared
    var body: some View {
        VStack(spacing: 0) {
            if preferences.enabled, let runtime = features.runtime {
                runtime.compactSettingsView
            } else {
                ContentUnavailableView("Your controls, a glance away", systemImage: "rectangle.topthird.inset.filled",
                    description: Text("Turn on Notch to choose playback, lock screen, and system activities."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { features.setEnabled(preferences.enabled) }
            .onChange(of: preferences.enabled) { _, enabled in features.setEnabled(enabled) }
    }
}

struct NotchSettingsBelowPlayer: View {
    @ObservedObject var model: ALOViewModel
    @ObservedObject private var preferences = ALONotchPreferences.shared
    @ObservedObject private var features = ALONotchFeatureBridge.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Label("Notch", systemImage: "rectangle.topthird.inset.filled")
                    .font(.headline)
                Toggle("Enable Notch", isOn: $preferences.enabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Enable Notch")
                Spacer()
                if preferences.enabled, let runtime = features.runtime {
                    Button { features.openNotch() } label: {
                        Label("Open Notch", systemImage: "rectangle.topthird.inset.filled")
                    }
                    .controlSize(.small)
                    .disabled(!runtime.canOpenActivity)
                    .help(runtime.canOpenActivity
                          ? "Open the current Notch activity."
                          : "Turn on a Home Page item or start an activity first.")
                }
                Button { features.dismissSettings() } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.plain).accessibilityLabel("Close notch settings")
            }.padding(12)
            ALONotchFeatureSettings(features: .shared)
                .transition(.opacity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("ALO.Notch.SettingsBelowPlayer")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: preferences.enabled)
    }
}
