import Foundation
import CryptoKit
import ALOIdentity

public enum NetworkAuthorityError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidName, invalidIdentifier, invalidRevision
    case limitExceeded, duplicateMember, duplicateChannel, invalidOwner, invalidMainChannel
    case invalidAllowlist, invalidSignature, notMember, channelNotFound, channelAccessDenied
    case ownerRequired, networkNotFound, rollback, ownerChanged, generationChanged
    case revisionConflict, quarantined, unexpectedRevision, invalidStorage, wrongRecipient
}

public enum NetworkMemberRole: String, Codable, Hashable, Sendable { case owner, member }

public struct NetworkMember: Codable, Hashable, Sendable {
    public let identity: PublicUserIdentity
    public let role: NetworkMemberRole
    public var userID: String { identity.userID }

    public init(identity: PublicUserIdentity, role: NetworkMemberRole = .member) {
        self.identity = identity
        self.role = role
    }
}

public enum NetworkChannelVisibility: String, Codable, Hashable, Sendable {
    /// Public only to authenticated members of this network.
    case publicToMembers
    case privateMembers
}

public struct NetworkChannel: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let visibility: NetworkChannelVisibility
    public let allowedUserIDs: [String]
    public let isMain: Bool
    public var isPrivate: Bool { visibility == .privateMembers }

    public init(id: UUID = UUID(), name: String,
                visibility: NetworkChannelVisibility = .publicToMembers,
                allowedUserIDs: [String] = [], isMain: Bool = false) throws {
        self.id = id
        self.name = name
        self.visibility = visibility
        self.allowedUserIDs = allowedUserIDs.sorted()
        self.isMain = isMain
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case id, name, visibility, allowedUserIDs, isMain }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      name: values.decode(String.self, forKey: .name),
                      visibility: values.decode(NetworkChannelVisibility.self, forKey: .visibility),
                      allowedUserIDs: values.decode([String].self, forKey: .allowedUserIDs),
                      isMain: values.decode(Bool.self, forKey: .isMain))
    }

    fileprivate func validate() throws {
        try NetworkManifest.validateName(name)
        guard id != NetworkManifest.zeroUUID else { throw NetworkAuthorityError.invalidIdentifier }
        guard allowedUserIDs.count <= NetworkManifest.maximumMembers else {
            throw NetworkAuthorityError.limitExceeded
        }
        guard Set(allowedUserIDs).count == allowedUserIDs.count,
              allowedUserIDs.allSatisfy({ $0.utf8.count <= 128 && !$0.isEmpty }),
              visibility == .privateMembers || allowedUserIDs.isEmpty else {
            throw NetworkAuthorityError.invalidAllowlist
        }
        guard !isMain || (name == "Main" && visibility == .publicToMembers && allowedUserIDs.isEmpty) else {
            throw NetworkAuthorityError.invalidMainChannel
        }
    }
}

/// An immutable owner-signed policy. Decoding verifies structure and signature;
/// repository acceptance additionally pins its owner/generation and revision.
public struct NetworkManifest: Codable, Hashable, Identifiable, Sendable {
    public static let currentVersion = 1
    public static let maximumMembers = 256
    public static let maximumChannels = 128
    public static let maximumCanonicalBytes = 128 * 1024
    public static let maximumEncodedBytes = 256 * 1024
    public static let signatureDomain = "alo.network.manifest.v1"

    public let formatVersion: Int
    public let id: UUID
    public let generation: UUID
    public let revision: UInt64
    public let name: String
    public let owner: PublicUserIdentity
    public let members: [NetworkMember]
    public let channels: [NetworkChannel]
    public let signature: Data

    public var mainChannel: NetworkChannel { channels.first(where: \.isMain)! }

