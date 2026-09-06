import Foundation

/// A root-authorized device claim, useful only when its full hash matches the authenticated TLS peer.
/// Multiple bindings can share a user root while retaining different installation identities.
public struct DeviceIdentityBinding: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let signingDomain = "alo.device.identity-binding.v1"
    public let version: Int
    public let userIdentity: PublicUserIdentity
    public let bindingID: UUID
    public let deviceName: String
    /// Reserved signed metadata; current app callers emit 1. No generation floor is enforced.
    /// Membership revocation applies to the entire user root, not an individual device binding.
    public let generation: UInt64
    public let installationPublicKeyHash: Data
    public let signature: Data

    public init(user: UserIdentity, bindingID: UUID = UUID(), deviceName: String,
                generation: UInt64, installationPublicKeyHash: Data) throws {
        try Self.validate(version: Self.currentVersion, deviceName: deviceName, generation: generation,
                          installationPublicKeyHash: installationPublicKeyHash)
        self.version = Self.currentVersion
        self.userIdentity = user.publicIdentity
        self.bindingID = bindingID
        self.deviceName = deviceName
        self.generation = generation
        self.installationPublicKeyHash = installationPublicKeyHash
        self.signature = try user.sign(Self.payload(version: version, userIdentity: userIdentity,
            bindingID: bindingID, deviceName: deviceName, generation: generation,
            installationPublicKeyHash: installationPublicKeyHash), domain: Self.signingDomain)
    }

    /// Require the full SPKI hash obtained from the current authenticated connection, never a claimed ID.
    public func verify(expectedInstallationPublicKeyHash: Data) throws {
        try Self.validate(version: version, deviceName: deviceName, generation: generation,
                          installationPublicKeyHash: installationPublicKeyHash)
        guard expectedInstallationPublicKeyHash.count == 32,
              installationPublicKeyHash == expectedInstallationPublicKeyHash else {
            throw UserIdentityError.installationKeyMismatch
        }
        guard userIdentity.verify(signature: signature, payload: Self.payload(version: version,
            userIdentity: userIdentity, bindingID: bindingID, deviceName: deviceName, generation: generation,
            installationPublicKeyHash: installationPublicKeyHash), domain: Self.signingDomain) else {
            throw UserIdentityError.invalidSignature
        }
    }

    private static func validate(version: Int, deviceName: String, generation: UInt64,
                                 installationPublicKeyHash: Data) throws {
        guard version == currentVersion else { throw UserIdentityError.unsupportedVersion }
        guard generation > 0, installationPublicKeyHash.count == 32,
              (1...128).contains(deviceName.utf8.count),
              deviceName == deviceName.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw UserIdentityError.invalidBinding
        }
    }

    private static func payload(version: Int, userIdentity: PublicUserIdentity, bindingID: UUID,
                                deviceName: String, generation: UInt64, installationPublicKeyHash: Data) -> Data {
        var bytes = Data()
        IdentityCanonicalEncoding.append(UInt64(version), to: &bytes)
        IdentityCanonicalEncoding.append(Data(userIdentity.userID.utf8), to: &bytes)
        IdentityCanonicalEncoding.append(userIdentity.publicKey, to: &bytes)
        IdentityCanonicalEncoding.append(Data(bindingID.uuidString.lowercased().utf8), to: &bytes)
        IdentityCanonicalEncoding.append(Data(deviceName.utf8), to: &bytes)
        IdentityCanonicalEncoding.append(generation, to: &bytes)
        IdentityCanonicalEncoding.append(installationPublicKeyHash, to: &bytes)
        return bytes
    }

    private enum CodingKeys: String, CodingKey {
        case version, userIdentity, bindingID, deviceName, generation, installationPublicKeyHash, signature
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        userIdentity = try values.decode(PublicUserIdentity.self, forKey: .userIdentity)
        bindingID = try values.decode(UUID.self, forKey: .bindingID)
        deviceName = try values.decode(String.self, forKey: .deviceName)
        generation = try values.decode(UInt64.self, forKey: .generation)
        installationPublicKeyHash = try values.decode(Data.self, forKey: .installationPublicKeyHash)
        signature = try values.decode(Data.self, forKey: .signature)
        try Self.validate(version: version, deviceName: deviceName, generation: generation,
                          installationPublicKeyHash: installationPublicKeyHash)
        guard signature.count == 64 else { throw UserIdentityError.invalidSignature }
    }
}
