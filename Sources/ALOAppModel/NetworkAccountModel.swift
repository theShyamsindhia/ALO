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
    @Published public private(set) var errorMessage: String?
    @Published public var displayName = ""
    @Published public var selectedNetworkID: String?
    public let repository: NetworkRepository
    private let defaults: UserDefaults
    private let suppliedStore: UserIdentityStore?
    private var centers = [UUID: NetworkPolicyCenter]()
    private var observations = [UUID: UUID]()
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
    public func resume() {
        guard defaults.bool(forKey: Self.preparedKey) || defaults.bool(forKey: Self.completedKey) else {
            clearLoadedIdentity()
            return
        }
        do {
            try validateName()
            guard let loaded = try store().load() else { throw NetworkAccountError.setupRequired }
            identity = loaded
            identityReady = defaults.bool(forKey: Self.completedKey)
            refresh()
        } catch { clearLoadedIdentity(); errorMessage = Self.describe(error) }
    }

    public func createIdentity() throws {
        try validateName()
        identity = try store().loadOrCreateForOnboarding()
        defaults.set(true, forKey: Self.preparedKey)
        defaults.set(displayName, forKey: Self.displayNameKey)
        errorMessage = nil
    }

    public func restoreIdentity(data: Data) throws {
        try validateName()
        identity = try store().restoreForOnboarding(from: data)
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
    public func completeIdentitySetup() throws {
        guard identity != nil else { throw NetworkAccountError.setupRequired }
        try validateName()
        defaults.set(displayName, forKey: Self.displayNameKey)
        defaults.set(true, forKey: Self.completedKey)
        identityReady = true
        refresh()
    }

    public var selectedNetwork: NetworkManifest? { networks.first { $0.id.uuidString == selectedNetworkID } }
    public var channels: [NetworkChannel] {
        guard let identity, let selectedNetwork else { return [] }
        return (try? selectedNetwork.accessibleChannels(for: identity.publicIdentity)) ?? []
    }

    public func refresh() {
        guard identityReady, let identity else { networks = []; selectedNetworkID = nil; return }
        do {
            let visible = try repository.networks(for: identity.publicIdentity)
            var selectionError: Error?
            if let selectedID = selectedNetworkID.flatMap(UUID.init(uuidString:)),
               !visible.contains(where: { $0.id == selectedID }) {
                do {
                    let previous = try repository.trustedManifest(id: selectedID)
                    if !previous.isMember(identity.publicIdentity) { selectionError = NetworkAuthorityError.notMember }
                } catch { selectionError = error }
            }
            networks = visible
            if !networks.contains(where: { $0.id.uuidString == selectedNetworkID }) {
                selectedNetworkID = networks.first?.id.uuidString
            }
            errorMessage = selectionError.map(Self.describe)
        } catch { networks = []; selectedNetworkID = nil; errorMessage = Self.describe(error) }
    }

    @discardableResult
    public func createNetwork(name: String) throws -> NetworkManifest {
        let manifest = try repository.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines), owner: requireIdentity())
        refresh(); selectedNetworkID = manifest.id.uuidString
        return manifest
    }

    @discardableResult
    public func importInvitation(data: Data) throws -> NetworkManifest {
        let invitation = try NetworkInvitation.decode(data)
        let manifest = try repository.importInvitation(invitation, for: requireIdentity().publicIdentity)
        try centers[manifest.id]?.reload()
        refresh(); selectedNetworkID = manifest.id.uuidString
        return manifest
    }

    public func publicIdentityData() throws -> Data {
        try NetworkMembershipRequest(identity: requireIdentity().publicIdentity).encoded()
    }

    public func addMember(data: Data, networkID: UUID) throws -> NetworkInvitation {
        let request = try NetworkMembershipRequest.decode(data)
        let identity = try requireIdentity()
        _ = try repository.addMember(request.identity, to: networkID, owner: identity)
        try centers[networkID]?.reload()
        refresh()
        return try repository.invitation(networkID: networkID, for: request.identity, owner: identity)
    }

    public func removeMember(userID: String, networkID: UUID) throws {
        _ = try repository.removeMember(userID: userID, from: networkID, owner: requireIdentity())
        try centers[networkID]?.reload(); refresh()
    }

    public func createChannel(name: String, networkID: UUID, isPrivate: Bool, allowedUserIDs: [String]) throws {
        let identity = try requireIdentity()
        let allowed = isPrivate ? Array(Set(allowedUserIDs + [identity.publicIdentity.userID])) : []
        _ = try repository.createChannel(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            in: networkID, owner: identity, visibility: isPrivate ? .privateMembers : .publicToMembers,
            allowedUserIDs: allowed)
        try centers[networkID]?.reload(); refresh()
    }

    /// Internal room transport is a channel session, not a separate public room.
    /// TLS NetworkChannelAuthorization enforces access for every channel role.
    public func room(channelID: String) -> RoomConfiguration? {
        guard identityReady, let identity, let id = UUID(uuidString: channelID),
              let network = networks.first(where: { $0.channels.contains { $0.id == id } }),
              let current = try? repository.network(id: network.id, for: identity.publicIdentity),
              let channel = try? current.authorize(identity.publicIdentity, channelID: id) else { return nil }
        return RoomConfiguration(id: channel.id.uuidString, name: "\(current.name) / #\(channel.name)",
            creatorPeerID: current.owner.userID, isPrivate: false, transportPolicy: .secureV2)
    }

    public func authorization(channelID: String, installationHash: Data, deviceName: String) throws -> NetworkChannelAuthorization {
        let identity = try requireIdentity()
        guard let channelUUID = UUID(uuidString: channelID),
              let network = networks.first(where: { $0.channels.contains { $0.id == channelUUID } }) else {
            throw NetworkAccountError.channelUnavailable
        }
        let center: NetworkPolicyCenter
        if let existing = centers[network.id] { center = existing; try center.reload() }
        else {
            center = try NetworkPolicyCenter(repository: repository, networkID: network.id)
            centers[network.id] = center
            observations[network.id] = center.observe { [weak self] in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        let device = try DeviceIdentityBinding(user: identity, deviceName: Self.bindingDeviceName(deviceName), generation: 1,
            installationPublicKeyHash: installationHash)
        return try NetworkChannelAuthorization(policy: center, channelID: channelUUID, localDevice: device)
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
        identityReady = false
        identity = nil
        networks = []
        selectedNetworkID = nil
    }

    /// Device labels are informational. Bound an OS-provided name before signing rather than
    /// failing an otherwise valid account's admission or splitting a Unicode character.
    private static func bindingDeviceName(_ rawName: String) -> String {
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

    public static func describe(_ error: Error) -> String {
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
