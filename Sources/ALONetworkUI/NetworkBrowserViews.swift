import SwiftUI

#if os(macOS)
/// Stable reading sizes; available space changes layout, not the type hierarchy.
public enum ALONetworkTypography {
    public static let title = Font.system(size: 22, weight: .bold)
    public static let heading = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 14)
    public static let label = Font.system(size: 14, weight: .semibold)
    public static let caption = Font.system(size: 11)
    public static let section = Font.system(size: 11, weight: .medium)
}

public enum ALONativeNetworkLayout {
    public static let minimumSidebarWidth: CGFloat = 210
    public static let maximumSidebarWidth: CGFloat = 280
    public static let panelInset: CGFloat = 8
    public static let windowRadius: CGFloat = 34
    public static let panelRadius: CGFloat = 28

    public static func sidebarWidth(for width: CGFloat) -> CGFloat {
        min(maximumSidebarWidth, max(minimumSidebarWidth, (width * 0.28).rounded()))
    }
}

private struct CompactNetworkLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var aloCompactNetworkLayout: Bool {
        get { self[CompactNetworkLayoutKey.self] }
        set { self[CompactNetworkLayoutKey.self] = newValue }
    }
}

/// The window frame owns the outer contour; no second content mask or painted backing.
public struct ALONetworkWindowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    public init() {}

    public var body: some View {
        if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
        else { NetworkWindowVisualEffect() }
    }
}

private struct NetworkWindowVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.identifier = NSUserInterfaceItemIdentifier("ALO.Network.WindowBlur")
        // Keep the native backdrop intact: fading its alpha exposes sharp content
        // behind the window instead of progressively blurring that content.
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The same window-owned columns are used by the account adapter and public
/// render fixtures, so empty detail content cannot recenter an intrinsic HStack.
public struct ALONativeNetworkColumns<Sidebar: View, Detail: View>: View {
    private let sidebar: Sidebar
    private let detail: Detail

    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = detail()
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar.frame(width: ALONativeNetworkLayout.sidebarWidth(for: geometry.size.width))
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: ALONativeNetworkLayout.panelRadius, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: ALONativeNetworkLayout.panelRadius, style: .continuous))
                    .padding([.top, .trailing, .bottom], ALONativeNetworkLayout.panelInset)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .environment(\.aloCompactNetworkLayout, geometry.size.width < 900 || geometry.size.height < 600)
        }
        .background(ALONetworkWindowBackground())
        .ignoresSafeArea()
        .tint(.blue)
    }
}
#endif

public struct ALONetworkSidebar: View {
    private let networks: [ALONetworkSummary]
    @Binding private var selectedNetworkID: String?
    private let identityName: String
    private let identityFingerprint: String
    private let onCreateNetwork: () -> Void
    private let onImportNetwork: () -> Void
    private let onExportPublicIdentity: () -> Void
    private let nearbyNetworks: [ALONearbyNetworkSummary]
    private let joinRequests: [ALOJoinRequestSummary]
    private let isBusy: Bool
    private let onJoin: (UUID) -> Void
    private let onApprove: (UUID) -> Void
    private let onDecline: (UUID) -> Void
    private let nearbyError: String?
    private let nearbyNotice: String?
    private let onRetryNearby: () -> Void
    private let onCancelJoin: (UUID) -> Void
    private let onExportRecovery: (() -> Void)?
    private let channels: [ALOChannelSummary]
    private let selectedChannelID: String?
    private let onOpenChannel: (String) -> Void
    @State private var reviewingRequest: ALOJoinRequestSummary?
    @State private var showingIdentity = false
    @State private var search = ""
    private let nowPlaying: AnyView?
    #if os(macOS)
    @Environment(\.aloCompactNetworkLayout) private var compactLayout
    #endif

