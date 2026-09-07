import Foundation
import Combine
import ALOCore
import ALOIdentity
import ALORooms
import ALONetworking

public enum NetworkAccountError: LocalizedError {
    case setupRequired, nameRequired, nameTooLong, channelUnavailable
    public var errorDescription: String? {
        switch self {
        case .setupRequired: return "Set up your ALO identity and save its recovery file first."
        case .nameRequired: return "Enter a name between 1 and 80 characters, without control characters."
        case .nameTooLong: return "This name is too long for a device identity. Use fewer emoji or accented characters."
        case .channelUnavailable: return "This channel is unavailable or your identity no longer has access."
        }
    }
}

/// The shared application API for identity, networks and channels. Platform
/// adapters own file pickers/audio/UI; they never invent room membership from
/// discovery records. No legacy Spaces are loaded into this generation.
@MainActor
public final class NetworkAccountModel: ObservableObject {
    @Published public private(set) var identity: UserIdentity?
    @Published public private(set) var identityReady = false
    @Published public private(set) var networks = [NetworkManifest]()
    @Published public private(set) var networkRecordDiagnostics = [NetworkRepository.RecordDiagnostic]()
    @Published public private(set) var additionalNetworkRecordDiagnosticCount = 0
    @Published public private(set) var errorMessage: String?
    @Published public var displayName = ""
    @Published public var selectedNetworkID: String? {
        didSet { if !updatingSelection { accessLossNotice = nil } }
    }
    public let repository: NetworkRepository
    private let defaults: UserDefaults
    private let suppliedStore: UserIdentityStore?
    private var identityGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var updatingSelection = false
    private var accessLossNotice: (networkID: UUID, message: String)?
    private lazy var worker = NetworkAccountRepositoryWorker(repository: repository) { [weak self] in
        Task { @MainActor [weak self] in await self?.refresh() }
    }
    private static let completedKey = "alo.networks-v1.identitySetupComplete"
    private static let preparedKey = "alo.networks-v1.identityPrepared"
    private static let displayNameKey = "alo.networks-v1.identityDisplayName"

    public init(defaults: UserDefaults = .standard, repository: NetworkRepository = NetworkRepository(),
                identityStore: UserIdentityStore? = nil) {
        self.defaults = defaults; self.repository = repository; suppliedStore = identityStore
        displayName = defaults.string(forKey: Self.displayNameKey) ?? ""
    }

    private func store() throws -> UserIdentityStore {
        if let suppliedStore { return suppliedStore }
        let bundle = Bundle.main.bundleIdentifier ?? "in.werai.audio"
        let namespace = try UserIdentityKeychainNamespace(applicationID: bundle,
            environment: bundle == "in.werai.audio.dev" ? .development : .production)
        return UserIdentityStore(storage: KeychainUserIdentityStorage(namespace: namespace))
    }

    /// Only an explicitly prepared new-generation account may resume. Merely
    /// browsing/discovering never creates a root key or imports an old device.
    public func resume() async {
        identityGeneration &+= 1
        guard defaults.bool(forKey: Self.preparedKey) || defaults.bool(forKey: Self.completedKey) else {
            clearLoadedIdentity()
            return
        }
        do {
            try validateName()
            guard let loaded = try store().load() else { throw NetworkAccountError.setupRequired }
            identity = loaded
            identityReady = defaults.bool(forKey: Self.completedKey)
            await refresh()
        } catch { clearLoadedIdentity(); errorMessage = Self.describe(error) }
    }

    public func createIdentity() throws {
        try validateName()
        identity = try store().loadOrCreateForOnboarding()
        identityGeneration &+= 1
        defaults.set(true, forKey: Self.preparedKey)
        defaults.set(displayName, forKey: Self.displayNameKey)
        errorMessage = nil
    }

    public func restoreIdentity(data: Data) throws {
        try validateName()
        identity = try store().restoreForOnboarding(from: data)
        identityGeneration &+= 1
        defaults.set(true, forKey: Self.preparedKey)
        defaults.set(displayName, forKey: Self.displayNameKey)
        errorMessage = nil
    }

    public func recoveryData() throws -> Data {
        guard let identity else { throw NetworkAccountError.setupRequired }
        return IdentityRecoveryDocument(identity: identity).serializedData()
    }

