import Foundation

/// Versioned social-chat operations carried by the existing bounded chat channel.
/// No activity frames or media data enter this history.
public struct RoomChatOperation: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case message, edit, delete, reaction, pin }
    public static let prefix = "[ALO chat v1] "
    public static let maximumTextLength = 700
    public static let emoji = ["❤️", "😂", "🔥", "👏", "👍", "🎮"]
    public let id: UUID
    public let kind: Kind
    public let target: UUID?
    public let text: String?
    public let enabled: Bool?
    public let timestamp: UInt64
    public let mentionedParticipantIDs: [String]?
    public let attachment: RoomChatAttachment?

    public init(id: UUID = UUID(), kind: Kind, target: UUID? = nil, text: String? = nil, enabled: Bool? = nil, timestamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000), mentionedParticipantIDs: [String]? = nil, attachment: RoomChatAttachment? = nil) {
        self.mentionedParticipantIDs = mentionedParticipantIDs
        self.attachment = attachment
        self.id = id; self.kind = kind; self.target = target
        self.text = text; self.enabled = enabled; self.timestamp = timestamp
    }

    public var encoded: String? {
        guard isValid, let data = try? JSONEncoder().encode(self), let json = String(data: data, encoding: .utf8) else { return nil }
        let wire = Self.prefix + json
        return wire.count <= 2000 ? wire : nil
    }

    public static func decode(_ text: String) -> Self? {
        guard text.hasPrefix(prefix), text.count <= 2000,
              let operation = try? JSONDecoder().decode(Self.self, from: Data(text.dropFirst(prefix.count).utf8)), operation.isValid else { return nil }
        return operation
    }

    private var isValid: Bool {
        if let ids = mentionedParticipantIDs {
            guard ids.count <= 8, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
                  ids.reduce(0, { $0 + $1.utf8.count }) <= 512 else { return false }
        }
        switch kind {
        case .message:
            let cleanText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !cleanText.isEmpty || attachment?.isValid == true,
                  cleanText.count <= Self.maximumTextLength,
                  !cleanText.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { return false }
            return attachment == nil || attachment?.isValid == true
        case .edit:
            guard attachment == nil, target != nil, let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= Self.maximumTextLength,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { return false }
            return true
        case .delete: return target != nil && attachment == nil
        case .reaction: return target != nil && Self.emoji.contains(text ?? "") && enabled != nil && attachment == nil
        case .pin: return target != nil && enabled != nil && attachment == nil
        }
    }
}

public struct RoomChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let senderID: String
    public let sender: String
    public var text: String
    public let sentNanos: UInt64
    public var replyTo: UUID?
    public var mentionedParticipantIDs: [String]?
    public var attachment: RoomChatAttachment?
    public var edited = false
    public var deleted = false
    public var pinned = false
    public var reactions: [String: Set<String>] = [:]
    public init(id: UUID = UUID(), senderID: String, sender: String, text: String, sentNanos: UInt64, replyTo: UUID? = nil, mentionedParticipantIDs: [String]? = nil, attachment: RoomChatAttachment? = nil) {
        self.mentionedParticipantIDs = mentionedParticipantIDs
        self.attachment = attachment
        self.id = id; self.senderID = senderID; self.sender = sender
        self.text = text; self.sentNanos = sentNanos; self.replyTo = replyTo
    }

    public var previewText: String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        return attachment.map { "Sent a file · \($0.fileName)" } ?? "Message"
    }
}

/// Replays operations in a deterministic order, including edits arriving before
/// their message. Deletion wins permanently; only the original author may edit
/// or delete. Pins are collaborative and reactions belong to their sender.
public struct RoomChatDocument: Sendable {
    private struct Entry: Sendable {
        let operation: RoomChatOperation
        let senderID: String
        let sender: String
        let sentNanos: UInt64
        let version: MeshVersion
    }
    private var entries: [UUID: Entry] = [:]
    public private(set) var messages: [RoomChatMessage] = []
    public init() {}

