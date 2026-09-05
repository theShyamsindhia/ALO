import Foundation
import ALOCore
import ALOAppleMedia
import ALONetworking

/// Narrow native seam: tests exercise ownership and cutover without opening an
/// output device. Implementations and the owner use one serial playback queue.
protocol SecureMacPlaybackTrack: AnyObject {
    var clockOffsetNanos: Int64? { get set }
    var outputLatencyForTimingNanos: UInt64 { get }
    var renderSchedulingHeadroomForTimingNanos: UInt64 { get }
    var outputHardwareFormatForDiagnostics: AudioOutputHardwareFormat? { get }
    var outstandingPlaybackBufferCount: Int { get }
    var pendingPlaybackPacketCount: Int { get }
    var activePlayoutDelayNanos: UInt64 { get }
    var automaticSyncState: String { get }
    func accept(_ packet: AudioPacket)
    func maintainSync()
    func setTargetLatencyNanos(_ nanos: UInt64)
    func setAutomaticSyncEnabled(_ enabled: Bool)
    func setLevel(volume: Double, muted: Bool)
    func setDuckingGain(_ gain: Double)
    func setRoomPlayback(playing: Bool)
    func syncReport() -> PlaybackSyncReport
    func stop()
}

extension SynchronizedPlayer: SecureMacPlaybackTrack {}

/// One selected broadcaster's output timeline, independent of transport ticket
/// UUIDs/generations. Like MediaPlaybackTransition, prepare is reversible and
/// commit routes by capture boundary. Native played-back completions, rather
/// than a wall-clock guess, release the predecessor's hardware graph lease.
final class SecureMacPlaybackTimeline {
    typealias PreparationError = AppleMediaError
    private struct RepairTarget: Equatable {
        let epoch: UInt64
        let delay: UInt64
    }
    private final class Track {
        let id: UUID
        let player: any SecureMacPlaybackTrack
        var anchor: MediaStreamAnchor?
        var floor: (capture: UInt64, frame: UInt64)?
        var delay = RoomTiming.defaultPlayoutDelayNanos
        var captureEnd: UInt64?
        var firstAudibleTime: UInt64?
        var reportsActivity = false
        init(id: UUID, player: any SecureMacPlaybackTrack) { self.id = id; self.player = player }
    }
    private struct Proposal {
        let id: UUID
        let anchor: MediaStreamAnchor
        let offset: Int64
        let successor: Track?
        let renewal: Bool
        let renderBoundary: UInt64
        let expiresAt: UInt64
        var packets: [AudioPacket] = []
    }
    private struct Cutover {
        let predecessor: Track
        let capture: UInt64
        let renderBoundary: UInt64
    }
    private let makePlayer: (@escaping (Bool) -> Void) throws -> any SecureMacPlaybackTrack
    private let nowNanos: () -> UInt64
    private let playbackActivity: (Bool) -> Void
    private var active: Track!
    private var proposed: Proposal?
    private var cutover: Cutover?
    private var latestOffset: Int64?
    private var volume: Double = 1
    private var muted = false
    private var duckingGain: Double = 1
    private var playing = true
    private var automaticSyncEnabled = true
    private var stopped = false
    private var reportedActivity = false
    private var repairedTarget: RepairTarget?
    /// Uncommitted future PCM is a separate, fixed-size proposal hold.
    static let maximumBufferedPackets = 128
    /// Native played-back completions can lag the audible deadline. Allow one
    /// maximum-delay timeline plus 100 ms of bounded callback/reorder slack;
    /// this is accounting headroom, never extra playout latency.
    static let hardwareCompletionSlackNanos: UInt64 = 100_000_000
    static let maximumScheduledPackets: Int = {
        let packetDuration = UInt64(AudioPacket.framesPerPacket) * 1_000_000_000 / UInt64(AudioPacket.sampleRate)
        let duration = RoomTiming.maximumPlayoutDelayNanos + hardwareCompletionSlackNanos
        return Int((duration + packetDuration - 1) / packetDuration)
    }()

