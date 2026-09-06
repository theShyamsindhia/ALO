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

    func configure(model: ALOViewModel) {
        guard self.model !== model else { return }
        self.model?.lyrics.setExternalDemand(false)
        self.model = model
        roomObservations.removeAll()
        let changes: [AnyPublisher<Void, Never>] = [
            model.$nowPlaying.map { _ in () }.eraseToAnyPublisher(),
            model.$phase.map { _ in () }.eraseToAnyPublisher(),
            model.$audioIsRendering.map { _ in () }.eraseToAnyPublisher(),
            model.$statusText.map { _ in () }.eraseToAnyPublisher(),
            model.$roomName.map { _ in () }.eraseToAnyPublisher()
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
            runtime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
            self.runtime = runtime
        }
        guard runtime?.isEnabled != enabled else { return }
        if !enabled { model?.lyrics.setExternalDemand(false) }
        runtime?.setEnabled(enabled)
        updateRoomPlayback()
    }

    private func updateRoomPlayback() {
        guard let runtime, runtime.isEnabled else { return }
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
            case .openSource: model.showFloatingBar()
            case .seek: break // Room transport does not advertise seek support.
            }
        }
        updateRoomLyrics()
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
        return RoomPlaybackSnapshot(title: media.title ?? "Room audio",
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
        model?.showNotchSettingsBelowPlayer()
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
                    Toggle("Room media", isOn: Binding(get: { runtime.roomMediaEnabled }, set: { runtime.roomMediaEnabled = $0 }))
                        .toggleStyle(.switch).controlSize(.mini).font(.caption)
                        .help("Show this room's artwork and playback in Notch and on the lock screen.")
                    Button { features.openNotch() } label: {
                        Label("Open Notch", systemImage: "rectangle.topthird.inset.filled")
                    }
                    .controlSize(.small)
                    .disabled(!runtime.canOpenActivity)
                    .help(runtime.canOpenActivity
                          ? "Open the current Notch activity."
                          : "Turn on a Home Page item or start an activity first.")
                }
                Button { model.notchSettingsVisible = false } label: {
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
