import SwiftUI
import ALONetworkUI

/// Deterministic public display values: this fixture never touches an account,
/// credentials, discovery, or playback. Also usable by the standalone renderer.
struct NetworkBrowserFixture: View {
    let state: String
    @State private var networkID: String? = "studio"
    @State private var channelID: String? = "main"

    private var networks: [ALONetworkSummary] {
        state == "empty" ? [] : [
            .init(id: "studio", name: state == "long" ? "Studio for collaborative music and late-night conversations" : "Studio", memberCount: 4, isOwner: true),
            .init(id: "friends", name: "Friends", memberCount: 8, isOwner: false)
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ALONetworkSidebar(networks: networks, selectedNetworkID: $networkID,
                identityName: "Raj", identityFingerprint: "public-preview-identity",
                onCreateNetwork: {}, onImportNetwork: {}, onExportPublicIdentity: {},
                nearbyNetworks: state == "empty" ? [] : [
                    .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                          name: state == "long" ? "Shyam’s network for the entire neighbourhood" : "Shyam’s network",
                          status: state == "pending" || state == "long" ? .waitingForApproval : nil)
                ], joinRequests: state == "pending" || state == "long" ? [
                    .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                          name: "Alex", networkName: "Studio", fingerprint: "public-preview-request")
                ] : [])
                .frame(width: 230)
            Divider()
            if let network = networks.first {
                VStack(spacing: 0) {
                    ALOChannelList(network: network, channels: [
                        .init(id: "main", name: "Main", isPrivate: false, isMain: true),
                        .init(id: "music", name: state == "long" ? "Music for focused work and collaborative listening sessions" : "Music", isPrivate: false),
                        .init(id: "private", name: "After hours", isPrivate: true)
                    ], selectedChannelID: $channelID, onCreateChannel: {}, onAddMember: {}, onImportInvitation: {})
                    Divider()
                    HStack {
                        Button("Members", systemImage: "person.2") {}
                        Spacer()
                        Button("Join channel", systemImage: "arrow.right.circle.fill") {}.buttonStyle(.borderedProminent)
                    }.padding(16)
                }
            } else {
                ContentUnavailableView {
                    Label("Your networks live here", systemImage: "network")
                } description: {
                    Text("Create a network for your group, or join one nearby. Your channels will appear here.")
                } actions: {
                    Button("Create network") {}.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
