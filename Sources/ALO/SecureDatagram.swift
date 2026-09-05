import Foundation
import CryptoKit

public enum SecureTransportError: Error, Equatable {
    case malformed, oversized, wrongContext, replay, nonceExhausted
    case invalidCredentials, missingTLSExporter, unsupportedProtocol, downgradeForbidden
    case capacity, expired, unvalidatedReturnPath, invalidState
}

public enum DatagramChannel: UInt8, Codable, CaseIterable, Sendable {
    case audio = 1, voice = 2, timing = 3, returnPath = 4
}

// Explicit network byte order; no alignment-dependent loads or untrusted allocation lengths.
struct WireBytes {
    var data = Data()
    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
    mutating func append(_ value: UUID) {
        var bytes = value.uuid
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }
    mutating func append(_ value: Data) { data.append(value) }
    mutating func field(_ value: Data) { append(UInt32(value.count)); append(value) }
}

struct WireReader {
    let data: Data
    var offset = 0
    mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        guard data.count - offset >= MemoryLayout<T>.size else { throw SecureTransportError.malformed }
        var value: T = 0
        for byte in data.dropFirst(offset).prefix(MemoryLayout<T>.size) { value = (value << 8) | T(byte) }
        offset += MemoryLayout<T>.size
        return value
    }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw SecureTransportError.malformed }
        defer { offset += count }
        return Data(data.dropFirst(offset).prefix(count))
    }
}

/// Sender and receiver order is significant: reversing them derives a different key.
public struct SecureDatagramContext: Equatable, Sendable {
    public let roomID: UUID
    public let senderID: UUID
    public let receiverID: UUID
    public let broadcasterEpoch: UInt64
    public let sessionID: UUID
    public let generation: UInt64
    public let channel: DatagramChannel

    public init(roomID: UUID, senderID: UUID, receiverID: UUID, broadcasterEpoch: UInt64,
                sessionID: UUID, generation: UInt64, channel: DatagramChannel) {
        self.roomID = roomID; self.senderID = senderID; self.receiverID = receiverID
        self.broadcasterEpoch = broadcasterEpoch; self.sessionID = sessionID
        self.generation = generation; self.channel = channel
    }

    var binding: Data {
        var wire = WireBytes()
        wire.append(Data("ALO/datagram/v2".utf8)); wire.append(roomID)
        wire.append(senderID); wire.append(receiverID); wire.append(broadcasterEpoch)
        wire.append(sessionID); wire.append(generation); wire.append(channel.rawValue)
        return wire.data
    }
}

public enum SecureDatagram {
    public static let headerSize = 48
    public static let tagSize = 16
    public static let maximumSize = 1_200
    public static let maximumPayloadSize = maximumSize - headerSize - tagSize
    static let magic: UInt32 = 0x414C4F32 // ALO2

    static func material(secret: SymmetricKey, context: SecureDatagramContext) throws -> (SymmetricKey, Data) {
        guard secret.bitCount >= 256 else { throw SecureTransportError.invalidCredentials }
        let material = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret,
            salt: Data("ALO/datagram/HKDF-SHA256/v2".utf8), info: context.binding, outputByteCount: 36)
        let bytes = material.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), Data(bytes.suffix(4)))
    }

    static func nonce(prefix: Data, sequence: UInt64) throws -> AES.GCM.Nonce {
        var wire = WireBytes(); wire.append(prefix); wire.append(sequence)
        return try AES.GCM.Nonce(data: wire.data)
    }

    static func header(context: SecureDatagramContext, sequence: UInt64, payloadSize: Int) -> Data {
        var wire = WireBytes(); wire.append(magic); wire.append(UInt8(2))
        wire.append(context.channel.rawValue); wire.append(UInt16(0)); wire.append(context.sessionID)
        wire.append(context.generation); wire.append(sequence); wire.append(UInt32(payloadSize)); wire.append(UInt32(0))
        return wire.data
    }
}

/// Own one sealer per direction/context on a serial executor. Never recreate it with the
/// same secret and context: reconnects must allocate a fresh session ID or generation.
/// Reference semantics prevent accidental sequence duplication by copying a value.
public final class DatagramSealer {
    public let context: SecureDatagramContext
    private let key: SymmetricKey
    private let noncePrefix: Data
    private var nextSequence: UInt64?
    private let lock = NSLock()