    public init(
        networks: [ALONetworkSummary],
        selectedNetworkID: Binding<String?>,
        identityName: String,
        identityFingerprint: String,
        onCreateNetwork: @escaping () -> Void,
        onImportNetwork: @escaping () -> Void,
        onExportPublicIdentity: @escaping () -> Void,
        nearbyNetworks: [ALONearbyNetworkSummary] = [],
        joinRequests: [ALOJoinRequestSummary] = [],
        isBusy: Bool = false,
        onJoin: @escaping (UUID) -> Void = { _ in },
        onApprove: @escaping (UUID) -> Void = { _ in },
        onDecline: @escaping (UUID) -> Void = { _ in },
        nearbyError: String? = nil,
        nearbyNotice: String? = nil,
        onRetryNearby: @escaping () -> Void = {},
        onCancelJoin: @escaping (UUID) -> Void = { _ in },
        onExportRecovery: (() -> Void)? = nil,
        channels: [ALOChannelSummary] = [],
        selectedChannelID: String? = nil,
        onOpenChannel: @escaping (String) -> Void = { _ in },
        nowPlaying: AnyView? = nil
    ) {
        self.networks = networks
        _selectedNetworkID = selectedNetworkID
        self.identityName = identityName
        self.identityFingerprint = identityFingerprint
        self.onCreateNetwork = onCreateNetwork
        self.onImportNetwork = onImportNetwork
        self.onExportPublicIdentity = onExportPublicIdentity
        self.nearbyNetworks = nearbyNetworks; self.joinRequests = joinRequests
        self.isBusy = isBusy; self.onJoin = onJoin; self.onApprove = onApprove; self.onDecline = onDecline
        self.nearbyError = nearbyError; self.onRetryNearby = onRetryNearby
        self.nearbyNotice = nearbyNotice
        self.onCancelJoin = onCancelJoin
        self.onExportRecovery = onExportRecovery
        self.channels = channels
        self.selectedChannelID = selectedChannelID
        self.onOpenChannel = onOpenChannel
        self.nowPlaying = nowPlaying
    }

    public var body: some View {
        #if os(macOS)
        desktopSidebar
        #else
        mobileSidebar
        #endif
    }