    /// UI calls this only after the recovery acknowledgement. Re-export is safe:
    /// retries always use the same prepared root, never generate another account.
    public func completeIdentitySetup() async throws {
        guard identity != nil else { throw NetworkAccountError.setupRequired }
        try validateName()
        defaults.set(displayName, forKey: Self.displayNameKey)
        defaults.set(true, forKey: Self.completedKey)
        identityReady = true
        await refresh()
    }

    public var selectedNetwork: NetworkManifest? { networks.first { $0.id.uuidString == selectedNetworkID } }
    public var channels: [NetworkChannel] {
        guard let identity, let selectedNetwork else { return [] }
        return (try? selectedNetwork.accessibleChannels(for: identity.publicIdentity)) ?? []
    }

    public func refresh() async {
        refreshGeneration &+= 1
        let request = refreshGeneration
        let identityToken = identityGeneration
        guard identityReady, let identity else {
            networks = []; selectedNetworkID = nil
            networkRecordDiagnostics = []; additionalNetworkRecordDiagnosticCount = 0
            return
        }
        let selectedID = selectedNetworkID.flatMap(UUID.init(uuidString:))
        do {
            let result = try await worker.perform { worker in
                let listing = try worker.repository.listing(for: identity.publicIdentity)
                var selectionError: Error?
                if let selectedID, !listing.networks.contains(where: { $0.id == selectedID }) {
                    if let diagnostic = listing.diagnostics.first(where: { $0.networkID == selectedID }) {
                        selectionError = diagnostic.reason == .quarantined
                            ? NetworkAuthorityError.quarantined : NetworkAuthorityError.invalidStorage
                    } else {
                        do {
                            let previous = try worker.repository.trustedManifest(id: selectedID)
                            if !previous.isMember(identity.publicIdentity) { selectionError = NetworkAuthorityError.notMember }
                        } catch { selectionError = error }
                    }
                }
                return NetworkAccountListing(listing: listing, selectionMessage: selectionError.map(Self.describe))
            }
            guard request == refreshGeneration, identityToken == identityGeneration, !Task.isCancelled else { return }
            let listing = result.listing
            let visible = listing.networks
            networkRecordDiagnostics = listing.diagnostics
            additionalNetworkRecordDiagnosticCount = listing.omittedDiagnosticCount
            let selectionMessage = selectedID?.uuidString == selectedNetworkID ? result.selectionMessage : nil
            if let selectedID, let selectionMessage {
                accessLossNotice = (selectedID, selectionMessage)
            } else if let notice = accessLossNotice, visible.contains(where: { $0.id == notice.networkID }) {
                accessLossNotice = nil
            }
            networks = visible
            if !networks.contains(where: { $0.id.uuidString == selectedNetworkID }) {
                updatingSelection = true
                selectedNetworkID = networks.first?.id.uuidString
                updatingSelection = false
            }
            // Access loss is actionable even when an unrelated record is damaged.
            // Keep it through observer/manual refresh races until repaired or
            // the user explicitly chooses another network.
            errorMessage = [accessLossNotice?.message, Self.describeListingDiagnostics(listing)].compactMap { $0 }.nilIfEmptyJoined()
        } catch {
            guard request == refreshGeneration, identityToken == identityGeneration, !Task.isCancelled else { return }
            networks = []; selectedNetworkID = nil
            networkRecordDiagnostics = []; additionalNetworkRecordDiagnosticCount = 0
            errorMessage = Self.describe(error)
        }
    }

