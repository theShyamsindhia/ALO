import Foundation
import Security
import ALOCore
import ALONetworking

/// Private room credentials never enter UserDefaults, logs, or room documents.
final class MobileRoomStore: @unchecked Sendable {
    /// Explicit opt-in only. Release and physical-device builds cannot enable this path.
    static let usesTemporarySimulatorIdentity: Bool = {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--alo-temporary-simulator-identity")
        #else
        return false
        #endif
    }()
    let namespace: IdentityKeychainNamespace
    private let directory: URL?
    private let memoryLock = NSLock()
    private var temporaryRoom: RoomConfiguration?
    private var temporaryDocuments: [String: Data] = [:]
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: namespace.service + ".selected-room",
         kSecAttrAccount as String: "selected"]
    }

    init() throws {
        #if DEBUG
        namespace = try IdentityKeychainNamespace(applicationID: "in.werai.ios", environment: .development)
        #else
        namespace = try IdentityKeychainNamespace(applicationID: "in.werai.ios", environment: .production)
        #endif
        if Self.usesTemporarySimulatorIdentity { directory = nil; return }
        directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true).appendingPathComponent("RoomState")
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    func selectedRoom() throws -> RoomConfiguration? {
        if Self.usesTemporarySimulatorIdentity {
            memoryLock.lock(); defer { memoryLock.unlock() }; return temporaryRoom
        }
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError.keychain(status) }
        let previous = try JSONDecoder().decode(RoomConfiguration.self, from: data)
        let room = try previous.upgradedToCurrentSystem()
        if room != previous { try saveSelectedRoom(room) }
        guard room.transportPolicy == .secureV2, UUID(uuidString: room.id) != nil else { throw StoreError.invalidRoom }
        try room.validateForJoining()
        return room
    }

    func saveSelectedRoom(_ previous: RoomConfiguration) throws {
        let room = try previous.upgradedToCurrentSystem()
        try room.validateForJoining()
        if Self.usesTemporarySimulatorIdentity {
            memoryLock.lock(); defer { memoryLock.unlock() }; temporaryRoom = room; return
        }
        let data = try JSONEncoder().encode(room)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError.keychain(added) }
        } else if status != errSecSuccess { throw StoreError.keychain(status) }
    }

    func clearSelectedRoom() throws {
        if Self.usesTemporarySimulatorIdentity {
            memoryLock.lock(); defer { memoryLock.unlock() }; temporaryRoom = nil; return
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
    }

    func document(roomID: String) throws -> Data? {
        if Self.usesTemporarySimulatorIdentity {
            guard UUID(uuidString: roomID) != nil else { throw StoreError.invalidRoom }
            memoryLock.lock(); defer { memoryLock.unlock() }; return temporaryDocuments[roomID]
        }
        let url = try documentURL(roomID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func saveDocument(_ data: Data, roomID: String) throws {
        guard data.count <= 64 * 1_024 * 1_024 else { throw StoreError.documentTooLarge }
        if Self.usesTemporarySimulatorIdentity {
            guard UUID(uuidString: roomID) != nil else { throw StoreError.invalidRoom }
            memoryLock.lock(); defer { memoryLock.unlock() }
            // Only the active test room is retained, keeping the harness memory bounded.
            temporaryDocuments = [roomID: data]; return
        }
        try data.write(to: documentURL(roomID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func documentURL(_ roomID: String) throws -> URL {
        guard let id = UUID(uuidString: roomID), let directory else { throw StoreError.invalidRoom }
        return directory.appendingPathComponent(id.uuidString).appendingPathExtension("automerge")
    }
    enum StoreError: Error { case keychain(OSStatus), invalidRoom, documentTooLarge }
}
