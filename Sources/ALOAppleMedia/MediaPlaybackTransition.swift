import Foundation
import ALOCore

/// Output-only make-before-break state. Transport generations belong to the
/// caller; these tokens identify render ownership across route/engine resets.
/// Preparing (including a failed preparation) never mutates the live scheduler.
public struct MediaPlaybackTransition: Sendable {
    public struct Delivery: Sendable {
        public let trackID: UUID
        public let buffer: ScheduledPCMBuffer
    }
    private struct Track: Sendable {
        let id: UUID
        let anchor: AudioPlaybackAnchor
        let renderBoundary: UInt64
        let outputLatencyNanos: UInt64
        var scheduler: PCMPlaybackScheduler
    }
    private var active: Track?
    private var proposed: Track?
    private var committed: Track?
    private var retiring: Track?
    private var latestOffsetNanos: Int64?
    private var continuousProposal: UUID?
    public var trackIDs: Set<UUID> { Set([active?.id, committed?.id, retiring?.id].compactMap { $0 }) }
    public var activeID: UUID? { active?.id }
    public var hasScheduledAudio: Bool {
        (active?.scheduler.scheduledCount ?? 0) + (committed?.scheduler.scheduledCount ?? 0) > 0
    }
    public init() {}

    public mutating func prepare(id: UUID, anchor: AudioPlaybackAnchor, offsetNanos: Int64,
                                 outputLatencyNanos: UInt64, nowNanos: UInt64,
                                 preserveCurrentTimeline: Bool = false) throws {
        guard committed == nil else { throw AppleMediaError.capacity }
        continuousProposal = nil
        var scheduler = PCMPlaybackScheduler()
        try scheduler.setAnchor(anchor, clockOffsetNanos: offsetNanos,
                                outputLatencyNanos: outputLatencyNanos, nowNanos: nowNanos)
        guard let local = PCMPlaybackScheduler.localTime(hostTime: anchor.hostPlaybackTimeNanos, offset: offsetNanos),
              local >= outputLatencyNanos else { throw AppleMediaError.invalidAnchor }
        let boundary = local - outputLatencyNanos
        if preserveCurrentTimeline, let active,
           active.outputLatencyNanos == outputLatencyNanos,
           active.anchor.hostPlaybackTimeNanos >= active.anchor.captureTimeNanos,
           anchor.hostPlaybackTimeNanos >= anchor.captureTimeNanos,
           active.anchor.hostPlaybackTimeNanos - active.anchor.captureTimeNanos == anchor.hostPlaybackTimeNanos - anchor.captureTimeNanos {
            // A ticket renewal on the same publisher timeline is not an output
            // discontinuity. Keep scheduled buffers and the hardware player.
            proposed = nil; continuousProposal = id; return
        }
        guard retiring == nil else { throw AppleMediaError.capacity }
        if preserveCurrentTimeline, let active,
           anchor.hostPlaybackTimeNanos >= anchor.captureTimeNanos,
           active.anchor.hostPlaybackTimeNanos >= active.anchor.captureTimeNanos,
           anchor.hostPlaybackTimeNanos - anchor.captureTimeNanos > active.anchor.hostPlaybackTimeNanos - active.anchor.captureTimeNanos,
           active.scheduler.lastScheduledCaptureEndNanos.map({ $0 > anchor.captureTimeNanos }) == true {
            // The room has already committed a larger delay, but this local
            // renderer crossed its capture boundary. Retrying that boundary on
            // the old timeline cannot succeed; let the owner reset ONLY itself.
            throw AppleMediaError.missedCutover
        }
        guard active?.scheduler.lastScheduledRenderEndNanos.map({ $0 <= boundary }) ?? true,
              active?.scheduler.lastScheduledCaptureEndNanos.map({ $0 <= anchor.captureTimeNanos }) ?? true else {
            throw AppleMediaError.invalidAnchor
        }
        proposed = Track(id: id, anchor: anchor, renderBoundary: boundary,
                         outputLatencyNanos: outputLatencyNanos, scheduler: scheduler)
        latestOffsetNanos = offsetNanos
    }

