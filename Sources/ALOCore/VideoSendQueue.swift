import Foundation

/// Encoded H.264 must recover at a configuration-bearing IDR after any drop.
/// Owned by the sender's serial queue; in-flight TCP work is bounded separately.
public struct VideoSendQueue {
    public struct Entry {
        public let frame: VideoFrame
        public let enqueuedNanos: UInt64
        public var byteCount: Int {
            36 + frame.parameterSet1.count + frame.parameterSet2.count + frame.payload.count
        }
    }
    public let maximumBytes: Int
    public let maximumFrames: Int
    public let maximumAgeNanos: UInt64
    public private(set) var requiresKeyframe = true
    public private(set) var byteCount = 0
    public var count: Int { entries.count }
    private var entries: [Entry] = []

    public init(maximumBytes: Int = 4 * 1_024 * 1_024, maximumFrames: Int = 8,
                maximumAgeNanos: UInt64 = 250_000_000) {
        precondition(maximumBytes > 36 && maximumFrames > 0 && maximumAgeNanos > 0)
        self.maximumBytes = maximumBytes; self.maximumFrames = maximumFrames
        self.maximumAgeNanos = maximumAgeNanos
    }

    @discardableResult public mutating func append(_ frame: VideoFrame, nowNanos: UInt64) -> Bool {
        if let first = entries.first,
           nowNanos < first.enqueuedNanos || nowNanos - first.enqueuedNanos > maximumAgeNanos {
            reset()
        }
        let entry = Entry(frame: frame, enqueuedNanos: nowNanos)
        guard entry.byteCount <= maximumBytes else { reset(); return false }
        if count >= maximumFrames || byteCount > maximumBytes - entry.byteCount { reset() }
        if requiresKeyframe {
            guard frame.isKeyframe, !frame.parameterSet1.isEmpty, !frame.parameterSet2.isEmpty else { return false }
            requiresKeyframe = false
        }
        entries.append(entry)
        byteCount += entry.byteCount
        return true
    }

    public mutating func takeNext(nowNanos: UInt64) -> Entry? {
        guard let first = entries.first else { return nil }
        guard nowNanos >= first.enqueuedNanos,
              nowNanos - first.enqueuedNanos <= maximumAgeNanos else { reset(); return nil }
        entries.removeFirst()
        byteCount -= first.byteCount
        return first
    }

    public mutating func reset() {
        entries.removeAll(keepingCapacity: false)
        byteCount = 0
        requiresKeyframe = true
    }
}