    @discardableResult
    public mutating func receive(senderID: String, sender: String, text: String, sentNanos: UInt64, version: MeshVersion) -> Bool {
        // Tray mutations share the durable chat transport for compatibility,
        // but are reduced by RoomTrayDocument and must never appear as messages.
        if text.hasPrefix(RoomTrayOperation.prefix) { return false }
        let operation: RoomChatOperation
        if text.hasPrefix(RoomChatOperation.prefix) {
            guard let decoded = RoomChatOperation.decode(text) else { return false }
            operation = decoded
        } else {
            // Legacy text has a stable ID on every peer, allowing replies to it.
            operation = RoomChatOperation(id: Self.legacyID(senderID + "|" + String(sentNanos) + "|" + text), kind: .message, text: String(text.prefix(2000)), timestamp: 0)
        }
        guard entries[operation.id] == nil else { return false }
        entries[operation.id] = Entry(operation: operation, senderID: senderID, sender: sender, sentNanos: sentNanos, version: version)
        rebuild()
        return operation.kind == .message
    }

    private mutating func rebuild() {
        let ordered = entries.values.sorted {
            // Use the replica's common Lamport order for every format; sender
            // uptime and the rich payload's user timestamp cannot reorder chat.
            if $0.version != $1.version { return $0.version < $1.version }
            return $0.operation.id.uuidString < $1.operation.id.uuidString
        }
        var result: [UUID: RoomChatMessage] = [:]
        var order: [UUID] = []
        for entry in ordered where entry.operation.kind == .message {
            let op = entry.operation
            result[op.id] = RoomChatMessage(id: op.id, senderID: entry.senderID, sender: entry.sender, text: op.text ?? "", sentNanos: entry.sentNanos, replyTo: op.target, mentionedParticipantIDs: op.mentionedParticipantIDs, attachment: op.attachment)
            order.append(op.id)
        }
        for entry in ordered where entry.operation.kind != .message {
            let op = entry.operation
            guard let target = op.target, var message = result[target], !message.deleted else { continue }
            switch op.kind {
            case .edit:
                if entry.senderID == message.senderID { message.text = op.text ?? message.text; message.mentionedParticipantIDs = op.mentionedParticipantIDs; message.edited = true }
            case .delete:
                if entry.senderID == message.senderID { message.deleted = true; message.text = "Message deleted"; message.mentionedParticipantIDs = nil; message.attachment = nil; message.reactions = [:]; message.pinned = false }
            case .reaction:
                let emoji = op.text ?? ""
                if op.enabled == true { message.reactions[emoji, default: []].insert(entry.senderID) }
                else { message.reactions[emoji]?.remove(entry.senderID) }
            case .pin: message.pinned = op.enabled == true
            case .message: break
            }
            result[target] = message
        }
        messages = order.suffix(500).compactMap { result[$0] }
        // Drop whole conversations rather than individual tombstones, so a
        // bounded in-memory log never resurrects a deleted retained message.
        while entries.count > 4000, let oldest = messages.first {
            entries = entries.filter { $0.key != oldest.id && ($0.value.operation.kind == .message || $0.value.operation.target != oldest.id) }
            messages.removeFirst()
        }
        if entries.count > 4000 {
            let retained = Set(ordered.suffix(4000).map { $0.operation.id })
            entries = entries.filter { retained.contains($0.key) }
        }
    }

    private static func legacyID(_ value: String) -> UUID {
        var a: UInt64 = 14695981039346656037
        var b: UInt64 = 1099511628211
        for byte in value.utf8 { a = (a ^ UInt64(byte)) &* 1099511628211; b = (b ^ UInt64(byte)) &* 14695981039346656037 }
        let hex = String(format: "%016llx%016llx", a, b)
        let chars = Array(hex)
        let formatted = [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-")
        return UUID(uuidString: formatted)!
    }
}
