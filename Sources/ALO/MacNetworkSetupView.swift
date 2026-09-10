import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ALOIdentity
import ALORooms
import ALOAppModel
import ALONetworkUI
import ALOCore

@MainActor
struct MacNetworkSetupView: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @ObservedObject var model: ALOViewModel
    @ObservedObject var account: NetworkAccountModel
    @State private var sheet: Sheet?
    @State private var name = ""
    @State private var packageText = ""
    @State private var recoveryImport = ""
    @State private var recoveryExported = false
    @State private var busy = false
    @State private var error: String?
    @State private var nearbyJoinFeedback = ALONearbyJoinFeedback()
    @State private var selectedChannelID: String?
    @State private var pendingChannelID: String?
    @State private var privateChannel = false
    @State private var allowed = Set<String>()
    @State private var invitation: NetworkInvitation?
    @State private var pendingImport: NetworkInvitation?
    @State private var pendingMember: NetworkMembershipRequest?
    @State private var removingMember: NetworkMember?
    @State private var confirmationNetworkID: UUID?
    private enum Sheet: String, Identifiable { case createNetwork, importNetwork, addMember, createChannel, members; var id: Self { self } }

    var body: some View {
        Group {
            if account.identityReady {
                // The native window owns its dimensions. Keep the original
                // geometry proposal without the old card/header: otherwise
                // List's intrinsic size can enlarge NSHostingView's window.
                GeometryReader { geometry in
                    networkBrowser.frame(width: geometry.size.width, height: geometry.size.height)
                }
                .ignoresSafeArea()
            } else {
                onboardingContainer
            }
        }
        .sheet(item: $sheet) { selection in
            sheetView(selection).frame(width: 600, height: 520)
                .interactiveDismissDisabled(busy)
                .alert(confirmationTitle, isPresented: Binding(
                    get: { pendingImport != nil || pendingMember != nil || removingMember != nil },
                    set: { if !$0 { clearConfirmation() } })) {
                    Button("Cancel", role: .cancel, action: clearConfirmation)
                        .disabled(busy)
                    Button(confirmationAction, role: removingMember == nil ? nil : .destructive) {
                        confirmAction()
                    }
                    .disabled(busy)
                } message: { Text(confirmationMessage) }
        }
        .onChange(of: account.selectedNetworkID) { _, _ in
            selectedChannelID = account.channels.contains(where: { $0.id.uuidString == model.selectedRoomID }) ? model.selectedRoomID : nil
            clearConfirmation()
        }
        .onAppear {
            selectedChannelID = model.phase == .live ? model.selectedRoomID : nil
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .live, selectedChannelID == nil,
               account.channels.contains(where: { $0.id.uuidString == model.selectedRoomID }) {
                selectedChannelID = model.selectedRoomID
            }
            if phase == .idle, let id = pendingChannelID {
                pendingChannelID = nil
                model.joinChannel(id)
            } else if phase == .idle {
                selectedChannelID = nil
            }
        }
        .onDisappear { pendingChannelID = nil }
    }

    private var onboardingContainer: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            HStack {
                Text("ALO").font(.title3.weight(.bold))
                Text("Set up ALO").foregroundStyle(.secondary)
                Spacer()
                Button { NSApp.keyWindow?.close() } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }
                    .help("Hide this window").accessibilityLabel("Hide this window")
            }.buttonStyle(.borderless).controlSize(.large)
                .padding(18)
            Divider()
            identitySetup
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .padding(10)
    }

    private var confirmationTitle: String {
        if pendingImport != nil { return "Trust this network owner?" }
        if pendingMember != nil { return "Add this identity to the network?" }
        return "Remove network member?"
    }

    private var confirmationMessage: String {
        if let pendingImport {
            return "\(pendingImport.manifest.name)\nOwner: \(pendingImport.manifest.owner.userID)\n\nConfirm the owner's full fingerprint through a trusted exchange before importing."
        }
        if let pendingMember {
            return "\(pendingMember.identity.userID)\n\nVerify this public identity with the person. All devices they authorize will gain access to public channels."
        }
        return "Their devices lose access when they learn this signed policy. Disconnected devices must reconnect to an updated peer to learn about the removal."
    }

    private var confirmationAction: String {
        pendingImport != nil ? "Trust owner and import" : pendingMember != nil ? "Add verified member" : "Remove member"
    }

    private func clearConfirmation() {
        pendingImport = nil; pendingMember = nil; removingMember = nil; confirmationNetworkID = nil
    }

    private func confirmAction() {
        guard !busy else { return }
        let pendingImport = pendingImport, pendingMember = pendingMember
        let removingMember = removingMember, confirmationNetworkID = confirmationNetworkID
        clearConfirmation()
        performAsync {
            if let pendingImport {
                _ = try await account.importInvitation(data: pendingImport.encoded())
                sheet = nil; selectedChannelID = account.channels.first?.id.uuidString
            } else if let pendingMember, let confirmationNetworkID {
                invitation = try await account.addMember(data: pendingMember.encoded(), networkID: confirmationNetworkID)
            } else if let removingMember, let confirmationNetworkID {
                try await account.removeMember(userID: removingMember.userID, networkID: confirmationNetworkID)
            }
        }
    }

    private var identitySetup: some View {
        ALOIdentitySetupView(stage: account.identity == nil ? .identity : .recovery,
            displayName: $account.displayName, recoveryImportText: $recoveryImport,
            recoveryExported: recoveryExported, isBusy: busy, errorMessage: error ?? account.errorMessage,
            onCreateIdentity: { perform { try account.createIdentity() } },
            onRestoreIdentity: { perform { try account.restoreIdentity(data: Data(recoveryImport.utf8)); recoveryImport = "" } },
            onImportRecoveryFile: {
                openFile { url in
                    let identity = try IdentityRecoveryDocument.restore(fromFile: url)
                    try account.restoreIdentity(data: IdentityRecoveryDocument(identity: identity).serializedData())
                    recoveryImport = ""
                }
            },
            onExportRecovery: exportRecovery,
            onContinue: { performAsync { try await account.completeIdentitySetup(); recoveryImport = "" } })
    }

    private var networkBrowser: some View {
        ALONativeNetworkColumns {
            ALONetworkSidebar(networks: account.networks.map(summary), selectedNetworkID: $account.selectedNetworkID,
                identityName: account.displayName, identityFingerprint: account.identity?.publicIdentity.userID ?? "",
                onCreateNetwork: { present(.createNetwork) }, onImportNetwork: { present(.importNetwork) },
                onExportPublicIdentity: { perform { try savePublic(try account.publicIdentityData(), name: "ALO-public-identity.json") } },
                nearbyNetworks: account.nearbyNetworks.map { .init(id: $0.id, name: $0.name, status: account.joinRequestStatus[$0.id].map(joinState)) },
                joinRequests: account.pendingJoinRequests.map { request in
                    .init(id: request.id, name: request.displayName,
                          networkName: account.networks.first(where: { $0.id == request.networkID })?.name ?? "your network",
                          fingerprint: request.identity.userID)
                }, isBusy: busy,
                onJoin: { id in
                    let attempt = nearbyJoinFeedback.begin()
                    Task { @MainActor in
                        do {
                            try await account.requestToJoin(networkID: id)
                            nearbyJoinFeedback.finish(attempt)
                        } catch is CancellationError { nearbyJoinFeedback.finish(attempt) }
                        catch { nearbyJoinFeedback.finish(attempt, errorMessage: NetworkAccountModel.describe(error)) }
                    }
                },
                onApprove: { id in performAsync { try await account.approveJoinRequest(id: id) } },
                onDecline: { id in performAsync { try await account.rejectJoinRequest(id: id) } },
                nearbyError: account.nearbyNetworkError,
                nearbyNotice: account.nearbyNetworkNotice,
                onRetryNearby: { Task { @MainActor in account.stopNearbyNetworking(); await account.startNearbyNetworking() } },
                onCancelJoin: { id in nearbyJoinFeedback.cancel(); account.cancelJoinRequest(networkID: id) },
                onExportRecovery: exportRecovery,
                channels: account.channels.map { .init(id: $0.id.uuidString, name: $0.name, isPrivate: $0.isPrivate, isMain: $0.isMain) },
                selectedChannelID: selectedChannelID,
                onOpenChannel: openChannel,
                nowPlaying: model.phase == .live && !model.nowPlaying.isEmpty ? AnyView(nowPlayingCard) : nil)
                .disabled(model.phase == .starting)
        } detail: {
            channelConversation
        }
    }

    private func openChannel(_ id: String) {
        guard model.phase != .starting, account.channels.contains(where: { $0.id.uuidString == id }) else { return }
        selectedChannelID = id
        if model.phase == .live, model.selectedRoomID == id { return }
        if model.phase == .live {
            pendingChannelID = id
            model.stop()
        } else {
            if model.phase == .failed { model.tryAgain() }
            model.joinChannel(id)
        }
    }

    private var channelConversation: some View {
        VStack(spacing: 0) {
            if model.phase == .live, selectedChannelID == model.selectedRoomID {
                RoomChatPanel(messages: model.messages, currentParticipantID: model.currentParticipantID,
                    roomTitle: selectedChannelTitle, firstUnreadMessageID: model.firstUnreadMessageID,
                    unreadCount: model.unreadMessageCount, isPresented: controlActiveState == .active, accent: .blue,
                    onLatestVisibilityChanged: model.setChatViewportAtLatest, send: model.sendChatOperation,
                    sendAttachment: model.sendChatAttachment, attachmentURL: model.chatAttachmentURL,
                    draft: $model.draftMessage, notificationMode: $model.chatNotificationMode,
                    mentionNames: model.participants.map(\.name),
                    mentionMembers: model.participants.filter { $0.id != model.currentParticipantID }
                        .map { RoomMentionMember(id: $0.id, name: $0.name) },
                    usesNativeLayout: true, subtitle: channelSubtitle,
                    headerActions: AnyView(channelActions), channelMenu: AnyView(channelMenu))
                    .id(model.selectedRoomID)
            } else if model.phase == .starting {
                NetworkConversationHeader(title: selectedChannelTitle, subtitle: "Opening channel…") { channelActions }
                ProgressView("Opening channel…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NetworkConversationHeader(title: selectedChannelTitle, subtitle: channelSubtitle) {
                    channelActions
                    Menu { channelMenu } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Channel options")
                }
                ContentUnavailableView("Choose a channel", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Open a channel in the sidebar to join the conversation."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = nearbyJoinFeedback.errorMessage ?? error ?? account.errorMessage ?? model.errorMessage {
                Text(message).foregroundStyle(.secondary).padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var selectedChannelTitle: String {
        account.channels.first(where: { $0.id.uuidString == selectedChannelID })?.name
            ?? account.selectedNetwork?.name ?? "Spaces"
    }

    private var channelSubtitle: String {
        if model.phase == .live, selectedChannelID == model.selectedRoomID {
            return "\(account.selectedNetwork?.name ?? "") · \(model.participants.count) people connected"
        }
        return account.selectedNetwork == nil ? "Your people, nearby." : "Choose a channel to connect"
    }

    @ViewBuilder private var channelActions: some View {
        if account.selectedNetwork != nil {
            Button { present(.members) } label: { Image(systemName: "person.2").frame(width: 28, height: 32) }
                .help("Members").accessibilityLabel("Members")
            if model.phase == .live, selectedChannelID == model.selectedRoomID {
                Button { model.showWalkieBar() } label: { Image(systemName: "mic").frame(width: 28, height: 32) }
                    .help("Voice controls").accessibilityLabel("Voice controls")
                Button { model.toggleVideoFromFloatingBar() } label: {
                    Image(systemName: "display").frame(width: 28, height: 32)
                }.help("Share screen").accessibilityLabel("Share screen")
            }
        }
    }

    @ViewBuilder private var channelMenu: some View {
        if account.selectedNetwork?.owner.userID == account.identity?.publicIdentity.userID,
           account.selectedNetwork != nil {
            Button("Create channel…") { present(.createChannel) }
            Button("Add member…") { present(.addMember) }
        }
        Button("Import invitation…") { present(.importNetwork) }
        if model.phase == .live { Button("Leave channel") { model.stop() } }
    }

    private var nowPlayingCard: some View {
        NetworkNowPlayingCard(title: model.nowPlaying.title ?? "Shared audio", artist: model.nowPlaying.artist,
            channel: account.channels.first(where: { $0.id.uuidString == model.selectedRoomID })?.name ?? model.roomTitle,
            artwork: model.nowPlaying.artworkData, isPlaying: model.nowPlaying.isPlaying != false) {
                if let id = model.selectedRoomID,
                   let network = account.networks.first(where: { $0.channels.contains(where: { $0.id.uuidString == id }) }) {
                    account.selectedNetworkID = network.id.uuidString
                    openChannel(id)
                }
            }
    }

    @ViewBuilder private func sheetView(_ selection: Sheet) -> some View {
        switch selection {
        case .createNetwork:
            ALOCreateNetworkView(name: $name, isBusy: busy, errorMessage: error, onCreate: {
                performAsync { _ = try await account.createNetwork(name: name); sheet = nil; selectedChannelID = account.channels.first?.id.uuidString }
            }, onCancel: { sheet = nil })
        case .importNetwork:
            ALOImportInvitationView(invitationText: $packageText, isBusy: busy, errorMessage: error,
                onImport: { perform { pendingImport = try NetworkInvitation.decode(Data(packageText.utf8)) } },
                onImportFile: { openFile { url in packageText = String(decoding: try boundedRead(url, maximum: NetworkManifest.maximumEncodedBytes + 4096), as: UTF8.self) } },
                onCancel: { sheet = nil })
        case .addMember:
            ALOAddMemberView(networkName: account.selectedNetwork?.name ?? "", publicIdentityText: $packageText,
                recipient: invitation.map { ALOMemberSummary(id: $0.recipient.userID, name: "Invited member", fingerprint: $0.recipient.userID) },
                invitationText: invitation.flatMap { try? String(decoding: $0.encoded(), as: UTF8.self) }, isBusy: busy, errorMessage: error,
                onCreateInvitation: { perform {
                    guard let network = account.selectedNetwork else { throw NetworkAccountError.channelUnavailable }
                    pendingMember = try NetworkMembershipRequest.decode(Data(packageText.utf8))
                    confirmationNetworkID = network.id
                } },
                onImportPublicIdentityFile: { openFile { url in packageText = String(decoding: try boundedRead(url, maximum: 4096), as: UTF8.self) } },
                onExportInvitation: { perform { if let invitation { try savePublic(invitation.encoded(), name: "ALO-network-invitation.json") } } },
                onCancel: { sheet = nil })
        case .createChannel:
            ALOCreateChannelView(networkName: account.selectedNetwork?.name ?? "", name: $name, isPrivate: $privateChannel,
                selectedMemberIDs: $allowed, members: memberSummaries, isBusy: busy, errorMessage: error, onCreate: {
                    guard let networkID = account.selectedNetwork?.id else {
                        error = NetworkAccountModel.describe(NetworkAccountError.channelUnavailable)
                        return
                    }
                    let channelName = name, visibility = privateChannel, allowedIDs = Array(allowed)
                    performAsync {
                        try await account.createChannel(name: channelName, networkID: networkID, isPrivate: visibility, allowedUserIDs: allowedIDs)
                        sheet = nil
                    }
                }, onCancel: { sheet = nil })
        case .members:
            VStack(alignment: .leading) {
                Text("Network members").font(.title2).padding()
                List(account.selectedNetwork?.members ?? [], id: \.userID) { member in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(member.role == .owner ? "Owner" : "Member").font(.headline)
                            Text(member.userID).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Spacer()
                        if account.selectedNetwork?.owner == account.identity?.publicIdentity, member.role != .owner {
                            Button("Remove", role: .destructive) {
                                guard !busy else { return }
                                confirmationNetworkID = account.selectedNetwork?.id
                                removingMember = member
                            }
                            .disabled(busy)
                        }
                    }.padding(.vertical, 8)
                }
                if let error { Text(error).foregroundStyle(.red).padding() }
                HStack { Spacer(); Button("Done") { sheet = nil }.keyboardShortcut(.cancelAction).disabled(busy) }.padding()
            }
        }
    }

    private var memberSummaries: [ALOMemberSummary] {
        (account.selectedNetwork?.members ?? []).map { member in
            ALOMemberSummary(id: member.userID, name: member.identity == account.identity?.publicIdentity ? account.displayName : "Member \(member.userID.suffix(8))",
                fingerprint: member.userID, isCurrentUser: member.identity == account.identity?.publicIdentity)
        }
    }

    private func joinState(_ state: NetworkJoinState) -> ALONearbyJoinState {
        switch state {
        case .waitingForApproval: .waitingForApproval
        case .joined: .joined
        case .cancelled: .cancelled
        case .failed(let message): .failed(message)
        }
    }

    private func summary(_ network: NetworkManifest) -> ALONetworkSummary {
        ALONetworkSummary(id: network.id.uuidString, name: network.name, memberCount: network.members.count,
            isOwner: network.owner == account.identity?.publicIdentity)
    }

    private func present(_ next: Sheet) {
        guard !busy else { return }
        // Retire screen feedback only; the account's join request is untouched.
        nearbyJoinFeedback.cancel()
        error = nil; name = ""; packageText = ""; invitation = nil; privateChannel = false; allowed = []; sheet = next
    }

    private func perform(_ action: () throws -> Void) {
        guard !busy else { return }
        do { error = nil; try action() } catch { self.error = NetworkAccountModel.describe(error) }
    }

    private func performAsync(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { self.error = NetworkAccountModel.describe(error) }
        }
    }

    private func exportRecovery() {
        perform {
            guard let identity = account.identity else { throw NetworkAccountError.setupRequired }
            let panel = NSSavePanel()
            panel.title = "Save your recovery key"
            panel.message = "Anyone with this file can impersonate you. Save it privately."
            panel.nameFieldStringValue = "ALO-identity-\(identity.publicIdentity.userID.suffix(8)).txt"
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try IdentityRecoveryDocument(identity: identity).export(to: url)
            recoveryExported = true
        }
    }

    private func openFile(_ action: (URL) throws -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .json, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try action(url) }
    }

    private func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maximum + 1), data.count <= maximum else { throw NetworkAuthorityError.limitExceeded }
        return data
    }

    private func savePublic(_ data: Data, name: String) throws {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }
}
