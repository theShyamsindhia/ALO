import Foundation
import ALOCore

/// Multiplexed only inside an admitted media-control channel. Unknown peers do
/// not get annotation state; the application must complete capability exchange.
public enum AnnotationWireMessage: Codable, Sendable {
    case hello(capabilities: [String])
    case command(AnnotationCommand)
    case event(AnnotationEvent)
    case snapshotChunk(AnnotationSnapshotChunk)
    case requestSnapshot
    case rejection(commandID: UUID, reason: AnnotationRejection)
    case ended(sessionID: UUID)

    public static let capability = "annotations.v1"
    public static let maximumWireBytes = 196_608

    private struct Envelope: Codable {
        let protocolName: String
        let message: AnnotationWireMessage
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(Envelope(protocolName: Self.capability, message: self))
        guard data.count <= Self.maximumWireBytes else { throw SecureTransportError.oversized }
        return data
    }

    public init(encoded data: Data) throws {
        guard data.count <= Self.maximumWireBytes else { throw SecureTransportError.oversized }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.protocolName == Self.capability else { throw SecureTransportError.unsupportedProtocol }
        try envelope.message.validate()
        self = envelope.message
    }

    private func validate() throws {
        switch self {
        case .hello(let capabilities):
            guard capabilities.count <= 16, capabilities.allSatisfy({ $0.utf8.count <= 64 }),
                  Set(capabilities).count == capabilities.count else { throw SecureTransportError.malformed }
        case .command(let command):
            guard try JSONEncoder().encode(command).count <= AnnotationAuthority.maximumPayloadBytes else {
                throw SecureTransportError.oversized
            }
        case .event(let event):
            guard event.revision < UInt64.max else { throw SecureTransportError.malformed }
            if case .upsert(let object) = event.change { try Self.validate(object) }
        case .snapshotChunk(let chunk): try chunk.validate()
        default: break
        }
    }

    static func validate(_ object: AnnotationObject) throws {
        guard object.revision < UInt64.max, !object.authorID.isEmpty, object.authorID.utf8.count <= 256,
              !object.points.isEmpty, object.points.count <= AnnotationAuthority.maximumPoints,
              object.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              AnnotationAuthority.colors.contains(object.color), object.width.isFinite,
              (0.001...0.05).contains(object.width) else { throw SecureTransportError.malformed }
    }
}

public struct AnnotationSnapshotChunk: Codable, Sendable {
    public let transferID: UUID
    public let sessionID: UUID
    public let index: Int
    public let count: Int
    public let bytes: Data
    public static let chunkBytes = 131_072
    public static let maximumSnapshotBytes = 8 * 1_024 * 1_024

    public init(transferID: UUID, sessionID: UUID, index: Int, count: Int, bytes: Data) throws {
        self.transferID = transferID; self.sessionID = sessionID
        self.index = index; self.count = count; self.bytes = bytes
        try validate()
    }

    func validate() throws {
        guard (1...64).contains(count), (0..<count).contains(index), !bytes.isEmpty,
              bytes.count <= Self.chunkBytes,
              index == count - 1 || bytes.count == Self.chunkBytes else { throw SecureTransportError.malformed }
    }

    public static func split(_ snapshot: AnnotationSnapshot) throws -> [Self] {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumSnapshotBytes else { throw SecureTransportError.oversized }
        let count = (data.count + chunkBytes - 1) / chunkBytes
        let transferID = UUID()
        return try (0..<count).map { index in
            let lower = index * chunkBytes
            return try Self(transferID: transferID, sessionID: snapshot.sessionID, index: index,
                            count: count, bytes: data.subdata(in: lower..<min(lower + chunkBytes, data.count)))
        }
    }
}

/// One bounded, ordered snapshot in flight per admitted peer. A malicious peer
/// cannot retain arbitrary parallel transfers, trickle forever or splice sessions.
public struct AnnotationSnapshotAssembler {
    private var transferID: UUID?
    private var sessionID: UUID?
    private var count = 0
    private var nextIndex = 0
    private var deadlineNanos: UInt64 = 0
    private var bytes = Data()
    public var bufferedByteCount: Int { bytes.count }
    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func append(_ chunk: AnnotationSnapshotChunk, nowNanos: UInt64) throws -> AnnotationSnapshot? {
        do {
            try chunk.validate()
            if transferID == nil {
                guard chunk.index == 0 else { throw SecureTransportError.malformed }
                transferID = chunk.transferID; sessionID = chunk.sessionID; count = chunk.count
                deadlineNanos = nowNanos > UInt64.max - 10_000_000_000 ? .max : nowNanos + 10_000_000_000
            }
            guard nowNanos < deadlineNanos, transferID == chunk.transferID,
                  sessionID == chunk.sessionID, count == chunk.count, nextIndex == chunk.index,
                  bytes.count <= AnnotationSnapshotChunk.maximumSnapshotBytes - chunk.bytes.count else {
                throw SecureTransportError.malformed
            }
            bytes.append(chunk.bytes); nextIndex += 1
            guard nextIndex == count else { return nil }
            let snapshot = try JSONDecoder().decode(AnnotationSnapshot.self, from: bytes)
            guard snapshot.sessionID == sessionID, snapshot.revision < UInt64.max,
                  snapshot.objects.count <= AnnotationAuthority.maximumObjects,
                  snapshot.leases.count <= 128, snapshot.commandSequences.count <= 128,
                  snapshot.objects.allSatisfy({ $0.points.count <= AnnotationAuthority.maximumPoints }),
                  Set(snapshot.objects.map(\.id)).count == snapshot.objects.count else {
                throw SecureTransportError.malformed
            }
            for object in snapshot.objects { try AnnotationWireMessage.validate(object) }
            reset()
            return snapshot
        } catch {
            reset()
            throw error
        }
    }
}
