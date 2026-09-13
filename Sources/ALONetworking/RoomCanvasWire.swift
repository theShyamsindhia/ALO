import Foundation
import CryptoKit
import ALOCore

/// A separate application protocol. These messages must only be accepted on
/// an admitted canvas connection, never on screen-sharing annotation channels.
public enum RoomCanvasMessage: Codable, Sendable {
    case join
    case requestCheckpoint
    case requestImage(sha256: Data)
    case checkpointChunk(RoomCanvasChunk)
    case imageChunk(RoomCanvasChunk)
    case command(AnnotationCommand)
    case update(RoomCanvasUpdate)
    case rejected(commandID: UUID, reason: AnnotationRejection)
    case ended

    public static let capability = "alo.room-canvas.v1"
    public static let maximumWireBytes = 196_608
    private struct Envelope: Codable {
        let protocolName: String
        let roomID: UUID
        let canvasID: UUID
        let message: RoomCanvasMessage
    }

    public func encoded(roomID: UUID, canvasID: UUID) throws -> Data {
        try validate(canvasID: canvasID)
        let bytes = try JSONEncoder().encode(Envelope(protocolName: Self.capability,
            roomID: roomID, canvasID: canvasID, message: self))
        guard bytes.count <= Self.maximumWireBytes else { throw SecureTransportError.oversized }
        return bytes
    }

    public init(encoded bytes: Data, roomID: UUID, canvasID: UUID) throws {
        guard bytes.count <= Self.maximumWireBytes else { throw SecureTransportError.oversized }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.protocolName == Self.capability else { throw SecureTransportError.unsupportedProtocol }
        guard envelope.roomID == roomID, envelope.canvasID == canvasID else { throw SecureTransportError.wrongContext }
        try envelope.message.validate(canvasID: canvasID)
        self = envelope.message
    }

    private func validate(canvasID: UUID) throws {
        switch self {
        case .requestImage(let digest):
            guard digest.count == 32 else { throw SecureTransportError.malformed }
        case .checkpointChunk(let chunk), .imageChunk(let chunk): try chunk.validate()
        case .command(let command):
            guard try JSONEncoder().encode(command).count <= AnnotationAuthority.maximumPayloadBytes else {
                throw SecureTransportError.oversized
            }
        case .update(let update):
            guard update.canvasID == canvasID, update.revision > 0, update.revision < UInt64.max,
                  update.events.count <= AnnotationAuthority.maximumObjects + 1,
                  update.participants.map({ $0.count <= 64 }) ?? true,
                  update.commandSequences.count <= 128,
                  update.commandSequences.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value < UInt64.max })
            else { throw SecureTransportError.malformed }
            for event in update.events {
                guard event.sessionID == update.annotationSessionID, event.revision < UInt64.max else {
                    throw SecureTransportError.malformed
                }
                if case .upsert(let object) = event.change { try AnnotationWireMessage.validate(object) }
            }
        default: break
        }
    }
}

/// Image and checkpoint payloads use separate assemblers on each canvas
/// connection. Each holds at most 8 MB and verifies the complete SHA-256.
public struct RoomCanvasChunk: Codable, Sendable {
    public static let maximumPayloadBytes = 8 * 1_024 * 1_024
    public static let chunkBytes = 65_536
    public let transferID: UUID
    public let offset: Int
    public let totalBytes: Int
    public let sha256: Data
    public let bytes: Data

    public init(transferID: UUID, offset: Int, totalBytes: Int, sha256: Data, bytes: Data) {
        self.transferID = transferID; self.offset = offset; self.totalBytes = totalBytes
        self.sha256 = sha256; self.bytes = bytes
    }

    func validate() throws {
        guard (1...Self.maximumPayloadBytes).contains(totalBytes), offset >= 0, offset < totalBytes,
              offset.isMultiple(of: Self.chunkBytes), sha256.count == 32,
              bytes.count == min(Self.chunkBytes, totalBytes - offset) else { throw SecureTransportError.malformed }
    }

    public static func split(_ data: Data) throws -> [Self] {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else { throw SecureTransportError.oversized }
        let id = UUID(), digest = Data(SHA256.hash(data: data))
        return stride(from: 0, to: data.count, by: chunkBytes).map { offset in
            .init(transferID: id, offset: offset, totalBytes: data.count, sha256: digest,
                  bytes: data.subdata(in: offset..<min(offset + chunkBytes, data.count)))
        }
    }

    public static func checkpoint(_ snapshot: RoomCanvasSnapshot) throws -> [Self] {
        guard snapshot.isValid else { throw SecureTransportError.malformed }
        return try split(JSONEncoder().encode(snapshot))
    }
}

public struct RoomCanvasPayloadAssembler: Sendable {
    private let expectedImage: RoomCanvasImage?
    private var transferID: UUID?
    private var totalBytes = 0
    private var digest = Data()
    private var deadline: UInt64 = 0
    private var bytes = Data()
    public var bufferedByteCount: Int { bytes.count }

    /// Pass the complete descriptor for image downloads. Checkpoints
    /// instead validate their decoded room/canvas/owner and state before apply.
    public init(image: RoomCanvasImage? = nil) { self.expectedImage = image }

    public mutating func reset() {
        transferID = nil; totalBytes = 0; digest.removeAll(); deadline = 0; bytes.removeAll()
    }

    /// The connection owner must tick this even when no more chunks arrive.
    @discardableResult
    public mutating func expire(nowNanos: UInt64) -> Bool {
        guard transferID != nil, nowNanos >= deadline else { return false }
        reset()
        return true
    }

    public mutating func append(_ chunk: RoomCanvasChunk, nowNanos: UInt64) throws -> Data? {
        do {
            try chunk.validate()
            if transferID == nil {
                guard chunk.offset == 0 else { throw SecureTransportError.wrongContext }
                if let image = expectedImage, !image.isValid || image.sha256 != chunk.sha256 || image.byteCount != chunk.totalBytes {
                    throw SecureTransportError.wrongContext
                }
                transferID = chunk.transferID; totalBytes = chunk.totalBytes; digest = chunk.sha256
                deadline = nowNanos > UInt64.max - 10_000_000_000 ? .max : nowNanos + 10_000_000_000
            }
            guard nowNanos < deadline, transferID == chunk.transferID, totalBytes == chunk.totalBytes,
                  digest == chunk.sha256, chunk.offset == bytes.count else { throw SecureTransportError.malformed }
            bytes.append(chunk.bytes)
            guard bytes.count == totalBytes else { return nil }
            guard Data(SHA256.hash(data: bytes)) == digest else { throw SecureTransportError.malformed }
            let result = bytes
            reset()
            return result
        } catch {
            reset()
            throw error
        }
    }
}
