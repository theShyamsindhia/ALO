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
            sheetView(selection).frame(width: 540, height: sheetHeight(selection))
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
            ZStack(alignment: .topTrailing) {
                identitySetup
                    .frame(width: geometry.size.width, height: geometry.size.height)
                Button { NSApp.keyWindow?.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(ALOBrand.neutralSoft, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(16)
                .help("Hide this window").accessibilityLabel("Hide this window")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(10)
    }

    private func sheetHeight(_ selection: Sheet) -> CGFloat {
        switch selection {
        case .createNetwork: 360
        case .importNetwork: 500
        case .addMember: invitation == nil ? 540 : 600
        case .createChannel: privateChannel ? 600 : 440
        case .members: 520
        }
    }

    private var confirmationTitle: String {
        if let pendingImport { return "Join \(pendingImport.manifest.name)?" }
        if pendingMember != nil { return "Add this person?" }
        return "Remove this person?"
    }

    private var confirmationMessage: String {
        if let pendingImport {
            return "Owner's verification code: \(ALOIdentityCode.short(pendingImport.manifest.owner.userID))\n\nAsk the owner to read their code from their profile menu. Continue only if it matches."
        }
        if let pendingMember {
            return "Their verification code: \(ALOIdentityCode.short(pendingMember.identity.userID))\n\nCheck it matches the code on their screen. They'll be able to join every public channel."
        }
        return "They lose access as soon as their devices hear about it. Devices that are offline find out the next time they connect."
    }

    private var confirmationAction: String {
        pendingImport != nil ? "Codes match, join" : pendingMember != nil ? "Codes match, add" : "Remove"
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
                onExportPublicIdentity: { perform { try savePublic(try account.publicIdentityData(),
                    name: "\(account.displayName.isEmpty ? "My" : account.displayName) - ALO public identity.json",
                    title: "Share your public identity",
                    message: "Send this file to a network owner so they can add you. It contains no secrets.") } },
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
                nowPlaying: model.phase == .live && !model.nowPlaying.isEmpty ? AnyView(nowPlayingCard) : nil,
                onSmokingStats: { model.smokingLog.showHistory() },
                onEditProfile: { model.editDeviceIdentity() },
                onCreateChannel: createChannelAction)
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
                    unreadCount: model.unreadMessageCount, isPresented: controlActiveState == .active, accent: ALOBrand.blue,
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
                NetworkConversationHeader(title: selectedChannelTitle, subtitle: "Connecting…") { channelActions }
                ALOStateView(.loading, title: "Opening \(selectedChannelTitle)…",
                             message: "Finding the people here and lining up the clock so you hear the same moment.")
            } else {
                NetworkConversationHeader(title: selectedChannelTitle, subtitle: channelSubtitle) {
                    channelActions
                    Menu { channelMenu } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Channel options")
                }
                idleConversationState
            }
            if let message = bannerMessage {
                ALOInlineError(message: message)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var selectedChannelTitle: String {
        account.channels.first(where: { $0.id.uuidString == selectedChannelID })?.name
            ?? account.selectedNetwork?.name ?? "Networks"
    }

    private var isNetworkOwner: Bool {
        account.selectedNetwork != nil
            && account.selectedNetwork?.owner.userID == account.identity?.publicIdentity.userID
    }

    private var createChannelAction: (() -> Void)? {
        guard isNetworkOwner else { return nil }
        return { present(.createChannel) }
    }

    /// Errors that belong to the whole window. A failed channel open is shown in the
    /// conversation state instead, with its own retry.
    private var bannerMessage: String? {
        let channelFailure = model.phase == .failed && selectedChannelID != nil
        return nearbyJoinFeedback.errorMessage ?? error ?? account.errorMessage
            ?? (channelFailure ? nil : model.errorMessage)
    }

    @ViewBuilder private var idleConversationState: some View {
        if model.phase == .failed, let id = selectedChannelID {
            ALOStateView(.problem, systemImage: "wifi.exclamationmark", title: "Couldn't open \(selectedChannelTitle)",
                         message: model.errorMessage ?? "Make sure you're on the same Wi-Fi as the others, then try again.") {
                Button { openChannel(id) } label: { ALOActionLabel(title: "Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.aloPrimary)
            }
        } else if account.selectedNetwork == nil {
            ALOStateView(systemImage: "person.2.wave.2.fill", title: "Listen together",
                         message: "Start a network for your group, or join one nearby from the sidebar.") {
                Button("Open invitation…") { present(.importNetwork) }.buttonStyle(.aloSecondary)
                Button { present(.createNetwork) } label: { ALOActionLabel(title: "Create network", systemImage: "plus") }
                    .buttonStyle(.aloPrimary)
            }
        } else if account.channels.isEmpty {
            if isNetworkOwner {
                ALOStateView(systemImage: "number", title: "No channels yet",
                             message: "Channels are where people listen and chat. Make one to get started.") {
                    Button { present(.createChannel) } label: { ALOActionLabel(title: "Create channel", systemImage: "plus") }
                        .buttonStyle(.aloPrimary)
                }
            } else {
                ALOStateView(systemImage: "lock", title: "No channels you can join",
                             message: "Ask the owner of \(account.selectedNetwork?.name ?? "this network") for access, then open the invitation they send.") {
                    Button("Open invitation…") { present(.importNetwork) }.buttonStyle(.aloSecondary)
                }
            }
        } else if let first = account.channels.first(where: \.isMain) ?? account.channels.first {
            ALOStateView(systemImage: "headphones", title: "Pick a channel",
                         message: "Join a channel to hear what's playing and chat with everyone in it.") {
                Button { openChannel(first.id.uuidString) } label: {
                    ALOActionLabel(title: "Join \(first.name)", systemImage: first.isPrivate ? "lock" : "number")
                }
                .buttonStyle(.aloPrimary)
            }
        }
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
        if isNetworkOwner {
            Button("Create channel…") { present(.createChannel) }
            Button("Add someone…") { present(.addMember) }
        }
        Button("People…") { present(.members) }
        Button("Open invitation…") { present(.importNetwork) }
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
                onExportInvitation: { perform { if let invitation { try savePublic(invitation.encoded(),
                    name: "\(account.selectedNetwork?.name ?? "ALO") invitation.json",
                    title: "Save invitation",
                    message: "Send this file to the person you added. It only works for them.") } } },
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
            ALOMembersView(networkName: account.selectedNetwork?.name ?? "this network", members: memberSummaries,
                canManage: isNetworkOwner, isBusy: busy, errorMessage: error,
                onRemove: { userID in
                    guard !busy, let member = account.selectedNetwork?.members.first(where: { $0.userID == userID }) else { return }
                    confirmationNetworkID = account.selectedNetwork?.id
                    removingMember = member
                },
                onAddMember: { present(.addMember) },
                onDone: { sheet = nil })
        }
    }

    /// The signed roster carries identities, not names, so other people are labelled by role
    /// and shown with their verification code.
    private var memberSummaries: [ALOMemberSummary] {
        (account.selectedNetwork?.members ?? []).map { member in
            let isCurrentUser = member.identity == account.identity?.publicIdentity
            let isOwner = member.role == .owner
            return ALOMemberSummary(id: member.userID,
                name: isCurrentUser ? account.displayName : (isOwner ? "Network owner" : "Member"),
                fingerprint: member.userID, isCurrentUser: isCurrentUser, isOwner: isOwner)
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
            panel.message = "Anyone with this file can sign in as you. Keep it somewhere private."
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
        panel.message = "Choose the file someone sent you."; panel.prompt = "Open"
        panel.allowedContentTypes = [.plainText, .json, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try action(url) }
    }

    private func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maximum + 1), data.count <= maximum else { throw NetworkAuthorityError.limitExceeded }
        return data
    }

    private func savePublic(_ data: Data, name: String, title: String, message: String) throws {
        let safeName = name.map { "/:\\".contains($0) ? "-" : $0 }
        let panel = NSSavePanel(); panel.nameFieldStringValue = String(safeName); panel.allowedContentTypes = [.json]
        panel.title = title; panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }
}