    fileprivate static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Main's identifier depends only on the network ID, never a name or a peer.
    public static func mainChannelID(for networkID: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("alo.network.main.v1\0\(networkID.uuidString.lowercased())".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func create(name: String, owner: UserIdentity, id: UUID = UUID(),
                              generation: UUID = UUID()) throws -> NetworkManifest {
        let main = try NetworkChannel(id: mainChannelID(for: id), name: "Main", isMain: true)
        return try signed(id: id, generation: generation, revision: 1, name: name,
                          owner: owner, members: [NetworkMember(identity: owner.publicIdentity, role: .owner)],
                          channels: [main])
    }

    /// Used for signing explicit owner policy changes. No private key is retained.
    public static func signed(id: UUID, generation: UUID, revision: UInt64, name: String,
                              owner: UserIdentity, members: [NetworkMember],
                              channels: [NetworkChannel]) throws -> NetworkManifest {
        let unsigned = try NetworkManifest(formatVersion: currentVersion, id: id, generation: generation,
                                           revision: revision, name: name, owner: owner.publicIdentity,
                                           members: members, channels: channels, signature: Data(), verify: false)
        let signature = try owner.sign(unsigned.canonicalBytes(), domain: signatureDomain)
        return try NetworkManifest(formatVersion: currentVersion, id: id, generation: generation,
                                   revision: revision, name: name, owner: owner.publicIdentity,
                                   members: members, channels: channels, signature: signature, verify: true)
    }

    private init(formatVersion: Int, id: UUID, generation: UUID, revision: UInt64, name: String,
                 owner: PublicUserIdentity, members: [NetworkMember], channels: [NetworkChannel],
                 signature: Data, verify: Bool) throws {
        self.formatVersion = formatVersion
        self.id = id
        self.generation = generation
        self.revision = revision
        self.name = name
        self.owner = owner
        self.members = members.sorted { $0.userID < $1.userID }
        self.channels = channels.sorted { $0.id.uuidString < $1.id.uuidString }
        self.signature = signature
        try validateStructure()
        if verify { try validateSignature() }
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, generation, revision, name, owner, members, channels, signature
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(formatVersion: values.decode(Int.self, forKey: .formatVersion),
                      id: values.decode(UUID.self, forKey: .id),
                      generation: values.decode(UUID.self, forKey: .generation),
                      revision: values.decode(UInt64.self, forKey: .revision),
                      name: values.decode(String.self, forKey: .name),
                      owner: values.decode(PublicUserIdentity.self, forKey: .owner),
                      members: values.decode([NetworkMember].self, forKey: .members),
                      channels: values.decode([NetworkChannel].self, forKey: .channels),
                      signature: values.decode(Data.self, forKey: .signature), verify: true)
    }

    public static func decode(_ data: Data) throws -> NetworkManifest {
        guard data.count <= maximumEncodedBytes else { throw NetworkAuthorityError.limitExceeded }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw NetworkAuthorityError.limitExceeded }
        return data
    }

    public func validateSignature() throws {
        guard signature.count == 64,
              owner.verify(signature: signature, payload: try canonicalBytes(), domain: Self.signatureDomain) else {
            throw NetworkAuthorityError.invalidSignature
        }
    }

    /// The caller must first authenticate this public identity (for remote peers,
    /// verify its root-signed device binding against the actual TLS identity).
    public func isMember(_ authenticatedIdentity: PublicUserIdentity) -> Bool {
        members.contains { $0.identity == authenticatedIdentity }
    }

    public func accessibleChannels(for authenticatedIdentity: PublicUserIdentity) throws -> [NetworkChannel] {
        guard isMember(authenticatedIdentity) else { throw NetworkAuthorityError.notMember }
        return channels.filter { mayAccess($0, identity: authenticatedIdentity) }.sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            return $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
        }
    }

    @discardableResult
    public func authorize(_ authenticatedIdentity: PublicUserIdentity, channelID: UUID) throws -> NetworkChannel {
        guard isMember(authenticatedIdentity) else { throw NetworkAuthorityError.notMember }
        guard let channel = channels.first(where: { $0.id == channelID }) else {
            throw NetworkAuthorityError.channelNotFound
        }
        guard mayAccess(channel, identity: authenticatedIdentity) else { throw NetworkAuthorityError.channelAccessDenied }
        return channel
    }

    public func addingMember(_ identity: PublicUserIdentity, signedBy signer: UserIdentity) throws -> NetworkManifest {
        try requireOwner(signer)
        if members.contains(where: { $0.identity == identity }) { return self }
        return try replacing(members: members + [NetworkMember(identity: identity)], signedBy: signer)
    }

    public func removingMember(userID: String, signedBy signer: UserIdentity) throws -> NetworkManifest {
        try requireOwner(signer)
        guard userID != owner.userID else { throw NetworkAuthorityError.invalidOwner }
        guard members.contains(where: { $0.userID == userID }) else { return self }
        let updatedChannels = try channels.map { channel in
            try NetworkChannel(id: channel.id, name: channel.name, visibility: channel.visibility,
                               allowedUserIDs: channel.allowedUserIDs.filter { $0 != userID }, isMain: channel.isMain)
        }
        return try replacing(members: members.filter { $0.userID != userID }, channels: updatedChannels, signedBy: signer)
    }

    public func addingChannel(_ channel: NetworkChannel, signedBy signer: UserIdentity) throws -> NetworkManifest {
        try replacing(channels: channels + [channel], signedBy: signer)
    }

    public func updatingChannel(_ channel: NetworkChannel, signedBy signer: UserIdentity) throws -> NetworkManifest {
        try requireOwner(signer)
        guard let previous = channels.first(where: { $0.id == channel.id }) else {
            throw NetworkAuthorityError.channelNotFound
        }
        guard !previous.isMain || previous == channel else { throw NetworkAuthorityError.invalidMainChannel }
        if previous == channel { return self }
        return try replacing(channels: channels.map { $0.id == channel.id ? channel : $0 }, signedBy: signer)
    }

