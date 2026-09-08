import Foundation

/// Length-prefixed JSON records. Callers feed at most one bounded socket read.
public struct NetworkDeviceMessageFraming {
    public static let maximumPayload = 24 * 1024
    private var buffer = Data()
    private var failed = false
    public init() {}
    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumPayload else { throw CodexDeviceMessagingError.invalidEnvelope }
        let count = UInt32(payload.count)
        return Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + payload
    }
    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard !failed, bytes.count <= Self.maximumPayload + 4,
              buffer.count + bytes.count <= 2 * (Self.maximumPayload + 4) else {
            failed = true; buffer.removeAll(); throw CodexDeviceMessagingError.capacity
        }
        buffer.append(bytes)
        var frames = [Data]()
        while buffer.count >= 4 {
            let count = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard count > 0, count <= Self.maximumPayload else {
                failed = true; buffer.removeAll(); throw CodexDeviceMessagingError.invalidEnvelope
            }
            guard buffer.count >= count + 4 else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(count)))
            buffer.removeFirst(count + 4)
        }
        return frames
    }
}
