import Foundation
import ALOCore

public enum AppleMediaError: Error, Equatable {
    case invalidPCM, invalidAnchor, clockNotReady, late, tooFarAhead, capacity, duplicate, invalidState
    case microphoneDenied, unavailableInput, audioConfiguration, generationExhausted
}

/// A v2 microphone packet before the transport adds its authenticated envelope.
/// At 48 kHz, 480 mono PCM16 samples occupy 960 bytes and represent 10 ms.
public struct VoicePCMChunk: Sendable, Equatable {
    public static let sampleRate = 48_000
    public static let framesPerChunk = 480
    public let frameIndex: UInt64
    public let captureTimeNanos: UInt64
    public let samples: [Int16]

    public init(frameIndex: UInt64, captureTimeNanos: UInt64, samples: [Int16]) throws {
        guard samples.count == Self.framesPerChunk else { throw AppleMediaError.invalidPCM }
        self.frameIndex = frameIndex
        self.captureTimeNanos = captureTimeNanos
        self.samples = samples
    }
}

/// Broadcaster clock values: the first capture frame will become audible at the
/// agreed future host time. ClockSynchronizer supplies host-minus-local offset.
public struct AudioPlaybackAnchor: Sendable, Equatable {
    public let captureTimeNanos: UInt64
    public let hostPlaybackTimeNanos: UInt64
    public init(captureTimeNanos: UInt64, hostPlaybackTimeNanos: UInt64) {
        self.captureTimeNanos = captureTimeNanos
        self.hostPlaybackTimeNanos = hostPlaybackTimeNanos
    }
}

public struct AudioBufferToken: Hashable, Sendable {
    public let generation: UInt64
    public let frameIndex: UInt64
}

public struct ScheduledPCMBuffer: Sendable {
    public let token: AudioBufferToken
    public let renderTimeNanos: UInt64
    public let samples: [Int16]
    public let channels: UInt32
    public var frameCount: Int { samples.count / Int(channels) }
}

public struct AudioSchedulingLimits: Sendable {
    public let maximumBuffers: Int
    public let schedulingHorizonNanos: UInt64
    public let maximumFutureNanos: UInt64
    public let minimumLeadNanos: UInt64

    public init(maximumBuffers: Int = 128, schedulingHorizonNanos: UInt64 = 100_000_000,
                maximumFutureNanos: UInt64 = 2_000_000_000, minimumLeadNanos: UInt64 = 3_000_000) {
        self.maximumBuffers = min(512, max(1, maximumBuffers))
        self.minimumLeadNanos = min(50_000_000, minimumLeadNanos)
        self.schedulingHorizonNanos = max(self.minimumLeadNanos, min(500_000_000, schedulingHorizonNanos))
        self.maximumFutureNanos = max(self.schedulingHorizonNanos, min(5_000_000_000, maximumFutureNanos))
    }
}

/// A bounded jitter/scheduling queue. All times are monotonic nanoseconds;
/// invalidation drops queued and scheduled ownership before accepting a new anchor.
public struct PCMPlaybackScheduler: Sendable {
    private struct Pending: Sendable {
        let frameIndex: UInt64
        let captureTimeNanos: UInt64
        let samples: [Int16]
        let channels: UInt32
        var frameCount: UInt64 { UInt64(samples.count / Int(channels)) }
    }
    public let limits: AudioSchedulingLimits
    public private(set) var generation: UInt64 = 0
    public private(set) var lateDrops: UInt64 = 0
    public private(set) var anchor: AudioPlaybackAnchor?
    public var pendingCount: Int { pending.count }
    public var scheduledCount: Int { scheduled.count }
    public var bufferedCount: Int { pending.count + scheduled.count }
    private var offsetNanos: Int64 = 0
    private var outputLatencyNanos: UInt64 = 0
    private var pending: [UInt64: Pending] = [:]
    private var scheduled = Set<AudioBufferToken>()
    private var lastScheduledFrameEnd: UInt64?
    private var exhausted = false

    public init(limits: AudioSchedulingLimits = .init()) { self.limits = limits }

    public mutating func setAnchor(_ anchor: AudioPlaybackAnchor, clockOffsetNanos: Int64,
                                  outputLatencyNanos: UInt64, nowNanos: UInt64) throws {
        invalidate()
        guard !exhausted else { throw AppleMediaError.generationExhausted }
        guard let local = Self.localTime(hostTime: anchor.hostPlaybackTimeNanos, offset: clockOffsetNanos),
              local > outputLatencyNanos,
              local - outputLatencyNanos > nowNanos,
              local - outputLatencyNanos - nowNanos >= limits.minimumLeadNanos else {
            throw AppleMediaError.invalidAnchor
        }
        self.anchor = anchor
        offsetNanos = clockOffsetNanos
        self.outputLatencyNanos = outputLatencyNanos
    }

