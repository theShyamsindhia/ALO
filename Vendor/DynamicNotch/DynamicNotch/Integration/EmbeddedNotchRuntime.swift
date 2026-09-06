public import AppKit
import Combine
import SwiftUI

/// ALO owns application and panel lifecycle. This adapter embeds the original
/// DynamicNotch feature views, event engine, gestures, and settings in that panel.
@MainActor
public final class EmbeddedNotchRuntime: ObservableObject {
    static weak var activeInstance: EmbeddedNotchRuntime?
    public var onSettingsRequested: (@MainActor () -> Void)?
    enum SettingsDestination {
        case section(SettingsRootViewModel.Section)
        case subPage(SettingsSubPage)
    }
    static let settingsRequestNotification = Notification.Name("ALOEmbeddedNotchSettingsRequested")
    private var pendingSettingsDestination: SettingsDestination?

    /// Keep the destination until the inline settings view has actually mounted.
    @discardableResult
    func requestEmbeddedSettings(_ destination: SettingsDestination? = nil) -> Bool {
        guard let onSettingsRequested else { return false }
        pendingSettingsDestination = destination
        onSettingsRequested()
        NotificationCenter.default.post(name: Self.settingsRequestNotification, object: self)
        return true
    }

    func requestedSettingsDestination() -> SettingsDestination? {
        // Menu-bar and floating hosts may coexist; a hidden host must not
        // consume the route before the visible host has mounted.
        pendingSettingsDestination
    }

    @Published public private(set) var isEnabled = false
    @Published public private(set) var activityActive = false
    @Published public private(set) var presentationSize: CGSize = .zero
    @Published public private(set) var hitTestSize: CGSize = .zero
    @Published public private(set) var displayRevision: UInt = 0
    @Published public private(set) var isLocked = false

    public var onRoomLyricsDemandChanged: ((Bool) -> Void)?
    /// ALO owns room membership and file transport. These callbacks let the
    /// original tray UI request room operations without duplicating that state.
    public var onRoomTrayAddRequested: (([URL]) -> Void)?
    public var onRoomTrayRemoveRequested: (([String]) -> Void)?
    public var onRoomTrayDownloadRequested: ((String) -> Void)?
    public var onRoomTrayExportRequested: ((String, URL) -> Void)?
    private var roomLyricsPayload: RoomLyricsPayload?
    private var roomPlaybackSnapshot: RoomPlaybackSnapshot?
    private var roomPlaybackCommand: @MainActor (RoomPlaybackCommand) -> Void = { _ in }
    private var roomService: RoomPlaybackService?
    private var roomViewModel: NowPlayingViewModel?
    private var roomContentVisible = false
    public var interactiveScreenRect: CGRect? { delegate.activeNotchScreenRect }
    public var canvasSize: CGSize { OverlayWindowLayout.appCanvasSize }
    public var windowYOffset: CGFloat { 1 }

    enum ActivityOpeningTarget: Equatable {
        case currentActivity
        case homePage
        case unavailable
    }

    private let delegate: AppDelegate
    private let activation: FeatureActivation
    private var observations = Set<AnyCancellable>()

    public var preferredScreen: NSScreen? {
        NSScreen.preferredNotchScreen(for: delegate.settingsViewModel)
    }

    public var shouldHideInFullscreen: Bool {
        guard delegate.settingsViewModel.application.isNotchHiddenInFullscreenEnabled,
              let screen = preferredScreen else { return false }
        return SkyLightOperator.shared.isFullscreenSpaceActive(on: screen)
    }