    @discardableResult
    public func createNetwork(name: String) async throws -> NetworkManifest {
        let identity = try requireIdentity(), token = identityGeneration
        let manifest = try await worker.perform { try $0.repository.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines), owner: identity) }
        try requireCurrentIdentity(identity, generation: token)
        await refresh()
        try requireCurrentIdentity(identity, generation: token)
        if networks.contains(where: { $0.id == manifest.id }) { selectedNetworkID = manifest.id.uuidString }
        return manifest
    }

    @discardableResult
    public func importInvitation(data: Data) async throws -> NetworkManifest {
        let identity = try requireIdentity(), token = identityGeneration
        let manifest = try await worker.perform { worker in
            let invitation = try NetworkInvitation.decode(data)
            let manifest = try worker.repository.importInvitation(invitation, for: identity.publicIdentity)
            try worker.centers[manifest.id]?.reload()
            return manifest
        }
        try requireCurrentIdentity(identity, generation: token)
        await refresh()
        try requireCurrentIdentity(identity, generation: token)
        if networks.contains(where: { $0.id == manifest.id }) { selectedNetworkID = manifest.id.uuidString }
        return manifest
    }

    public func publicIdentityData() throws -> Data {
        try NetworkMembershipRequest(identity: requireIdentity().publicIdentity).encoded()
    }

    public func addMember(data: Data, networkID: UUID) async throws -> NetworkInvitation {
        let identity = try requireIdentity(), token = identityGeneration
        let invitation = try await worker.perform { worker in
            let request = try NetworkMembershipRequest.decode(data)
            _ = try worker.repository.addMember(request.identity, to: networkID, owner: identity)
            try worker.centers[networkID]?.reload()
            return try worker.repository.invitation(networkID: networkID, for: request.identity, owner: identity)
        }
        try requireCurrentIdentity(identity, generation: token)
        await refresh()
        try requireCurrentIdentity(identity, generation: token)
        return invitation
    }

    public func removeMember(userID: String, networkID: UUID) async throws {
        let identity = try requireIdentity(), token = identityGeneration
        try await worker.perform { worker in
            _ = try worker.repository.removeMember(userID: userID, from: networkID, owner: identity)
            try worker.centers[networkID]?.reload()
        }
        try requireCurrentIdentity(identity, generation: token)
        await refresh()
        try requireCurrentIdentity(identity, generation: token)
    }

    public func createChannel(name: String, networkID: UUID, isPrivate: Bool, allowedUserIDs: [String]) async throws {
        let identity = try requireIdentity(), token = identityGeneration
        let allowed = isPrivate ? Array(Set(allowedUserIDs + [identity.publicIdentity.userID])) : []
        try await worker.perform { worker in
            _ = try worker.repository.createChannel(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                in: networkID, owner: identity, visibility: isPrivate ? .privateMembers : .publicToMembers,
                allowedUserIDs: allowed)
            try worker.centers[networkID]?.reload()
        }
        try requireCurrentIdentity(identity, generation: token)
        await refresh()
        try requireCurrentIdentity(identity, generation: token)
    }

    /// Cached, verified presentation only: this never grants transport access.
    /// Joining must await authorization(), which reloads disk policy off-main.
    public func room(channelID: String) -> RoomConfiguration? {
        guard identityReady, let identity, let id = UUID(uuidString: channelID),
              let network = networks.first(where: { $0.channels.contains { $0.id == id } }),
              let channel = try? network.authorize(identity.publicIdentity, channelID: id) else { return nil }
        return RoomConfiguration(id: channel.id.uuidString, name: "\(network.name) / #\(channel.name)",
            creatorPeerID: network.owner.userID, isPrivate: false, transportPolicy: .secureV2)
    }

    public func authorization(channelID: String, installationHash: Data, deviceName: String) async throws -> NetworkChannelAuthorization {
        let identity = try requireIdentity(), token = identityGeneration
        guard let channelUUID = UUID(uuidString: channelID),
              let network = networks.first(where: { $0.channels.contains { $0.id == channelUUID } }) else {
            throw NetworkAccountError.channelUnavailable
        }
        let authorization = try await worker.perform { worker in
            let center: NetworkPolicyCenter
            if let existing = worker.centers[network.id] { center = existing; try center.reload() }
            else {
                center = try NetworkPolicyCenter(repository: worker.repository, networkID: network.id)
                worker.centers[network.id] = center
                worker.observations[network.id] = center.observe(worker.policyChanged)
            }
            let device = try DeviceIdentityBinding(user: identity, deviceName: Self.bindingDeviceName(deviceName), generation: 1,
                installationPublicKeyHash: installationHash)
            return try NetworkChannelAuthorization(policy: center, channelID: channelUUID, localDevice: device)
        }
        try requireCurrentIdentity(identity, generation: token)
        // Policy may advance while the continuation waits for MainActor. This
        // fast snapshot check takes no repository or durable-transaction lock.
        _ = try authorization.policy.snapshot().authorize(identity.publicIdentity, channelID: channelUUID)
        return authorization
    }

    private func requireCurrentIdentity(_ expected: UserIdentity, generation: UInt64) throws {
        try Task.checkCancellation()
        guard identityReady, identityGeneration == generation, identity?.publicIdentity == expected.publicIdentity else {
            throw NetworkAccountError.setupRequired
        }
    }

    private func requireIdentity() throws -> UserIdentity {
        guard identityReady, let identity else { throw NetworkAccountError.setupRequired }
        return identity
    }

    private func validateName() throws {
        displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard (1...80).contains(displayName.count),
              !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NetworkAccountError.nameRequired
        }
        guard displayName.utf8.count <= 128 else { throw NetworkAccountError.nameTooLong }
    }

    private func clearLoadedIdentity() {
        identityGeneration &+= 1
        identityReady = false
        identity = nil
        accessLossNotice = nil
        networks = []
        selectedNetworkID = nil
        networkRecordDiagnostics = []
        additionalNetworkRecordDiagnosticCount = 0
    }

    private static func describeListingDiagnostics(_ listing: NetworkRepository.Listing) -> String? {
        guard listing.unavailableRecordCount > 0 else { return nil }
        let affected = listing.diagnostics.prefix(3).map {
            "\($0.networkID.uuidString.lowercased()) (\($0.reason == .quarantined ? "conflicting policy" : "unreadable or invalid"))"
        }.joined(separator: ", ")
        let summary = listing.unavailableRecordCount == 1 ? "One saved network is unavailable."
            : "\(listing.unavailableRecordCount) saved networks are unavailable."
        return "\(summary) Verified networks remain available. Check unreadable policy files and their permissions. Conflicting signed policies require a new network and invitation from the owner. Affected records: \(affected)."
    }

    /// Device labels are informational. Bound an OS-provided name before signing rather than
    /// failing an otherwise valid account's admission or splitting a Unicode character.
    nonisolated private static func bindingDeviceName(_ rawName: String) -> String {
        let cleaned = String(String.UnicodeScalarView(rawName.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        var result = ""
        var byteCount = 0
        for character in cleaned {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= 128 else { break }
            result.append(character)
            byteCount += bytes
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "ALO device" : result
    }

    nonisolated public static func describe(_ error: Error) -> String {
        if let error = error as? NetworkAuthorityError {
            switch error {
            case .notMember, .channelAccessDenied: return "Your identity is not allowed in this network or channel. Ask the owner for an invitation."
            case .wrongRecipient: return "This invitation is for a different ALO identity. Ask the owner to invite your public identity."
            case .ownerRequired: return "Only the network owner can change membership and channels."
            case .invalidName: return "Enter a network or channel name between 1 and 80 characters."
            case .rollback: return "This invitation is older than the network policy already saved on this device."
            case .quarantined, .revisionConflict: return "Conflicting signed policies permanently blocked this network on this device. Ask the owner to create a new network and send a new invitation."
            case .invalidStorage: return "Saved network policy could not be read. Access is blocked until this device's network storage is repaired."
            case .networkNotFound: return "This network is no longer saved on this device. Ask the owner for an invitation."
            default: return "The network document could not be verified (\(error))."
            }
        }
        if error is UserIdentityError { return "The identity could not be loaded or verified. Check the recovery file and Keychain access, then retry." }
        return error.localizedDescription
    }
}

private struct NetworkAccountListing: Sendable {
    let listing: NetworkRepository.Listing
    let selectionMessage: String?
}

/// Queue confinement covers both storage and the cache: a mutation cannot miss
/// reloading a center that another async request has just created.
private final class NetworkAccountRepositoryWorker: @unchecked Sendable {
    let repository: NetworkRepository
    let policyChanged: @Sendable () -> Void
    var centers = [UUID: NetworkPolicyCenter]()
    var observations = [UUID: UUID]()
    private let queue = DispatchQueue(label: "alo.network-account.repository", qos: .userInitiated)

    init(repository: NetworkRepository, policyChanged: @escaping @Sendable () -> Void) {
        self.repository = repository; self.policyChanged = policyChanged
    }

    deinit {
        for (id, observation) in observations { centers[id]?.removeObserver(observation) }
    }

    func perform<T: Sendable>(_ work: @escaping @Sendable (NetworkAccountRepositoryWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work(self) }) }
        }
    }
}

private extension Array where Element == String {
    func nilIfEmptyJoined() -> String? { isEmpty ? nil : joined(separator: "\n\n") }
}