    /// Apply fresh drift estimates only to buffers that have not been scheduled.
    public mutating func updateClockOffset(_ offsetNanos: Int64) { self.offsetNanos = offsetNanos }

    public mutating func enqueueMedia(_ packet: AudioPacket, nowNanos: UInt64) throws {
        guard !packet.samples.isEmpty, packet.samples.count.isMultiple(of: 2),
              packet.samples.count <= Int(AudioPacket.framesPerPacket) * 2 else { throw AppleMediaError.invalidPCM }
        try enqueue(Pending(frameIndex: packet.frameIndex, captureTimeNanos: packet.captureTimeNanos,
                            samples: packet.samples, channels: 2), now: nowNanos)
    }

    public mutating func enqueueVoice(_ chunk: VoicePCMChunk, nowNanos: UInt64) throws {
        try enqueue(Pending(frameIndex: chunk.frameIndex, captureTimeNanos: chunk.captureTimeNanos,
                            samples: chunk.samples, channels: 1), now: nowNanos)
    }

    public mutating func drain(nowNanos: UInt64) -> [ScheduledPCMBuffer] {
        var result: [ScheduledPCMBuffer] = []
        for packet in pending.values.sorted(by: { $0.frameIndex < $1.frameIndex }) {
            guard let render = renderTime(for: packet.captureTimeNanos) else {
                pending.removeValue(forKey: packet.frameIndex); continue
            }
            if render <= nowNanos || render - nowNanos < limits.minimumLeadNanos {
                pending.removeValue(forKey: packet.frameIndex)
                lateDrops = lateDrops == .max ? .max : lateDrops + 1
                continue
            }
            if render - nowNanos > limits.schedulingHorizonNanos { continue }
            pending.removeValue(forKey: packet.frameIndex)
            if let end = lastScheduledFrameEnd, packet.frameIndex < end { continue }
            let (end, overflow) = packet.frameIndex.addingReportingOverflow(packet.frameCount)
            guard !overflow else { continue }
            let token = AudioBufferToken(generation: generation, frameIndex: packet.frameIndex)
            scheduled.insert(token)
            lastScheduledFrameEnd = end
            result.append(ScheduledPCMBuffer(token: token, renderTimeNanos: render,
                                             samples: packet.samples, channels: packet.channels))
        }
        return result
    }

    /// A completion from a previous engine/route cannot release a new buffer.
    @discardableResult public mutating func completed(_ token: AudioBufferToken) -> Bool {
        guard token.generation == generation else { return false }
        return scheduled.remove(token) != nil
    }

    public mutating func invalidate() {
        if generation == .max { exhausted = true } else { generation += 1 }
        anchor = nil
        pending.removeAll(keepingCapacity: true)
        scheduled.removeAll(keepingCapacity: true)
        lastScheduledFrameEnd = nil
    }

    private mutating func enqueue(_ packet: Pending, now: UInt64) throws {
        guard !exhausted, anchor != nil else { throw AppleMediaError.invalidState }
        guard let render = renderTime(for: packet.captureTimeNanos) else { throw AppleMediaError.invalidAnchor }
        guard render > now, render - now >= limits.minimumLeadNanos else {
            lateDrops = lateDrops == .max ? .max : lateDrops + 1
            throw AppleMediaError.late
        }
        guard render - now <= limits.maximumFutureNanos else { throw AppleMediaError.tooFarAhead }
        guard pending[packet.frameIndex] == nil,
              !scheduled.contains(AudioBufferToken(generation: generation, frameIndex: packet.frameIndex)),
              lastScheduledFrameEnd.map({ packet.frameIndex >= $0 }) ?? true else { throw AppleMediaError.duplicate }
        guard !packet.frameIndex.addingReportingOverflow(packet.frameCount).overflow else { throw AppleMediaError.invalidPCM }
        guard bufferedCount < limits.maximumBuffers else { throw AppleMediaError.capacity }
        pending[packet.frameIndex] = packet
    }

    private func renderTime(for capture: UInt64) -> UInt64? {
        guard let anchor, capture >= anchor.captureTimeNanos else { return nil }
        let (host, overflow) = anchor.hostPlaybackTimeNanos.addingReportingOverflow(capture - anchor.captureTimeNanos)
        guard !overflow, let local = Self.localTime(hostTime: host, offset: offsetNanos),
              local >= outputLatencyNanos else { return nil }
        return local - outputLatencyNanos
    }

    static func localTime(hostTime: UInt64, offset: Int64) -> UInt64? {
        if offset >= 0 {
            let magnitude = UInt64(offset)
            return hostTime >= magnitude ? hostTime - magnitude : nil
        }
        let magnitude = UInt64(-(offset + 1)) + 1
        let (local, overflow) = hostTime.addingReportingOverflow(magnitude)
        return overflow ? nil : local
    }
}