    public init() {
        let delegate = AppDelegate()
        self.delegate = delegate
        self.activation = FeatureActivation(container: delegate.container)
        delegate.container.fileTrayViewModel.onRoomAddRequested = { [weak self] urls in
            self?.onRoomTrayAddRequested?(urls)
        }
        delegate.container.fileTrayViewModel.onRoomRemoveRequested = { [weak self] itemIDs in
            self?.onRoomTrayRemoveRequested?(itemIDs)
        }
        delegate.container.fileTrayViewModel.onRoomDownloadRequested = { [weak self] itemID in
            self?.onRoomTrayDownloadRequested?(itemID)
        }
        delegate.container.fileTrayViewModel.onRoomExportRequested = { [weak self] itemID, url in
            self?.onRoomTrayExportRequested?(itemID, url)
        }
        AppDelegate.embeddedInstance = delegate
        Self.activeInstance = self
        delegate.notchViewModel.$notchModel
            .receive(on: RunLoop.main)
            .sink { [weak self] model in
                guard let self else { return }
                let active = self.isEnabled && model.content != nil
                if self.activityActive != active { self.activityActive = active }
                self.refreshPresentationGeometry()
            }
            .store(in: &observations)
        delegate.notchViewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPresentationGeometry() }
            .store(in: &observations)
        delegate.settingsViewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshPresentationGeometry()
                self?.objectWillChange.send()
            }
            .store(in: &observations)
        delegate.settingsViewModel.application.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.delegate.notchViewModel.updateDimensions()
                self.displayRevision &+= 1
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.delegate.notchViewModel.updateDimensions()
                self.displayRevision &+= 1
            }
            .store(in: &observations)
        let workspace = NSWorkspace.shared.notificationCenter
        Publishers.Merge(
            workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.displayRevision &+= 1 }
        .store(in: &observations)
        delegate.lockScreenManager.$isLocked
            .receive(on: RunLoop.main)
            .sink { [weak self] locked in
                guard let self else { return }
                self.isLocked = locked
                self.delegate.notchViewModel.isLocked = locked
            }
            .store(in: &observations)
    }

    /// Supplying a snapshot makes the tray room-backed. Pass `nil` after
    /// leaving a room to restore the standalone local tray.
    public func updateRoomTray(_ snapshot: RoomTraySnapshot?) {
        delegate.container.fileTrayViewModel.applyRoomSnapshot(snapshot)
    }

    /// Feature choices remain persisted when the master switch is turned off.
    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        delegate.notchViewModel.setActivityEventsEnabled(enabled)
        if enabled {
            _ = NotchInitialFeatureProfile.apply(
                defaults: .aloNotch,
                domainName: UserDefaults.aloNotchDomainName,
                settings: delegate.settingsViewModel
            )
            // Construct the original event subscriptions before monitors emit events.
            _ = delegate.notchEventCoordinator
            delegate.observeOutsideClickDismissal()
            delegate.notchViewModel.updateDimensions()
            activation.setEnabled(true)
            // The coordinator persists across disable/re-enable, while the engine
            // clears activities. Restore the selected idle page on every enable.
            if delegate.settingsViewModel.homePage.isHomePageLiveActivityEnabled {
                delegate.notchEventCoordinator.handleHomePageEvent(.homePageOn)
            }
            reconcileRoomPlayback()
            activityActive = delegate.notchViewModel.displayedContent != nil
        } else {
            activation.setEnabled(false)
            reconcileRoomPlayback()
            delegate.stopOutsideClickMonitoring()
            delegate.cancellables.removeAll()
            delegate.airDropController.resetTargetState()
            SettingsWindowController.shared.close()
            activityActive = false
        }
    }

    public func makeHostPanel() -> NSPanel {
        let panel = OverlayPanelFactory.makePanel(frame: .zero, level: OverlayWindowLevel.interactiveNotch)
        SkyLightOperator.shared.delegateWindow(panel, to: .notchSurface)
        delegate.hostWindow = panel
        return panel
    }

    public func makeHostView() -> NSView {
        NotchHostingView(rootView: contentView)
    }

    public func hostFrame(on screen: NSScreen) -> NSRect {
        OverlayWindowLayout.topAnchoredFrame(on: screen, size: OverlayWindowLayout.appCanvasSize)
    }

    public func attachHostWindow(_ window: NSWindow) {
        delegate.hostWindow = window
    }

    public func setPresentationHidden(_ hidden: Bool) {
        delegate.notchViewModel.setActivityPresentationHidden(hidden)
    }

    /// Mount this only while the master switch is enabled. The original view
    /// provides the original animations, input gestures and drag destinations.
    public var contentView: AnyView {
        guard isEnabled else { return AnyView(EmptyView()) }
        return AnyView(NotchView(
            notchEventCoordinator: delegate.notchEventCoordinator,
            notchViewModel: delegate.notchViewModel,
            airDropViewModel: delegate.airDropViewModel,
            airDropController: delegate.airDropController,
            settingsViewModel: delegate.settingsViewModel
        ).defaultAppStorage(.aloNotch).transaction { transaction in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        })
    }

    /// Keep this mounted over ALO's room surface so an initial drag can awaken
    /// the original AirDrop/tray activity before another feature is visible.
    public var dragDestinationView: AnyView {
        let files = delegate.settingsViewModel.mediaAndFiles
        guard isEnabled, files.isAirDropLiveActivityEnabled || files.isTrayLiveActivityEnabled else {
            return AnyView(EmptyView())
        }
        return AnyView(NotchDragAndDropDestinationOverlay(
            airDropViewModel: delegate.airDropViewModel,
            airDropController: delegate.airDropController,
            settingsViewModel: delegate.settingsViewModel
        ).defaultAppStorage(.aloNotch))
    }

    private func refreshPresentationGeometry() {
        let size = delegate.notchViewModel.presentedNotchSize
        if presentationSize != size { presentationSize = size }
        var interactive = size
        if delegate.shouldShowPageIndicator {
            let indicator = delegate.pageIndicatorSize
            if delegate.settingsViewModel.homePage.homePageScrollAxis == .vertical {
                // The indicator sits on the right; a centered hit rectangle
                // must grow on both sides to include its complete width.
                interactive.width += 2 * (indicator.width + 16)
                interactive.height = max(interactive.height, size.height / 2 + indicator.height / 2)
            } else {
                interactive.height += indicator.height + 8
            }
        }
        if hitTestSize != interactive { hitTestSize = interactive }
    }

    public var settingsView: AnyView { settingsContent(embedded: false) }

    /// Reuses original feature pages inside ALO's main Settings pane.
    public var compactSettingsView: AnyView { settingsContent(embedded: true) }

    private func settingsContent(embedded: Bool) -> AnyView {
        guard isEnabled else { return AnyView(EmptyView()) }
        return AnyView(
            SettingsRootView(container: delegate.container, embedded: embedded)
                .defaultAppStorage(.aloNotch)
        )
    }

    public func showSettings() {
        if requestEmbeddedSettings() { return }
        guard isEnabled else { return }
        SettingsWindowController.shared.setupDependencies(appDelegate: delegate)
        SettingsWindowController.shared.showWindow()
    }

    public func updateRoomPlayback(_ snapshot: RoomPlaybackSnapshot?, onCommand: @escaping @MainActor (RoomPlaybackCommand) -> Void) {
        roomPlaybackSnapshot = snapshot
        roomPlaybackCommand = onCommand
        reconcileRoomPlayback()
    }

    public func updateRoomLyrics(_ payload: RoomLyricsPayload) {
        roomLyricsPayload = payload
        roomViewModel?.applyRoomLyrics(payload)
    }

    public func showRoomMention(
        _ snapshot: RoomMentionSnapshot,
        onOpen: @escaping @MainActor () -> Void
    ) {
        guard isEnabled else { return }
        delegate.notchViewModel.send(
            .showTemporaryNotification(
                RoomMentionNotchContent(snapshot: snapshot, onOpen: onOpen),
                duration: 4.5
            )
        )
    }

    private func reconcileRoomPlayback() {
        guard isEnabled, let snapshot = roomPlaybackSnapshot else {
            activation.setLockScreenMediaSource(nil)
            roomViewModel?.stopMonitoring()
            roomService?.update(nil)
            if roomContentVisible {
                delegate.notchViewModel.send(.hideLiveActivity(id: RoomNowPlayingNotchContent.activityID))
                roomContentVisible = false
            }
            return
        }
        if roomService == nil {
            let service = RoomPlaybackService()
            roomService = service
            roomViewModel = NowPlayingViewModel(service: service,
                audioOutputRouting: SystemAudioOutputRoutingService(),
                lyricsProvider: InactiveLyricsProvider())
            roomViewModel?.configureExternalLyrics { [weak self] demand in
                self?.onRoomLyricsDemandChanged?(demand)
            }
        }
        guard let service = roomService, let viewModel = roomViewModel else { return }
        service.onCommand = roomPlaybackCommand
        service.update(snapshot)
        viewModel.startMonitoring()
        if let roomLyricsPayload { viewModel.applyRoomLyrics(roomLyricsPayload) }
        activation.setLockScreenMediaSource(viewModel)
        if !roomContentVisible {
            let content = NowPlayingNotchContent(nowPlayingViewModel: viewModel,
                settings: delegate.settingsViewModel.mediaAndFiles,
                applicationSettings: delegate.settingsViewModel.application)
            delegate.notchViewModel.send(.showLiveActivity(RoomNowPlayingNotchContent(original: content)))
            roomContentVisible = true
        }
    }

    public var canOpenActivity: Bool {
        let settings = delegate.settingsViewModel.homePage
        return Self.activityOpeningTarget(
            isEnabled: isEnabled,
            hasCurrentActivity: delegate.notchViewModel.displayedContent != nil,
            isHomePageEnabled: settings.isHomePageLiveActivityEnabled,
            hasEnabledHomePageItem: settings.homePageOrder.contains {
                !settings.homePageDisabled.contains($0)
            }
        ) != .unavailable
    }

    @discardableResult
    public func openActivity() -> Bool {
        let settings = delegate.settingsViewModel.homePage
        let target = Self.activityOpeningTarget(
            isEnabled: isEnabled,
            hasCurrentActivity: delegate.notchViewModel.displayedContent != nil,
            isHomePageEnabled: settings.isHomePageLiveActivityEnabled,
            hasEnabledHomePageItem: settings.homePageOrder.contains {
                !settings.homePageDisabled.contains($0)
            }
        )
        switch target {
        case .currentActivity:
            delegate.notchViewModel.expandActiveLiveActivity()
        case .homePage:
            delegate.notchEventCoordinator.handleHomePageEvent(.homePageOn)
            delegate.notchViewModel.expandActiveLiveActivity()
        case .unavailable:
            return false
        }
        return true
    }

    static func activityOpeningTarget(isEnabled: Bool, hasCurrentActivity: Bool,
                                      isHomePageEnabled: Bool, hasEnabledHomePageItem: Bool) -> ActivityOpeningTarget {
        guard isEnabled else { return .unavailable }
        if hasCurrentActivity { return .currentActivity }
        if isHomePageEnabled, hasEnabledHomePageItem { return .homePage }
        return .unavailable
    }
}
