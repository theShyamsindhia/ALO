import Foundation

public struct AudioPacket: Equatable, Sendable {
    public static let sampleRate: UInt32 = 48_000
    public static let channelCount: UInt16 = 2
    public static let framesPerPacket: UInt16 = 240

    private static let magic: UInt32 = 0x5745_5241 // WERA
    private static let version: UInt8 = 1
    private static let headerSize = 36

    public let sequence: UInt32
    public let frameIndex: UInt64
    public let captureTimeNanos: UInt64
    public let samples: [Int16]

    public init(sequence: UInt32, frameIndex: UInt64, captureTimeNanos: UInt64, samples: [Int16]) {
        self.sequence = sequence
        self.frameIndex = frameIndex
        self.captureTimeNanos = captureTimeNanos
        self.samples = samples
    }

    public var frameCount: UInt16 {
        UInt16(samples.count / Int(Self.channelCount))
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + samples.count * MemoryLayout<Int16>.size)
        data.appendLittleEndian(Self.magic)
        data.append(Self.version)
        data.append(0)
        data.appendLittleEndian(Self.channelCount)
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(frameIndex)
        data.appendLittleEndian(captureTimeNanos)
        data.appendLittleEndian(Self.sampleRate)
        data.appendLittleEndian(frameCount)
        data.appendLittleEndian(UInt16(0))

        for sample in samples {
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }
        return data
    }

    public init?(data: Data) {
        guard data.count >= Self.headerSize else { return nil }
        var reader = DataReader(data)
        guard reader.read(UInt32.self) == Self.magic,
              reader.read(UInt8.self) == Self.version
        else { return nil }

        _ = reader.read(UInt8.self)
        guard reader.read(UInt16.self) == Self.channelCount,
              let sequence = reader.read(UInt32.self),
              let frameIndex = reader.read(UInt64.self),
              let captureTimeNanos = reader.read(UInt64.self),
              reader.read(UInt32.self) == Self.sampleRate,
              let frameCount = reader.read(UInt16.self)
        else { return nil }

        _ = reader.read(UInt16.self)
        let sampleCount = Int(frameCount) * Int(Self.channelCount)
        guard frameCount > 0,
              frameCount <= Self.framesPerPacket,
              data.count == Self.headerSize + sampleCount * MemoryLayout<Int16>.size
        else { return nil }

        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            guard let bits = reader.read(UInt16.self) else { return nil }
            samples.append(Int16(bitPattern: bits))
        }

        self.init(
            sequence: sequence,
            frameIndex: frameIndex,
            captureTimeNanos: captureTimeNanos,
            samples: samples
        )
    }
}

public final class AudioPacketizer {
    private let packetFrames = Int(AudioPacket.framesPerPacket)
    private let channels = Int(AudioPacket.channelCount)
    private var pendingSamples = [Int16]()
    private var pendingStartNanos: UInt64?
    private var nextSequence: UInt32 = 0
    private var nextFrameIndex: UInt64 = 0

    public init() {}

    public func append(samples: [Int16], captureTimeNanos: UInt64) -> [AudioPacket] {
        guard !samples.isEmpty, samples.count.isMultiple(of: channels) else { return [] }

        if pendingSamples.isEmpty {
            pendingStartNanos = captureTimeNanos
        }
        pendingSamples.append(contentsOf: samples)

        let samplesPerPacket = packetFrames * channels
        var packets = [AudioPacket]()
        var consumedSamples = 0
        var packetStartNanos = pendingStartNanos ?? captureTimeNanos

        while pendingSamples.count - consumedSamples >= samplesPerPacket {
            let end = consumedSamples + samplesPerPacket
            let packetSamples = Array(pendingSamples[consumedSamples..<end])
            packets.append(AudioPacket(
                sequence: nextSequence,
                frameIndex: nextFrameIndex,
                captureTimeNanos: packetStartNanos,
                samples: packetSamples
            ))

            nextSequence &+= 1
            nextFrameIndex &+= UInt64(packetFrames)
            consumedSamples = end
            packetStartNanos &+= UInt64(packetFrames) * 1_000_000_000 / UInt64(AudioPacket.sampleRate)
        }

        if consumedSamples > 0 {
            pendingSamples.removeFirst(consumedSamples)
            pendingStartNanos = pendingSamples.isEmpty ? nil : packetStartNanos
        }
        return packets
    }
}

private struct DataReader {
    let data: Data
    var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let byteCount = MemoryLayout<T>.size
        guard offset + byteCount <= data.count else { return nil }
        var value: T = 0
        for index in 0..<byteCount {
            value |= T(data[offset + index]) << T(index * 8)
        }
        offset += byteCount
        return value
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
