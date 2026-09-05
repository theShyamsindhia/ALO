public import AppKit
import Combine
import SwiftUI

/// ALO owns application and panel lifecycle. This adapter embeds the original
/// DynamicNotch feature views, event engine, gestures, and settings in that panel.
@MainActor
public final class EmbeddedNotchRuntime: ObservableObject {
    @Published public private(set) var isEnabled = false
    @Published public private(set) var activityActive = false
    @Published public private(set) var presentationSize: CGSize = .zero
    @Published public private(set) var hitTestSize: CGSize = .zero
    @Published public private(set) var displayRevision: UInt = 0
    @Published public private(set) var isLocked = false

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
        AppDelegate.embeddedInstance = delegate
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

    /// Feature choices remain persisted when the master switch is turned off.
    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        delegate.notchViewModel.setActivityEventsEnabled(enabled)
        if enabled {
            // Construct the original event subscriptions before monitors emit events.
            _ = delegate.notchEventCoordinator
            delegate.observeOutsideClickDismissal()
            delegate.notchViewModel.updateDimensions()
            activation.setEnabled(true)
            activityActive = delegate.notchViewModel.displayedContent != nil
        } else {
            activation.setEnabled(false)
            delegate.stopOutsideClickMonitoring()
            delegate.cancellables.removeAll()
            delegate.airDropController.resetTargetState()
            SettingsWindowController.shared.close()
            activityActive = false
        }
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

    public var settingsView: AnyView {
        guard isEnabled else { return AnyView(EmptyView()) }
        return AnyView(SettingsRootView(container: delegate.container).defaultAppStorage(.aloNotch))
    }

    public func showSettings() {
        guard isEnabled else { return }
        SettingsWindowController.shared.setupDependencies(appDelegate: delegate)
        SettingsWindowController.shared.showWindow()
    }

    public func openHomePage() {
        guard isEnabled else { return }
        let settings = delegate.settingsViewModel.homePage
        guard settings.isHomePageLiveActivityEnabled,
              settings.homePageOrder.contains(where: { !settings.homePageDisabled.contains($0) }) else {
            showSettings()
            return
        }
        delegate.notchEventCoordinator.handleHomePageEvent(.homePageOn)
        delegate.notchViewModel.expandActiveLiveActivity()
    }
}
