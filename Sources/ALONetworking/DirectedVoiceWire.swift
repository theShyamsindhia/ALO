import Foundation

/// A logical local Talk/Open Line transmission, independent of transport ticket
/// renewal. A fresh user action uses a fresh UUID; its recipient snapshot is fixed.
public struct VoiceSessionIdentifier: Codable, Equatable, Hashable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64
    public init(sessionID: UUID, generation: UInt64 = 1) {
        self.sessionID = sessionID; self.generation = generation
    }
    var isValid: Bool { generation > 0 && generation < .max }
}

enum DirectedVoiceWire {
    static let maximumControlBytes = 4_096
    static let pcmBytes = 960
    enum Message {
        case subscribe(UUID, VoiceSessionIdentifier)
        case grant(UUID, VoiceSessionIdentifier, MediaSubscriptionTicket, UInt16)
        case ready(UUID)
        case reject(UUID)
        case ping(UInt64)
        case pong(UInt64)
    }
    private enum Payload: Codable {
        case subscribe(UUID, VoiceSessionIdentifier)
        case grant(UUID, VoiceSessionIdentifier, Data, UInt16)
        case ready(UUID), reject(UUID), ping(UInt64), pong(UInt64)
    }
    private struct Envelope: Codable {
        let protocolName: String
        let version: UInt8
        let message: Payload
    }
    static func encode(_ message: Message) throws -> Data {
        let payload: Payload
        switch message {
        case let .subscribe(id, session):
            guard session.isValid else { throw SecureTransportError.malformed }
            payload = .subscribe(id, session)
        case let .grant(id, session, ticket, port):
            guard session.isValid, port > 0, ticket.channels == [.voice],
                  ticket.broadcasterEpoch == session.generation,
                  ticket.subscriptionSequence > 0, ticket.subscriptionSequence < .max,
                  ticket.validForSeconds > 0, ticket.validForSeconds <= 30 else { throw SecureTransportError.malformed }
            payload = .grant(id, session, try ticket.encoded(), port)
        case .ready(let id): payload = .ready(id)
        case .reject(let id): payload = .reject(id)
        case .ping(let id): payload = .ping(id)
        case .pong(let id): payload = .pong(id)
        }
        let bytes = try JSONEncoder().encode(Envelope(protocolName: "alo.directed-voice", version: 2, message: payload))
        guard bytes.count <= maximumControlBytes else { throw SecureTransportError.oversized }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> Message {
        guard bytes.count <= maximumControlBytes else { throw SecureTransportError.oversized }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.protocolName == "alo.directed-voice", envelope.version == 2 else { throw SecureTransportError.unsupportedProtocol }
        let message: Message
        switch envelope.message {
        case let .subscribe(id, session): message = .subscribe(id, session)
        case let .grant(id, session, ticket, port): message = .grant(id, session, try MediaSubscriptionTicket(encoded: ticket), port)
        case .ready(let id): message = .ready(id)
        case .reject(let id): message = .reject(id)
        case .ping(let id): message = .ping(id)
        case .pong(let id): message = .pong(id)
        }
        _ = try encode(message); return message
    }

    struct Packet {
        let sequence: UInt64
        let frameIndex: UInt64
        let captureTimeNanos: UInt64
        let pcm: Data
        func encoded() -> Data {
            var wire = WireBytes()
            wire.append(UInt32(0x414C_5032)); wire.append(sequence); wire.append(frameIndex)
            wire.append(captureTimeNanos); wire.append(pcm)
            return wire.data
        }
        static func decode(_ data: Data) throws -> Self {
            guard data.count == 28 + pcmBytes else { throw SecureTransportError.malformed }
            var reader = WireReader(data: data)
            guard try reader.integer(UInt32.self) == 0x414C_5032 else { throw SecureTransportError.malformed }
            let sequence = try reader.integer(UInt64.self), frame = try reader.integer(UInt64.self)
            let capture = try reader.integer(UInt64.self)
            guard sequence <= UInt64.max / 480, frame == sequence * 480, capture <= UInt64(Int64.max) else {
                throw SecureTransportError.malformed
            }
            return Self(sequence: sequence, frameIndex: frame, captureTimeNanos: capture, pcm: try reader.bytes(pcmBytes))
        }
    }
}
