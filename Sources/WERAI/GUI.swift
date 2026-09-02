import AppKit
import Combine
import CoreGraphics
import SwiftUI
import WERAICore

@MainActor
enum GUIApplication {
    private static var appDelegate: WERAIAppDelegate?

    static func run() {
        _ = BroadcastAudioRouter().recoverStaleRoute()
        let application = NSApplication.shared
        let delegate = WERAIAppDelegate()
        appDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
private final class WERAIAppDelegate: NSObject, NSApplicationDelegate {
    private let model = WERAIViewModel()
    private let updater = AppUpdater()
    private var window: NSWindow?
    private var roomBarController: FloatingRoomWindowController?
    private var fullScreenVideoController: FullScreenVideoWindowController?
    private var statusMenuController: WERAIStatusMenuController?
    private var phaseObserver: AnyCancellable?
    private var fullScreenObserver: AnyCancellable?
    private var videoPinnedObserver: AnyCancellable?
    private var videoFullScreenToggleObserver: AnyCancellable?
    private var floatingBarObserver: AnyCancellable?
    private var terminationSignalSources = [DispatchSourceSignal]()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignalHandlers()
        installMainMenu()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ALO"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 860, height: 600)
        window.contentView = NSHostingView(rootView: WERAIView(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        statusMenuController = WERAIStatusMenuController(model: model) { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        updater.updateAvailableHandler = { [weak self] version in self?.presentUpdate(version: version) }
        updater.messageHandler = { [weak self] message in self?.presentUpdateMessage(message) }
        model.peerVersionHandler = { [weak updater] version in updater?.observePeerVersion(version) }
        updater.start()

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

    private func updateWindows(for phase: WERAIViewModel.Phase) {
        if phase == .live {
            window?.orderOut(nil)
            updateFloatingBar(hidden: model.floatingBarHidden)
        } else {
            statusMenuController?.closePopover()
            fullScreenVideoController?.close()
            fullScreenVideoController = nil
            roomBarController?.close()
            roomBarController = nil
            window?.makeKeyAndOrderFront(nil)
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
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit ALO",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates(userInitiated: true)
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
private final class WERAIStatusMenuController: NSObject, NSPopoverDelegate {
    private let model: WERAIViewModel
    private let openMainWindow: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let badgeView = StatusUnreadBadgeView()
    private var observers = Set<AnyCancellable>()

    init(model: WERAIViewModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "cat.fill",
            accessibilityDescription: "ALO"
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "ALO"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            badgeView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(badgeView)
            NSLayoutConstraint.activate([
                badgeView.widthAnchor.constraint(equalToConstant: 8),
                badgeView.heightAnchor.constraint(equalToConstant: 8),
                badgeView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                badgeView.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
            ])
        }

        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentSize = panelSize
        popover.contentViewController = NSHostingController(
            rootView: FloatingRoomView(model: model, presentation: .menuBar)
        )

        model.$unreadMessageCount
            .removeDuplicates()
            .sink { [weak self] count in self?.updateBadge(count: count) }
            .store(in: &observers)
        model.$phase
            .removeDuplicates()
            .sink { [weak self] phase in self?.updatePhase(phase) }
            .store(in: &observers)
        model.$floatingBarHidden
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
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

    func popoverDidClose(_ notification: Notification) {
        model.setMenuBarPopoverVisible(false)
    }

    @objc private func togglePopover() {
        guard model.phase == .live else {
            openMainWindow()
            return
        }
        popover.isShown ? closePopover() : showPopover()
    }

    private var panelSize: NSSize {
        NSSize(width: FloatingMetrics.width, height: model.floatingPanelHeight)
    }

    private func resizePopover() {
        guard popover.contentSize != panelSize else { return }
        popover.contentSize = panelSize
    }

    private func syncMotionPreference() {
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updateBadge(count: Int) {
        badgeView.isHidden = count == 0
        let detail = count == 0 ? "ALO" : "ALO · \(count) unread message\(count == 1 ? "" : "s")"
        statusItem.button?.toolTip = detail
        statusItem.button?.setAccessibilityLabel(detail)
    }

    private func updatePhase(_ phase: WERAIViewModel.Phase) {
        if phase != .live { closePopover() }
        statusItem.button?.image = NSImage(
            systemSymbolName: phase == .live ? "cat.fill" : "cat",
            accessibilityDescription: "ALO"
        )
        statusItem.button?.image?.isTemplate = true
    }
}

private final class StatusUnreadBadgeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.cgColor
        layer?.cornerRadius = 4
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct RoomMessage: Identifiable, Equatable {
    let id = UUID()
    let sender: String
    let text: String
    let sentNanos: UInt64
}

private enum FloatingMetrics {
    static let width: CGFloat = 520
    static let barHeight: CGFloat = 58
    static let cornerRadius: CGFloat = 22
    static let separatorHeight: CGFloat = 1
    static let expansionDuration: TimeInterval = 0.24
    static let messagePreviewHeight: CGFloat = 116
    static let chatHeight: CGFloat = 380
    static let queueHeight: CGFloat = 392
    static let videoHeight: CGFloat = 476
    static let permissionHeight: CGFloat = 244

    static func peopleHeight(count: Int) -> CGFloat {
        min(420, max(268, CGFloat(count * 64 + 148)))
    }
}

@MainActor
final class WERAIViewModel: ObservableObject {
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
    @Published var createPrivateRoom = false
    @Published var privateRoomKey = ""
    @Published var statusText = "Ready"
    @Published var errorMessage: String?
    @Published var errorIsPermissionRelated = false
    @Published var participants = [RoomParticipant]()
    @Published var messages = [RoomMessage]()
    @Published var draftMessage = ""
    @Published var unreadMessageCount = 0
    @Published private(set) var incomingMessagePreview: RoomMessage?
    @Published var mediaQueue = [RoomQueueItem]()
    @Published var queueURL = ""
    @Published var queueNotice: String?
    @Published var videoFrame: CGImage?
    @Published var videoFullscreen = false
    @Published var videoViewerPinned = false
    @Published var videoFullScreenToggle = 0
    @Published var currentUserName = "This Mac"
    @Published var currentParticipantID: String?
    @Published var roomHasVideo = false
    @Published var nowPlaying = NowPlayingMedia()
    @Published var localNowPlaying = NowPlayingMedia()
    @Published private(set) var audioIsRendering = false
    @Published var experience: Experience = .audio
    @Published var mediaSwitchBusy = false
    @Published var permissionNotice = false
    @Published var floatingSection: FloatingSection = .collapsed
    @Published var floatingBarHidden: Bool
    @Published private(set) var menuBarPopoverVisible = false

    private var roomBrowser: MeshRoomBrowser!
    private var meshSession: MeshSession?
    private var requestedVideoBroadcast = false
    private var videoBroadcastTimeoutTask: Task<Void, Never>?
    private let roomStore = RoomStore()
    private let nodeID: String
    private var localNowPlayingMonitor: NowPlayingMonitor?
    private var incomingMessagePreviewTask: Task<Void, Never>?
    private var activeRoom: String?
    private var activeRoomConfiguration: RoomConfiguration?
    private var isLeavingRoom = false
    private static let floatingBarPreferenceKey = "floatingBarHidden"

    init() {
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
        savedRooms = roomStore.load()
        floatingBarHidden = defaults.object(forKey: Self.floatingBarPreferenceKey) == nil
            ? true
            : defaults.bool(forKey: Self.floatingBarPreferenceKey)
        selectedRoomID = savedRooms.first?.id
        roomBrowser = MeshRoomBrowser(
            updateHandler: { [weak self] rooms in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.nearbyRooms = rooms
                    if self.selectedRoomID == nil || !self.roomChoices.contains(where: { $0.id == self.selectedRoomID }) {
                        self.selectedRoomID = rooms.first?.id ?? self.savedRooms.first?.id
                    }
                }
            },
            errorHandler: { [weak self] message in
                DispatchQueue.main.async { self?.statusText = "Local network unavailable: \(message)" }
            }
        )
        roomBrowser.start()
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
            hasMedia: !nowPlaying.isEmpty
        )
    }
    var roomSyncLabel: String {
        if !hasBroadcaster { return "No broadcaster" }
        if nowPlaying.isPlaying == false { return "Paused" }
        if audioIsRendering { return "Synced" }
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
                accessKey: key
            )
            try? roomStore.save(unlocked)
            savedRooms = roomStore.load()
            open(unlocked, broadcastInitially: false)
        } else { open(room, broadcastInitially: false) }
    }

    func forgetRoom(roomID: String) {
        do {
            try roomStore.forget(roomID: roomID)
            savedRooms = roomStore.load()
            if selectedRoomID == roomID {
                selectedRoomID = nearbyRooms.first?.id ?? savedRooms.first?.id
            }
        } catch {
            errorMessage = "Could not forget the room: \(error.localizedDescription)"
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
        activeRoom = room.name
        activeRoomConfiguration = room
        phase = .starting
        statusText = "Opening \(room.name)"
        roomBrowser.stop()
        let session = MeshSession(
            room: room,
            nodeID: nodeID,
            displayName: currentUserName,
            initialEvents: roomStore.loadEvents(roomID: room.id),
            statusHandler: { [weak self] status in
                guard let self else { return }
                self.statusText = status
                if let rendering = Self.renderingState(for: status) {
                    self.audioIsRendering = rendering
                }
                if self.phase == .starting, !self.isLeavingRoom { self.phase = .live }
                self.updateLocalNowPlayingMonitor()
            },
            identityHandler: identityCallback,
            participantsHandler: participantCallback,
            mediaStateHandler: mediaStateCallback,
            nowPlayingHandler: nowPlayingCallback,
            chatHandler: chatCallback,
            queueHandler: queueCallback,
            videoHandler: videoCallback,
            peerVersionHandler: { [weak self] version in self?.peerVersionHandler(version) },
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
            replicaPersistenceHandler: { [weak self] replica in
                self?.roomStore.saveEvents(replica.events, roomID: room.id)
            }
        )
        meshSession = session
        do {
            try session.start(broadcastInitially: broadcastInitially)
            try? roomStore.save(room)
            savedRooms = roomStore.load()
            phase = .live
            statusText = broadcastInitially ? "Starting this Mac's broadcast" : "Room open"
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
        if selection == .video { statusText = "Preparing ALO Display and video capture" }
        Task {
            do {
                try await meshSession?.setVideoEnabled(selection == .video)
                experience = selection
                floatingSection = selection == .video ? .video : .collapsed
                statusText = selection == .video
                    ? "ALO Display is live · use Displays Settings to arrange it"
                    : "Audio room active"
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
            ? "Taking over room audio and preparing ALO Display"
            : "Starting audio and video broadcast"
        meshSession.beginBroadcasting(videoEnabled: true)
        videoBroadcastTimeoutTask?.cancel()
        videoBroadcastTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.requestedVideoBroadcast else { return }
            self.requestedVideoBroadcast = false
            self.mediaSwitchBusy = false
            self.statusText = "Video broadcast did not start · try again"
            self.errorMessage = "ALO could not finish taking over audio and starting ALO Display."
            self.videoBroadcastTimeoutTask = nil
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
        if meshSession?.sendMediaCommand(.togglePlayPause) != true {
            statusText = "Wait for the broadcaster connection, then try again"
        }
    }

    func toggleBroadcasting() {
        guard !mediaSwitchBusy else { return }
        if isHost { meshSession?.stopBroadcasting() }
        else {
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

    func syncAllDevices() {
        if meshSession?.requestResync() == true {
            statusText = "Syncing listeners to the broadcaster"
        } else {
            statusText = "Wait for the audio connection, then try syncing again"
        }
    }

    func hideFloatingBar() {
        floatingSection = .collapsed
        floatingBarHidden = true
        UserDefaults.standard.set(true, forKey: Self.floatingBarPreferenceKey)
    }

    func showFloatingBar() {
        videoFullscreen = false
        floatingBarHidden = false
        UserDefaults.standard.set(false, forKey: Self.floatingBarPreferenceKey)
    }

    func setMenuBarPopoverVisible(_ visible: Bool) {
        menuBarPopoverVisible = visible
        if visible, floatingSection == .chat {
            unreadMessageCount = 0
        } else if !visible, floatingBarHidden {
            floatingSection = .collapsed
        }
    }

    func canControl(_ participant: RoomParticipant) -> Bool {
        isHost || participant.id == currentParticipantID
    }

    func sendMessage() {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        meshSession?.sendChat(text)
        draftMessage = ""
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

    func canRemoveQueueItem(_ item: RoomQueueItem) -> Bool {
        isHost || item.addedByID == currentParticipantID
    }

    func playQueueItem(_ item: RoomQueueItem) {
        guard let url = validMediaURL(item.url) else { return }
        if !isHost {
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
            unreadMessageCount = 0
        }
    }

    func toggleFloatingVideo() {
        guard roomHasVideo else { return }
        dismissIncomingMessagePreview()
        floatingSection = floatingSection == .video ? .collapsed : .video
    }

    func toggleVideoFromFloatingBar() {
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
        isLeavingRoom = true
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
        statusText = "Looking for rooms"
        roomBrowser.restart()
    }

    func dismissPermissionNotice() {
        permissionNotice = false
    }

    func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openDisplaysSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        ) else { return }
        if NSWorkspace.shared.open(url) {
            statusText = "Arrange ALO Display beside your physical screens"
        }
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
        isLeavingRoom = true
        stopLocalNowPlayingMonitor()
        meshSession?.stopImmediately()
    }

    private func ensureScreenRecordingPermission() -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            permissionNotice = true
            let granted = CGRequestScreenCaptureAccess()
            statusText = granted
                ? "Recording access granted · restart ALO to begin broadcasting"
                : "ALO needs Screen & System Audio Recording to broadcast"
            return false
        }
        permissionNotice = false
        return true
    }

    private var identityCallback: (String, String) -> Void {
        { [weak self] id, name in
            DispatchQueue.main.async {
                self?.currentParticipantID = id
                self?.currentUserName = name
            }
        }
    }

    private var participantCallback: ([RoomParticipant]) -> Void {
        { [weak self] participants in
            DispatchQueue.main.async { self?.participants = participants }
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
                    self.statusText = "Audio and ALO Display are live"
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

    private var chatCallback: (String, String, UInt64) -> Void {
        { [weak self] sender, text, sentNanos in
            DispatchQueue.main.async {
                guard let self else { return }
                self.messages.append(RoomMessage(sender: sender, text: text, sentNanos: sentNanos))
                let chatIsVisible = self.floatingSection == .chat
                    && (!self.floatingBarHidden || self.menuBarPopoverVisible)
                if sender != self.currentUserName, !chatIsVisible {
                    self.unreadMessageCount += 1
                    if self.floatingSection == .collapsed {
                        self.presentIncomingMessagePreview(self.messages[self.messages.count - 1])
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

    private var nowPlayingCallback: (NowPlayingMedia) -> Void {
        { [weak self] media in
            DispatchQueue.main.async { self?.nowPlaying = media }
        }
    }

    private var videoCallback: (CGImage) -> Void {
        { [weak self] image in
            DispatchQueue.main.async { self?.videoFrame = image }
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
            isMuted: muted
        )
    }

    private func resetRoomState() {
        stopLocalNowPlayingMonitor()
        isLeavingRoom = false
        errorMessage = nil
        errorIsPermissionRelated = false
        permissionNotice = false
        participants = []
        messages = []
        unreadMessageCount = 0
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

    private func dismissIncomingMessagePreview() {
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
}

private struct WERAIView: View {
    @ObservedObject var model: WERAIViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var roomNameFocused: Bool

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "ALO / V\(version ?? "DEV")"
    }

    var body: some View {
        ZStack {
            AmbientBackground(isLive: model.phase == .live)
            switch model.phase {
            case .idle: idleView
            case .starting: progressView
            case .live: EmptyView()
            case .failed: errorView
            }
            if model.permissionNotice { permissionOverlay }
        }
        .frame(minWidth: 860, minHeight: 600)
        .tint(Palette.controlAccent)
        .ignoresSafeArea()
    }

    private var idleView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Rectangle()
                    .fill(Palette.controlAccent)
                    .frame(width: 46, height: 4)
                Text("LISTEN\nTOGETHER.")
                    .font(.system(size: 44, weight: .black, design: .default))
                    .tracking(-1.8)
                    .lineSpacing(-5)
                    .foregroundStyle(Palette.ink)
                Text("One room for synchronized sound, conversation, and an optional shared screen.")
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: 330, alignment: .leading)
                Text("\(versionLabel)  /  LOCAL  /  P2P  /  FREE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(Palette.accentText)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            setupConsole
                .frame(width: 510)
        }
        .padding(.horizontal, 72)
        .padding(.top, 34)
    }

    private var setupConsole: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.mode == .share ? "Create a room" : "Your rooms")
                        .font(.system(size: 17, weight: .bold, design: .default))
                        .foregroundStyle(Palette.ink)
                    Text(model.mode == .share ? "Create the group first. Anyone can broadcast afterward." : "Nearby and previously joined rooms")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button(model.mode == .share ? "Back to rooms" : "Create room") {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86)) {
                        model.mode = model.mode == .share ? .listen : .share
                    }
                }
                .buttonStyle(LandingButtonStyle(filled: model.mode == .listen))
            }
            .padding(16)

            Rectangle()
                .fill(Palette.strokeStrong)
                .frame(height: 1)

            Group {
                if model.mode == .share {
                    VStack(spacing: 12) {
                        TextField("Room name", text: $model.roomName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .medium, design: .default))
                            .foregroundStyle(Palette.ink)
                            .focused($roomNameFocused)
                            .onSubmit(model.startSharing)
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(Palette.composer)
                            .overlay(Rectangle().stroke(roomNameFocused ? Palette.controlAccent : Palette.strokeStrong, lineWidth: roomNameFocused ? 2 : 1))

                        HStack(spacing: 8) {
                            Button {
                                model.createPrivateRoom.toggle()
                            } label: {
                                Label(
                                    model.createPrivateRoom ? "Private" : "Public",
                                    systemImage: model.createPrivateRoom ? "lock.fill" : "person.3.fill"
                                )
                            }
                            .buttonStyle(LandingButtonStyle(filled: model.createPrivateRoom))
                            Spacer()
                            Button("Create room", action: model.startSharing)
                                .buttonStyle(LandingButtonStyle(filled: true))
                                .disabled(!model.canStartSharing)
                        }
                    }
                } else {
                    roomList
                }
            }
            .padding(16)
        }
        .background(Palette.opaqueSurface.opacity(0.9))
        .overlay(Rectangle().stroke(Palette.strokeStrong, lineWidth: 1.5))
    }

    private var roomList: some View {
        VStack(spacing: 10) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if model.roomChoices.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 22))
                                .foregroundStyle(Palette.accent)
                            Text("Looking for rooms on your network…")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Palette.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(model.roomChoices) { room in roomCard(room) }
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: 270)

            if model.selectedRoomConfiguration?.isPrivate == true,
               model.selectedRoomConfiguration?.accessKey == nil {
                TextField("Private room invite key", text: $model.privateRoomKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(Palette.composer)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack {
                Text("Rooms stay saved on this Mac")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button("Open room", action: model.joinSelectedRoom)
                    .buttonStyle(LandingButtonStyle(filled: true))
                    .disabled(!model.canJoin)
            }
        }
    }

    private func roomCard(_ room: RoomConfiguration) -> some View {
        let nearby = model.nearbyRooms.first(where: { $0.id == room.id })
        let saved = model.savedRooms.contains(where: { $0.id == room.id })
        let selected = model.selectedRoomID == room.id
        return HStack(spacing: 12) {
            Button {
                model.selectedRoomID = room.id
                model.privateRoomKey = ""
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: room.isPrivate ? "lock.fill" : "person.3.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Palette.selectedControlText : Palette.accent)
                        .frame(width: 34, height: 34)
                        .background(selected ? Palette.controlAccent : Palette.accentSoft)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.name)
                            .font(.system(size: 13, weight: .bold, design: .default))
                            .foregroundStyle(Palette.ink)
                        Text(nearby.map { "Nearby · \($0.peerCount) \($0.peerCount == 1 ? "person" : "people")" } ?? "Saved on this Mac")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(nearby == nil ? Palette.secondary : Palette.accentText)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Palette.controlAccent : Palette.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if saved {
                Button { model.forgetRoom(roomID: room.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
                .buttonStyle(FlatToolButtonStyle(active: false))
                .help("Forget this room on this Mac")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(selected ? Palette.accentSoft.opacity(0.7) : Palette.composer)
        .overlay(Rectangle().stroke(selected ? Palette.controlAccent : Palette.strokeStrong, lineWidth: selected ? 1.5 : 1))
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
                    Text("Allow broadcasting")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                    Text("For audio, turn ALO on under System Audio Recording Only (or Screen & System Audio Recording). Video sharing requires Screen & System Audio Recording. Then restart ALO once.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                        .lineSpacing(3)
                }
                HStack(spacing: 9) {
                    Button("Open Recording Settings", action: model.openPrivacySettings)
                        .buttonStyle(PillButtonStyle(filled: true))
                    Button("Restart ALO", action: model.restartApplication)
                        .buttonStyle(PillButtonStyle(filled: false))
                }
            }
            .padding(24)
            .frame(width: 420)
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
                    .frame(maxWidth: 410, alignment: .leading)
            }
            HStack(spacing: 9) {
                Button("Try again", action: model.tryAgain)
                    .buttonStyle(PillButtonStyle(filled: true))
                if model.errorIsPermissionRelated {
                    Button("Recording Settings", action: model.openPrivacySettings)
                        .buttonStyle(PillButtonStyle(filled: false))
                }
            }
        }
        .padding(28)
        .glass(cornerRadius: 26)
    }
}

private enum RoomControlsPresentation {
    case floating
    case menuBar
}

private struct FloatingRoomView: View {
    @ObservedObject var model: WERAIViewModel
    var presentation: RoomControlsPresentation = .floating
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool

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

    private var messageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .bottom)
                    .combined(with: .scale(scale: 0.96, anchor: .bottom))
                    .combined(with: .opacity),
                removal: .opacity
            )
    }

    private var hasExpandedContent: Bool {
        model.permissionNotice
            || model.floatingSection != .collapsed
            || model.incomingMessagePreview != nil
    }

    private var expandedContentHeight: CGFloat {
        max(0, model.floatingPanelHeight - FloatingMetrics.barHeight - FloatingMetrics.separatorHeight)
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
                peopleMixer
            case .video:
                videoPlayer
            }
        }
    }

    var body: some View {
        Group {
            if presentation == .floating {
                roomContent.floatingSurface(cornerRadius: FloatingMetrics.cornerRadius)
            } else {
                roomContent.background(Palette.opaqueSurface)
            }
        }
        .tint(Palette.controlAccent)
    }

    private var roomContent: some View {
        VStack(spacing: 0) {
            if hasExpandedContent {
                expandedContent
                    .frame(width: FloatingMetrics.width, height: expandedContentHeight)
                    .id(expansionIdentity)
                    .transition(panelTransition)

                Divider()
                    .overlay(Palette.strokeStrong)
                    .frame(height: FloatingMetrics.separatorHeight)
                    .transition(.opacity)
            }

            roomBar
        }
        .frame(width: FloatingMetrics.width, height: model.floatingPanelHeight, alignment: .bottom)
        .animation(panelAnimation, value: model.floatingSection)
        .animation(panelAnimation, value: model.permissionNotice)
        .animation(panelAnimation, value: model.participants.count)
        .animation(panelAnimation, value: model.incomingMessagePreview?.id)
    }

    private var roomBar: some View {
        HStack(spacing: 8) {
            roomIdentity

            roomBarButton(
                icon: model.isHost ? "dot.radiowaves.left.and.right" : "waveform.badge.mic",
                activeIcon: "dot.radiowaves.left.and.right",
                active: model.isHost,
                disabled: model.mediaSwitchBusy,
                help: model.isHost ? "Stop broadcasting this Mac" : (model.hasBroadcaster ? "Take over room audio" : "Broadcast this Mac")
            ) { model.toggleBroadcasting() }

            roomBarButton(
                icon: model.roomIsPlaying ? "pause.fill" : "play.fill",
                active: false,
                help: model.roomIsPlaying ? "Pause for everyone" : "Play for everyone"
            ) { model.toggleRoomPlayback() }

            roomBarButton(
                icon: "music.note.list",
                activeIcon: "music.note.list",
                active: model.floatingSection == .queue,
                help: "Room queue"
            ) { model.showQueue() }
            .keyboardShortcut("4", modifiers: .command)

            roomBarButton(
                icon: "bubble.left.and.text.bubble.right",
                activeIcon: "bubble.left.and.text.bubble.right.fill",
                active: model.floatingSection == .chat,
                badge: model.unreadMessageCount,
                help: "Conversation"
            ) { model.showChat() }
            .keyboardShortcut("1", modifiers: .command)

            roomBarButton(
                icon: "person.2",
                activeIcon: "person.2.fill",
                active: model.floatingSection == .people,
                help: "People and volume"
            ) { model.showPeople() }
            .keyboardShortcut("2", modifiers: .command)

            roomBarButton(
                icon: model.mediaSwitchBusy ? "hourglass" : "rectangle.on.rectangle",
                activeIcon: "rectangle.fill.on.rectangle.fill",
                active: model.floatingSection == .video || model.experience == .video,
                disabled: !model.canSelectVideo || model.mediaSwitchBusy,
                help: model.videoControlHelp
            ) { model.toggleVideoFromFloatingBar() }
            .keyboardShortcut("3", modifiers: .command)

            roomBarButton(
                icon: presentation == .menuBar && model.floatingBarHidden ? "macwindow" : "eye.slash",
                active: false,
                help: model.floatingBarHidden ? "Show floating controls" : "Hide floating controls"
            ) {
                model.floatingBarHidden ? model.showFloatingBar() : model.hideFloatingBar()
            }

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
        .padding(.horizontal, 8)
        .frame(width: FloatingMetrics.width, height: FloatingMetrics.barHeight)
        .onChange(of: model.floatingSection) { _, section in
            composerFocused = section == .chat
        }
    }

    @ViewBuilder
    private var roomIdentity: some View {
        let identity = HStack(spacing: 9) {
            artworkTile

            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlaying.title ?? model.roomTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(model.audioIsRendering ? Palette.syncText : Palette.secondary)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(model.nowPlaying.title == nil
                        ? "\(model.participants.count) listening · \(model.roomSyncLabel)"
                        : "\(model.roomTitle) · \(model.roomSyncLabel)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.detailText)
                    .lineLimit(1)
                }
            }
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

    private var artworkTile: some View {
        Group {
            if let data = model.nowPlaying.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Palette.artworkFallback
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.accentText)
                }
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
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
                .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Circle()
                        .fill(Palette.red)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Palette.opaqueSurface, lineWidth: 1))
                        .offset(x: -2, y: 3)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.35, anchor: .bottomLeading).combined(with: .opacity)
                        )
                }
            }
        }
        .buttonStyle(FlatToolButtonStyle(active: active))
        .disabled(disabled)
        .opacity(disabled ? 0.36 : 1)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(badge > 0 ? "\(badge) unread" : active ? "Selected" : "")
    }

    private func incomingMessagePreview(_ message: RoomMessage) -> some View {
        Button(action: model.showChat) {
            HStack(spacing: 10) {
                messageAvatar(message.sender, size: 30)

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
                    ? "Anyone can add media"
                    : "\(model.mediaQueue.count) queued · anyone can add"
            )
            Divider().opacity(0.42)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.mediaQueue) { item in
                        queueRow(item)
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if model.messages.isEmpty {
                            VStack(spacing: 7) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Palette.controlIcon)
                                Text("Start the conversation")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                Text("Everyone in the room will see it.")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Palette.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 170, alignment: .center)
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            let showsSender = index == 0
                                || model.messages[index - 1].sender != message.sender
                            floatingMessage(message, showsSender: showsSender)
                                .id(message.id)
                                .transition(messageTransition)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.messages.count) {
                    if let last = model.messages.last {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.04)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            Divider().opacity(0.42)
            messageComposer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.8),
            value: model.messages.count
        )
    }

    private var chatHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Room chat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("\(model.participants.count) here · live")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }

            Spacer()

            HStack(spacing: -5) {
                ForEach(Array(model.participants.prefix(3))) { participant in
                    messageAvatar(participant.name, size: 22)
                        .overlay(Circle().stroke(Palette.opaqueSurface, lineWidth: 1.5))
                }
            }
            .accessibilityHidden(true)

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
            messageAvatar(model.currentUserName, size: 26)

            TextField("Message \(model.roomTitle)", text: $model.draftMessage)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .focused($composerFocused)
                .onSubmit(model.sendMessage)

            Button(action: model.sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.selectedControlText)
                    .frame(width: 26, height: 26)
                    .background(Palette.controlAccent)
                    .clipShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(!hasDraft)
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
                    composerFocused ? Palette.controlAccent : Palette.strokeStrong,
                    lineWidth: 1
                )
        )
        .padding(10)
        .onTapGesture { composerFocused = true }
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72),
            value: hasDraft
        )
    }

    private func floatingMessage(_ message: RoomMessage, showsSender: Bool) -> some View {
        let own = message.sender == model.currentUserName
        return HStack(alignment: .bottom, spacing: 7) {
            if own {
                Spacer(minLength: 74)
            } else {
                messageAvatar(message.sender, size: 24)
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
                    .foregroundStyle(own ? Palette.selectedControlText : Palette.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(own ? Palette.controlAccent : Palette.messageSurface)
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

    private func messageAvatar(_ name: String, size: CGFloat) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(Palette.accentText)
            .frame(width: size, height: size)
            .background(Palette.accentSoft)
            .clipShape(Circle())
            .accessibilityLabel(name)
    }

    private var peopleMixer: some View {
        VStack(spacing: 0) {
            panelHeader(
                title: "People",
                detail: "Each Mac has its own level",
                syncAction: model.syncAllDevices
            )
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

    private func floatingParticipant(_ participant: RoomParticipant) -> some View {
        let controllable = model.canControl(participant)
        return HStack(spacing: 11) {
            ZStack {
                Palette.artworkFallback
                Text(String(participant.name.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.accentText)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.id == model.currentParticipantID ? "You" : participant.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(participant.isMuted ? "Muted" : "In sync")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(participant.isMuted ? Palette.red : Palette.accentText)
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
                Button(action: model.openDisplaysSettings) {
                    Image(systemName: "display.2")
                }
                .buttonStyle(VideoControlButtonStyle())
                .help("Arrange ALO Display")
                .accessibilityLabel("Open Displays Settings")
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
                Text("Broadcasting needs recording access")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Enable ALO under System Audio Recording Only (or Screen & System Audio Recording), restart once, then broadcast again.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            Button("Recording Settings", action: model.openPrivacySettings)
                .buttonStyle(PillButtonStyle(filled: true))
            Button("Restart", action: model.restartApplication)
                .buttonStyle(PillButtonStyle(filled: false))
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
                    Label("Sync all", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle(filled: false))
                .help("Re-align every Mac to the room clock")
                .accessibilityLabel("Sync all Macs now")
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

private struct FlatToolButtonStyle: ButtonStyle {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(active ? Palette.controlAccent : configuration.isPressed ? Palette.controlHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0.08), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0.04), value: active)
    }
}

private struct LandingButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(filled ? Palette.selectedControlText : Palette.ink)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(filled ? Palette.controlAccent : Palette.messageSurface)
            .overlay(Rectangle().stroke(Palette.strokeStrong, lineWidth: 1.5))
            .offset(y: !reduceMotion && configuration.isPressed ? 1 : 0)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct InlineActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.selectedControlText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Palette.controlAccent.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
    }
}

private struct VideoOverlayButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 30)
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

private final class FloatingRoomPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FloatingRoomWindowController {
    private let panel: FloatingRoomPanel
    private let model: WERAIViewModel
    private var modelObserver: AnyCancellable?
    private var pendingShrink: DispatchWorkItem?
    private var hasPosition = false

    init(model: WERAIViewModel) {
        self.model = model
        panel = FloatingRoomPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: FloatingMetrics.width,
                height: model.floatingPanelHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
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

        modelObserver = Publishers.CombineLatest4(
            model.$floatingSection.removeDuplicates(),
            model.$permissionNotice.removeDuplicates(),
            model.$participants.map(\.count).removeDuplicates(),
            model.$incomingMessagePreview.map { $0?.id }.removeDuplicates()
        )
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

        let height = model.floatingPanelHeight
        guard abs(panel.frame.height - height) > 0.5
                || abs(panel.frame.width - FloatingMetrics.width) > 0.5 else { return }
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
        frame.size = NSSize(width: FloatingMetrics.width, height: height)
        frame.origin.y = fixedBottomEdge
        if let screenFrame {
            frame.origin.x = min(max(frame.origin.x, screenFrame.minX), screenFrame.maxX - frame.width)
            frame.origin.y = max(frame.origin.y, screenFrame.minY)
            frame.size.height = min(frame.height, screenFrame.maxY - frame.origin.y)
        }
        panel.setFrame(frame, display: true)
    }
}

private final class FullScreenVideoWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct FullScreenVideoView: View {
    @ObservedObject var model: WERAIViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
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

            HStack(spacing: 10) {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
                Text(model.isHost ? "YOUR SCREEN" : "LIVE SCREEN")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                Text("·")
                Text(model.roomTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Button(model.isHost ? "Stop sharing" : "Audio only") {
                    model.selectExperience(.audio)
                }
                .buttonStyle(VideoOverlayButtonStyle())
                Button(action: model.toggleVideoViewerPinned) {
                    Image(systemName: model.videoViewerPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(VideoControlButtonStyle())
                .help(model.videoViewerPinned ? "Unpin from desktops" : "Keep on every desktop")
                .accessibilityLabel(model.videoViewerPinned ? "Unpin video window" : "Pin video window")
                Button(action: model.openDisplaysSettings) {
                    Image(systemName: "display.2")
                }
                .buttonStyle(VideoControlButtonStyle())
                .help("Arrange ALO Display")
                .accessibilityLabel("Open Displays Settings")
                Button(action: model.toggleVideoWindowFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(VideoControlButtonStyle())
                .help("Toggle full screen")
                .accessibilityLabel("Toggle full screen")
                Button(action: model.exitVideoFullscreen) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(VideoControlButtonStyle())
                .help("Close video window")
                .accessibilityLabel("Close video window")
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 14)
            .frame(width: 520, height: 48)
            .background(.ultraThinMaterial.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .padding(.bottom, 28)
        }
        .onExitCommand(perform: model.exitVideoFullscreen)
    }
}

@MainActor
private final class FullScreenVideoWindowController: NSObject, NSWindowDelegate {
    private let window: FullScreenVideoWindow
    private let closeHandler: () -> Void

    init(model: WERAIViewModel, closeHandler: @escaping () -> Void) {
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? Palette.selectedControlText : destructive ? Palette.red : Palette.ink)
            .padding(.horizontal, 15)
            .frame(height: 36)
            .background(filled ? Palette.controlAccent : destructive ? Palette.redSoft : Palette.messageSurface)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 30, height: 30)
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
        light: NSColor(red: 0.72, green: 0.18, blue: 0.29, alpha: 1),
        dark: NSColor(red: 0.95, green: 0.40, blue: 0.42, alpha: 1),
        highContrastLight: NSColor(red: 0.55, green: 0.09, blue: 0.20, alpha: 1),
        highContrastDark: NSColor(red: 1.00, green: 0.54, blue: 0.53, alpha: 1)
    )
    static let selectedControlText = adaptive(
        light: .white,
        dark: NSColor(red: 0.13, green: 0.03, blue: 0.06, alpha: 1),
        highContrastLight: .white,
        highContrastDark: .black
    )
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
        light: NSColor(red: 0.56, green: 0.11, blue: 0.23, alpha: 1),
        dark: NSColor(red: 1.00, green: 0.60, blue: 0.59, alpha: 1),
        highContrastLight: NSColor(red: 0.42, green: 0.05, blue: 0.15, alpha: 1),
        highContrastDark: NSColor(red: 1.00, green: 0.82, blue: 0.80, alpha: 1)
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
        light: NSColor(red: 0.97, green: 0.87, blue: 0.88, alpha: 1),
        dark: NSColor(red: 0.20, green: 0.08, blue: 0.13, alpha: 1)
    )
    static let artworkFallback = accentSoft
    static let blueSoft = adaptive(
        light: NSColor(red: 0.85, green: 0.87, blue: 0.97, alpha: 1),
        dark: NSColor(red: 0.09, green: 0.10, blue: 0.27, alpha: 1)
    )
    static let video = Color(red: 0.045, green: 0.035, blue: 0.09)
    static let red = Color(nsColor: .systemRed)
    static let redSoft = Color(nsColor: .systemRed).opacity(0.16)
    static let shadow = Color(red: 0.17, green: 0.04, blue: 0.18).opacity(0.18)

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