    convenience init(audioOutput: RoomAudioOutputEngine, playbackActivity: @escaping (Bool) -> Void = { _ in }) throws {
        try self.init(makePlayer: { activity in
            try SynchronizedPlayer(audioOutput: audioOutput, playbackActivityChanged: activity)
        }, playbackActivity: playbackActivity)
    }

    init(makePlayer: @escaping (@escaping (Bool) -> Void) throws -> any SecureMacPlaybackTrack,
         nowNanos: @escaping () -> UInt64 = MonotonicClock.nowNanos,
         playbackActivity: @escaping (Bool) -> Void = { _ in }) throws {
        self.makePlayer = makePlayer
        self.nowNanos = nowNanos
        self.playbackActivity = playbackActivity
        active = try newTrack()
    }

    var outputLatencyForTimingNanos: UInt64 { active.player.outputLatencyForTimingNanos }
    var renderSchedulingHeadroomForTimingNanos: UInt64 { active.player.renderSchedulingHeadroomForTimingNanos }
    var outputHardwareFormatForDiagnostics: AudioOutputHardwareFormat? { active.player.outputHardwareFormatForDiagnostics }
    var committedAnchor: MediaStreamAnchor? { active.anchor }
    var targetLatencyNanos: UInt64 { active.delay }
    var trackCount: Int { stopped ? 0 : 1 + (cutover == nil && proposed?.successor == nil ? 0 : 1) }

    func setAutomaticSyncEnabled(_ enabled: Bool) {
        automaticSyncEnabled = enabled
        active.player.setAutomaticSyncEnabled(enabled)
        proposed?.successor?.player.setAutomaticSyncEnabled(enabled)
        cutover?.predecessor.player.setAutomaticSyncEnabled(enabled)
    }
    /// A committed successor is not audible until its future boundary. Keep
    /// preference diagnostics on the same track as the current timing report.
    private var reportingPlayer: any SecureMacPlaybackTrack {
        if let cutover, nowNanos() < cutover.renderBoundary { return cutover.predecessor.player }
        return active.player
    }
    var activePlayoutDelayNanos: UInt64 { reportingPlayer.activePlayoutDelayNanos }
    var automaticSyncState: String { reportingPlayer.automaticSyncState }

    var clockOffsetNanos: Int64? {
        get { latestOffset }
        set {
            latestOffset = newValue
            // A committed boundary is already in local render time. Do not
            // change one participant's anchor math underneath scheduled PCM.
            guard cutover == nil else { return }
            active.player.clockOffsetNanos = newValue
        }
    }

