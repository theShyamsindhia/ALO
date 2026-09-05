import Foundation
import ALOCore

/// A publisher's capture clock, shared by local playback and every subscription.
/// Joining or repairing a receiver reads this reference; it never retimes it.
public final class CapturedMediaTimeline: @unchecked Sendable {
    public struct PlayoutCutover: Equatable, Sendable {
        public let captureTimeNanos: UInt64
        public let frameIndex: UInt64
        public let playoutDelayNanos: UInt64
    }
    private let lock = NSLock()
    private var latest: AudioPacket?
    private var playing = true
    private var delay = RoomTiming.defaultPlayoutDelayNanos
    private var pendingCutover: PlayoutCutover?
    private var cutoverAnnounced = false

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
                if cutoverAnnounced, let cutover = pendingCutover, packet.captureTimeNanos >= cutover.captureTimeNanos,
                   packet.frameIndex >= cutover.frameIndex {
                    delay = cutover.playoutDelayNanos
                    pendingCutover = nil
                    cutoverAnnounced = false
                }
            }
            return playing && lackedReference && latest != nil
        }
    }

    public func invalidateCaptureReference() { lock.withLock { latest = nil } }

    public func setPlaying(_ value: Bool) {
        lock.withLock {
            if playing != value {
                latest = nil
                if cutoverAnnounced, let cutover = pendingCutover { delay = cutover.playoutDelayNanos }
                pendingCutover = nil
                cutoverAnnounced = false
            }
            playing = value
        }
    }

    public func setPlayoutDelay(_ nanos: UInt64) {
        lock.withLock { delay = RoomTiming.clampedPlayoutDelay(nanos); pendingCutover = nil; cutoverAnnounced = false }
    }

    public var playoutDelayNanos: UInt64 { lock.withLock { delay } }
    public var requestedPlayoutDelayNanos: UInt64 { lock.withLock { pendingCutover?.playoutDelayNanos ?? delay } }

    /// One immutable future capture boundary, announced to local and remote
    /// renderers before any output switches. Repeated reports cannot move it.
    /// Live decreases are prohibited; paused/initial timelines can change safely.
    public func schedulePlayoutDelay(_ nanos: UInt64, now: UInt64) -> PlayoutCutover? {
        lock.withLock {
            guard pendingCutover == nil else { return nil }
            let requested = RoomTiming.clampedPlayoutDelay(nanos)
            guard requested != delay else { return nil }
            guard playing, let latest else { delay = requested; return nil }
            guard requested > delay, latest.captureTimeNanos <= now,
                  now - latest.captureTimeNanos < 130_000_000 else { return nil }
            // Half a second of preparation lead, aligned to the source's 5 ms
            // packet grid. This is an extrapolated capture clock, not join time.
            let target = now.addingReportingOverflow(500_000_000)
            guard !target.overflow else { return nil }
            let count = (target.partialValue - latest.captureTimeNanos + 4_999_999) / 5_000_000
            let capture = latest.captureTimeNanos.addingReportingOverflow(count * 5_000_000)
            let frame = latest.frameIndex.addingReportingOverflow(count * 240)
            guard !capture.overflow, !frame.overflow,
                  capture.partialValue <= UInt64(Int64.max) - requested else { return nil }
            let cutover = PlayoutCutover(captureTimeNanos: capture.partialValue, frameIndex: frame.partialValue,
                playoutDelayNanos: requested)
            pendingCutover = cutover
            cutoverAnnounced = false
            return cutover
        }
    }

    /// Only after the broadcaster's own renderer accepted this future boundary.
    @discardableResult public func announce(_ cutover: PlayoutCutover) -> Bool {
        lock.withLock {
            guard pendingCutover == cutover else { return false }
            cutoverAnnounced = true
            return true
        }
    }

    public func cancelUnannounced(_ cutover: PlayoutCutover) {
        lock.withLock {
            if !cutoverAnnounced, pendingCutover == cutover { pendingCutover = nil }
        }
    }

    public func anchor(for stream: MediaStreamIdentifier, issuedAtHostNanos now: UInt64) -> MediaStreamAnchor? {
        lock.withLock {
            if playing, cutoverAnnounced, let cutover = pendingCutover {
                return MediaStreamAnchor(stream: stream, captureTimeNanos: cutover.captureTimeNanos,
                    frameIndex: cutover.frameIndex,
                    hostPlaybackTimeNanos: cutover.captureTimeNanos + cutover.playoutDelayNanos,
                    issuedAtHostNanos: now)
            }
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
