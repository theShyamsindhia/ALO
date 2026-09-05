import Contacts
import Foundation
import OSLog

protocol MessagesContactStoring {
    var authorizationStatus: CNAuthorizationStatus { get }

    func contact(matching identifier: String) throws -> CNContact?
}

final class SystemMessagesContactStore: MessagesContactStoring {

    // ARC cleanup owns no UI/executor work. Avoid the isolated-deinit
    // backdeployment thunk when released by a synchronous macOS 15 callback.
    nonisolated deinit {}

    private var storedContactStore: CNContactStore?
    private let initializationLock = NSLock()

    init(contactStore: CNContactStore? = nil) {
        self.storedContactStore = contactStore
    }

    private func authorizedContactStore() -> CNContactStore {
        initializationLock.lock()
        defer { initializationLock.unlock() }
        if let storedContactStore { return storedContactStore }
        let store = CNContactStore()
        storedContactStore = store
        return store
    }

    var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func contact(matching identifier: String) throws -> CNContact? {
        guard authorizationStatus == .authorized else { return nil }
        let contactStore = authorizedContactStore()
        let predicate: NSPredicate

        if identifier.contains("@") {
            predicate = CNContact.predicateForContacts(matchingEmailAddress: identifier)
        } else {
            predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: identifier))
        }

        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]

        return try contactStore.unifiedContacts(matching: predicate, keysToFetch: keys).first
    }
}

final class MessagesContactResolver {
    nonisolated deinit {}
    static let shared = MessagesContactResolver()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicNotch", category: "MessagesContactResolver")
    private let lock = NSLock()

    private let contactStore: any MessagesContactStoring
    private var cachedSenders: [String: MessagesSender] = [:]

    init(contactStore: any MessagesContactStoring = SystemMessagesContactStore()) {
        self.contactStore = contactStore
    }

    func sender(for identifier: String) -> MessagesSender {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedIdentifier.isEmpty else {
            return fallbackSender(for: normalizedIdentifier)
        }

        guard contactStore.authorizationStatus == .authorized else {
            return fallbackSender(for: normalizedIdentifier)
        }

        let cacheKey = normalizedIdentifier.lowercased()

        lock.lock()
        if let cachedSender = cachedSenders[cacheKey] {
            lock.unlock()
            return cachedSender
        }
        lock.unlock()

        // Guard against priority inversion: if invoked on the User-Interactive main thread
        // with the real system contact store, do not block the UI thread waiting on contactsd.
        // Return fallback immediately and resolve contact asynchronously on a background queue.
        if Thread.isMainThread && contactStore is SystemMessagesContactStore {
            let fallback = fallbackSender(for: normalizedIdentifier)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                _ = self.resolveAndCacheContact(for: normalizedIdentifier, cacheKey: cacheKey)
            }
            return fallback
        }

        return resolveAndCacheContact(for: normalizedIdentifier, cacheKey: cacheKey)
    }

    @discardableResult
    private func resolveAndCacheContact(for normalizedIdentifier: String, cacheKey: String) -> MessagesSender {
        do {
            guard let contact = try contactStore.contact(matching: normalizedIdentifier) else {
                return fallbackSender(for: normalizedIdentifier)
            }

            let formattedName = CNContactFormatter.string(from: contact, style: .fullName)
            let displayName = nonEmpty(formattedName) ?? nonEmpty(contact.organizationName) ?? normalizedIdentifier

            let sender = MessagesSender(
                identifier: normalizedIdentifier,
                displayName: displayName,
                avatarData: contact.thumbnailImageData,
                isKnownContact: true
            )

            lock.lock()
            cachedSenders[cacheKey] = sender
            lock.unlock()

            return sender
        } catch {
            logger.error("Could not resolve Messages contact: \(error.localizedDescription, privacy: .public)")
            return fallbackSender(for: normalizedIdentifier)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }

        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizedValue.isEmpty ? nil : normalizedValue
    }

    private func fallbackSender(for identifier: String) -> MessagesSender {
        MessagesSender(identifier: identifier, displayName: identifier, avatarData: nil)
    }
}