    func prepare(id: UUID, anchor: MediaStreamAnchor, clockOffsetNanos offset: Int64) throws {
        guard !stopped else { throw AppleMediaError.invalidState }
        guard proposed == nil else { throw AppleMediaError.capacity }
        retireIfDrained()
        guard cutover == nil else { throw AppleMediaError.capacity }
        let delay = try validate(anchor)
        let continuous = playing && active.anchor?.state == .running
        // Each ticket has a NEW session UUID. Epoch identifies continuity for
        // this wrapper's fixed selected broadcaster; ticket identity does not.
        let renewal = continuous && active.anchor?.stream.broadcasterEpoch == anchor.stream.broadcasterEpoch
            && active.delay == delay && anchor.state == .running
        if renewal || anchor.state == .paused {
            proposed = Proposal(id: id, anchor: anchor, offset: offset, successor: nil,
                renewal: renewal, renderBoundary: 0, expiresAt: .max)
            return
        }
        guard !continuous || delay >= active.delay else { throw AppleMediaError.invalidAnchor }
        if missedCutover(anchor, delay: delay) { throw PreparationError.missedCutover }
        let next = continuous ? try newTrack() : nil
        do {
            let output = next?.player ?? active.player
            guard delay >= RoomTiming.outputLatencyFloor(output.outputLatencyForTimingNanos,
                renderSchedulingHeadroomNanos: output.renderSchedulingHeadroomForTimingNanos) else {
                throw AppleMediaError.invalidAnchor
            }
            let boundary = try renderTime(anchor.hostPlaybackTimeNanos, offset: offset, output: output)
            let headroom = output.renderSchedulingHeadroomForTimingNanos
            let now = nowNanos()
            guard boundary > now, boundary - now > headroom else { throw AppleMediaError.invalidAnchor }
            var expiry = boundary - headroom
            if continuous {
                guard active.captureEnd.map({ $0 <= anchor.captureTimeNanos }) ?? true,
                      let oldOffset = active.player.clockOffsetNanos else { throw AppleMediaError.invalidAnchor }
                let (oldHostBoundary, overflow) = anchor.captureTimeNanos.addingReportingOverflow(active.delay)
                guard !overflow else { throw AppleMediaError.invalidAnchor }
                let oldBoundary = try renderTime(oldHostBoundary, offset: oldOffset, output: active.player)
                let oldHeadroom = active.player.renderSchedulingHeadroomForTimingNanos
                guard oldBoundary > now, oldBoundary - now > oldHeadroom else { throw AppleMediaError.invalidAnchor }
                expiry = min(expiry, oldBoundary - oldHeadroom)
            }
            next?.player.setTargetLatencyNanos(delay)
            next?.player.clockOffsetNanos = offset
            proposed = Proposal(id: id, anchor: anchor, offset: offset, successor: next,
                renewal: false, renderBoundary: boundary, expiresAt: expiry)
        } catch { next?.player.stop(); throw error }
    }

    func commit(id: UUID) throws {
        guard !stopped, let proposal = proposed, proposal.id == id else { throw AppleMediaError.invalidState }
        guard nowNanos() < proposal.expiresAt else {
            cancelPreparation(id: id)
            throw AppleMediaError.invalidAnchor
        }
        if proposal.renewal {
            proposed = nil
            active.anchor = proposal.anchor
            clockOffsetNanos = proposal.offset
            // Keep the original capture/frame floor, player, and queued PCM.
            return
        }
        if proposal.anchor.state == .paused {
            proposed = nil
            proposal.successor?.player.stop()
            setRoomPlayback(playing: false)
            active.anchor = proposal.anchor
            active.delay = proposal.anchor.hostPlaybackTimeNanos - proposal.anchor.captureTimeNanos
            active.player.setTargetLatencyNanos(active.delay)
            clockOffsetNanos = proposal.offset
            return
        }
        guard proposal.successor == nil || (active.captureEnd.map { $0 <= proposal.anchor.captureTimeNanos } ?? true) else {
            cancelPreparation(id: id)
            throw AppleMediaError.invalidAnchor
        }
        proposed = nil
        let previous = active!
        if let next = proposal.successor {
            cutover = Cutover(predecessor: previous, capture: proposal.anchor.captureTimeNanos,
                renderBoundary: proposal.renderBoundary)
            active = next
        }
        active.anchor = proposal.anchor
        active.floor = (proposal.anchor.captureTimeNanos, proposal.anchor.frameIndex)
        active.delay = proposal.anchor.hostPlaybackTimeNanos - proposal.anchor.captureTimeNanos
        active.player.setTargetLatencyNanos(active.delay) // Only a new or paused player.
        active.player.clockOffsetNanos = proposal.offset
        latestOffset = proposal.offset
        playing = true
        active.player.setRoomPlayback(playing: true)
        for packet in proposal.packets { deliver(packet, to: active) }
        updateActivity()
    }

    func cancelPreparation(id: UUID) {
        guard let proposal = proposed, proposal.id == id else { return }
        proposed = nil
        proposal.successor?.player.stop()
        // The predecessor's scheduling state was never changed. Replay the
        // bounded held tail in wire-sequence order if this timeline is live.
        if playing && active.anchor != nil {
            for packet in proposal.packets.sorted(by: { $0.frameIndex < $1.frameIndex }) { deliver(packet, to: active) }
        }
    }

