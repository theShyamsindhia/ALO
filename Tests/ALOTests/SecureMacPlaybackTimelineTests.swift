import Foundation
import Testing
@testable import ALO
import ALOCore
import ALOAppleMedia
import ALONetworking

struct SecureMacPlaybackTimelineTests {
    private final class Player: SecureMacPlaybackTrack {
        var clockOffsetNanos: Int64?
        var outputLatencyForTimingNanos: UInt64 = 0
        var renderSchedulingHeadroomForTimingNanos: UInt64 = 25_000_000
        var outputHardwareFormatForDiagnostics: AudioOutputHardwareFormat? { nil }
        var outstandingPlaybackBufferCount = 0
        var pendingPlaybackPacketCount = 0
        var packets: [AudioPacket] = []
        var latencyChanges: [UInt64] = []
        var stops = 0
        var volume: Double = 1
        var muted = false
        var ducking: Double = 1
        var playing = true
        var pauseCalls = 0
        let activity: (Bool) -> Void
        init(activity: @escaping (Bool) -> Void) { self.activity = activity }
        func accept(_ packet: AudioPacket) {
            packets.append(packet); outstandingPlaybackBufferCount += 1; activity(true)
        }
        func maintainSync() {}
        func setTargetLatencyNanos(_ nanos: UInt64) { latencyChanges.append(nanos) }
        func setLevel(volume: Double, muted: Bool) { self.volume = volume; self.muted = muted }
        func setDuckingGain(_ gain: Double) { ducking = gain }
        func setRoomPlayback(playing: Bool) {
            self.playing = playing
            if !playing { pauseCalls += 1; outstandingPlaybackBufferCount = 0; pendingPlaybackPacketCount = 0; activity(false) }
        }
        func syncReport() -> PlaybackSyncReport {
            .init(measuredAtNanos: 0, latenessNanos: 0, latePacketCount: 0, resyncCount: 0)
        }
        func stop() { stops += 1; outstandingPlaybackBufferCount = 0; activity(false) }
    }

    private final class Rig {
        var now: UInt64 = 1_000_000_000
        var players: [Player] = []
        var activities: [Bool] = []
        var failCreation = false
        var output: SecureMacPlaybackTimeline!
        init() throws {
            output = try SecureMacPlaybackTimeline(makePlayer: { [unowned self] callback in
                if self.failCreation { throw AppleMediaError.audioConfiguration }
                let player = Player(activity: callback)
                self.players.append(player)
                return player
            }, nowNanos: { [unowned self] in self.now }, playbackActivity: { [unowned self] in self.activities.append($0) })
        }
    }

    private func anchor(capture: UInt64 = 1_000_000_000, frame: UInt64 = 0,
                        delay: UInt64 = 250_000_000, epoch: UInt64 = 4,
                        generation: UInt64 = 1,
                        state: MediaStreamAnchor.State = .running) -> MediaStreamAnchor {
        .init(stream: .init(sessionID: UUID(), broadcasterEpoch: epoch, generation: generation),
            captureTimeNanos: capture, frameIndex: frame, hostPlaybackTimeNanos: capture + delay,
            issuedAtHostNanos: 1_000_000_000, state: state)
    }

    private func packet(_ frame: UInt64 = 0, capture: UInt64 = 1_000_000_000) -> AudioPacket {
        .init(sequence: UInt32(frame / 240), frameIndex: frame, captureTimeNanos: capture,
            samples: Array(repeating: 7, count: 480))
    }

    private func start(_ rig: Rig, delay: UInt64 = 250_000_000) throws {
        let id = UUID()
        try rig.output.prepare(id: id, anchor: anchor(delay: delay), clockOffsetNanos: 0)
        try rig.output.commit(id: id)
    }