    public func removingChannel(id channelID: UUID, signedBy signer: UserIdentity) throws -> NetworkManifest {
        try requireOwner(signer)
        guard let channel = channels.first(where: { $0.id == channelID }) else {
            throw NetworkAuthorityError.channelNotFound
        }
        guard !channel.isMain else { throw NetworkAuthorityError.invalidMainChannel }
        return try replacing(channels: channels.filter { $0.id != channelID }, signedBy: signer)
    }

    public func renamed(to name: String, signedBy signer: UserIdentity) throws -> NetworkManifest {
        try requireOwner(signer)
        if self.name == name { return self }
        return try replacing(name: name, signedBy: signer)
    }

    /// A binary encoding with fixed field order, length-prefixed UTF-8/data, and
    /// sorted set-like collections. JSON formatting/order never affects signing.
    public func canonicalBytes() throws -> Data {
        var writer = NetworkCanonicalWriter()
        writer.string("alo.network.manifest.v1")
        writer.number(UInt64(formatVersion))
        writer.uuid(id)
        writer.uuid(generation)
        writer.number(revision)
        writer.string(name)
        writer.identity(owner)
        writer.number(UInt64(members.count))
        for member in members {
            writer.identity(member.identity)
            writer.string(member.role.rawValue)
        }
        writer.number(UInt64(channels.count))
        for channel in channels {
            writer.uuid(channel.id)
            writer.string(channel.name)
            writer.string(channel.visibility.rawValue)
            writer.number(channel.isMain ? 1 : 0)
            writer.number(UInt64(channel.allowedUserIDs.count))
            for userID in channel.allowedUserIDs { writer.string(userID) }
        }
        guard writer.data.count <= Self.maximumCanonicalBytes else { throw NetworkAuthorityError.limitExceeded }
        return writer.data
    }

    private func mayAccess(_ channel: NetworkChannel, identity: PublicUserIdentity) -> Bool {
        identity == owner || channel.visibility == .publicToMembers || channel.allowedUserIDs.contains(identity.userID)
    }

    private func requireOwner(_ signer: UserIdentity) throws {
        guard signer.publicIdentity == owner else { throw NetworkAuthorityError.ownerRequired }
    }

    private func replacing(name: String? = nil, members: [NetworkMember]? = nil,
                           channels: [NetworkChannel]? = nil, signedBy signer: UserIdentity) throws -> NetworkManifest {
        try requireOwner(signer)
        guard revision < UInt64.max else { throw NetworkAuthorityError.invalidRevision }
        return try Self.signed(id: id, generation: generation, revision: revision + 1, name: name ?? self.name,
                               owner: signer, members: members ?? self.members, channels: channels ?? self.channels)
    }

    private func validateStructure() throws {
        guard formatVersion == Self.currentVersion else { throw NetworkAuthorityError.unsupportedVersion }
        guard id != Self.zeroUUID, generation != Self.zeroUUID else { throw NetworkAuthorityError.invalidIdentifier }
        guard revision > 0 else { throw NetworkAuthorityError.invalidRevision }
        try Self.validateName(name)
        guard !members.isEmpty, members.count <= Self.maximumMembers,
              !channels.isEmpty, channels.count <= Self.maximumChannels else { throw NetworkAuthorityError.limitExceeded }
        guard Set(members.map(\.userID)).count == members.count else { throw NetworkAuthorityError.duplicateMember }
        guard members.filter({ $0.role == .owner }).count == 1,
              members.contains(where: { $0.role == .owner && $0.identity == owner }) else {
            throw NetworkAuthorityError.invalidOwner
        }
        guard Set(channels.map(\.id)).count == channels.count,
              Set(channels.map { $0.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }).count == channels.count else {
            throw NetworkAuthorityError.duplicateChannel
        }
        let mainChannels = channels.filter(\.isMain)
        guard mainChannels.count == 1, mainChannels[0].id == Self.mainChannelID(for: id) else {
            throw NetworkAuthorityError.invalidMainChannel
        }
        let memberIDs = Set(members.map(\.userID))
        for channel in channels {
            try channel.validate()
            guard Set(channel.allowedUserIDs).isSubset(of: memberIDs) else { throw NetworkAuthorityError.invalidAllowlist }
        }
        _ = try canonicalBytes()
        _ = try encoded()
    }

    fileprivate static func validateName(_ name: String) throws {
        guard (1...80).contains(name.utf8.count),
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name == name.precomposedStringWithCanonicalMapping,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw NetworkAuthorityError.invalidName
        }
    }
}

private struct NetworkCanonicalWriter {
    var data = Data()
    mutating func number(_ number: UInt64) {
        var value = number.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    mutating func bytes(_ value: Data) { number(UInt64(value.count)); data.append(value) }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    mutating func uuid(_ value: UUID) { string(value.uuidString.lowercased()) }
    mutating func identity(_ value: PublicUserIdentity) { string(value.userID); bytes(value.publicKey) }
}