    /// Explicit, receiver-local repair after a typed missed-cutover rejection.
    /// Ordinary prepare failures never enter this path, and classification alone
    /// leaves healthy PCM untouched. The next fresh anchor reuses this graph.
    @discardableResult
    func repairMissedCutover(_ anchor: MediaStreamAnchor) -> Bool {
        guard !stopped, proposed == nil, cutover == nil,
              let delay = try? validate(anchor), missedCutover(anchor, delay: delay) else { return false }
        let target = RepairTarget(epoch: anchor.stream.broadcasterEpoch, delay: delay)
        guard repairedTarget != target else { return false }
        setRoomPlayback(playing: false)
        repairedTarget = target
        return true
    }

    func accept(_ packet: AudioPacket) {
        guard !stopped, playing, valid(packet) else { return }
        expirePreparation()
        retireIfDrained()
        if var proposal = proposed, !proposal.renewal, proposal.anchor.state == .running,
           packet.captureTimeNanos >= proposal.anchor.captureTimeNanos {
            // Warmup may deliver the future tail before its ACK is committed.
            // Do not schedule it on the predecessor or depend on a second copy.
            guard !proposal.packets.contains(where: { $0.frameIndex == packet.frameIndex }) else { return }
            guard proposal.packets.count < Self.maximumBufferedPackets else {
                cancelPreparation(id: proposal.id)
                deliver(packet, to: active)
                return
            }
            proposal.packets.append(packet)
            proposed = proposal
            return
        }
        if let cutover, packet.captureTimeNanos < cutover.capture {
            guard nowNanos() < cutover.renderBoundary,
                  captureEnd(packet).map({ $0 <= cutover.capture }) == true else { return }
            deliver(packet, to: cutover.predecessor)
        } else { deliver(packet, to: active) }
    }

    func maintainSync() {
        guard !stopped else { return }
        expirePreparation()
        cutover?.predecessor.player.maintainSync()
        active.player.maintainSync()
        retireIfDrained()
        updateActivity()
    }

    func setLevel(volume: Double, muted: Bool) {
        self.volume = volume; self.muted = muted
        active.player.setLevel(volume: volume, muted: muted)
        cutover?.predecessor.player.setLevel(volume: volume, muted: muted)
        proposed?.successor?.player.setLevel(volume: volume, muted: muted)
    }

    func setDuckingGain(_ gain: Double) {
        duckingGain = gain
        active.player.setDuckingGain(gain)
        cutover?.predecessor.player.setDuckingGain(gain)
        proposed?.successor?.player.setDuckingGain(gain)
    }

    func setRoomPlayback(playing: Bool) {
        guard !stopped, self.playing != playing else { return }
        self.playing = playing
        if !playing {
            repairedTarget = nil
            let proposal = proposed; proposed = nil
            proposal?.successor?.player.stop()
            let old = cutover; cutover = nil
            old?.predecessor.player.stop()
            active.anchor = nil; active.floor = nil; active.captureEnd = nil; active.firstAudibleTime = nil
            active.reportsActivity = false
            active.player.clockOffsetNanos = latestOffset
        }
        active.player.setRoomPlayback(playing: playing)
        updateActivity()
    }

    func syncReport() -> PlaybackSyncReport {
        reportingPlayer.syncReport()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        proposed?.successor?.player.stop(); proposed = nil
        cutover?.predecessor.player.stop(); cutover = nil
        active.player.stop()
        updateActivity()
    }

    private func newTrack() throws -> Track {
        let id = UUID()
        let player = try makePlayer { [weak self] value in
            guard let self else { return }
            if self.active?.id == id { self.active.reportsActivity = value }
            if self.cutover?.predecessor.id == id { self.cutover?.predecessor.reportsActivity = value }
            self.updateActivity()
        }
        player.setLevel(volume: volume, muted: muted)
        player.setDuckingGain(duckingGain)
        player.setAutomaticSyncEnabled(automaticSyncEnabled)
        return Track(id: id, player: player)
    }