    @Test("Maximum room delay retains callback slack beyond its scheduled PCM depth")
    func maximumDelayAllowsBoundedHardwareCompletionSlack() throws {
        let rig = try Rig()
        try start(rig, delay: RoomTiming.maximumPlayoutDelayNanos)
        // At 600 ms, 120 five-millisecond buffers can legitimately await
        // dataPlayedBack. Another 50 ms of callbacks/reordering is not overload.
        rig.players[0].outstandingPlaybackBufferCount = 120
        rig.players[0].pendingPlaybackPacketCount = 10
        let fresh = packet()
        rig.output.accept(fresh)
        #expect(rig.players[0].packets.map(\.frameIndex) == [fresh.frameIndex])
        #expect(rig.players[0].outstandingPlaybackBufferCount == 121)
        #expect(SecureMacPlaybackTimeline.maximumBufferedPackets == 128,
            "The proposal hold bound is independent and must remain unchanged")
    }

    @Test("Hardware scheduling remains bounded and resumes admission after a completion")
    func hardwareCompletionSlackHasAnExactBound() throws {
        let rig = try Rig()
        try start(rig, delay: RoomTiming.maximumPlayoutDelayNanos)
        let maximum = SecureMacPlaybackTimeline.maximumScheduledPackets
        #expect(maximum == 140, "600 ms timeline plus 100 ms slack at five milliseconds per packet")
        rig.players[0].pendingPlaybackPacketCount = 10
        rig.players[0].outstandingPlaybackBufferCount = maximum - 11
        rig.output.accept(packet())
        #expect(rig.players[0].packets.count == 1)
        #expect(rig.players[0].pendingPlaybackPacketCount + rig.players[0].outstandingPlaybackBufferCount == maximum)
        let next = packet(240, capture: 1_005_000_000)
        rig.output.accept(next)
        #expect(rig.players[0].packets.count == 1, "Missing callbacks cannot grow the native backlog without bound")
        rig.players[0].outstandingPlaybackBufferCount -= 1
        rig.output.accept(next)
        #expect(rig.players[0].packets.map(\.frameIndex) == [0, 240])
        #expect(rig.players[0].pendingPlaybackPacketCount + rig.players[0].outstandingPlaybackBufferCount == maximum)
    }

    @Test("A queued host cutover cannot survive pause and resume before its executor drains")
    func hostQueuedCutoverIsInvalidatedByPauseResume() throws {
        let rig = try Rig()
        try start(rig)
        rig.output.accept(packet())
        let source = CapturedMediaTimeline()
        source.observe([packet()])
        let change = try #require(source.schedulePlayoutDelay(400_000_000, now: rig.now))
        let queue = DispatchQueue(label: "alo.test.host-paused-stage")
        let renderer = SecureMacMediaHost.LocalRenderer(player: rig.output, timeline: source,
            epoch: 4, queue: queue, nowNanos: { rig.now })
        queue.suspend()
        renderer.stage(change, authorizeCommit: { commit in try commit(); return true }) { accepted in
            if accepted { source.announce(change) }
        }
        // Both transitions happen before the staged work can run. The source
        // discards its unannounced reservation and resumes at the old delay.
        source.setPlaying(false); renderer.setPlaying(false)
        source.setPlaying(true); renderer.setPlaying(true)
        queue.resume()
        queue.sync {}
        #expect(source.playoutDelayNanos == 250_000_000)
        #expect(rig.output.targetLatencyNanos == source.playoutDelayNanos)

        let resumed = packet(240, capture: 1_005_000_000)
        rig.now = resumed.captureTimeNanos
        source.observe([resumed]); renderer.append([resumed])
        queue.sync { renderer.drain() }
        #expect(rig.players[0].pauseCalls == 1, "A rapid resume must not erase the actual pause")
        #expect(rig.output.trackCount == 1)
        #expect(rig.output.committedAnchor?.captureTimeNanos == resumed.captureTimeNanos)
        #expect(rig.output.targetLatencyNanos == source.playoutDelayNanos)
        renderer.stop()
        queue.sync {}
    }

    @Test("A host stage rejected after preparation cannot commit or reset healthy PCM")
    func hostPreparedStageRequiresCurrentAuthority() throws {
        let rig = try Rig()
        try start(rig)
        rig.output.accept(packet())
        let source = CapturedMediaTimeline()
        source.observe([packet()])
        let change = try #require(source.schedulePlayoutDelay(400_000_000, now: rig.now))
        let queue = DispatchQueue(label: "alo.test.host-revoked-stage")
        let renderer = SecureMacMediaHost.LocalRenderer(player: rig.output, timeline: source,
            epoch: 4, queue: queue, nowNanos: { rig.now })
        renderer.stage(change, authorizeCommit: { _ in
            #expect(rig.players.count == 2, "Native preparation precedes the authority transaction")
            // Models an ingress generation revoked while native preparation
            // ran; the real stage must not invoke commit after rejection.
            return false
        }, completion: { accepted in
            #expect(!accepted)
            source.cancelUnannounced(change)
        })
        queue.sync {}
        #expect(rig.output.targetLatencyNanos == 250_000_000)
        #expect(rig.output.trackCount == 1)
        #expect(rig.players[0].pauseCalls == 0 && rig.players[0].stops == 0)
        #expect(rig.players[0].outstandingPlaybackBufferCount == 1)
        #expect(rig.players[1].stops == 1)
        #expect(source.requestedPlayoutDelayNanos == 250_000_000)
        renderer.stop()
        queue.sync {}
    }

    @Test("A new subscription UUID and generation do not reset the same-epoch timeline")
    func ticketRenewalPreservesQueuedPCMAndOriginalFloor() throws {
        let rig = try Rig()
        try start(rig)
        rig.output.accept(packet())
        let firstSession = try #require(rig.output.committedAnchor?.stream.sessionID)
        let renewal = anchor(capture: 1_100_000_000, frame: 4_800, generation: 2)
        #expect(renewal.stream.sessionID != firstSession)
        let id = UUID()
        try rig.output.prepare(id: id, anchor: renewal, clockOffsetNanos: 5)
        rig.output.accept(packet(240, capture: 1_005_000_000))
        try rig.output.commit(id: id)
        rig.output.accept(packet(480, capture: 1_010_000_000))
        #expect(rig.players.count == 1 && rig.players[0].stops == 0)
        #expect(rig.players[0].latencyChanges == [250_000_000])
        #expect(rig.players[0].packets.map(\.frameIndex) == [0, 240, 480])
        rig.output.stop()
    }

    @Test("Prepare holds the future tail and commit routes it exactly once to the successor")
    func futureCutoverAndCompletionOwnership() throws {
        let rig = try Rig()
        try start(rig)
        rig.output.accept(packet())
        let id = UUID()
        try rig.output.prepare(id: id, anchor: anchor(capture: 1_200_000_000, frame: 9_600, delay: 400_000_000), clockOffsetNanos: 0)
        rig.output.accept(packet(240, capture: 1_005_000_000))
        rig.output.accept(packet(9_600, capture: 1_200_000_000))
        #expect(rig.players[0].packets.count == 2 && rig.players[1].packets.isEmpty)
        #expect(rig.players[0].latencyChanges == [250_000_000] && rig.players[0].stops == 0)
        try rig.output.commit(id: id)
        #expect(rig.players[1].packets.map(\.frameIndex) == [9_600])
        rig.output.accept(packet(480, capture: 1_010_000_000))
        rig.output.accept(packet(9_840, capture: 1_205_000_000))
        #expect(rig.players[0].packets.map(\.frameIndex) == [0, 240, 480])
        #expect(rig.players[1].packets.map(\.frameIndex) == [9_600, 9_840])
        rig.players[0].outstandingPlaybackBufferCount = 0
        rig.output.maintainSync()
        #expect(rig.output.trackCount == 2 && rig.players[0].stops == 0,
                "An empty callback count before the future boundary is not permission to stop the predecessor")
        rig.now = 1_600_000_000
        rig.output.maintainSync()
        #expect(rig.output.trackCount == 1 && rig.players[0].stops == 1)
        rig.output.stop()
    }

    @Test("Missing hardware completions retain at most two tracks and reject another transition")
    func missingCompletionCannotGrowTheGraph() throws {
        let rig = try Rig()
        try start(rig)
        rig.output.accept(packet())
        let id = UUID()
        try rig.output.prepare(id: id, anchor: anchor(capture: 1_200_000_000, frame: 9_600, delay: 400_000_000), clockOffsetNanos: 0)
        try rig.output.commit(id: id)
        rig.output.clockOffsetNanos = 100
        #expect(rig.players.allSatisfy { $0.clockOffsetNanos == 0 })
        rig.now = 1_700_000_000
        rig.output.maintainSync()
        #expect(rig.output.trackCount == 2 && rig.players[0].stops == 0)
        #expect(throws: AppleMediaError.capacity) {
            try rig.output.prepare(id: UUID(), anchor: anchor(capture: 1_800_000_000, frame: 38_400, delay: 500_000_000), clockOffsetNanos: 100)
        }
        #expect(rig.players.count == 2)
        rig.players[0].outstandingPlaybackBufferCount = 0
        rig.players[0].pendingPlaybackPacketCount = 1
        rig.output.maintainSync()
        #expect(rig.output.trackCount == 2)
        rig.players[0].pendingPlaybackPacketCount = 0
        rig.output.maintainSync()
        #expect(rig.output.trackCount == 1 && rig.players[1].clockOffsetNanos == 100)
        rig.output.stop()
    }

    @Test("Failed preparation and cancelled ACK preserve the live player and replay held PCM")
    func preparationFailureAndCancellation() throws {
        let rig = try Rig()
        try start(rig)
        rig.output.accept(packet())
        rig.failCreation = true
        #expect(throws: AppleMediaError.audioConfiguration) {
            try rig.output.prepare(id: UUID(), anchor: anchor(capture: 1_200_000_000, frame: 9_600, delay: 400_000_000), clockOffsetNanos: 0)
        }
        #expect(rig.players[0].stops == 0 && rig.players[0].outstandingPlaybackBufferCount == 1)
        rig.failCreation = false
        let id = UUID()
        try rig.output.prepare(id: id, anchor: anchor(capture: 1_200_000_000, frame: 9_600, delay: 400_000_000), clockOffsetNanos: 0)
        rig.output.accept(packet(9_600, capture: 1_200_000_000))
        rig.output.cancelPreparation(id: id)
        #expect(rig.players[0].packets.map(\.frameIndex) == [0, 9_600])
        #expect(rig.players[0].stops == 0 && rig.players[0].latencyChanges == [250_000_000])
        #expect(rig.players[1].stops == 1 && rig.output.trackCount == 1)
        rig.output.stop()
    }

    @Test("Late commit expires while the predecessor still has render headroom")
    func expiredCommitReplaysTail() throws {
        let rig = try Rig()
        try start(rig)
        let id = UUID()
        try rig.output.prepare(id: id, anchor: anchor(capture: 1_200_000_000, frame: 9_600, delay: 400_000_000), clockOffsetNanos: 0)
        rig.output.accept(packet(9_600, capture: 1_200_000_000))
        rig.now = 1_425_000_000
        #expect(throws: AppleMediaError.invalidAnchor) { try rig.output.commit(id: id) }
        #expect(rig.players[0].packets.map(\.frameIndex) == [9_600])
        #expect(rig.players[0].stops == 0 && rig.players[1].stops == 1)
        rig.output.stop()
    }

    @Test("An already accepted capture overlap and a live delay decrease are rejected")
    func unsafeTransitionsAreRejected() throws {
        let rig = try Rig()
        try start(rig, delay: 400_000_000)
        rig.output.accept(packet())
        #expect(throws: AppleMediaError.invalidAnchor) {
            try rig.output.prepare(id: UUID(), anchor: anchor(capture: 1_200_000_000, frame: 9_600), clockOffsetNanos: 0)
        }
        #expect(throws: SecureMacPlaybackTimeline.PreparationError.missedCutover) {
            try rig.output.prepare(id: UUID(), anchor: anchor(delay: 500_000_000), clockOffsetNanos: 0)
        }
        #expect(rig.players[0].stops == 0 && rig.players[0].latencyChanges == [400_000_000])
        rig.output.setRoomPlayback(playing: false)
        let id = UUID()
        try rig.output.prepare(id: id, anchor: anchor(), clockOffsetNanos: 0)
        try rig.output.commit(id: id)
        #expect(rig.output.targetLatencyNanos == 250_000_000)
        rig.output.stop()
    }

    @Test("Level and opt-in ducking follow prepared and committed tracks; pause invalidates both")
    func levelsAndPause() throws {
        let rig = try Rig()
        try start(rig)
        rig.output.setLevel(volume: 0.7, muted: true)
        rig.output.setDuckingGain(0.4)
        let id = UUID()
        try rig.output.prepare(id: id, anchor: anchor(capture: 1_200_000_000, frame: 9_600, delay: 400_000_000), clockOffsetNanos: 0)
        #expect(rig.players.allSatisfy { $0.volume == 0.7 && $0.muted && $0.ducking == 0.4 })
        rig.output.setLevel(volume: 0.3, muted: false)
        rig.output.setDuckingGain(1)
        try rig.output.commit(id: id)
        #expect(rig.players.allSatisfy { $0.volume == 0.3 && !$0.muted && $0.ducking == 1 })
        rig.output.setRoomPlayback(playing: false)
        #expect(rig.players[0].stops == 1 && !rig.players[1].playing && rig.output.trackCount == 1)
        rig.output.stop(); rig.output.stop()
        #expect(rig.players[1].stops == 1 && rig.output.trackCount == 0)
    }

    @Test("Playback activity remains false until the admitted audible deadline")
    func activityDoesNotReportFutureSchedulingAsRendering() throws {
        let rig = try Rig()
        try start(rig)
        rig.output.accept(packet())
        #expect(rig.activities.isEmpty)
        rig.now = 1_250_000_000
        rig.output.maintainSync()
        #expect(rig.activities == [true])
        rig.output.stop()
        #expect(rig.activities == [true, false])
    }

    @Test("Scheduled completion generations cannot release a replacement stream's PCM")
    func staleNativeCompletions() {
        let completions = PlaybackBufferCompletions()
        let old = completions.scheduled()
        _ = completions.scheduled()
        #expect(completions.count == 2)
        completions.invalidate()
        let current = completions.scheduled()
        completions.completed(generation: old)
        completions.completed(generation: old)
        #expect(completions.count == 1)
        completions.completed(generation: current)
        completions.completed(generation: current)
        #expect(completions.count == 0)
    }

    @Test("Repeated pause is inert and a lower-delay resume admits a fresh capture floor")
    func pauseAndLowerDelayResume() throws {
        let rig = try Rig()
        try start(rig, delay: 500_000_000)
        rig.output.accept(packet())
        rig.output.setRoomPlayback(playing: false)
        rig.output.setRoomPlayback(playing: false)
        #expect(rig.output.committedAnchor == nil && rig.players[0].pauseCalls == 1)
        let paused = UUID()
        try rig.output.prepare(id: paused, anchor: anchor(delay: 250_000_000, state: .paused), clockOffsetNanos: 0)
        try rig.output.commit(id: paused)
        #expect(rig.output.targetLatencyNanos == 250_000_000)
        let resumed = UUID()
        try rig.output.prepare(id: resumed, anchor: anchor(capture: 1_100_000_000, frame: 4_800), clockOffsetNanos: 0)
        try rig.output.commit(id: resumed)
        rig.output.accept(packet(240, capture: 1_005_000_000))
        rig.output.accept(packet(4_800, capture: 1_100_000_000))
        #expect(rig.players[0].packets.map(\.frameIndex) == [0, 4_800])
        #expect(rig.players.count == 1 && rig.players[0].stops == 0)
        rig.output.stop()
    }

    @Test("Only the listener that missed a shared cutover resets locally and rejoins the new delay")
    func missedCutoverRecoversWithoutRestartingHealthyOutput() throws {
        let healthy = try Rig(), delayed = try Rig()
        try start(healthy); try start(delayed)
        healthy.output.accept(packet()); delayed.output.accept(packet())
        let shared = anchor(capture: 1_200_000_000, frame: 9_600, delay: 400_000_000)
        let healthyID = UUID()
        try healthy.output.prepare(id: healthyID, anchor: shared, clockOffsetNanos: 0)
        try healthy.output.commit(id: healthyID)
        healthy.output.accept(packet(9_600, capture: 1_200_000_000))
        // The delayed listener kept consuming its committed 250 ms timeline.
        // Its next anchor is a latest captured reference, already in old PCM.
        delayed.now = 1_210_000_000
        delayed.output.accept(packet(10_080, capture: 1_210_000_000))
        let missed = anchor(capture: 1_210_000_000, frame: 10_080, delay: 400_000_000)
        #expect(throws: SecureMacPlaybackTimeline.PreparationError.missedCutover) {
            try delayed.output.prepare(id: UUID(), anchor: missed, clockOffsetNanos: 0)
        }
        #expect(delayed.players[0].pauseCalls == 0,
                "Classification itself must not destroy the predecessor")
        #expect(delayed.output.repairMissedCutover(missed))
        #expect(!delayed.output.repairMissedCutover(missed), "One repair attempt per target, not a reset loop")
        #expect(delayed.players[0].pauseCalls == 1 && delayed.output.committedAnchor == nil)
        #expect(healthy.players.allSatisfy { $0.pauseCalls == 0 && $0.stops == 0 })
        let fresh = anchor(capture: 1_220_000_000, frame: 10_560, delay: 400_000_000)
        let freshID = UUID()
        try delayed.output.prepare(id: freshID, anchor: fresh, clockOffsetNanos: 0)
        try delayed.output.commit(id: freshID)
        delayed.output.accept(packet(10_320, capture: 1_215_000_000))
        delayed.output.accept(packet(10_560, capture: 1_220_000_000))
        #expect(delayed.players[0].packets.map(\.frameIndex) == [0, 10_080, 10_560])
        #expect(delayed.output.targetLatencyNanos == healthy.output.targetLatencyNanos)
        #expect(delayed.players.count == 1 && healthy.players.count == 2)
        healthy.output.stop(); delayed.output.stop()
    }

    @Test("Capacity and unsupported hardware timing cannot authorize destructive cutover repair")
    func ordinaryPreparationFailureDoesNotRepair() throws {
        let rig = try Rig()
        try start(rig)
        rig.output.accept(packet())
        let id = UUID()
        try rig.output.prepare(id: id, anchor: anchor(capture: 1_200_000_000, frame: 9_600, delay: 400_000_000), clockOffsetNanos: 0)
        #expect(!rig.output.repairMissedCutover(anchor(delay: 400_000_000)))
        rig.output.cancelPreparation(id: id)
        rig.players[0].outputLatencyForTimingNanos = 300_000_000
        #expect(throws: AppleMediaError.invalidAnchor) {
            try rig.output.prepare(id: UUID(), anchor: anchor(delay: 400_000_000), clockOffsetNanos: 0)
        }
        #expect(!rig.output.repairMissedCutover(anchor(delay: 400_000_000)))
        #expect(rig.players[0].pauseCalls == 0 && rig.players[0].stops == 0)
        rig.output.stop()
    }
}
