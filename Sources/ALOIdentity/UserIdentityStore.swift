import Foundation
import Security

/// A storage backend must return nil only for a missing item. Read failures must throw.
/// The insertion must be atomic and return false only when an item already exists.
public protocol UserIdentityKeyStorage {
    func loadPrivateKey() throws -> Data?
    func insertPrivateKeyIfAbsent(_ bytes: Data) throws -> Bool
}

/// Creating this wrapper does not read or create a key. Onboarding explicitly chooses load, create, or restore.
public final class UserIdentityStore {
    private let storage: any UserIdentityKeyStorage
    public init(storage: any UserIdentityKeyStorage) { self.storage = storage }

    public func load() throws -> UserIdentity? {
        guard let bytes = try storage.loadPrivateKey() else { return nil }
        return try UserIdentity(rawPrivateKeyRepresentation: bytes)
    }

    public func loadOrCreateForOnboarding() throws -> UserIdentity {
        if let existing = try load() { return existing }
        let candidate = UserIdentity.generate()
        if try storage.insertPrivateKeyIfAbsent(candidate.rawPrivateKeyRepresentation) { return candidate }
        guard let winner = try load() else { throw UserIdentityError.storageRace }
        return winner
    }

    /// Never replaces a different local account. Recovery creates a new device binding separately.
    @discardableResult
    public func restoreForOnboarding(from documentData: Data) throws -> UserIdentity {
        let recovered = try IdentityRecoveryDocument.restore(from: documentData)
        if let existing = try load() {
            guard existing.publicIdentity == recovered.publicIdentity else { throw UserIdentityError.identityAlreadyExists }
            return existing
        }
        if try storage.insertPrivateKeyIfAbsent(recovered.rawPrivateKeyRepresentation) { return recovered }
        guard let winner = try load() else { throw UserIdentityError.storageRace }
        guard winner.publicIdentity == recovered.publicIdentity else { throw UserIdentityError.identityAlreadyExists }
        return winner
    }
}

public struct UserIdentityKeychainNamespace: Sendable {
    public enum Environment: String, Sendable { case production, development }
    public let service: String
    public init(applicationID: String, environment: Environment) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (3...128).contains(applicationID.utf8.count), applicationID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw UserIdentityError.invalidNamespace
        }
        service = applicationID + "." + environment.rawValue + ".alo.user-root-v1"
    }
}

/// Production callers must explicitly provide a scope. Tests should inject in-memory storage instead.
public final class KeychainUserIdentityStorage: UserIdentityKeyStorage {
    private let namespace: UserIdentityKeychainNamespace
    public init(namespace: UserIdentityKeychainNamespace) { self.namespace = namespace }

    private var baseQuery: [String: Any] {
        #if os(macOS)
        let dataProtection = false
        #else
        let dataProtection = true
        #endif
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: namespace.service,
                kSecAttrAccount as String: "user-root-p256-v1",
                kSecUseDataProtectionKeychain as String: dataProtection,
                kSecAttrSynchronizable as String: false]
    }

    public func loadPrivateKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw UserIdentityError.keychain(status) }
        guard let bytes = result as? Data else { throw UserIdentityError.invalidPrivateKey }
        _ = try UserIdentity(rawPrivateKeyRepresentation: bytes)
        return bytes
    }

    public func insertPrivateKeyIfAbsent(_ bytes: Data) throws -> Bool {
        _ = try UserIdentity(rawPrivateKeyRepresentation: bytes)
        var query = baseQuery
        query[kSecValueData as String] = bytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw UserIdentityError.keychain(status) }
        return true
    }
}
