import CryptoKit
import Foundation

/// Immutable file metadata carried by the durable room-tray operation log.
/// File bytes travel separately on the bounded attachment channel.
public struct RoomTrayItemMetadata: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let attachment: RoomChatAttachment
    public let digest: Data

    public var id: String { UUID(uuidString: attachment.id)?.uuidString ?? attachment.id }
    public var sha256Digest: Data { digest }

    public init(attachment: RoomChatAttachment, digest: Data) {
        self.attachment = attachment
        self.digest = digest
    }

    public init?(attachment: RoomChatAttachment, data: Data) {
        guard let payload = RoomChatAttachmentPayload(attachment: attachment, data: data) else {
            return nil
        }
        self.init(attachment: payload.attachment, digest: Data(SHA256.hash(data: payload.data)))
    }

    public var isValid: Bool {
        attachment.isValid && digest.count == SHA256.Digest.byteCount
    }
}

/// A versioned tray mutation encoded as chat text so older ALO versions can
/// safely ignore it without failing room-state decoding.
public struct RoomTrayOperation: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case add
        case remove
    }

    /// Nest under the established chat marker. Older clients attempt to decode
    /// this as rich chat, fail closed, and never display the JSON as a legacy
    /// text message.
    public static let prefix = RoomChatOperation.prefix + "[ALO tray v1] "
    public static let maximumWireBytes = 2_000

    public let id: UUID
    public let kind: Kind
    public let item: RoomTrayItemMetadata?
    public let targetItemID: String?
    public let timestamp: UInt64

    public init(
        id: UUID = UUID(),
        kind: Kind,
        item: RoomTrayItemMetadata? = nil,
        targetItemID: String? = nil,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) {
        self.id = id
        self.kind = kind
        self.item = item
        self.targetItemID = targetItemID
        self.timestamp = timestamp
    }

    public static func add(
        _ item: RoomTrayItemMetadata,
        id: UUID = UUID(),
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) -> Self {
        Self(id: id, kind: .add, item: item, timestamp: timestamp)
    }

    public static func remove(
        itemID: String,
        id: UUID = UUID(),
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) -> Self {
        Self(id: id, kind: .remove, targetItemID: itemID, timestamp: timestamp)
    }

    public var encoded: String? {
        guard isValid,
              let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        let wire = Self.prefix + json
        return wire.utf8.count <= Self.maximumWireBytes ? wire : nil
    }

    public static func decode(_ text: String) -> Self? {
        guard text.hasPrefix(prefix), text.utf8.count <= maximumWireBytes,
              let operation = try? JSONDecoder().decode(
                Self.self,
                from: Data(text.dropFirst(prefix.count).utf8)
              ),
              operation.isValid
        else { return nil }
        return operation
    }

    public var isValid: Bool {
        switch kind {
        case .add:
            return item?.isValid == true && targetItemID == nil
        case .remove:
            return item == nil && Self.isValidItemID(targetItemID)
        }
    }

    private static func isValidItemID(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.utf8.count <= 128 && UUID(uuidString: value) != nil
    }
}

/// A bounded transient request for a missing room-tray blob. Any peer with a
/// verified cached copy may answer it.
public struct RoomTrayFileRequest: Codable, Sendable, Equatable {
    public let itemID: String
    public let digest: Data

    public init(itemID: String, digest: Data) {
        self.itemID = itemID
        self.digest = digest
    }

    public var isValid: Bool {
        itemID.utf8.count <= 128 && UUID(uuidString: itemID) != nil
            && digest.count == SHA256.Digest.byteCount
    }

    public var canonicalItemID: String? { UUID(uuidString: itemID)?.uuidString }
}

/// A materialized tray row. The operation's authenticated sender is retained
/// separately from the immutable file metadata for attribution in the UI.
public struct RoomTrayItem: Identifiable, Sendable, Equatable {
    public let metadata: RoomTrayItemMetadata
    public let addedByID: String
    public let addedBy: String
    public let version: MeshVersion

    public var id: String { metadata.id }
    public var attachment: RoomChatAttachment { metadata.attachment }
    public var digest: Data { metadata.digest }

    public init(
        metadata: RoomTrayItemMetadata,
        addedByID: String,
        addedBy: String,
        version: MeshVersion
    ) {
        self.metadata = metadata
        self.addedByID = addedByID
        self.addedBy = addedBy
        self.version = version
    }
}

