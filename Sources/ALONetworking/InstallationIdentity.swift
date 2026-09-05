import Foundation
import Security
import CryptoKit

public enum IdentityError: Error, Equatable {
    case invalidNamespace, keychain(OSStatus), keyGeneration, invalidKey, invalidCertificate
    case identityCreation, unknownPeer, changedPeerKey, peerIdentityMismatch
}

public struct IdentityKeychainNamespace: Sendable {
    public enum Environment: String, Sendable { case production, development }
    public let service: String
    public init(applicationID: String, environment: Environment) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (3...128).contains(applicationID.utf8.count), applicationID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw IdentityError.invalidNamespace
        }
        service = applicationID + "." + environment.rawValue + ".alo.identity-v2"
    }
}

// Minimal DER writer for a fixed P-256 self-signed X.509 profile. No remote ASN.1 is parsed here.
enum CertificateDER {
    static func field(_ tag: UInt8, _ contents: Data) -> Data {
        var length = Data()
        if contents.count < 128 { length.append(UInt8(contents.count)) }
        else {
            var value = contents.count, bytes = [UInt8]()
            while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
        }
        return Data([tag]) + length + contents
    }
    static func sequence(_ data: Data) -> Data { field(0x30, data) }
    static func oid(_ bytes: [UInt8]) -> Data { field(0x06, Data(bytes)) }
    static let signatureAlgorithm = sequence(oid([0x2a,0x86,0x48,0xce,0x3d,0x04,0x03,0x02]))
    static func spki(_ x963: Data) -> Data {
        sequence(sequence(oid([0x2a,0x86,0x48,0xce,0x3d,0x02,0x01]) +
                          oid([0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07])) + field(0x03, Data([0]) + x963))
    }
    static func name(_ nodeID: UUID) -> Data {
        sequence(field(0x31, sequence(oid([0x55,0x04,0x03]) + field(0x0c, Data(nodeID.uuidString.utf8)))))
    }
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return field(0x18, Data(formatter.string(from: date).utf8)) // GeneralizedTime has no 2050 cutoff.
    }
}

public struct PeerPublicIdentity: Equatable, Sendable {
    public let nodeID: UUID
    public let publicKeyHash: Data
    public init(publicKeyHash: Data) throws {
        guard publicKeyHash.count == 32 else { throw IdentityError.invalidKey }
        let b = Array(publicKeyHash.prefix(16))
        nodeID = UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        self.publicKeyHash = publicKeyHash
    }
    public static func from(publicKey: SecKey) throws -> Self {
        let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any]
        guard attributes?[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attributes?[kSecAttrKeySizeInBits as String] as? Int == 256,
              let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              bytes.count == 65, bytes.first == 4 else { throw IdentityError.invalidKey }
        return try Self(publicKeyHash: Data(SHA256.hash(data: CertificateDER.spki(bytes))))
    }
    public static func from(certificate: SecCertificate) throws -> Self {
        guard let key = SecCertificateCopyKey(certificate) else { throw IdentityError.invalidCertificate }
        return try from(publicKey: key)
    }
}

/// Private keys are serialized only into a device-only Keychain entry, never onto the wire.
/// Certificates can rotate while the installation key, SPKI pin, and node ID remain stable.
public final class InstallationIdentity {
    public let publicIdentity: PeerPublicIdentity
    public let certificate: SecCertificate
    public let identity: SecIdentity
    let signedCertificateBody: Data
    let certificateSignature: Data