    /// ACK may be delayed. Recheck admission without destroying the predecessor
    /// if its already-scheduled buffers now overlap this proposed boundary.
    public mutating func commit(id: UUID, nowNanos: UInt64) throws {
        if continuousProposal == id, active != nil {
            continuousProposal = nil; return
        }
        guard let proposed, proposed.id == id, committed == nil,
              proposed.renderBoundary > nowNanos,
              active?.scheduler.lastScheduledRenderEndNanos.map({ $0 <= proposed.renderBoundary }) ?? true,
              active?.scheduler.lastScheduledCaptureEndNanos.map({ $0 <= proposed.anchor.captureTimeNanos }) ?? true else {
            throw AppleMediaError.invalidAnchor
        }
        var successor = proposed
        var predecessor = active
        try predecessor?.scheduler.transferPendingMedia(atOrAfterCaptureTimeNanos: proposed.anchor.captureTimeNanos,
                                                         to: &successor.scheduler, nowNanos: nowNanos)
        self.proposed = nil
        if predecessor == nil { active = successor }
        else { active = predecessor; committed = successor }
    }

    /// Receiver deduplication spans old/new tickets. Once committed, route by
    /// capture boundary, not whichever authenticated ticket delivered first.
    public mutating func enqueue(_ packet: AudioPacket, nowNanos: UInt64) throws {
        if let next = committed, packet.captureTimeNanos >= next.anchor.captureTimeNanos {
            try committed!.scheduler.enqueueMedia(packet, nowNanos: nowNanos)
        } else {
            guard active != nil else { throw AppleMediaError.invalidState }
            try active!.scheduler.enqueueMedia(packet, nowNanos: nowNanos)
        }
    }

    public mutating func drain(nowNanos: UInt64) -> [Delivery] {
        if let committed, nowNanos >= committed.renderBoundary {
            // Render time is not played-back completion (especially Bluetooth).
            // Keep the predecessor hardware track until every scheduled tail
            // buffer reports .dataPlayedBack; admit at most two live players.
            if let active, active.scheduler.scheduledCount > 0 { retiring = active }
            active = committed; self.committed = nil
            if let latestOffsetNanos { active?.scheduler.updateClockOffset(latestOffsetNanos) }
        }
        var deliveries: [Delivery] = []
        if let id = active?.id {
            let buffers = active!.scheduler.drain(nowNanos: nowNanos, beforeRenderTimeNanos: committed?.renderBoundary,
                                                  beforeCaptureTimeNanos: committed?.anchor.captureTimeNanos)
            deliveries += buffers.map { Delivery(trackID: id, buffer: $0) }
        }
        if let id = committed?.id {
            deliveries += committed!.scheduler.drain(nowNanos: nowNanos).map { Delivery(trackID: id, buffer: $0) }
        }
        return deliveries
    }
    public mutating func completed(trackID: UUID, token: AudioBufferToken) {
        if active?.id == trackID { active?.scheduler.completed(token) }
        if committed?.id == trackID { committed?.scheduler.completed(token) }
        if retiring?.id == trackID {
            retiring?.scheduler.completed(token)
            if retiring?.scheduler.scheduledCount == 0 { retiring = nil }
        }
    }
    public mutating func updateClockOffset(_ offset: Int64) {
        latestOffsetNanos = offset
        // A committed cutover is already admitted in local render time. Freeze
        // both schedulers until it occurs; moving only packet times could overlap
        // the predecessor or retire it before the successor is audible.
        guard committed == nil else { return }
        active?.scheduler.updateClockOffset(offset)
    }
    public mutating func reset() { active = nil; proposed = nil; committed = nil; retiring = nil; latestOffsetNanos = nil; continuousProposal = nil }
}