/// Deterministically reduces the durable room-tray operation set. Removes are
/// collaborative and permanent for an item ID, including when they arrive
/// before the matching add. New files therefore always need a fresh UUID.
public struct RoomTrayDocument: Sendable {
    public static let maximumActiveItems = 32
    public static let maximumActiveBytes = 64 * 1_024 * 1_024
    public static let maximumHistory = 512

    private struct Entry: Sendable {
        let operation: RoomTrayOperation
        let senderID: String
        let sender: String
        let version: MeshVersion
    }

    private var entries: [UUID: Entry] = [:]
    public private(set) var items: [RoomTrayItem] = []
    var retainedOperationCount: Int { entries.count }

    public init() {}

    public init(events: [MeshRoomEvent]) {
        self.init()
        for event in events.sorted(by: Self.eventPrecedes) {
            _ = receive(event)
        }
    }

    /// Applies one durable chat event when it contains a tray operation.
    @discardableResult
    public mutating func receive(_ event: MeshRoomEvent) -> Bool {
        guard event.kind == .chat,
              let senderID = event.senderID,
              let text = event.text
        else { return false }
        return receive(
            senderID: senderID,
            sender: event.sender ?? senderID,
            text: text,
            version: event.version
        )
    }

    /// Returns true when `text` is a valid, previously unseen tray operation.
    @discardableResult
    public mutating func receive(
        senderID: String,
        sender: String,
        text: String,
        version: MeshVersion
    ) -> Bool {
        guard senderID == version.nodeID, let operation = RoomTrayOperation.decode(text) else {
            return false
        }
        return receive(operation, senderID: senderID, sender: sender, version: version)
    }

    /// Accepts the already-decoded form used by local optimistic updates.
    @discardableResult
    public mutating func receive(
        _ operation: RoomTrayOperation,
        senderID: String,
        sender: String,
        version: MeshVersion
    ) -> Bool {
        guard senderID == version.nodeID, operation.isValid, entries[operation.id] == nil else {
            return false
        }
        entries[operation.id] = Entry(
            operation: operation,
            senderID: senderID,
            sender: sender,
            version: version
        )
        compactHistory()
        rebuild()
        return true
    }

    public func item(id: String) -> RoomTrayItem? {
        guard let canonicalID = Self.canonicalItemID(id) else { return nil }
        return items.first { $0.id == canonicalID }
    }

    public func contains(itemID: String, digest: Data) -> Bool {
        guard let canonicalID = Self.canonicalItemID(itemID) else { return false }
        return items.contains { $0.id == canonicalID && $0.digest == digest }
    }

    private mutating func compactHistory() {
        guard entries.count > Self.maximumHistory else { return }
        let retained = entries.values.sorted(by: Self.entryPrecedes).suffix(Self.maximumHistory)
        entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.operation.id, $0) })
    }

    private mutating func rebuild() {
        let ordered = entries.values.sorted(by: Self.entryPrecedes)
        let removedIDs = Set<String>(ordered.compactMap { entry -> String? in
            guard entry.operation.kind == .remove,
                  let target = entry.operation.targetItemID
            else { return nil }
            return Self.canonicalItemID(target)
        })

        var latestAddByItemID: [String: Entry] = [:]
        for entry in ordered where entry.operation.kind == .add {
            guard let item = entry.operation.item, !removedIDs.contains(item.id) else { continue }
            latestAddByItemID[item.id] = entry
        }

        var retained: [Entry] = []
        var retainedBytes = 0
        for entry in latestAddByItemID.values.sorted(by: Self.entryPrecedes).reversed() {
            guard retained.count < Self.maximumActiveItems,
                  let item = entry.operation.item,
                  retainedBytes <= Self.maximumActiveBytes - item.attachment.byteCount
            else { continue }
            retained.append(entry)
            retainedBytes += item.attachment.byteCount
        }

        items = retained.reversed().compactMap { entry in
            guard let metadata = entry.operation.item else { return nil }
            return RoomTrayItem(
                metadata: metadata,
                addedByID: entry.senderID,
                addedBy: entry.sender,
                version: entry.version
            )
        }
    }

    private static func entryPrecedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.version != rhs.version { return lhs.version < rhs.version }
        return lhs.operation.id.uuidString < rhs.operation.id.uuidString
    }

    private static func eventPrecedes(_ lhs: MeshRoomEvent, _ rhs: MeshRoomEvent) -> Bool {
        if lhs.version != rhs.version { return lhs.version < rhs.version }
        return lhs.id < rhs.id
    }

    private static func canonicalItemID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString
    }
}
