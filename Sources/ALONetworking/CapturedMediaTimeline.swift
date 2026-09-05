import Foundation
import ALOCore

/// A publisher's capture clock, shared by local playback and every subscription.
/// Joining or repairing a receiver reads this reference; it never retimes it.
public final class CapturedMediaTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: AudioPacket?
    private var playing = true
    private var delay = RoomTiming.defaultPlayoutDelayNanos

    public init() {}

    /// True only when a missing running reference becomes available. The owner
    /// refreshes waiting anchors once after this call, outside its capture lock.
    @discardableResult public func observe(_ packets: [AudioPacket]) -> Bool {
        lock.withLock {
            let lackedReference = latest == nil
            for packet in packets {
                guard !packet.samples.isEmpty,
                      packet.samples.count <= Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount),
                      packet.samples.count.isMultiple(of: Int(AudioPacket.channelCount)),
                      packet.frameIndex <= UInt64.max - UInt64(packet.frameCount),
                      latest.map({ packet.frameIndex > $0.frameIndex && packet.captureTimeNanos >= $0.captureTimeNanos }) ?? true
                else { continue }
                latest = packet
            }
            return playing && lackedReference && latest != nil
        }
    }

    public func invalidateCaptureReference() { lock.withLock { latest = nil } }

    public func setPlaying(_ value: Bool) {
        lock.withLock {
            if playing != value { latest = nil }
            playing = value
        }
    }

    public func setPlayoutDelay(_ nanos: UInt64) {
        lock.withLock { delay = RoomTiming.clampedPlayoutDelay(nanos) }
    }

    public var playoutDelayNanos: UInt64 { lock.withLock { delay } }

    public func anchor(for stream: MediaStreamIdentifier, issuedAtHostNanos now: UInt64) -> MediaStreamAnchor? {
        lock.withLock {
            let capture: UInt64
            let frame: UInt64
            if playing {
                // Do not resurrect pre-pause capture, or invent a frame reference
                // from join time when the publisher has not captured anything yet.
                guard let latest, latest.captureTimeNanos <= now,
                      now - latest.captureTimeNanos < delay - 120_000_000 else { return nil }
                capture = latest.captureTimeNanos
                frame = latest.frameIndex
            } else {
                capture = now
                frame = latest.map { $0.frameIndex + UInt64($0.frameCount) } ?? 0
            }
            let playback = capture.addingReportingOverflow(delay)
            guard !playback.overflow else { return nil }
            return MediaStreamAnchor(stream: stream, captureTimeNanos: capture, frameIndex: frame,
                hostPlaybackTimeNanos: playback.partialValue, issuedAtHostNanos: now,
                state: playing ? .running : .paused)
        }
    }
}
