import SwiftUI
import UniformTypeIdentifiers
import ALOAppModel
import ALOIdentity
import ALORooms
import ALONetworkUI

/// The iOS adapter owns document pickers; shared views receive only display values
/// and actions. No recovery key or invitation is sent to a server or the log.
struct MobileNetworkSetupView: View {
    @ObservedObject var account: NetworkAccountModel
    @ObservedObject var model: MobileRoomModel
    @State private var path: [Route] = []
    @State private var recoveryImportText = ""
    @State private var recoveryText: String?
    @State private var recoveryExported = false
    @State private var invitationText = ""
    @State private var publicIdentityText = ""
    @State private var preparedInvitation: NetworkInvitation?
    @State private var preparedInvitationText: String?
    @State private var pendingConfirmation: TrustConfirmation?
    @State private var networkName = ""
    @State private var channelName = ""
    @State private var privateChannel = false
    @State private var selectedMemberIDs = Set<String>()
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var importKind = ImportKind.invitation
    @State private var showImporter = false
    @State private var exportDocument: MobileNetworkDocument?
    @State private var exportFilename = "ALO invitation.txt"
    @State private var exportingRecovery = false
    @State private var showExporter = false

    private enum Route: Hashable {
        case channels, createNetwork, importInvitation, addMember(UUID), createChannel(UUID)
    }
    private enum ImportKind { case recovery, invitation, publicIdentity }

    /// Retain the verified public document and its destination while the user checks the fingerprint.
    /// Confirmation must never reread editable input or use a newly selected network.
    private enum TrustConfirmation {
        case invitation(NetworkInvitation)
        case member(NetworkMembershipRequest, networkID: UUID, networkName: String)

        var title: String {
            switch self {
            case .invitation: return "Trust this network owner?"
            case .member: return "Add this identity to the network?"
            }
        }

        var message: String {
            switch self {
            case .invitation(let invitation):
                return "Network: \(invitation.manifest.name)\n\nOwner fingerprint:\n\(invitation.manifest.owner.userID)\n\nCompare this full fingerprint with the owner through a trusted conversation. Import only when they match."
            case .member(let request, _, let name):
                return "Network: \(name)\n\nMember fingerprint:\n\(request.identity.userID)\n\nCompare this full fingerprint with the person through a trusted conversation. All devices they authorize will gain access to public channels."
            }
        }

        var actionTitle: String {
            switch self {
            case .invitation: return "Trust owner and import"
            case .member: return "Add verified member"
            }
        }