    private init(privateKey: SecKey, now: Date) throws {
        guard now.timeIntervalSince1970.isFinite,
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let x963 = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw IdentityError.invalidKey }
        publicIdentity = try PeerPublicIdentity.from(publicKey: publicKey)
        var serial = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        serial[serial.startIndex] &= 0x7f
        if serial.allSatisfy({ $0 == 0 }) { serial[serial.startIndex] = 1 }
        while serial.count > 1 && serial.first == 0 { serial.removeFirst() }
        if let first = serial.first, first & 0x80 != 0 { serial.insert(0, at: serial.startIndex) }
        let name = CertificateDER.name(publicIdentity.nodeID)
        let basicConstraints = CertificateDER.sequence(CertificateDER.oid([0x55,0x1d,0x13]) +
            CertificateDER.field(0x01, Data([0xff])) + CertificateDER.field(0x04, CertificateDER.sequence(Data())))
        let keyUsage = CertificateDER.sequence(CertificateDER.oid([0x55,0x1d,0x0f]) +
            CertificateDER.field(0x01, Data([0xff])) + CertificateDER.field(0x04, CertificateDER.field(0x03, Data([7,0x80]))))
        let extendedUsage = CertificateDER.sequence(CertificateDER.oid([0x55,0x1d,0x25]) +
            CertificateDER.field(0x04, CertificateDER.sequence(
                CertificateDER.oid([0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x01]) +
                CertificateDER.oid([0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x02]))))
        signedCertificateBody = CertificateDER.sequence(
            CertificateDER.field(0xa0, CertificateDER.field(0x02, Data([2]))) +
            CertificateDER.field(0x02, serial) + CertificateDER.signatureAlgorithm + name +
            CertificateDER.sequence(CertificateDER.time(now.addingTimeInterval(-300)) +
                                    CertificateDER.time(now.addingTimeInterval(365 * 86400))) + name +
            CertificateDER.spki(x963) + CertificateDER.field(0xa3, CertificateDER.sequence(basicConstraints + keyUsage + extendedUsage)))
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256,
                                                     signedCertificateBody as CFData, nil) as Data? else {
            throw IdentityError.invalidCertificate
        }
        certificateSignature = signature
        let der = CertificateDER.sequence(signedCertificateBody + CertificateDER.signatureAlgorithm +
                                           CertificateDER.field(0x03, Data([0]) + signature))
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw IdentityError.invalidCertificate }
        self.certificate = certificate
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else { throw IdentityError.identityCreation }
        self.identity = identity
    }

    func signRoomEvent(_ bytes: Data) throws -> Data {
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let privateKey,
              let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256,
                                                     bytes as CFData, nil) as Data? else { throw IdentityError.invalidKey }
        return signature
    }

    /// In-memory keys/certificates for tests and unpersisted previews. Never touches Keychain.
    public static func ephemeral(now: Date = Date()) throws -> InstallationIdentity {
        let parameters = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256] as CFDictionary
        guard let key = SecKeyCreateRandomKey(parameters, nil) else { throw IdentityError.keyGeneration }
        return try InstallationIdentity(privateKey: key, now: now)
    }

    public static func loadOrCreate(namespace: IdentityKeychainNamespace, now: Date = Date()) throws -> InstallationIdentity {
        // Generic-password service/account uniqueness is enforced atomically by Keychain.
        // SecKey applicationTag is only a lookup attribute and cannot arbitrate concurrent creators.
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace.service, kSecAttrAccount as String: "installation-p256-v2",
            kSecUseDataProtectionKeychain as String: true]
        let keyAttributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 256]
        func load() throws -> SecKey? {
            var query = base; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw IdentityError.keychain(status) }
            guard let bytes = result as? Data, bytes.count == 97,
                  let key = SecKeyCreateWithData(bytes as CFData, keyAttributes as CFDictionary, nil) else {
                throw IdentityError.invalidKey
            }
            return key
        }
        if let existing = try load() { return try InstallationIdentity(privateKey: existing, now: now) }
        guard let candidate = SecKeyCreateRandomKey(keyAttributes as CFDictionary, nil),
              let bytes = SecKeyCopyExternalRepresentation(candidate, nil) as Data?, bytes.count == 97 else {
            throw IdentityError.keyGeneration
        }
        var insertion = base; insertion[kSecValueData as String] = bytes
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insertion as CFDictionary, nil)
        if status == errSecSuccess { return try InstallationIdentity(privateKey: candidate, now: now) }
        guard status == errSecDuplicateItem else { throw IdentityError.keychain(status) }
        guard let winner = try load() else { throw IdentityError.invalidKey }
        return try InstallationIdentity(privateKey: winner, now: now)
    }
}
