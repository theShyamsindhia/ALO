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
    private var settingsWindow: NSWindow?

    func configure(model: ALOViewModel) {
        guard self.model !== model else { return }
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
        updateRoomPlayback()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled && runtime == nil {
            let runtime = EmbeddedNotchRuntime()
            runtime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
            self.runtime = runtime
        }
        guard runtime?.isEnabled != enabled else { return }
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

    func openActivities() {
        guard ALONotchPreferences.shared.enabled else { return }
        setEnabled(true)
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

struct ALONotchFeatureSettings: View {
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
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { features.setEnabled(preferences.enabled) }
            .onChange(of: preferences.enabled) { _, enabled in features.setEnabled(enabled) }
    }
}