        var actionIdentifier: String {
            switch self {
            case .invitation: return "ALO.Network.ConfirmOwnerFingerprint"
            case .member: return "ALO.Network.ConfirmMemberFingerprint"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if account.identityReady { networkSidebar }
                else { identitySetup }
            }
            .navigationDestination(for: Route.self) { route in
                destination(route).navigationBarBackButtonHidden(busy)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .json, .data]) { result in
            switch result {
            case .success(let url): importFile(url)
            case .failure(let error): errorMessage = "The file could not be opened. \(error.localizedDescription)"
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: .plainText, defaultFilename: exportFilename) { result in
            switch result {
            case .success:
                if exportingRecovery { recoveryExported = true }
                errorMessage = nil
            case .failure(let error):
                errorMessage = "The file could not be exported. Retry with the same prepared document. \(error.localizedDescription)"
            }
            exportDocument = nil
            exportingRecovery = false
        }
        .alert(pendingConfirmation?.title ?? "Verify public identity", isPresented: Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }), presenting: pendingConfirmation) { confirmation in
                Button("Cancel", role: .cancel) { pendingConfirmation = nil }
                    .accessibilityIdentifier("ALO.Network.CancelFingerprintConfirmation")
                Button(confirmation.actionTitle) { confirm(confirmation) }
                    .accessibilityIdentifier(confirmation.actionIdentifier)
            } message: { confirmation in
                Text(confirmation.message)
            }
        .safeAreaInset(edge: .bottom) {
            if account.identityReady, path.isEmpty || path.last == .channels,
               let message = errorMessage ?? account.errorMessage ?? model.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle")
                    Button("Dismiss message") { errorMessage = nil; model.errorMessage = nil }
                }
                .font(.callout).padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
            }
        }
        .onChange(of: account.identityReady) { _, ready in
            if ready { recoveryText = nil; recoveryImportText = ""; model.activate() }
        }
        .onChange(of: path) { _, _ in pendingConfirmation = nil }
    }

    private var identitySetup: some View {
        ALOIdentitySetupView(stage: account.identity == nil ? .identity : .recovery,
            displayName: $account.displayName, recoveryImportText: $recoveryImportText,
            fingerprint: account.identity?.publicIdentity.userID, recoveryText: recoveryText,
            recoveryExported: recoveryExported, isBusy: busy,
            errorMessage: errorMessage ?? account.errorMessage,
            onCreateIdentity: { perform { try account.createIdentity() } },
            onRestoreIdentity: { perform {
                try account.restoreIdentity(data: Data(recoveryImportText.utf8))
                recoveryImportText = ""
            } },
            onImportRecoveryFile: { chooseFile(.recovery) },
            onRevealRecovery: { perform {
                recoveryText = String(decoding: try account.recoveryData(), as: UTF8.self)
            } },
            onExportRecovery: { prepareExport(recovery: true) { try account.recoveryData() } },
            onContinue: { perform { try account.completeIdentitySetup() } })
    }

    private var networkSidebar: some View {
        ALONetworkSidebar(networks: account.networks.map(summary),
            selectedNetworkID: Binding(get: { account.selectedNetworkID }, set: { id in
                account.selectedNetworkID = id
                if id != nil { path = [.channels] }
            }), identityName: account.displayName,
            identityFingerprint: account.identity?.publicIdentity.userID ?? "",
            onCreateNetwork: { networkName = ""; errorMessage = nil; path.append(.createNetwork) },
            onImportNetwork: openInvitationImport,
            onExportPublicIdentity: { prepareExport(recovery: false, filename: "ALO public identity.txt") {
                try account.publicIdentityData()
            } })
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .channels:
            if let network = account.selectedNetwork {
                ALOChannelList(network: summary(network), channels: account.channels.map {
                    ALOChannelSummary(id: $0.id.uuidString, name: $0.name, isPrivate: $0.isPrivate, isMain: $0.isMain)
                }, selectedChannelID: Binding(get: { model.room?.id }, set: { id in
                    if let id { model.joinChannel(id) }
                }), isBusy: busy,
                onCreateChannel: {
                    channelName = ""; privateChannel = false; selectedMemberIDs = []
                    errorMessage = nil; path.append(.createChannel(network.id))
                }, onAddMember: {
                    publicIdentityText = ""; preparedInvitation = nil; preparedInvitationText = nil
                    errorMessage = nil; path.append(.addMember(network.id))
                }, onImportInvitation: openInvitationImport)
                .safeAreaInset(edge: .bottom) {
                    Text("Joining connects to nearby devices and may ask for Local Network access. Your microphone stays off until you choose Talk or Open Line.")
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
            } else {
                ContentUnavailableView("Network unavailable", systemImage: "person.2.slash",
                    description: Text("Return to Networks and import an updated invitation."))
            }
        case .createNetwork:
            ALOCreateNetworkView(name: $networkName, isBusy: busy, errorMessage: errorMessage,
                onCreate: { perform {
                    try account.createNetwork(name: networkName)
                    path = [.channels]
                } }, onCancel: goBack)
        case .importInvitation:
            ALOImportInvitationView(invitationText: $invitationText, isBusy: busy, errorMessage: errorMessage,
                onImport: { perform {
                    let invitation = try NetworkInvitation.decode(Data(invitationText.utf8))
                    guard invitation.recipient == account.identity?.publicIdentity else {
                        throw NetworkAuthorityError.wrongRecipient
                    }
                    pendingConfirmation = .invitation(invitation)
                } }, onImportFile: { chooseFile(.invitation) }, onCancel: goBack)
        case .addMember(let networkID):
            if let network = account.networks.first(where: { $0.id == networkID }) {
                ALOAddMemberView(networkName: network.name, publicIdentityText: $publicIdentityText,
                    recipient: preparedInvitation.map { memberSummary($0.recipient) },
                    invitationText: preparedInvitationText, isBusy: busy, errorMessage: errorMessage,
                    onCreateInvitation: { perform {
                        guard network.owner == account.identity?.publicIdentity else {
                            throw NetworkAuthorityError.ownerRequired
                        }
                        let request = try NetworkMembershipRequest.decode(Data(publicIdentityText.utf8))
                        pendingConfirmation = .member(request, networkID: networkID, networkName: network.name)
                    } }, onImportPublicIdentityFile: { chooseFile(.publicIdentity) },
                    onExportInvitation: {
                        prepareExport(recovery: false, filename: "ALO network invitation.txt") {
                            guard let preparedInvitation else { throw NetworkAccountError.channelUnavailable }
                            return try preparedInvitation.encoded()
                        }
                    }, onCancel: goBack)
            }
        case .createChannel(let networkID):
            if let network = account.networks.first(where: { $0.id == networkID }) {
                ALOCreateChannelView(networkName: network.name, name: $channelName,
                    isPrivate: $privateChannel, selectedMemberIDs: $selectedMemberIDs,
                    members: network.members.map { memberSummary($0.identity) },
                    isBusy: busy, errorMessage: errorMessage,
                    onCreate: { perform {
                        try account.createChannel(name: channelName, networkID: networkID,
                            isPrivate: privateChannel, allowedUserIDs: Array(selectedMemberIDs))
                        goBack()
                    } }, onCancel: goBack)
            }
        }
    }

    private func summary(_ network: NetworkManifest) -> ALONetworkSummary {
        ALONetworkSummary(id: network.id.uuidString, name: network.name, memberCount: network.members.count,
            isOwner: network.owner == account.identity?.publicIdentity)
    }

    private func memberSummary(_ identity: PublicUserIdentity) -> ALOMemberSummary {
        let isCurrentUser = identity == account.identity?.publicIdentity
        return ALOMemberSummary(id: identity.userID,
            name: isCurrentUser ? account.displayName : "Member \(identity.userID.suffix(8))",
            fingerprint: identity.userID, isCurrentUser: isCurrentUser)
    }

    private func openInvitationImport() {
        invitationText = ""; errorMessage = nil; path.append(.importInvitation)
    }

    private func confirm(_ confirmation: TrustConfirmation) {
        pendingConfirmation = nil
        perform {
            switch confirmation {
            case .invitation(let invitation):
                try account.importInvitation(data: invitation.encoded())
                invitationText = ""; path = [.channels]
            case .member(let request, let networkID, _):
                let invitation = try account.addMember(data: request.encoded(), networkID: networkID)
                preparedInvitation = invitation
                preparedInvitationText = String(decoding: try invitation.encoded(), as: UTF8.self)
            }
        }
    }

    private func goBack() {
        guard !path.isEmpty else { return }
        errorMessage = nil
        path.removeLast()
    }

    private func perform(_ action: @escaping @MainActor () throws -> Void) {
        guard !busy else { return }
        busy = true; errorMessage = nil
        Task { @MainActor in
            await Task.yield()
            defer { busy = false }
            do { try action() }
            catch { errorMessage = NetworkAccountModel.describe(error) }
        }
    }

    private func chooseFile(_ kind: ImportKind) {
        importKind = kind; errorMessage = nil; showImporter = true
    }

    private func importFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let limit: Int
            switch importKind {
            case .recovery: limit = IdentityRecoveryDocument.maximumByteCount
            case .publicIdentity: limit = 4096
            case .invitation: limit = NetworkManifest.maximumEncodedBytes + 4096
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: limit + 1) ?? Data()
            guard bytes.count <= limit, let text = String(data: bytes, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            switch importKind {
            case .recovery: recoveryImportText = text
            case .invitation: invitationText = text
            case .publicIdentity: publicIdentityText = text
            }
            errorMessage = nil
        } catch {
            errorMessage = "The selected file could not be read. Choose a complete ALO text document and retry."
        }
    }

    private func prepareExport(recovery: Bool, filename: String = "ALO private recovery kit.txt", data: () throws -> Data) {
        do {
            exportDocument = MobileNetworkDocument(data: try data())
            exportingRecovery = recovery
            exportFilename = filename
            errorMessage = nil; showExporter = true
        } catch { errorMessage = NetworkAccountModel.describe(error) }
    }
}

private struct MobileNetworkDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.fileAttributes = [FileAttributeKey.posixPermissions.rawValue: 0o600,
                                  FileAttributeKey.protectionKey.rawValue: FileProtectionType.complete]
        return wrapper
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Only the explicit simulator launch flag selects this store. Onboarding still
/// creates/restores the identity through the same UI and account code paths.
final class MobileTemporaryIdentityStorage: UserIdentityKeyStorage {
    private var data: Data?
    func loadPrivateKey() throws -> Data? { data }
    func insertPrivateKeyIfAbsent(_ bytes: Data) throws -> Bool {
        guard data == nil else { return false }
        data = bytes
        return true
    }
}
#endif