    private func deliver(_ packet: AudioPacket, to track: Track) {
        guard let floor = track.floor, packet.captureTimeNanos >= floor.capture, packet.frameIndex >= floor.frame,
              track.player.pendingPlaybackPacketCount + track.player.outstandingPlaybackBufferCount < Self.maximumScheduledPackets,
              let end = captureEnd(packet) else { return }
        track.captureEnd = max(track.captureEnd ?? 0, end)
        if track.firstAudibleTime == nil, let offset = track.player.clockOffsetNanos {
            let (host, overflow) = packet.captureTimeNanos.addingReportingOverflow(track.delay)
            if !overflow { track.firstAudibleTime = RoomTiming.clientTimeNanos(hostTimeNanos: host, clockOffsetNanos: offset) }
        }
        track.player.accept(packet)
        updateActivity()
    }

    private func expirePreparation() {
        if let proposal = proposed, nowNanos() >= proposal.expiresAt { cancelPreparation(id: proposal.id) }
    }

    private func retireIfDrained() {
        guard let cutover, nowNanos() >= cutover.renderBoundary,
              cutover.predecessor.player.outstandingPlaybackBufferCount == 0,
              cutover.predecessor.player.pendingPlaybackPacketCount == 0 else { return }
        self.cutover = nil
        cutover.predecessor.player.stop()
        active.player.clockOffsetNanos = latestOffset
    }

    private func updateActivity() {
        let now = nowNanos()
        let tracks = [active, cutover?.predecessor].compactMap { $0 }
        let next = !stopped && playing && tracks.contains {
            $0.reportsActivity && $0.firstAudibleTime.map { now >= $0 } == true
        }
        guard next != reportedActivity else { return }
        reportedActivity = next
        playbackActivity(next)
    }

    private func validate(_ anchor: MediaStreamAnchor) throws -> UInt64 {
        guard anchor.hostPlaybackTimeNanos >= anchor.captureTimeNanos,
              anchor.sampleRate == AudioPacket.sampleRate, anchor.channelCount == AudioPacket.channelCount,
              anchor.framesPerPacket == AudioPacket.framesPerPacket else { throw AppleMediaError.invalidAnchor }
        let delay = anchor.hostPlaybackTimeNanos - anchor.captureTimeNanos
        guard delay >= RoomTiming.outputLatencyFloor(outputLatencyForTimingNanos,
                  renderSchedulingHeadroomNanos: renderSchedulingHeadroomForTimingNanos),
              delay <= RoomTiming.maximumPlayoutDelayNanos else { throw AppleMediaError.invalidAnchor }
        return delay
    }

    private func missedCutover(_ anchor: MediaStreamAnchor, delay: UInt64) -> Bool {
        playing && active.anchor?.state == .running && anchor.state == .running
            && active.anchor?.stream.broadcasterEpoch == anchor.stream.broadcasterEpoch
            && delay > active.delay
            && active.captureEnd.map { $0 > anchor.captureTimeNanos } == true
    }

    private func renderTime(_ host: UInt64, offset: Int64, output: any SecureMacPlaybackTrack) throws -> UInt64 {
        guard let local = RoomTiming.clientTimeNanos(hostTimeNanos: host, clockOffsetNanos: offset),
              local >= output.outputLatencyForTimingNanos else { throw AppleMediaError.invalidAnchor }
        return local - output.outputLatencyForTimingNanos
    }

    private func captureEnd(_ packet: AudioPacket) -> UInt64? {
        let result = packet.captureTimeNanos.addingReportingOverflow(UInt64(packet.frameCount) * 1_000_000_000 / UInt64(AudioPacket.sampleRate))
        return result.overflow ? nil : result.partialValue
    }

    private func valid(_ packet: AudioPacket) -> Bool {
        !packet.samples.isEmpty && packet.samples.count.isMultiple(of: Int(AudioPacket.channelCount))
            && packet.samples.count <= Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
            && !packet.frameIndex.addingReportingOverflow(UInt64(packet.frameCount)).overflow
            && captureEnd(packet) != nil
    }
}
