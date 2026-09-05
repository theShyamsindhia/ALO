import Foundation
import ALOCore

enum MediaVideoWire {
    static let maximumFrameBytes = 4 * 1_024 * 1_024
    static let chunkBytes = 192 * 1_024
    static let frameDeadlineNanos: UInt64 = 5_000_000_000
    static let openDeadlineNanos: UInt64 = 25_000_000_000
    static let heartbeatIntervalNanos: UInt64 = 2_000_000_000
    static func heartbeat(_ nonce: UInt64, reply: Bool) -> Data {
        var wire = WireBytes()
        wire.append(UInt32(reply ? 0x414C_5651 : 0x414C_5650)); wire.append(nonce)
        return wire.data
    }
    static func heartbeatNonce(_ data: Data, reply: Bool) -> UInt64? {
        guard data.count == 12 else { return nil }
        var reader = WireReader(data: data)
        guard (try? reader.integer(UInt32.self)) == (reply ? 0x414C_5651 : 0x414C_5650) else { return nil }
        return try? reader.integer(UInt64.self)
    }
    struct Binding: Codable {
        let protocolName: String
        let version: UInt16
        let accepted: Bool
        let stream: MediaStreamIdentifier
    }
    static func binding(_ stream: MediaStreamIdentifier, accepted: Bool) throws -> Data {
        guard stream.generation < .max, stream.broadcasterEpoch < .max else { throw SecureTransportError.malformed }
        return try JSONEncoder().encode(Binding(protocolName: "alo.video", version: 2, accepted: accepted, stream: stream))
    }
    static func decodeBinding(_ data: Data, accepted: Bool) throws -> MediaStreamIdentifier {
        guard data.count <= 4_096 else { throw SecureTransportError.oversized }
        let message = try JSONDecoder().decode(Binding.self, from: data)
        guard message.protocolName == "alo.video", message.version == 2, message.accepted == accepted,
              message.stream.generation < .max, message.stream.broadcasterEpoch < .max else { throw SecureTransportError.malformed }
        return message.stream
    }
    static func validate(_ frame: VideoFrame) -> Bool {
        frame.captureTimeNanos <= UInt64(Int64.max) && frame.width > 0 && frame.width <= 8_192 &&
        frame.height > 0 && frame.height <= 8_192 && !frame.payload.isEmpty &&
        frame.parameterSet1.count <= 65_536 && frame.parameterSet2.count <= 65_536 &&
        36 + frame.parameterSet1.count + frame.parameterSet2.count + frame.payload.count <= maximumFrameBytes
    }
    static func chunk(_ data: Data, sequence: UInt64, offset: Int) -> Data {
        var wire = WireBytes()
        wire.append(UInt32(0x414C_5632)); wire.append(sequence)
        wire.append(UInt32(data.count)); wire.append(UInt32(offset))
        wire.append(data.subdata(in: offset..<min(data.count, offset + chunkBytes)))
        return wire.data
    }
}

/// One bounded frame at a time; any malformed or timed-out chunk terminates only
/// its video channel. Sequence/offset rules prevent partial-frame splicing.
struct MediaVideoAssembler {
    private var bytes = Data()
    private var total = 0
    private var sequence: UInt64 = 1
    private var started: UInt64?
    var assembling: Bool { started != nil }
    func expired(now: UInt64) -> Bool {
        started.map { now < $0 || now - $0 >= MediaVideoWire.frameDeadlineNanos } ?? false
    }
    mutating func append(_ data: Data, now: UInt64) throws -> VideoFrame? {
        guard data.count > 20, data.count <= MediaVideoWire.chunkBytes + 20, !expired(now: now) else {
            throw SecureTransportError.oversized
        }
        var reader = WireReader(data: data)
        guard try reader.integer(UInt32.self) == 0x414C_5632,
              try reader.integer(UInt64.self) == sequence else { throw SecureTransportError.wrongContext }
        let size = Int(try reader.integer(UInt32.self)), offset = Int(try reader.integer(UInt32.self))
        guard size >= 36, size <= MediaVideoWire.maximumFrameBytes, offset == bytes.count,
              data.count - 20 <= size - offset else { throw SecureTransportError.malformed }
        if started == nil { started = now; total = size }
        guard size == total else { throw SecureTransportError.malformed }
        bytes.append(data.dropFirst(20))
        guard bytes.count == total else { return nil }
        // The existing frame decoder remains the codec wire implementation, but
        // strict header checks prevent its permissive reset behavior hiding errors.
        guard bytes[4] == 1, bytes[5] <= 1, bytes[6] == 0, bytes[7] == 0 else { throw SecureTransportError.malformed }
        var lengths = WireReader(data: bytes, offset: 24)
        let first = Int(try lengths.integer(UInt32.self)), second = Int(try lengths.integer(UInt32.self))
        let payload = Int(try lengths.integer(UInt32.self))
        guard first <= 65_536, second <= 65_536, payload > 0,
              36 + first + second + payload == bytes.count else { throw SecureTransportError.malformed }
        let frames = VideoFrameStreamDecoder().append(bytes)
        guard frames.count == 1, let frame = frames.first, MediaVideoWire.validate(frame), sequence < .max else {
            throw SecureTransportError.malformed
        }
        bytes.removeAll(); started = nil; total = 0; sequence += 1
        return frame
    }
}
