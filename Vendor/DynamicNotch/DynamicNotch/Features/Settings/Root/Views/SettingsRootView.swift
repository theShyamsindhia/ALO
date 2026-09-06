import SwiftUI
internal import AppKit

enum SettingsWindowLayout {
    static let width: CGFloat = 760
    static let height: CGFloat = 590
}

struct SettingsRootView: View {
    private enum SelectionChangeOrigin {
        case sidebar
        case history
        case search
        case initial
    }

    @Environment(\.openURL) private var openURL
    @ObservedObject var powerService: PowerService
    @ObservedObject var settingsViewModel: SettingsViewModel

    let notchViewModel: NotchViewModel
    let notchEventCoordinator: NotchEventCoordinator
    let bluetoothViewModel: BluetoothViewModel
    let wifiViewModel: WifiViewModel
    let vpnViewModel: VpnViewModel
    let downloadViewModel: DownloadViewModel
    let nowPlayingViewModel: NowPlayingViewModel
    let timerViewModel: TimerViewModel
    let lockScreenManager: LockScreenManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var embeddedDetailVisible = false
    private let embedded: Bool
    private let viewModel: SettingsRootViewModel
    
    @AppStorage("settings.general.isBlueNightMode") private var isBlueNightMode = false
    @Environment(\.colorScheme) private var colorScheme
    
