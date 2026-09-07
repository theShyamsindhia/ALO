import SwiftUI

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
    private let onRetryNearby: () -> Void
    private let onCancelJoin: (UUID) -> Void

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
        onRetryNearby: @escaping () -> Void = {},
        onCancelJoin: @escaping (UUID) -> Void = { _ in }
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
        self.onCancelJoin = onCancelJoin
    }

    public var body: some View {
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
                            VStack(alignment: .leading, spacing: 8) {
                                Text(request.name).fontWeight(.medium)
                                Text("Wants to join \(request.networkName). Approve only if you recognize this person.")
                                    .font(.callout).foregroundStyle(.secondary)
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
                        }.padding(.vertical, 6)
                    }
                }
                Section("Nearby networks") {
                    if let nearbyError {
                        ALOInlineError(message: nearbyError)
                        Button("Try again", action: onRetryNearby)
                            .frame(minHeight: ALONetworkMetrics.actionHeight)
                    }
                    ForEach(nearbyNetworks) { network in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(network.name).fontWeight(.medium)
                            if let status = network.status {
                                Text(status).font(.callout).foregroundStyle(.secondary)
                            }
                            if network.status == "Waiting for approval" {
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
                    } else {
                        Text("The owner approves your request before you can enter.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(action: onCreateNetwork) {
                        ALOActionLabel(title: "Create network", systemImage: "plus")
                    }.accessibilityIdentifier("ALO.Network.Create")
                    DisclosureGroup("Other ways to connect") {
                        Button(action: onImportNetwork) {
                            ALOActionLabel(title: "Import invitation", systemImage: "square.and.arrow.down")
                        }.accessibilityIdentifier("ALO.Network.Import")
                        Button(action: onExportPublicIdentity) {
                            ALOActionLabel(title: "Share public identity…", systemImage: "square.and.arrow.up")
                        }.accessibilityIdentifier("ALO.Identity.SharePublic")
                    }
                }
            }
            .listStyle(.sidebar)
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
            VStack(alignment: .leading, spacing: 8) {
                Text(network.name).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("Public channels are visible only to members of this network.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            List(selection: $selectedChannelID) {
                Section("Channels") {
                    ForEach(orderedChannels) { channel in
                        HStack(spacing: 10) {
                            Image(systemName: channel.isPrivate ? "lock" : "number")
                                .font(.body.weight(.medium))
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
                        Text(isBusy ? "Loading channels…" : "No channels available. Import an updated invitation to refresh your access.")
                            .foregroundStyle(.secondary)
                    }
                }
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
                if let errorMessage {
                    Section { ALOInlineError(message: errorMessage) }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .navigationTitle(network.name)
    }

    private var orderedChannels: [ALOChannelSummary] {
        channels.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
