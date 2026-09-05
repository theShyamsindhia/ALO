import CryptoKit
import Foundation

public struct RoomChatAttachment: Codable, Sendable, Equatable, Hashable, Identifiable {
    public static let maximumBytes = 8 * 1_024 * 1_024
    public let id: String
    public let fileName: String
    public let contentType: String?
    public let byteCount: Int

    public init(id: String = UUID().uuidString, fileName: String, contentType: String? = nil, byteCount: Int) {
        self.id = id
        self.fileName = URL(fileURLWithPath: fileName).lastPathComponent
        self.contentType = contentType
        self.byteCount = byteCount
    }

    public var isValid: Bool {
        UUID(uuidString: id) != nil && id.utf8.count <= 128
            && !fileName.isEmpty && fileName != "." && fileName != ".." && fileName.utf8.count <= 255
            && URL(fileURLWithPath: fileName).lastPathComponent == fileName
            && !fileName.contains("/") && !fileName.contains("\\")
            && byteCount > 0 && byteCount <= Self.maximumBytes
            && (contentType?.utf8.count ?? 0) <= 128
            && !(contentType ?? "").unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public struct RoomChatAttachmentPayload: Sendable, Equatable {
    public let attachment: RoomChatAttachment
    public let data: Data

    public init?(attachment: RoomChatAttachment, data: Data) {
        guard attachment.isValid, data.count == attachment.byteCount else { return nil }
        self.attachment = attachment
        self.data = data
    }
}

public struct RoomChatAttachmentPacket: Codable, Sendable, Equatable {
    public static let chunkBytes = 96 * 1_024
    public static let maximumChunks = 96
    public let attachment: RoomChatAttachment
    public let digest: Data
    public let chunkIndex: Int
    public let chunkCount: Int
    public let bytes: Data

    public var isValid: Bool {
        attachment.isValid && digest.count == SHA256.Digest.byteCount
            && chunkCount > 0 && chunkCount <= Self.maximumChunks
            && chunkIndex >= 0 && chunkIndex < chunkCount
            && !bytes.isEmpty && bytes.count <= Self.chunkBytes
    }

    public static func packets(for payload: RoomChatAttachmentPayload) -> [Self] {
        let digest = Data(SHA256.hash(data: payload.data))
        let count = (payload.data.count + chunkBytes - 1) / chunkBytes
        guard count > 0, count <= maximumChunks else { return [] }
        return (0..<count).map { index in
            let start = index * chunkBytes
            let end = min(start + chunkBytes, payload.data.count)
            return Self(attachment: payload.attachment, digest: digest, chunkIndex: index,
                        chunkCount: count, bytes: payload.data.subdata(in: start..<end))
        }
    }
}

public struct RoomChatAttachmentAssembler: Sendable {
    private struct Pending: Sendable {
        let attachment: RoomChatAttachment
        let digest: Data
        let chunkCount: Int
        var nextChunk: Int
        var data: Data
    }
    private var pending = [String: Pending]()
    private var order = [String]()
    private let maximumActiveTransfers = 8

    public init() {}

    public mutating func receive(senderID: String, packet: RoomChatAttachmentPacket) -> RoomChatAttachmentPayload? {
        guard !senderID.isEmpty, packet.isValid else { return nil }
        let key = senderID + "|" + packet.attachment.id
        if packet.chunkIndex == 0 {
            if pending[key] == nil, pending.count >= maximumActiveTransfers, let oldest = order.first {
                pending.removeValue(forKey: oldest)
                order.removeFirst()
            }
            pending[key] = Pending(attachment: packet.attachment, digest: packet.digest,
                                   chunkCount: packet.chunkCount, nextChunk: 0, data: Data())
            order.removeAll { $0 == key }
            order.append(key)
        }
        guard var transfer = pending[key], transfer.attachment == packet.attachment,
              transfer.digest == packet.digest, transfer.chunkCount == packet.chunkCount,
              transfer.nextChunk == packet.chunkIndex,
              transfer.data.count <= packet.attachment.byteCount - packet.bytes.count else {
            pending.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        transfer.data.append(packet.bytes)
        transfer.nextChunk += 1
        if transfer.nextChunk < transfer.chunkCount {
            pending[key] = transfer
            return nil
        }
        pending.removeValue(forKey: key)
        order.removeAll { $0 == key }
        guard transfer.data.count == transfer.attachment.byteCount,
              Data(SHA256.hash(data: transfer.data)) == transfer.digest else { return nil }
        return RoomChatAttachmentPayload(attachment: transfer.attachment, data: transfer.data)
    }
}