    private var mobileSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Networks").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("Your people, nearby.").foregroundStyle(.secondary).font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            List(selection: $selectedNetworkID) {
                if !joinRequests.isEmpty {
                    Section("Requests to join") {
                        ForEach(joinRequests) { request in
                            Group {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(request.name).fontWeight(.medium)
                                    Text("Wants to join \(request.networkName). Approve only if you recognize this person.")
                                        .font(.callout).foregroundStyle(.secondary)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                DisclosureGroup("Verify identity") {
                                    Text("Compare this fingerprint with the person through a trusted conversation.")
                                        .font(.callout).foregroundStyle(.secondary)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                    ALOFingerprint(value: request.fingerprint)
                                }
                                .buttonStyle(.borderless)
                                HStack {
                                    Button("Approve") { onApprove(request.id) }.buttonStyle(.borderedProminent)
                                    Button("Decline") { onDecline(request.id) }.buttonStyle(.bordered)
                                }.frame(minHeight: ALONetworkMetrics.actionHeight).disabled(isBusy)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                Section("Your networks") {
                    ForEach(networks) { network in
                        HStack(spacing: 10) {
                            Image(systemName: "person.2")
                                .font(.body.weight(.medium))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(network.name).fontWeight(.medium)
                                Text("\(network.memberCount) \(network.memberCount == 1 ? "member" : "members")\(network.isOwner ? " · Owner" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: ALONetworkMetrics.actionHeight)
                        .contentShape(Rectangle())
                        .tag(network.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("ALO.Network.\(network.id)")
                    }
                    if networks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Find your people.").fontWeight(.medium)
                            Text("Join a nearby network, or create one for your group.")
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 6)
                    }
                }
                Section("Nearby networks") {
                    if let nearbyNotice {
                        Text(nearbyNotice).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let nearbyError {
                        ALOInlineError(message: nearbyError)
                        Button("Try again", action: onRetryNearby)
                            .frame(minHeight: ALONetworkMetrics.actionHeight)
                    }
                    ForEach(nearbyNetworks) { network in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(network.name).fontWeight(.medium)
                            if let status = network.status {
                                Text(status.message).font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if network.status == .waitingForApproval {
                                Button("Cancel request") { onCancelJoin(network.id) }
                                    .buttonStyle(.bordered)
                                    .frame(minHeight: ALONetworkMetrics.actionHeight)
                                    .accessibilityLabel("Cancel request to join \(network.name)")
                            } else {
                            Button("Join") { onJoin(network.id) }
                                .buttonStyle(.bordered)
                                .frame(minHeight: ALONetworkMetrics.actionHeight)
                                .disabled(isBusy)
                                .accessibilityLabel("Join \(network.name)")
                            }
                        }
                    }
                    if nearbyNetworks.isEmpty {
                        Text("Nearby networks appear here while their owner has ALO open. Connect to the same local network.")
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("The owner approves your request before you can enter.")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    Button(action: onCreateNetwork) {
                        ALOActionLabel(title: "Create network", systemImage: "plus")
                    }.accessibilityIdentifier("ALO.Network.Create")
                    DisclosureGroup("Other ways to connect") {
                        if !identityFingerprint.isEmpty {
                            ALOFingerprint(value: identityFingerprint)
                        }
                        Button(action: onImportNetwork) {
                            ALOActionLabel(title: "Import invitation", systemImage: "square.and.arrow.down")
                        }.accessibilityIdentifier("ALO.Network.Import")
                        Button(action: onExportPublicIdentity) {
                            ALOActionLabel(title: "Share public identity…", systemImage: "square.and.arrow.up")
                        }.accessibilityIdentifier("ALO.Identity.SharePublic")
                    }
                }
            }
            .listStyle(.inset)
            .lineLimit(nil)
            .frame(minHeight: 0, maxHeight: .infinity)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label(identityName, systemImage: "person.crop.circle").fontWeight(.medium)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Networks")
    }

    #if os(macOS)
    private func sidebarHeading(_ title: String) -> some View {
        Text(title.uppercased()).font(ALONetworkTypography.section).tracking(0.6)
            .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private var visibleNetworks: [ALONetworkSummary] {
        networks.filter { network in
            search.isEmpty || network.name.localizedCaseInsensitiveContains(search)
                || (network.id == selectedNetworkID && channels.contains {
                    $0.name.localizedCaseInsensitiveContains(search)
                })
        }
    }

    private var desktopSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Spaces").font(ALONetworkTypography.title).tracking(-0.4)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Button("Create network…", systemImage: "plus", action: onCreateNetwork)
                        .accessibilityIdentifier("ALO.Network.Create")
                    Button("Import invitation…", systemImage: "square.and.arrow.down", action: onImportNetwork)
                        .accessibilityIdentifier("ALO.Network.Import")
                } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .regular))
                        .frame(width: 32, height: 32).foregroundStyle(Color.blue)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Add a network").accessibilityLabel("Add a network")
            }
            .padding(.horizontal, compactLayout ? 20 : 24)
            .padding(.top, compactLayout ? 52 : 60).padding(.bottom, compactLayout ? 12 : 16)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search spaces", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Search networks and channels")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .font(ALONetworkTypography.body).padding(.horizontal, 12).frame(height: compactLayout ? 34 : 38)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
            .padding(.horizontal, compactLayout ? 12 : 16).padding(.bottom, compactLayout ? 12 : 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    sidebarHeading("Your networks")
                    ForEach(visibleNetworks) { network in
                        Button { selectedNetworkID = network.id } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 16)).foregroundStyle(Color.blue)
                                    .frame(width: 32, height: 32)
                                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(network.name).font(ALONetworkTypography.label).lineLimit(2)
                                    Text("\(network.memberCount) \(network.memberCount == 1 ? "person" : "people")\(network.isOwner ? " · Your network" : "")")
                                        .font(ALONetworkTypography.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: selectedNetworkID == network.id ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(isBusy).help(network.name)
                        .accessibilityIdentifier("ALO.Network.\(network.id)")
                        if selectedNetworkID == network.id {
                            ForEach(channels.filter {
                                search.isEmpty || network.name.localizedCaseInsensitiveContains(search)
                                    || $0.name.localizedCaseInsensitiveContains(search)
                            }) { channel in
                                Button { onOpenChannel(channel.id) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: channel.isPrivate ? "lock" : "number")
                                            .font(.system(size: 16)).frame(width: 32)
                                        Text(channel.name).font(selectedChannelID == channel.id
                                            ? ALONetworkTypography.label : ALONetworkTypography.body)
                                            .lineLimit(2)
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(selectedChannelID == channel.id ? Color.blue : .primary)
                                    .padding(.horizontal, 8).frame(minHeight: compactLayout ? 36 : 40)
                                    .background(selectedChannelID == channel.id ? Color.blue.opacity(0.11) : .clear,
                                                in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).disabled(isBusy)
                                .accessibilityLabel("Open \(channel.name) channel")
                                .accessibilityAddTraits(selectedChannelID == channel.id ? .isSelected : [])
                                .accessibilityIdentifier("ALO.Channel.Open.\(channel.id)")
                            }
                        }
                    }
                    if networks.isEmpty {
                        Text("Join a nearby network or create one for your group.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Create network…", action: onCreateNetwork).buttonStyle(.borderless)
                    } else if visibleNetworks.isEmpty {
                        Text("No matching spaces").font(.callout).foregroundStyle(.secondary)
                    }
                    if !joinRequests.isEmpty {
                        sidebarHeading("Requests · \(joinRequests.count)").padding(.top, 12)
                        ForEach(joinRequests) { request in
                            Button { reviewingRequest = request } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(request.name).lineLimit(2)
                                        Text(request.networkName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .accessibilityLabel("Review \(request.name)'s request to join \(request.networkName)")
                        }
                    }
                    Divider().opacity(0.5).padding(.vertical, compactLayout ? 8 : 16)
                    sidebarHeading("Nearby")
                    ForEach(nearbyNetworks.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { network in
                        HStack(spacing: 8) {
                            Image(systemName: "person.2").font(.system(size: 16))
                                .foregroundStyle(.secondary).frame(width: 32, height: 32)
                                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(network.name).font(ALONetworkTypography.body).lineLimit(2).help(network.name)
                                if let status = network.status {
                                    Text(status.message).font(ALONetworkTypography.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 4)
                            if network.status == .waitingForApproval {
                                Button("Cancel") { onCancelJoin(network.id) }
                                    .accessibilityLabel("Cancel request to join \(network.name)")
                            } else if network.status != .joined {
                                Button("Join") { onJoin(network.id) }.disabled(isBusy)
                                    .accessibilityLabel("Join \(network.name)")
                            }
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    if nearbyNetworks.isEmpty {
                        Text("No nearby networks").font(.callout).foregroundStyle(.secondary)
                            .help("Networks appear while their owner has ALO open on the same local network.")
                    }
                    if let nearbyNotice {
                        Text(nearbyNotice).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let nearbyError {
                        ALOInlineError(message: nearbyError)
                        Button("Try again", action: onRetryNearby)
                    }
                }
                .padding(.horizontal, compactLayout ? 12 : 16).padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            if let nowPlaying {
                Divider().opacity(0.5).padding(.horizontal, compactLayout ? 20 : 24)
                nowPlaying.padding(.horizontal, compactLayout ? 12 : 16).padding(.vertical, 8)
            }
            Divider().opacity(0.5).padding(.horizontal, compactLayout ? 20 : 24)
            HStack(spacing: 8) {
                Text(String(identityName.prefix(1)).uppercased())
                    .font(ALONetworkTypography.label).foregroundStyle(Color.blue)
                    .frame(width: 32, height: 32).background(Color.blue.opacity(0.09), in: Circle())
                Text(identityName).font(ALONetworkTypography.label).lineLimit(1).help(identityName)
                Spacer(minLength: 4)
                Menu {
                    Button("Share public identity…", systemImage: "square.and.arrow.up", action: onExportPublicIdentity)
                        .accessibilityIdentifier("ALO.Identity.SharePublic")
                    Button("View identity fingerprint…") { showingIdentity = true }
                    if let onExportRecovery {
                        Divider()
                        Button("Export identity recovery file…", systemImage: "key", action: onExportRecovery)
                            .accessibilityIdentifier("ALO.Identity.ExportRecovery")
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Identity options").accessibilityLabel("Identity options")
            }.padding(.horizontal, compactLayout ? 20 : 24).padding(.vertical, compactLayout ? 10 : 16)
        }
        .sheet(item: $reviewingRequest) { request in
            VStack(alignment: .leading, spacing: 20) {
                Text("Request to join").font(.title2.weight(.semibold))
                Text("\(request.name) wants to join \(request.networkName).")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Approve only if you recognize this person. Compare their fingerprint through a trusted conversation.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ALOFingerprint(value: request.fingerprint)
                HStack {
                    Button("Cancel") { reviewingRequest = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Decline", role: .destructive) { onDecline(request.id); reviewingRequest = nil }
                    Button("Approve") { onApprove(request.id); reviewingRequest = nil }.buttonStyle(.borderedProminent)
                }.disabled(isBusy)
            }.padding(24).frame(width: 440).interactiveDismissDisabled(isBusy)
        }
        .sheet(isPresented: $showingIdentity) {
            VStack(alignment: .leading, spacing: 20) {
                Text(identityName).font(.title2.weight(.semibold))
                ALOFingerprint(value: identityFingerprint)
                HStack { Spacer(); Button("Done") { showingIdentity = false }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 440)
        }
        .onChange(of: joinRequests.map(\.id)) { _, ids in
            if let request = reviewingRequest, !ids.contains(request.id) { reviewingRequest = nil }
        }
    }
    #endif
}

/// Navigation only. The parent must filter private channels using authenticated
/// membership before constructing the display values passed to this view.
public struct ALOChannelList: View {
    private let network: ALONetworkSummary
    private let channels: [ALOChannelSummary]
    @Binding private var selectedChannelID: String?
    private let isBusy: Bool
    private let errorMessage: String?
    private let onCreateChannel: () -> Void
    private let onAddMember: () -> Void
    private let onImportInvitation: () -> Void

    public init(
        network: ALONetworkSummary,
        channels: [ALOChannelSummary],
        selectedChannelID: Binding<String?>,
        isBusy: Bool = false,
        errorMessage: String? = nil,
        onCreateChannel: @escaping () -> Void,
        onAddMember: @escaping () -> Void,
        onImportInvitation: @escaping () -> Void
    ) {
        self.network = network
        self.channels = channels
        _selectedChannelID = selectedChannelID
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.onCreateChannel = onCreateChannel
        self.onAddMember = onAddMember
        self.onImportInvitation = onImportInvitation
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "person.2.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(network.name).font(.title2.weight(.semibold)).lineLimit(2)
                        .help(network.name).accessibilityAddTraits(.isHeader)
                    Text("\(network.memberCount) \(network.memberCount == 1 ? "member" : "members") · \(channels.count) \(channels.count == 1 ? "channel" : "channels")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    if network.isOwner {
                        Button("Create channel…", systemImage: "plus", action: onCreateChannel)
                        Button("Add member…", systemImage: "person.badge.plus", action: onAddMember)
                    }
                    Button("Import invitation…", systemImage: "square.and.arrow.down", action: onImportInvitation)
                } label: { Image(systemName: "ellipsis.circle").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).fixedSize().disabled(isBusy)
                .help("Network actions").accessibilityLabel("Network actions")
            }.padding(24)
                .help("Public channels are visible only to network members.")
            #else
            VStack(alignment: .leading, spacing: 8) {
                Text(network.name).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("Public channels are visible only to members of this network.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            #endif

            List(selection: $selectedChannelID) {
                Section("Channels") {
                    ForEach(orderedChannels) { channel in
                        HStack(spacing: 10) {
                            Image(systemName: channel.isPrivate ? "lock" : "number")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(channel.name).fontWeight(.medium)
                                Text(channel.isPrivate ? "Private · invited members" : (channel.isMain ? "Everyone starts here" : "All network members"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: ALONetworkMetrics.actionHeight)
                        .contentShape(Rectangle())
                        .tag(channel.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(channel.name), \(channel.isPrivate ? "private channel, invited members" : "public channel, all network members")")
                        .accessibilityIdentifier("ALO.Channel.\(channel.id)")
                    }
                    if channels.isEmpty {
                        #if os(macOS)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(isBusy ? "Loading channels…" : (network.isOwner
                                ? "No channels yet. Create one for your network."
                                : "No channels available. Import an updated invitation to refresh your access."))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if network.isOwner && !isBusy {
                                Button("Create channel…", systemImage: "plus", action: onCreateChannel)
                                    .accessibilityIdentifier("ALO.Channel.CreateEmpty")
                            }
                        }.padding(.vertical, 8)
                        #else
                        Text(isBusy ? "Loading channels…" : "No channels available. Import an updated invitation to refresh your access.")
                            .foregroundStyle(.secondary)
                        #endif
                    }
                }
                #if !os(macOS)
                Section {
                    if network.isOwner {
                        Button(action: onCreateChannel) {
                            ALOActionLabel(title: "Create channel", systemImage: "plus")
                        }.disabled(isBusy)
                        Button(action: onAddMember) {
                            ALOActionLabel(title: "Add network member", systemImage: "person.badge.plus")
                        }.disabled(isBusy)
                    }
                    Button(action: onImportInvitation) {
                        ALOActionLabel(title: "Import invitation", systemImage: "square.and.arrow.down")
                    }.disabled(isBusy)
                }
                #endif
                if let errorMessage {
                    Section { ALOInlineError(message: errorMessage) }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            #else
            .listStyle(.sidebar)
            #endif
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #endif
        .navigationTitle(network.name)
    }

    private var orderedChannels: [ALOChannelSummary] {
        channels.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
