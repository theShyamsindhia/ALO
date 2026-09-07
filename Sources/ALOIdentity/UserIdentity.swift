import CryptoKit
import Foundation

public enum UserIdentityError: Error, Equatable {
    case invalidPublicKey, invalidPrivateKey, inconsistentUserID
    case invalidSigningDomain, payloadTooLarge, invalidBinding, invalidSignature
    case installationKeyMismatch, unsupportedVersion, invalidRecoveryDocument
    case invalidNamespace, keychain(Int32), identityAlreadyExists, storageRace
}

/// A user root is independent of the TLS identity of each of that user's installations.
public struct PublicUserIdentity: Codable, Hashable, Sendable {
    public let userID: String
    /// Canonical, uncompressed P-256 X9.63 representation (65 bytes).
    public let publicKey: Data

    public init(publicKey: Data) throws {
        guard publicKey.count == 65, publicKey.first == 4,
              let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              key.x963Representation == publicKey else { throw UserIdentityError.invalidPublicKey }
        self.publicKey = publicKey
        self.userID = "alo-user-v1:" + SHA256.hash(data: Data("ALO-USER-ROOT-ID-V1\0".utf8) + publicKey)
            .map { String(format: "%02x", $0) }.joined()
    }

    public init(userID: String, publicKey: Data) throws {
        try self.init(publicKey: publicKey)
        guard self.userID == userID else { throw UserIdentityError.inconsistentUserID }
    }

    /// Verifies a raw 64-byte P-256 signature over the same domain and canonical payload.
    /// Callers define a unique versioned domain and canonicalize every authorization field.
    public func verify(signature: Data, payload: Data, domain: String) -> Bool {
        guard signature.count == 64,
              let message = try? IdentityCanonicalEncoding.signingMessage(payload: payload, domain: domain),
              let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    private enum CodingKeys: String, CodingKey { case userID, publicKey }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(userID: values.decode(String.self, forKey: .userID),
                      publicKey: values.decode(Data.self, forKey: .publicKey))
    }
}

/// Private material is retained in memory and exported only by the explicit recovery API.
/// Construction and signing have no storage or Keychain side effects.
public struct UserIdentity: Sendable {
    private let privateKey: P256.Signing.PrivateKey
    public let publicIdentity: PublicUserIdentity

    private init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
        // CryptoKit generates a valid canonical public key for every private key.
        self.publicIdentity = try! PublicUserIdentity(publicKey: privateKey.publicKey.x963Representation)
    }

    public static func generate() -> Self { Self(privateKey: P256.Signing.PrivateKey()) }
    /// Tests and previews never need a real Keychain or an installed app's identity.
    public static func ephemeral() -> Self { generate() }

    public func sign(_ payload: Data, domain: String) throws -> Data {
        let message = try IdentityCanonicalEncoding.signingMessage(payload: payload, domain: domain)
        return try privateKey.signature(for: message).rawRepresentation
    }

    init(rawPrivateKeyRepresentation bytes: Data) throws {
        guard bytes.count == 32, let key = try? P256.Signing.PrivateKey(rawRepresentation: bytes) else {
            throw UserIdentityError.invalidPrivateKey
        }
        self.init(privateKey: key)
    }

    var rawPrivateKeyRepresentation: Data { privateKey.rawRepresentation }
}

enum IdentityCanonicalEncoding {
    static let maximumPayloadBytes = 1_048_576

    static func signingMessage(payload: Data, domain: String) throws -> Data {
        let domainBytes = Data(domain.utf8)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-/_")
        guard domain.hasPrefix("alo."), (5...128).contains(domainBytes.count),
              domain.unicodeScalars.allSatisfy(allowed.contains) else { throw UserIdentityError.invalidSigningDomain }
        guard payload.count <= maximumPayloadBytes else { throw UserIdentityError.payloadTooLarge }
        var result = Data("ALO-ROOT-SIGNATURE-V1\0".utf8)
        append(domainBytes, to: &result)
        append(payload, to: &result)
        return result
    }

    static func append(_ bytes: Data, to output: inout Data) {
        append(UInt64(bytes.count), to: &output)
        output.append(bytes)
    }

    static func append(_ value: UInt64, to output: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
    }
}
