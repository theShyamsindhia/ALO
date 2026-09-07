import Foundation
import ALOIdentity

/// Shareable request containing only public identity. Possessing this document
/// grants nothing: an owner must explicitly add this identity to a signed policy.
public struct NetworkMembershipRequest: Codable, Hashable, Sendable {
    public let formatVersion: Int
    public let identity: PublicUserIdentity

    public init(identity: PublicUserIdentity) {
        formatVersion = 1
        self.identity = identity
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, identity }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .formatVersion) == 1 else {
            throw NetworkAuthorityError.unsupportedVersion
        }
        self.init(identity: try values.decode(PublicUserIdentity.self, forKey: .identity))
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw NetworkAuthorityError.limitExceeded }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// The recipient is already present in the signed manifest. This envelope is a
/// routing hint, not a bearer token; changing it cannot create a membership grant.
public struct NetworkInvitation: Codable, Hashable, Sendable {
    public let formatVersion: Int
    public let recipient: PublicUserIdentity
    public let manifest: NetworkManifest

    public init(manifest: NetworkManifest, recipient: PublicUserIdentity) throws {
        try manifest.validateSignature()
        guard manifest.isMember(recipient) else { throw NetworkAuthorityError.notMember }
        formatVersion = 1
        self.recipient = recipient
        self.manifest = manifest
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, recipient, manifest }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .formatVersion) == 1 else {
            throw NetworkAuthorityError.unsupportedVersion
        }
        try self.init(manifest: values.decode(NetworkManifest.self, forKey: .manifest),
                      recipient: values.decode(PublicUserIdentity.self, forKey: .recipient))
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= NetworkManifest.maximumEncodedBytes + 4096 else { throw NetworkAuthorityError.limitExceeded }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= NetworkManifest.maximumEncodedBytes + 4096 else { throw NetworkAuthorityError.limitExceeded }
        return data
    }
}
