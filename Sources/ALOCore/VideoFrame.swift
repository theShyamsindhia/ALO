import Foundation

public struct VideoFrame: Sendable, Equatable {
    private static let magic: UInt32 = 0x5745_5256
    private static let headerSize = 36
    private static let maximumFrameSize = 12 * 1_024 * 1_024

    public let captureTimeNanos: UInt64
    public let width: UInt32
    public let height: UInt32
    public let isKeyframe: Bool
    public let parameterSet1: Data
    public let parameterSet2: Data
    public let payload: Data

    public init(
        captureTimeNanos: UInt64,
        width: UInt32,
        height: UInt32,
        isKeyframe: Bool,
        parameterSet1: Data = Data(),
        parameterSet2: Data = Data(),
        payload: Data
    ) {
        self.captureTimeNanos = captureTimeNanos
        self.width = width
        self.height = height
        self.isKeyframe = isKeyframe
        self.parameterSet1 = parameterSet1
        self.parameterSet2 = parameterSet2
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + parameterSet1.count + parameterSet2.count + payload.count)
        data.appendBigEndian(Self.magic)
        data.append(1)
        data.append(isKeyframe ? 1 : 0)
        data.append(contentsOf: [0, 0])
        data.appendBigEndian(captureTimeNanos)
        data.appendBigEndian(width)
        data.appendBigEndian(height)
        data.appendBigEndian(UInt32(parameterSet1.count))
        data.appendBigEndian(UInt32(parameterSet2.count))
        data.appendBigEndian(UInt32(payload.count))
        data.append(parameterSet1)
        data.append(parameterSet2)
        data.append(payload)
        return data
    }

    fileprivate static func decode(from data: Data) -> VideoFrame? {
        guard data.count >= headerSize,
              data.readBigEndian(UInt32.self, at: 0) == magic,
              data[4] == 1,
              let captureTime = data.readBigEndian(UInt64.self, at: 8),
              let width = data.readBigEndian(UInt32.self, at: 16),
              let height = data.readBigEndian(UInt32.self, at: 20),
              let firstLength = data.readBigEndian(UInt32.self, at: 24),
              let secondLength = data.readBigEndian(UInt32.self, at: 28),
              let payloadLength = data.readBigEndian(UInt32.self, at: 32)
        else { return nil }

        let total = headerSize + Int(firstLength) + Int(secondLength) + Int(payloadLength)
        guard total == data.count, total <= maximumFrameSize else { return nil }
        var offset = headerSize
        let first = data.subdata(in: offset..<(offset + Int(firstLength)))
        offset += Int(firstLength)
        let second = data.subdata(in: offset..<(offset + Int(secondLength)))
        offset += Int(secondLength)
        let payload = data.subdata(in: offset..<total)
        return VideoFrame(
            captureTimeNanos: captureTime,
            width: width,
            height: height,
            isKeyframe: data[5] & 1 == 1,
            parameterSet1: first,
            parameterSet2: second,
            payload: payload
        )
    }
}

public final class VideoFrameStreamDecoder {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) -> [VideoFrame] {
        buffer.append(data)
        var frames = [VideoFrame]()

        while buffer.count >= 36 {
            guard buffer.readBigEndian(UInt32.self, at: 0) == 0x5745_5256,
                  let firstLength = buffer.readBigEndian(UInt32.self, at: 24),
                  let secondLength = buffer.readBigEndian(UInt32.self, at: 28),
                  let payloadLength = buffer.readBigEndian(UInt32.self, at: 32)
            else {
                buffer.removeAll()
                break
            }

            let total = 36 + Int(firstLength) + Int(secondLength) + Int(payloadLength)
            guard total <= 12 * 1_024 * 1_024 else {
                buffer.removeAll()
                break
            }
            guard buffer.count >= total else { break }
            let frameData = buffer.subdata(in: 0..<total)
            buffer.removeSubrange(0..<total)
            if let frame = VideoFrame.decode(from: frameData) {
                frames.append(frame)
            }
        }
        return frames
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        guard offset >= 0, count >= offset + MemoryLayout<T>.size else { return nil }
        return self.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> T in
            var value: T = 0
            Swift.withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: rawBuffer[offset..<(offset + MemoryLayout<T>.size)])
            }
            return T(bigEndian: value)
        }
    }
}