    public convenience init(secret: SymmetricKey, context: SecureDatagramContext) throws {
        try self.init(secret: secret, context: context, initialSequence: 0)
    }

    // Internal sequence injection is only for exhaustion tests; production always starts at zero.
    init(secret: SymmetricKey, context: SecureDatagramContext, initialSequence: UInt64) throws {
        self.context = context
        (key, noncePrefix) = try SecureDatagram.material(secret: secret, context: context)
        nextSequence = initialSequence
    }

    public func seal(_ payload: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard payload.count <= SecureDatagram.maximumPayloadSize else { throw SecureTransportError.oversized }
        guard let sequence = nextSequence else { throw SecureTransportError.nonceExhausted }
        // Consume before encryption, including failure paths.
        nextSequence = sequence == UInt64.max ? nil : sequence + 1
        let header = SecureDatagram.header(context: context, sequence: sequence, payloadSize: payload.count)
        let box = try AES.GCM.seal(payload, using: key,
            nonce: SecureDatagram.nonce(prefix: noncePrefix, sequence: sequence), authenticating: header)
        return header + box.ciphertext + box.tag
    }
}

/// A 64-packet replay window. Only successfully authenticated packets advance this window.
struct AuthenticatedReplayWindow: Sendable {
    private(set) var highest: UInt64?
    private var bitmap: UInt64 = 0
    func accepts(_ sequence: UInt64) -> Bool {
        guard let highest else { return true }
        if sequence > highest { return true }
        let distance = highest - sequence
        return distance < 64 && bitmap & (UInt64(1) << distance) == 0
    }
    mutating func record(_ sequence: UInt64) {
        guard let highest else { self.highest = sequence; bitmap = 1; return }
        if sequence > highest {
            let distance = sequence - highest
            bitmap = distance >= 64 ? 1 : (bitmap << distance) | 1
            self.highest = sequence
        } else { bitmap |= UInt64(1) << (highest - sequence) }
    }
}

/// Own on the same serial executor as its flow; authentication precedes replay mutation.
public final class DatagramOpener {
    public let context: SecureDatagramContext
    private let key: SymmetricKey
    private let noncePrefix: Data
    private var replay = AuthenticatedReplayWindow()
    private var authorization: (() -> Bool)?
    private let lock = NSLock()

    func bindAuthorization(_ authorization: @escaping () -> Bool) {
        lock.lock(); defer { lock.unlock() }; self.authorization = authorization
    }

    public init(secret: SymmetricKey, context: SecureDatagramContext) throws {
        self.context = context
        (key, noncePrefix) = try SecureDatagram.material(secret: secret, context: context)
    }

    public func open(_ packet: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard authorization?() ?? true else { throw SecureTransportError.invalidCredentials }
        guard packet.count <= SecureDatagram.maximumSize else { throw SecureTransportError.oversized }
        guard packet.count >= SecureDatagram.headerSize + SecureDatagram.tagSize else { throw SecureTransportError.malformed }
        var reader = WireReader(data: packet)
        guard try reader.integer(UInt32.self) == SecureDatagram.magic,
              try reader.integer(UInt8.self) == 2,
              try reader.integer(UInt8.self) == context.channel.rawValue,
              try reader.integer(UInt16.self) == 0 else { throw SecureTransportError.malformed }
        var session = WireBytes(); session.append(context.sessionID)
        guard try reader.bytes(16) == session.data,
              try reader.integer(UInt64.self) == context.generation else { throw SecureTransportError.wrongContext }
        let sequence = try reader.integer(UInt64.self)
        let length = try reader.integer(UInt32.self)
        guard try reader.integer(UInt32.self) == 0,
              Int(length) == packet.count - SecureDatagram.headerSize - SecureDatagram.tagSize else {
            throw SecureTransportError.malformed
        }
        guard replay.accepts(sequence) else { throw SecureTransportError.replay }
        let header = Data(packet.prefix(SecureDatagram.headerSize))
        let box = try AES.GCM.SealedBox(nonce: SecureDatagram.nonce(prefix: noncePrefix, sequence: sequence),
            ciphertext: reader.bytes(Int(length)), tag: reader.bytes(SecureDatagram.tagSize))
        let plaintext = try AES.GCM.open(box, using: key, authenticating: header)
        guard authorization?() ?? true else { throw SecureTransportError.invalidCredentials }
        replay.record(sequence)
        return plaintext
    }
}