    private var nsBackgroundColor: NSColor {
        if isBlueNightMode && colorScheme == .dark {
            return NSColor(red: 0.07, green: 0.11, blue: 0.17, alpha: 1.0)
        } else if colorScheme == .dark {
            return NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        } else {
            return NSColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1.0)
        }
    }
    
    @StateObject private var permissionController = SettingsPermissionController()
    @State private var searchText = ""
    @State private var selectedSection: SettingsRootViewModel.Section
    @State private var selectionHistory: SettingsRootViewModel.SelectionHistory
    @State private var isShowingSearchSelection = false
    @State private var pendingResetSubPage: SettingsSubPage?
    @State private var navigationPath: [SettingsSubPage] = []
    @State private var availableDisplays = NSScreen.availableNotchDisplays()
    @ObservedObject private var updater = SparkleUpdater.shared

    init(container: AppContainer, embedded: Bool = false) {
        self.init(
            powerService: container.powerService,
            settingsViewModel: container.settingsViewModel,
            notchViewModel: container.notchViewModel,
            notchEventCoordinator: container.notchEventCoordinator,
            bluetoothViewModel: container.bluetoothViewModel,
            wifiViewModel: container.wifiViewModel,
            vpnViewModel: container.vpnViewModel,
            downloadViewModel: container.downloadViewModel,
            nowPlayingViewModel: container.nowPlayingViewModel,
            timerViewModel: container.timerViewModel,
            lockScreenManager: container.lockScreenManager,
            embedded: embedded
        )
    }

    init(
        powerService: PowerService,
        settingsViewModel: SettingsViewModel,
        notchViewModel: NotchViewModel,
        notchEventCoordinator: NotchEventCoordinator,
        bluetoothViewModel: BluetoothViewModel,
        wifiViewModel: WifiViewModel,
        vpnViewModel: VpnViewModel,
        downloadViewModel: DownloadViewModel,
        nowPlayingViewModel: NowPlayingViewModel,
        timerViewModel: TimerViewModel,
        lockScreenManager: LockScreenManager,
        embedded: Bool = false
    ) {
        self.embedded = embedded
        self.powerService = powerService
        self.settingsViewModel = settingsViewModel
        self.notchViewModel = notchViewModel
        self.notchEventCoordinator = notchEventCoordinator
        self.bluetoothViewModel = bluetoothViewModel
        self.wifiViewModel = wifiViewModel
        self.vpnViewModel = vpnViewModel
        self.downloadViewModel = downloadViewModel
        self.nowPlayingViewModel = nowPlayingViewModel
        self.timerViewModel = timerViewModel
        self.lockScreenManager = lockScreenManager
        let rootViewModel = SettingsRootViewModel(
            settingsViewModel: settingsViewModel,
            notchViewModel: notchViewModel,
            notchEventCoordinator: notchEventCoordinator,
            bluetoothViewModel: bluetoothViewModel,
            powerService: powerService,
            wifiViewModel: wifiViewModel,
            vpnViewModel: vpnViewModel,
            downloadViewModel: downloadViewModel,
            nowPlayingViewModel: nowPlayingViewModel,
            timerViewModel: timerViewModel,
            lockScreenManager: lockScreenManager
        )
        self.viewModel = rootViewModel
        let initialSelection = rootViewModel.initialSelection()
        _selectedSection = State(initialValue: initialSelection)
        _selectionHistory = State(initialValue: .init(initialSelection: initialSelection))
    }

    private func localized(_ key: String, fallback: String? = nil) -> String {
        settingsViewModel.application.appLanguage.locale.dn(key, fallback: fallback)
    }

    @ViewBuilder
    var body: some View {
        if embedded { compactBody } else { windowBody }
    }

    private var compactBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if embeddedDetailVisible {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            if !navigationPath.isEmpty { navigationPath.removeLast() }
                            else { embeddedDetailVisible = false; searchText = "" }
                        }
                    } label: {
                        Label("Features", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.embedded.back")
                    Text("/").foregroundStyle(.tertiary)
                    Text(embeddedTitle(for: selectedSection))
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let page = navigationPath.last, page.canReset {
                        Button(localized("settings.reset.action", fallback: "Reset")) { pendingResetSubPage = page }
                            .buttonStyle(.borderless)
                    }
                } else {
                    Text("Features").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    TextField(localized("settings.search.prompt", fallback: "Search features"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 210)
                        .accessibilityIdentifier("settings.embedded.search")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            Group {
                if embeddedDetailVisible {
                    NavigationStack(path: $navigationPath) {
                        detailView(for: selectedSection)
                            .navigationBarBackButtonHidden(true)
                            .navigationDestination(for: SettingsSubPage.self) { page in
                                subPageView(for: page).navigationBarBackButtonHidden(true)
                            }
                    }
                    .padding(.horizontal, 8)
                    .transition(.opacity)
                } else {
                    ScrollView {
                        if embeddedSections.isEmpty {
                            SettingsSearchEmptyState(query: searchText)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                                ForEach(embeddedSections) { section in
                                    Button {
                                        applySelection(section, origin: .sidebar)
                                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                            embeddedDetailVisible = true
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Image(systemName: section.systemImage)
                                                    .font(.system(size: 17, weight: .semibold))
                                                    .foregroundStyle(section == .lockScreen ? Color.primary : section.tint)
                                                    .frame(width: 30, height: 28)
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                                            }
                                            Text(embeddedTitle(for: section))
                                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                                            Text(localized(section.subtitleKey, fallback: section.fallbackSubtitle))
                                                .font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(2).frame(height: 30, alignment: .topLeading)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(.primary.opacity(colorScheme == .dark ? 0.05 : 0.035), in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
                                        .contentShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("settings.embedded.feature.\(section.rawValue)")
                                }
                            }
                        }
                    }.padding(12)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: nsBackgroundColor))
        .environment(\.locale, settingsViewModel.application.appLanguage.locale)
        .preferredColorScheme(settingsViewModel.application.appearanceMode.preferredColorScheme)
        .accessibilityIdentifier("settings.embedded.root")
        .onAppear { applyPendingEmbeddedDestination() }
        .onReceive(NotificationCenter.default.publisher(for: EmbeddedNotchRuntime.settingsRequestNotification)) { _ in
            applyPendingEmbeddedDestination()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SelectSettingsSection"))) { notification in
            if let section = notification.object as? SettingsRootViewModel.Section {
                applySelection(section, origin: .sidebar); embeddedDetailVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SelectSettingsSubPage"))) { notification in
            if let page = notification.object as? SettingsSubPage {
                navigationPath = [page]; embeddedDetailVisible = true
            }
        }
        .alert(item: $pendingResetSubPage) { page in
            Alert(title: Text(localized("settings.reset.title")), message: Text(localized("settings.reset.message")),
                  primaryButton: .destructive(Text(localized("settings.reset.action"))) { reset(page) },
                  secondaryButton: .cancel(Text(localized("common.cancel"))))
        }
    }

    private var embeddedSections: [SettingsRootViewModel.Section] {
        let priority = ["nowPlaying", "lockScreen", "general", "homePage", "battery", "hud", "notifications", "downloads", "drop", "calendar", "wifi", "bluetooth", "vpn", "focus", "screenRecording"]
        return filteredSections.filter { $0.rawValue != "debug" }.sorted {
            (priority.firstIndex(of: $0.rawValue) ?? priority.count) < (priority.firstIndex(of: $1.rawValue) ?? priority.count)
        }
    }

    private func embeddedTitle(for section: SettingsRootViewModel.Section) -> String {
        section == .nowPlaying ? "Playback" : localized(section.titleKey, fallback: section.fallbackTitle)
    }

    private func applyPendingEmbeddedDestination() {
        guard let destination = EmbeddedNotchRuntime.activeInstance?.requestedSettingsDestination() else { return }
        searchText = ""
        embeddedDetailVisible = true
        switch destination {
        case .section(let section):
            applySelection(section, origin: .sidebar)
        case .subPage(let page):
            navigationPath = [page]
        }
    }

    private var windowBody: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                ForEach(groupedSections, id: \.group.id) { group in
                    Section {
                        ForEach(group.sections) { section in
                            NavigationLink(value: section) {
                                if let imageName = section.imageName {
                                    SettingsSidebarRow(
                                        title: localized(section.titleKey, fallback: section.fallbackTitle),
                                        imageName: imageName,
                                        tint: section.tint,
                                        iconColor: section.iconColor,
                                        stroke: section.stroke,
                                        showBadge: section == .general && updater.isUpdateAvailable
                                    )
                                } else {
                                    SettingsSidebarRow(
                                        title: localized(section.titleKey, fallback: section.fallbackTitle),
                                        systemImage: section.systemImage,
                                        tint: section.tint,
                                        iconColor: section.iconColor,
                                        stroke: section.stroke,
                                        showBadge: section == .general && updater.isUpdateAvailable
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(colorScheme == .dark ? .hidden : .visible)
            .background {
                if colorScheme == .dark {
                    if isBlueNightMode {
                        Color(red: 0.090, green: 0.129, blue: 0.169)
                    } else {
                        Color(red: 0.14, green: 0.14, blue: 0.15)
                    }
                }
            }
            .searchable(
                text: $searchText,
                placement: .sidebar,
                prompt: localized("settings.search.prompt")
            )
            .background {
                if colorScheme == .dark {
                    if isBlueNightMode {
                        Color(red: 0.090, green: 0.129, blue: 0.169).ignoresSafeArea()
                    } else {
                        Color(red: 0.14, green: 0.14, blue: 0.15).ignoresSafeArea()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 200)

        } detail: {
            NavigationStack(path: $navigationPath) {
                ZStack(alignment: .top) {
                    Group {
                        if filteredSections.isEmpty {
                            SettingsSearchEmptyState(query: searchText)
                        } else {
                            detailView(for: resolvedSelection)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    
                    Color.clear
                        .frame(height: 52)
                        .background {
                            Color(nsColor: nsBackgroundColor)
                        }
                        .overlay(alignment: .bottom) {
                            Divider()
                                .opacity(0.6)
                        }
                        .ignoresSafeArea(.container, edges: .top)
                }
                .scrollContentBackground(.hidden)
                .background {
                    Color(nsColor: nsBackgroundColor)
                }
                .navigationDestination(for: SettingsSubPage.self) { subPage in
                    ZStack(alignment: .top) {
                        subPageView(for: subPage)
                        
                        Color.clear
                            .frame(height: 52)
                            .background {
                                Color(nsColor: nsBackgroundColor)
                            }
                            .overlay(alignment: .bottom) {
                                Divider()
                                    .opacity(0.6)
                            }
                            .ignoresSafeArea(.container, edges: .top)
                    }
                    .navigationBarBackButtonHidden(true)
                    .toolbar { toolbarContent(for: resolvedSelection) }
                }
            }
        }
        .navigationTitle(currentTitle)
        .navigationSubtitle(currentSubtitle)
        .onChange(of: searchText) { _, newValue in
            syncSelectionWithSearch(query: newValue)
        }
        .onAppear {
            applySelection(viewModel.initialSelection(), origin: .initial)
            updateWindowStyle()
        }
        .onChange(of: isBlueNightMode) {
            updateWindowStyle()
        }
        .onChange(of: colorScheme) {
            updateWindowStyle()
        }
        .onChange(of: settingsViewModel.application.appearanceMode) {
            updateWindowStyle()
        }        .alert(item: $pendingResetSubPage) { subPage in
            Alert(
                title: Text(localized("settings.reset.title")),
                message: Text(localized("settings.reset.message")),
                primaryButton: .destructive(Text(localized("settings.reset.action"))) {
                    reset(subPage)
                },
                secondaryButton: .cancel(Text(localized("common.cancel")))
            )
        }
        .accessibilityIdentifier("settings.root")
        .environment(\.locale, settingsViewModel.application.appLanguage.locale)
        .preferredColorScheme(settingsViewModel.application.appearanceMode.preferredColorScheme)
        .background {
            Color(nsColor: nsBackgroundColor)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SelectSettingsSection"))) { notification in
            if let section = notification.object as? SettingsRootViewModel.Section {
                applySelection(section, origin: .sidebar)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SelectSettingsSubPage"))) { notification in
            if let subPage = notification.object as? SettingsSubPage {
                applySelection(.general, origin: .sidebar)
                navigationPath = [subPage]
            }
        }
    }

    private func updateWindowStyle() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "DynamicNotchSettingsWindow" }) else {
            return
        }
        
        switch settingsViewModel.application.appearanceMode {
        case .system:
            window.appearance = nil
        case .light:
            window.appearance = NSAppearance(named: .aqua)
        case .dark:
            window.appearance = NSAppearance(named: .darkAqua)
        }
        
        window.backgroundColor = nsBackgroundColor
        window.isOpaque = true
        
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
    }

    private var selectionBinding: Binding<SettingsRootViewModel.Section> {
        Binding(
            get: { selectedSection },
            set: { applySelection($0, origin: .sidebar) }
        )
    }

    private var filteredSections: [SettingsRootViewModel.Section] {
        let query = trimmedSearchText
        guard !query.isEmpty else {
            return viewModel.sections
        }

        return viewModel.sections.filter { section in
            searchableStrings(for: section).contains { value in
                value.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchableStrings(for section: SettingsRootViewModel.Section) -> [String] {
        [
            localized(section.titleKey, fallback: section.fallbackTitle),
            section.fallbackTitle,
            localized(section.subtitleKey, fallback: section.fallbackSubtitle),
            section.fallbackSubtitle
        ] + section.searchKeywords
    }

    private var groupedSections: [(group: SettingsRootViewModel.SidebarGroup, sections: [SettingsRootViewModel.Section])] {
        SettingsRootViewModel.SidebarGroup.allCases.compactMap { group in
            let sections = filteredSections.filter { $0.sidebarGroup == group }
            guard !sections.isEmpty else { return nil }
            return (group, sections)
        }
    }

    private var resolvedSelection: SettingsRootViewModel.Section {
        if filteredSections.contains(selectedSection) {
            return selectedSection
        }

        return filteredSections.first ?? .general
    }

    private var canNavigateBack: Bool {
        !navigationPath.isEmpty || selectionHistory.canGoBack
    }

    private var canNavigateForward: Bool {
        navigationPath.isEmpty && selectionHistory.canGoForward
    }

    private func applySelection(_ section: SettingsRootViewModel.Section, origin: SelectionChangeOrigin) {
        navigationPath.removeAll()
        switch origin {
        case .sidebar:
            guard selectedSection != section ||
                    isShowingSearchSelection ||
                    selectionHistory.currentSelection != section else {
                return
            }

            selectionHistory.record(section)
            selectedSection = section
            isShowingSearchSelection = false
            viewModel.persistSelection(section)

        case .history:
            guard selectedSection != section || isShowingSearchSelection else { return }
            selectedSection = section
            isShowingSearchSelection = false
            viewModel.persistSelection(section)

        case .search:
            guard selectedSection != section || !isShowingSearchSelection else { return }
            selectedSection = section
            isShowingSearchSelection = true

        case .initial:
            selectionHistory = .init(initialSelection: section)
            selectedSection = section
            isShowingSearchSelection = false
        }
    }

    private func syncSelectionWithSearch(query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedQuery.isEmpty {
            guard isShowingSearchSelection else { return }
            applySelection(selectionHistory.currentSelection, origin: .history)
            return
        }

        guard !filteredSections.isEmpty else { return }

        if !filteredSections.contains(selectedSection) {
            applySelection(filteredSections[0], origin: .search)
        }
    }

    private func navigateBack() {
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
            return
        }
        guard let previousSection = selectionHistory.goBack() else { return }
        revealSectionIfNeeded(previousSection)
        applySelection(previousSection, origin: .history)
    }

    private func navigateForward() {
        guard navigationPath.isEmpty else { return }
        guard let nextSection = selectionHistory.goForward() else { return }
        revealSectionIfNeeded(nextSection)
        applySelection(nextSection, origin: .history)
    }

    private func revealSectionIfNeeded(_ section: SettingsRootViewModel.Section) {
        guard !trimmedSearchText.isEmpty else { return }
        guard !filteredSections.contains(section) else { return }
        searchText = ""
    }

    private var compactGeneralSettings: some View {
        let pages: [SettingsSubPage] = [.notch, .appearance, .language, .permissions, .about]
        return SettingsPageScrollView {
            ForEach(pages) { page in
                NavigationLink(value: page) {
                    HStack {
                        Text(localized(page.titleKey, fallback: page.fallbackTitle))
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsRootViewModel.Section) -> some View {
        switch section {
        case .general:
            detailContainer(for: section) {
                if embedded {
                    compactGeneralSettings
                } else {
                    GeneralSettingsView(
                        applicationSettings: settingsViewModel.application,
                        permissionController: permissionController
                    )
                }
            }


        case .nowPlaying:
            detailContainer(for: section) {
                NowPlayingSettingsView(
                    settings: settingsViewModel.mediaAndFiles,
                    applicationSettings: settingsViewModel.application
                )
            }

        case .homePage:
            detailContainer(for: section) {
                 HomePageSettingsView(
                     homePageSettings: settingsViewModel.homePage,
                     applicationSettings: settingsViewModel.application
                 )
            }
            
        #if DEBUG
        case .debug:
            detailContainer(for: section) {
                DebugSettingsView(viewModel: viewModel.debugViewModel)
            }
        #endif
            
        case .calendar:
            detailContainer(for: section) {
                CalendarSettingsView(
                    settings: settingsViewModel.calendar
                )
            }

        case .notifications:
            detailContainer(for: section) {
                NotificationsSettingsView(
                    settings: settingsViewModel.notifications,
                    permissionController: permissionController
                )
            }
            
        case .downloads:
            detailContainer(for: section) {
                DownloadsSettingsView(
                    mediaSettings: settingsViewModel.mediaAndFiles,
                    appearanceSettings: settingsViewModel.application
                )
            }

        case .drop:
            detailContainer(for: section) {
                DragAndDropSettingsView(
                    mediaSettings: settingsViewModel.mediaAndFiles,
                    appearanceSettings: settingsViewModel.application
                )
            }

        case .screenRecording:
            detailContainer(for: section) {
                ScreenCaptureSettingsView(
                    settings: settingsViewModel.screenRecording,
                    appearanceSettings: settingsViewModel.application
                )
            }

        case .focus:
            detailContainer(for: section) {
                FocusSettingsView(
                    connectivitySettings: settingsViewModel.connectivity,
                    appearanceSettings: settingsViewModel.application
                )
            }

        case .bluetooth:
            detailContainer(for: section) {
                BluetoothSettingsView(
                    settings: settingsViewModel.connectivity,
                    applicationSettings: settingsViewModel.application
                )
            }

        case .wifi:
            detailContainer(for: section) {
                WifiSettingsView(
                    connectivitySettings: settingsViewModel.connectivity,
                    appearanceSettings: settingsViewModel.application
                )
            }

        case .vpn:
            detailContainer(for: section) {
                VpnSettingsView(
                    connectivitySettings: settingsViewModel.connectivity,
                    appearanceSettings: settingsViewModel.application
                )
            }

        case .battery:
            detailContainer(for: section) {
                BatterySettingsView(
                    batterySettings: settingsViewModel.battery,
                    appearanceSettings: settingsViewModel.application
                )
            }

        case .hud:
            detailContainer(for: section) {
                HUDSettingsView(
                    settings: settingsViewModel.hud,
                    applicationSettings: settingsViewModel.application
                )
            }

        case .lockScreen:
            detailContainer(for: section) {
                LockScreenSettingsView(settings: settingsViewModel.lockScreen, applicationSettings: settingsViewModel.application)
            }



        }
    }

    @ViewBuilder
    private func detailContainer<Content: View>(for section: SettingsRootViewModel.Section, @ViewBuilder content: () -> Content) -> some View {
        if embedded {
            content().accessibilityIdentifier(section.accessibilityIdentifier)
        } else {
            content()
                .accessibilityIdentifier(section.accessibilityIdentifier)
                .toolbar { toolbarContent(for: section) }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(for section: SettingsRootViewModel.Section) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                navigateBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!canNavigateBack)
            .help(localized("settings.navigation.back", fallback: "Back"))
            .keyboardShortcut("[", modifiers: [.command])
            .accessibilityLabel(Text(localized("settings.navigation.back", fallback: "Back")))
            .accessibilityIdentifier("settings.toolbar.back")

            Button {
                navigateForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!canNavigateForward)
            .help(localized("settings.navigation.forward", fallback: "Forward"))
            .keyboardShortcut("]", modifiers: [.command])
            .accessibilityLabel(Text(localized("settings.navigation.forward", fallback: "Forward")))
            .accessibilityIdentifier("settings.toolbar.forward")
        }

        if let subPage = navigationPath.last, subPage.canReset {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    pendingResetSubPage = subPage
                } label: {
                    Text(localized("settings.reset.action", fallback: "Reset"))
                }
                .help(
                    String(
                        format: localized("settings.reset.help.available", fallback: "Reset current tab to defaults"),
                        localized(subPage.titleKey, fallback: subPage.fallbackTitle)
                    )
                )
                .accessibilityIdentifier("settings.toolbar.resetCurrentSubPage")
            }
        }
    }

    private func openInternetURL(_ url: URL) {
        guard notchEventCoordinator.requestInternetAccess() else { return }
        openURL(url)
    }

    @ViewBuilder
    private func subPageView(for subPage: SettingsSubPage) -> some View {
        switch subPage {
        case .appearance:
            AppearanceSettingsView(applicationSettings: settingsViewModel.application)
        case .notch:
            NotchSettingsView(
                powerService: powerService,
                applicationSettings: settingsViewModel.application,
                availableDisplays: $availableDisplays
            )
        case .language:
            LanguageSettingsView(applicationSettings: settingsViewModel.application)
        case .system:
            SystemSettingsView(applicationSettings: settingsViewModel.application)
        case .permissions:
            PermissionsSettingsView(permissionController: permissionController, applicationSettings: settingsViewModel.application)
        case .softwareUpdate:
            SoftwareUpdateSettingsView()
        case .about:
            AboutAppSettingsView(
                applicationSettings: settingsViewModel.application,
                onRequestInternetAccess: {
                    notchEventCoordinator.requestInternetAccess()
                }
            )
        #if DEBUG
        case .debug:
            DebugSettingsView(viewModel: viewModel.debugViewModel)
        #endif
        case .activityPriorities:
            ActivityPrioritiesSettingsView(applicationSettings: settingsViewModel.application)
        case .notchDisplay:
            DisplaySettingsView(applicationSettings: settingsViewModel.application, availableDisplays: $availableDisplays)
        case .notchAnimation:
            AnimationSettingsView(applicationSettings: settingsViewModel.application)
        case .gestures:
            GesturesSettingsView(applicationSettings: settingsViewModel.application)
        case .fileTray:
            FileTraySettingsView(
                mediaSettings: settingsViewModel.mediaAndFiles,
                appearanceSettings: settingsViewModel.application
            )
        case .fileConverter:
            FileConverterSettingsView(
                mediaSettings: settingsViewModel.mediaAndFiles
            )
        case .homePagePages:
            HomePagePagesSettingsView(
                homePageSettings: settingsViewModel.homePage
            )
        case .timer:
            TimerSettingsView(
                mediaSettings: settingsViewModel.mediaAndFiles,
                appearanceSettings: settingsViewModel.application
            )
        case .appleMail:
            AppleMailNotificationsSettingsView(
                settings: settingsViewModel.notifications,
                permissionController: permissionController
            )
        case .messages:
            MessagesNotificationsSettingsView(
                settings: settingsViewModel.notifications,
                permissionController: permissionController
            )
        case .externalDrives:
            ExternalDrivesNotificationsSettingsView(
                settings: settingsViewModel.notifications
            )
        }
    }

    private var currentTitle: String {
        if filteredSections.isEmpty {
            return localized("settings.search.title")
        }
        if let subPage = navigationPath.last {
            return localized(subPage.titleKey, fallback: subPage.fallbackTitle)
        }
        return localized(resolvedSelection.titleKey, fallback: resolvedSelection.fallbackTitle)
    }

    private var currentSubtitle: String {
        if filteredSections.isEmpty {
            return ""
        }
        if let subPage = navigationPath.last {
            return localized(subPage.subtitleKey, fallback: subPage.fallbackSubtitle)
        }
        return localized(resolvedSelection.subtitleKey, fallback: resolvedSelection.fallbackSubtitle)
    }

    private func reset(_ subPage: SettingsSubPage) {
        switch subPage {
        case .appearance:
            settingsViewModel.application.resetAppearance()
        case .notch:
            settingsViewModel.application.resetNotch()
            settingsViewModel.application.resetDisplay()
        case .language:
            settingsViewModel.application.resetLanguage()
        case .activityPriorities:
            settingsViewModel.application.resetNotchContentPriorities()
        case .notchDisplay:
            settingsViewModel.application.resetDisplay()
        case .notchAnimation:
            settingsViewModel.application.resetAnimation()
        case .gestures:
            settingsViewModel.application.resetGestures()
        case .fileTray:
            settingsViewModel.mediaAndFiles.resetFileTray()
        case .fileConverter:
            settingsViewModel.mediaAndFiles.resetFileConverter()
        case .homePagePages:
            settingsViewModel.homePage.resetHomePage()
        case .appleMail, .messages, .externalDrives:
            settingsViewModel.notifications.reset()
        default:
            break
        }
    }
}
