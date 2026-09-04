import Foundation
import Network
import Testing
@testable import WERAI
@testable import WERAICore

@Suite("Single-Mac room integration", .serialized)
struct LoopbackRoomScaleTests {
    @Test("A receiver republishes its local mixer level after the host restarts")
    func receiverRestoresLocalLevelAfterHostRestart() throws {
        let roomName = "Host restart level test \(UUID().uuidString)"
        let firstReady = DispatchSemaphore(value: 0)
        let firstHost = HostServer(
            roomName: roomName,
            listenerReadyHandler: { _ in firstReady.signal() }
        )
        try firstHost.start()
        guard firstReady.wait(timeout: .now() + 3) == .success else {
            firstHost.stop()
            throw LoopbackTestError.hostDidNotStart
        }

        let participantID = "persistent-level-device"
        let observations = ReceiverRestartObservations(participantID: participantID)
        let receiver = try Receiver(
            requestedRoom: roomName,
            audioOutput: RoomAudioOutputEngine(idleStopDelay: .milliseconds(10)),
            participantID: participantID,
            capturesSystemMediaCommands: false,
            statusHandler: { observations.record(status: $0) },
            participantsHandler: { observations.record(participants: $0) }
        )
        try receiver.start()
        defer { receiver.stop() }
        guard waitUntil(timeout: 5, condition: { observations.connectedCount >= 1 }) else {
            firstHost.stop()
            throw LoopbackTestError.peerDidNotJoin
        }

        receiver.setLocalLevel(volume: 0.27, muted: true)
        #expect(waitUntil(timeout: 2) { observations.latestLevel == .init(volume: 0.27, muted: true) })

        firstHost.stop()
        #expect(waitUntil(timeout: 3) { observations.isSearching })
        observations.clearParticipants()
        Thread.sleep(forTimeInterval: 0.3)

        let secondReady = DispatchSemaphore(value: 0)
        let secondHost = HostServer(
            roomName: roomName,
            listenerReadyHandler: { _ in secondReady.signal() }
        )
        try secondHost.start()
        defer { secondHost.stop() }
        guard secondReady.wait(timeout: .now() + 3) == .success,
              waitUntil(timeout: 8, condition: { observations.connectedCount >= 2 })
        else { throw LoopbackTestError.peerDidNotJoin }

        #expect(waitUntil(timeout: 2) {
            observations.latestLevel == .init(volume: 0.27, muted: true)
        })
    }

    @Test("Rejoining with the same device identity replaces the stale receiver")
    func rejoiningDeviceReplacesStaleTransport() throws {
        let hostReady = DispatchSemaphore(value: 0)
        let state = PortState()
        let host = HostServer(
            roomName: "Rejoin replacement test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                hostReady.signal()
            }
        )
        try host.start()
        defer { host.stop() }
        guard hostReady.wait(timeout: .now() + 3) == .success,
              let hostPort = state.port
        else { throw LoopbackTestError.hostDidNotStart }

        let original = HeadlessLoopbackPeer(index: 901, participantID: "rejoining-device")
        let replacement = HeadlessLoopbackPeer(index: 902, participantID: "rejoining-device")
        try original.start(hostPort: hostPort)
        defer {
            original.stop()
            replacement.stop()
        }
        guard original.waitUntilJoined(timeout: 3) else {
            throw LoopbackTestError.peerDidNotJoin
        }
        original.setLevel(volume: 0.27, muted: true)
        #expect(waitUntil(timeout: 2) {
            original.levels.contains { level in
                abs(level.volume - 0.27) < 0.001 && level.muted
            }
        })
        original.requestResync(participantID: "rejoining-device")
        #expect(waitUntil(timeout: 2) { original.resyncCommandCount >= 1 })

        try replacement.start(hostPort: hostPort)
        guard replacement.waitUntilJoined(timeout: 3) else {
            throw LoopbackTestError.peerDidNotJoin
        }

        #expect(waitUntil(timeout: 2) {
            host.diagnosticsSnapshot().listenerCount == 1
        })
        #expect(waitUntil(timeout: 2) {
            replacement.levels.contains { level in
                abs(level.volume - 0.27) < 0.001 && level.muted
            }
        })
        let replacementResyncBaseline = replacement.resyncCommandCount
        replacement.requestResync(participantID: "rejoining-device")
        #expect(waitUntil(timeout: 0.7) {
            replacement.resyncCommandCount > replacementResyncBaseline
        })

        let samples = [Int16](
            repeating: 1_024,
            count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
        )
        host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos())
        #expect(waitUntil(timeout: 2) { replacement.packetCount == 1 })
        Thread.sleep(forTimeInterval: 0.1)
        #expect(original.packetCount == 0)
    }

    @Test("Bounded fan-out prevents live room latency growth")
    func boundedFanoutPreventsRoomScaleDelay() throws {
        let boundedPolicy = HostServer.AudioBackpressurePolicy.boundedLatest(maxInFlight: 8)
        let directEight = try runRoom(peerCount: 8, linkBitsPerSecond: nil, policy: boundedPolicy)
        let shapedOne = try runRoom(peerCount: 1, linkBitsPerSecond: 4_000_000, policy: boundedPolicy)
        let unboundedEight = try runRoom(peerCount: 8, linkBitsPerSecond: 4_000_000, policy: .unbounded)
        let boundedEight = try runRoom(peerCount: 8, linkBitsPerSecond: 4_000_000, policy: boundedPolicy)

        print("Direct 8-peer final packet age: \(directEight.maximumFinalAgeNanos / 1_000_000) ms")
        print("Shaped 1-peer final packet age: \(shapedOne.maximumFinalAgeNanos / 1_000_000) ms")
        print("Unbounded 8-peer final packet age: \(unboundedEight.maximumFinalAgeNanos / 1_000_000) ms")
        print("Bounded 8-peer final packet age: \(boundedEight.maximumFinalAgeNanos / 1_000_000) ms")
        print("Unbounded 8-peer audible lateness: \(unboundedEight.maximumAudibleLatenessNanos / 1_000_000) ms")
        print("Bounded 8-peer audible lateness: \(boundedEight.maximumAudibleLatenessNanos / 1_000_000) ms")
        print("Bounded packets delivered per peer: \(boundedEight.minimumPacketsReceived) / 200")
        print("Automatic resync commands after detected lateness: \(unboundedEight.resyncCommandsReceived)")

        // Negative control: fan-out over unconstrained localhost should remain comfortably
        // inside the player's 250 ms target buffer even with eight real NWConnections.
        #expect(directEight.maximumFinalAgeNanos < 100_000_000)
        #expect(directEight.maximumAudibleLatenessNanos < 50_000_000)
        #expect(directEight.minimumPacketsReceived >= 190)

        // Reproduction: the same real host and peers stay current with one stream, but
        // eight unicast streams exceed the shared 4 Mb/s link and accumulate delay.
        #expect(shapedOne.maximumFinalAgeNanos < 100_000_000)
        #expect(unboundedEight.maximumFinalAgeNanos > shapedOne.maximumFinalAgeNanos + 1_000_000_000)
        #expect(unboundedEight.maximumFinalAgeNanos > SynchronizedPlayer.targetLatencyNanos)
        #expect(unboundedEight.maximumAudibleLatenessNanos > 1_000_000_000)
        #expect(unboundedEight.minimumPacketsReceived >= 190)
        #expect(unboundedEight.maximumPacketArrivalSkewNanos > 5_000_000)
        #expect(unboundedEight.resyncCommandsReceived > 0)

        // Keeping only the newest unsent packet trades concealment for bounded latency.
        #expect(boundedEight.maximumFinalAgeNanos < SynchronizedPlayer.targetLatencyNanos)
        #expect(boundedEight.maximumAudibleLatenessNanos < 100_000_000)
        #expect(boundedEight.minimumPacketsReceived < unboundedEight.minimumPacketsReceived)
    }

    @Test("Receiver detects a late timeline and hard-resynchronizes")
    func receiverDetectsAndResynchronizes() throws {
        let player = try SynchronizedPlayer()
        defer { player.stop() }
        player.clockOffsetNanos = 0
        let captureNanos = MonotonicClock.nowNanos()
        let samples = [Int16](
            repeating: 0,
            count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
        )

        player.accept(AudioPacket(
            sequence: 0,
            frameIndex: 0,
            captureTimeNanos: captureNanos,
            samples: samples
        ))
        Thread.sleep(forTimeInterval: 0.45)
        player.accept(AudioPacket(
            sequence: 1,
            frameIndex: UInt64(AudioPacket.framesPerPacket),
            captureTimeNanos: captureNanos + 5_000_000,
            samples: samples
        ))

        let report = player.syncReport()
        print(
            "Receiver late by \(report.latenessNanos / 1_000_000) ms; "
                + "automatic resync count = \(report.resyncCount)"
        )
        #expect(report.latenessNanos > SynchronizedPlayer.hardResyncThresholdNanos)
        #expect(report.latePacketCount == 1)
        #expect(report.resyncCount == 1)
    }

    @Test("Render watchdog detects CPU stalls but ignores an inactive source")
    func renderWatchdogDetectsCPUStall() {
        var watchdog = PlaybackWatchdog()
        let start: UInt64 = 1_000_000_000

        let initialCheck = watchdog.shouldResynchronize(
            sampleTime: 2_400,
            nowNanos: start,
            lastPacketReceivedNanos: start
        )
        let beforeThreshold = watchdog.shouldResynchronize(
            sampleTime: 2_400,
            nowNanos: start + 200_000_000,
            lastPacketReceivedNanos: start + 200_000_000
        )
        let afterThreshold = watchdog.shouldResynchronize(
            sampleTime: 2_400,
            nowNanos: start + 300_000_000,
            lastPacketReceivedNanos: start + 300_000_000
        )
        #expect(!initialCheck)
        #expect(!beforeThreshold)
        #expect(afterThreshold)

        watchdog.reset()
        let inactiveInitialCheck = watchdog.shouldResynchronize(
            sampleTime: nil,
            nowNanos: start,
            lastPacketReceivedNanos: start
        )
        let inactiveLaterCheck = watchdog.shouldResynchronize(
            sampleTime: nil,
            nowNanos: start + 800_000_000,
            lastPacketReceivedNanos: start
        )
        #expect(!inactiveInitialCheck)
        #expect(!inactiveLaterCheck)
    }

    @Test("Listener re-anchors after sustained post-spike drift")
    func listenerReanchorsAfterSustainedPostSpikeDrift() {
        var recovery = PlaybackDriftRecovery()
        let delayed = SynchronizedPlayer.hardResyncThresholdNanos + 30_000_000

        for _ in 0..<(PlaybackDriftRecovery.minimumSampleCount - 1) {
            let shouldResynchronize = recovery.shouldResynchronize(latenessNanos: delayed)
            #expect(!shouldResynchronize)
        }
        let sustainedSevereDrift = recovery.shouldResynchronize(latenessNanos: delayed)
        #expect(sustainedSevereDrift)

        // A single delayed observation after recovery must not cause a resync loop.
        let postRecoveryDelay = recovery.shouldResynchronize(latenessNanos: delayed)
        let recoveredCheck = recovery.shouldResynchronize(latenessNanos: 2_000_000)
        let newDelay = recovery.shouldResynchronize(latenessNanos: delayed)
        #expect(!postRecoveryDelay)
        #expect(!recoveredCheck)
        #expect(!newDelay)
    }

    @Test("One busy listener cannot retime a three-device room")
    func oneBusyListenerCannotRetimeRoom() {
        let normal = RoomTiming.defaultPlayoutDelayNanos
        let delayed = RoomTiming.maximumPlayoutDelayNanos

        #expect(HostServer.consensusPlayoutDelay([normal]) == normal)
        #expect(HostServer.consensusPlayoutDelay([delayed]) == delayed)
        // The broadcaster's loopback receiver is excluded before this calculation,
        // so a one-listener room still follows its only remote recommendation.
        #expect(HostServer.consensusPlayoutDelay([normal, delayed]) == normal)
        #expect(HostServer.consensusPlayoutDelay([normal, normal, delayed]) == normal)
        #expect(HostServer.consensusPlayoutDelay([normal, delayed, delayed]) == delayed)
        #expect(HostServer.consensusPlayoutDelay(
            [normal, normal, 370_000_000],
            outputLatencyFloors: [250_000_000, 250_000_000, 370_000_000]
        ) == 370_000_000)

        let inputs = HostServer.timingInputs([
            (isLocal: true, isEligible: false, recommendation: delayed, outputLatencyFloor: 370_000_000),
            (isLocal: false, isEligible: true, recommendation: normal, outputLatencyFloor: normal),
        ])
        #expect(inputs.recommendations == [normal])
        #expect(inputs.outputLatencyFloors == [370_000_000, normal])
    }

    @Test("Participant play and pause requests force every receiver to resynchronize")
    func participantControlsHostPlayback() throws {
        let hostReady = DispatchSemaphore(value: 0)
        let commandReceived = DispatchSemaphore(value: 0)
        let state = PortState()
        let requestedCommands = LockedMediaCommands()
        let host = HostServer(
            roomName: "Playback control test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                hostReady.signal()
            },
            playbackRequestHandler: { command in
                requestedCommands.append(command)
                commandReceived.signal()
                return true
            }
        )
        try host.start()
        defer { host.stop() }
        guard hostReady.wait(timeout: .now() + 3) == .success,
              let hostPort = state.port
        else { throw LoopbackTestError.hostDidNotStart }

        let peer = HeadlessLoopbackPeer(index: 99)
        let observer = HeadlessLoopbackPeer(index: 100)
        try peer.start(hostPort: hostPort)
        try observer.start(hostPort: hostPort)
        defer {
            peer.stop()
            observer.stop()
        }
        guard peer.waitUntilJoined(timeout: 3), observer.waitUntilJoined(timeout: 3) else {
            throw LoopbackTestError.peerDidNotJoin
        }

        peer.setRoomPlayback(playing: false)
        #expect(commandReceived.wait(timeout: .now() + 2) == .success)
        #expect(requestedCommands.values == [.pause])
        // An accepted command is not proof that the source obeyed it. Keep
        // forwarding capture until Now Playing confirms the pause, otherwise
        // one ignored media-key request can latch the room silent forever.
        Thread.sleep(forTimeInterval: 0.1)
        #expect(!peer.playbackStates.contains(false))

        let samples = [Int16](
            repeating: 0,
            count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
        )
        host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos())
        #expect(waitUntil(timeout: 2) { peer.packetCount == 1 })

        host.setNowPlaying(NowPlayingMedia(title: "Test source", isPlaying: false))
        #expect(waitUntil(timeout: 2) { peer.playbackStates.contains(false) })
        #expect(waitUntil(timeout: 2) { observer.roomPlaybackStates.contains(false) })
        #expect(waitUntil(timeout: 2) {
            peer.resyncCommandCount == 1 && observer.resyncCommandCount == 1
        })

        host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos())
        Thread.sleep(forTimeInterval: 0.1)
        #expect(peer.packetCount == 1)

        peer.setRoomPlayback(playing: true)
        #expect(commandReceived.wait(timeout: .now() + 2) == .success)
        #expect(requestedCommands.values == [.pause, .play])
        #expect(waitUntil(timeout: 2) { observer.playbackStates.contains(true) })
        #expect(waitUntil(timeout: 2) { peer.roomPlaybackStates.contains(true) })
        #expect(waitUntil(timeout: 2) {
            peer.resyncCommandCount == 2 && observer.resyncCommandCount == 2
        })
        // A delayed or missing Now Playing update must not leave the host's
        // packet path latched in Pause after macOS accepts the Play request.
        host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos())
        #expect(waitUntil(timeout: 2) { peer.packetCount == 2 })

        // Later source confirmation reconciles metadata without a second reset.
        host.setNowPlaying(NowPlayingMedia(title: "Test source", isPlaying: true))
        Thread.sleep(forTimeInterval: 0.1)
        #expect(peer.resyncCommandCount == 2)
        #expect(observer.resyncCommandCount == 2)

        peer.sendMediaCommand(.nextTrack)
        #expect(commandReceived.wait(timeout: .now() + 2) == .success)
        #expect(requestedCommands.values == [.pause, .play, .nextTrack])
        #expect(peer.resyncCommandCount == 2)
        #expect(observer.resyncCommandCount == 2)

        host.setNowPlaying(NowPlayingMedia(title: "Test source", isPlaying: false))
        #expect(waitUntil(timeout: 2) { observer.playbackStates.last == false })
        #expect(waitUntil(timeout: 2) { peer.resyncCommandCount == 3 })
        #expect(observer.resyncCommandCount == 3)
    }

    @Test("Toggle requests become explicit idempotent source commands")
    func togglePlaybackRequestsAreNormalized() {
        let requestedCommands = LockedMediaCommands()
        let host = HostServer(
            roomName: "Playback normalization test",
            advertise: false,
            playbackRequestHandler: { command in
                requestedCommands.append(command)
                return true
            }
        )

        #expect(host.sendRoomMediaCommand(.togglePlayPause))
        #expect(host.sendRoomMediaCommand(.togglePlayPause))
        #expect(requestedCommands.values == [.pause, .play])
    }

    @Test("Manual resync aligns every selected synchronized output")
    func participantCanRequestManualResync() throws {
        let hostReady = DispatchSemaphore(value: 0)
        let state = PortState()
        let host = HostServer(
            roomName: "Manual sync test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                hostReady.signal()
            },
            localParticipantID: "loopback-peer-201"
        )
        try host.start()
        defer { host.stop() }
        guard hostReady.wait(timeout: .now() + 3) == .success,
              let hostPort = state.port
        else { throw LoopbackTestError.hostDidNotStart }

        let requester = HeadlessLoopbackPeer(index: 201)
        let target = HeadlessLoopbackPeer(index: 202)
        let healthyPeer = HeadlessLoopbackPeer(index: 203)
        for peer in [requester, target, healthyPeer] { try peer.start(hostPort: hostPort) }
        defer { [requester, target, healthyPeer].forEach { $0.stop() } }
        guard requester.waitUntilJoined(timeout: 3),
              target.waitUntilJoined(timeout: 3),
              healthyPeer.waitUntilJoined(timeout: 3)
        else { throw LoopbackTestError.peerDidNotJoin }

        requester.requestResync(participantID: "loopback-peer-202")
        #expect(waitUntil(timeout: 2) { target.resyncCommandCount == 1 })
        #expect(requester.resyncCommandCount == 0)
        #expect(healthyPeer.resyncCommandCount == 0)

        healthyPeer.requestResync(participantID: nil)
        #expect(waitUntil(timeout: 2) {
            requester.resyncCommandCount == 1
                && target.resyncCommandCount == 2
                && healthyPeer.resyncCommandCount == 1
        })
        let broadcasterCutover = try #require(requester.resyncCutovers.last)
        let targetCutover = try #require(target.resyncCutovers.last)
        let healthyCutover = try #require(healthyPeer.resyncCutovers.last)
        #expect(broadcasterCutover == targetCutover)
        #expect(targetCutover == healthyCutover)

        // The broadcaster's audible path is also a synchronized receiver.
        target.requestResync(participantID: "loopback-peer-201")
        #expect(waitUntil(timeout: 2) { requester.resyncCommandCount == 2 })
    }

    @Test("Listener playback controls reset every output on one shared boundary")
    func listenerPlaybackControlsResetAllSynchronizedOutputs() throws {
        let hostReady = DispatchSemaphore(value: 0)
        let commandReceived = DispatchSemaphore(value: 0)
        let state = PortState()
        let requestedCommands = LockedMediaCommands()
        let host = HostServer(
            roomName: "System playback source of truth \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                hostReady.signal()
            },
            playbackRequestHandler: { command in
                requestedCommands.append(command)
                commandReceived.signal()
                return true
            },
            localParticipantID: "loopback-peer-351"
        )
        try host.start()
        defer { host.stop() }
        guard hostReady.wait(timeout: .now() + 3) == .success,
              let hostPort = state.port
        else { throw LoopbackTestError.hostDidNotStart }

        let broadcasterOutput = HeadlessLoopbackPeer(index: 351)
        let listener = HeadlessLoopbackPeer(index: 352)
        try broadcasterOutput.start(hostPort: hostPort)
        try listener.start(hostPort: hostPort)
        defer {
            broadcasterOutput.stop()
            listener.stop()
        }
        guard broadcasterOutput.waitUntilJoined(timeout: 3),
              listener.waitUntilJoined(timeout: 3)
        else { throw LoopbackTestError.peerDidNotJoin }

        listener.sendMediaCommand(.pause)
        #expect(commandReceived.wait(timeout: .now() + 2) == .success)
        host.setNowPlaying(NowPlayingMedia(title: "System source", isPlaying: false))
        #expect(waitUntil(timeout: 2) { broadcasterOutput.roomPlaybackStates.last == false })
        #expect(waitUntil(timeout: 2) { listener.roomPlaybackStates.last == false })
        #expect(waitUntil(timeout: 2) {
            broadcasterOutput.resyncCommandCount == 1
                && listener.resyncCommandCount == 1
        })
        #expect(broadcasterOutput.resyncCutovers.last == listener.resyncCutovers.last)

        listener.sendMediaCommand(.play)
        #expect(commandReceived.wait(timeout: .now() + 2) == .success)
        host.setNowPlaying(NowPlayingMedia(title: "System source", isPlaying: true))
        #expect(waitUntil(timeout: 2) { broadcasterOutput.roomPlaybackStates.last == true })
        #expect(waitUntil(timeout: 2) { listener.roomPlaybackStates.last == true })
        #expect(waitUntil(timeout: 2) {
            broadcasterOutput.resyncCommandCount == 2
                && listener.resyncCommandCount == 2
        })
        #expect(broadcasterOutput.resyncCutovers.last == listener.resyncCutovers.last)
        #expect(requestedCommands.values == [.pause, .play])
    }

    @Test("A rejected source command does not publish a false room state")
    func rejectedSourcePlaybackCommandLeavesRoomRunning() throws {
        let hostReady = DispatchSemaphore(value: 0)
        let state = PortState()
        let host = HostServer(
            roomName: "Rejected playback control \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                hostReady.signal()
            },
            playbackRequestHandler: { _ in false }
        )
        try host.start()
        defer { host.stop() }
        guard hostReady.wait(timeout: .now() + 3) == .success,
              let hostPort = state.port
        else { throw LoopbackTestError.hostDidNotStart }

        let listener = HeadlessLoopbackPeer(index: 401)
        try listener.start(hostPort: hostPort)
        defer { listener.stop() }
        guard listener.waitUntilJoined(timeout: 3) else { throw LoopbackTestError.peerDidNotJoin }
        #expect(waitUntil(timeout: 2) { listener.roomPlaybackStates.last == true })

        listener.sendMediaCommand(.pause)
        Thread.sleep(forTimeInterval: 0.15)
        #expect(listener.roomPlaybackStates.last == true)
        #expect(listener.resyncCommandCount == 0)
        #expect(host.sendRoomMediaCommand(.pause) == false)
        #expect(listener.roomPlaybackStates.last == true)
    }

    @Test("Playback remains controllable when broadcaster and listener alternate commands")
    func alternatingPlaybackControllersDoNotBreakRoomControl() throws {
        let hostReady = DispatchSemaphore(value: 0)
        let state = PortState()
        let requestedCommands = LockedMediaCommands()
        let host = HostServer(
            roomName: "Alternating playback control \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                hostReady.signal()
            },
            playbackRequestHandler: { command in
                requestedCommands.append(command)
                return true
            }
        )
        try host.start()
        defer { host.stop() }
        guard hostReady.wait(timeout: .now() + 3) == .success,
              let hostPort = state.port
        else { throw LoopbackTestError.hostDidNotStart }

        let listener = HeadlessLoopbackPeer(index: 301)
        let observer = HeadlessLoopbackPeer(index: 302)
        try listener.start(hostPort: hostPort)
        try observer.start(hostPort: hostPort)
        defer { listener.stop(); observer.stop() }
        guard listener.waitUntilJoined(timeout: 3), observer.waitUntilJoined(timeout: 3) else {
            throw LoopbackTestError.peerDidNotJoin
        }

        host.sendRoomMediaCommand(.pause)
        #expect(waitUntil(timeout: 2) { requestedCommands.values.count == 1 })
        host.setNowPlaying(NowPlayingMedia(title: "Test source", isPlaying: false))
        #expect(waitUntil(timeout: 2) { observer.roomPlaybackStates.last == false })
        host.sendRoomMediaCommand(.play)
        #expect(waitUntil(timeout: 2) { requestedCommands.values.count == 2 })
        host.setNowPlaying(NowPlayingMedia(title: "Test source", isPlaying: true))
        #expect(waitUntil(timeout: 2) { observer.roomPlaybackStates.last == true })
        listener.sendMediaCommand(.pause)
        #expect(waitUntil(timeout: 2) { requestedCommands.values.count == 3 })
        host.setNowPlaying(NowPlayingMedia(title: "Test source", isPlaying: false))
        #expect(waitUntil(timeout: 2) { observer.roomPlaybackStates.last == false })
        listener.sendMediaCommand(.play)
        #expect(waitUntil(timeout: 2) { requestedCommands.values.count == 4 })
        host.setNowPlaying(NowPlayingMedia(title: "Test source", isPlaying: true))
        #expect(waitUntil(timeout: 2) { observer.roomPlaybackStates.last == true })
        host.sendRoomMediaCommand(.pause)
        #expect(waitUntil(timeout: 2) { requestedCommands.values.count == 5 })
        host.setNowPlaying(NowPlayingMedia(title: "Test source", isPlaying: false))
        #expect(waitUntil(timeout: 2) { observer.roomPlaybackStates.last == false })

        #expect(requestedCommands.values == [.pause, .play, .pause, .play, .pause])
        #expect(listener.resyncCommandCount == 5)
        #expect(observer.resyncCommandCount == 5)
        #expect(listener.resyncCutovers.suffix(5).allSatisfy { $0 > 0 })
        #expect(observer.resyncCutovers.suffix(5).allSatisfy { $0 > 0 })
    }

    @Test("An established listener can adapt timing after audio but a joiner cannot retime it")
    func joiningListenerKeepsEstablishedRoomTiming() throws {
        let hostReady = DispatchSemaphore(value: 0)
        let state = PortState()
        let host = HostServer(
            roomName: "Stable timing test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                hostReady.signal()
            }
        )
        try host.start()
        defer { host.stop() }
        guard hostReady.wait(timeout: .now() + 3) == .success,
              let hostPort = state.port
        else { throw LoopbackTestError.hostDidNotStart }

        let existingPeer = HeadlessLoopbackPeer(index: 101)
        try existingPeer.start(hostPort: hostPort)
        defer { existingPeer.stop() }
        guard existingPeer.waitUntilJoined(timeout: 3) else {
            throw LoopbackTestError.peerDidNotJoin
        }

        let samples = [Int16](
            repeating: 0,
            count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
        )
        host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos())
        #expect(waitUntil(timeout: 2) { existingPeer.packetCount == 1 })

        let establishedDelay = min(
            RoomTiming.maximumPlayoutDelayNanos,
            RoomTiming.defaultPlayoutDelayNanos + 40_000_000
        )
        existingPeer.recommendPlayoutDelay(establishedDelay)
        existingPeer.sendPing()
        #expect(existingPeer.waitForPong(timeout: 2))
        #expect(waitUntil(timeout: 2) { existingPeer.playoutDelays.last == establishedDelay })
        #expect(waitUntil(timeout: 2) { existingPeer.resyncCommandCount == 1 })

        let joiningPeer = HeadlessLoopbackPeer(index: 102)
        try joiningPeer.start(hostPort: hostPort)
        defer { joiningPeer.stop() }
        guard joiningPeer.waitUntilJoined(timeout: 3) else {
            throw LoopbackTestError.peerDidNotJoin
        }
        #expect(waitUntil(timeout: 2) {
            joiningPeer.playoutDelays.last == establishedDelay
        })

        joiningPeer.recommendPlayoutDelay(RoomTiming.maximumPlayoutDelayNanos)
        joiningPeer.sendPing()
        #expect(joiningPeer.waitForPong(timeout: 2))
        #expect(existingPeer.playoutDelays.last == establishedDelay)
        #expect(joiningPeer.playoutDelays.last == establishedDelay)
    }

    @Test("An active room does not repeatedly interrupt playback while lowering its buffer")
    func activeRoomDefersDownwardTimingChanges() throws {
        let ready = DispatchSemaphore(value: 0)
        let state = PortState()
        let host = HostServer(
            roomName: "Stable downward timing test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in state.set(port); ready.signal() }
        )
        try host.start()
        defer { host.stop() }
        guard ready.wait(timeout: .now() + 3) == .success, let port = state.port else {
            throw LoopbackTestError.hostDidNotStart
        }

        let peer = HeadlessLoopbackPeer(index: 104)
        try peer.start(hostPort: port)
        defer { peer.stop() }
        guard peer.waitUntilJoined(timeout: 3) else { throw LoopbackTestError.peerDidNotJoin }

        let samples = [Int16](
            repeating: 0,
            count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
        )
        host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos())
        #expect(waitUntil(timeout: 2) { peer.packetCount == 1 })

        peer.recommendPlayoutDelay(RoomTiming.maximumPlayoutDelayNanos)
        peer.sendPing()
        #expect(peer.waitForPong(timeout: 2))
        #expect(waitUntil(timeout: 2) {
            peer.playoutDelays.last == RoomTiming.maximumPlayoutDelayNanos
                && peer.resyncCommandCount == 1
        })

        Thread.sleep(forTimeInterval: 2.1)
        peer.recommendPlayoutDelay(RoomTiming.defaultPlayoutDelayNanos)
        peer.sendPing()
        #expect(peer.waitForPong(timeout: 2))
        Thread.sleep(forTimeInterval: 0.1)

        #expect(peer.playoutDelays.last == RoomTiming.maximumPlayoutDelayNanos)
        #expect(
            peer.resyncCommandCount == 1,
            "Reducing an active room buffer must not create a new audible cutover every two seconds."
        )
    }

    @Test("Live timing changes keep broadcaster and listeners on the same boundary")
    func liveTimingChangesIncludeBroadcasterOutput() throws {
        let ready = DispatchSemaphore(value: 0)
        let state = PortState()
        let host = HostServer(
            roomName: "Unified output timing test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                ready.signal()
            },
            localParticipantID: "loopback-peer-105"
        )
        try host.start()
        defer { host.stop() }
        guard ready.wait(timeout: .now() + 3) == .success, let port = state.port else {
            throw LoopbackTestError.hostDidNotStart
        }

        let broadcasterOutput = HeadlessLoopbackPeer(index: 105)
        let listener = HeadlessLoopbackPeer(index: 106)
        try broadcasterOutput.start(hostPort: port)
        try listener.start(hostPort: port)
        defer {
            broadcasterOutput.stop()
            listener.stop()
        }
        guard broadcasterOutput.waitUntilJoined(timeout: 3),
              listener.waitUntilJoined(timeout: 3)
        else { throw LoopbackTestError.peerDidNotJoin }

        let samples = [Int16](
            repeating: 0,
            count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
        )
        host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos())
        #expect(waitUntil(timeout: 2) {
            broadcasterOutput.packetCount == 1 && listener.packetCount == 1
        })

        listener.recommendPlayoutDelay(RoomTiming.maximumPlayoutDelayNanos)
        listener.sendPing()
        #expect(listener.waitForPong(timeout: 2))
        #expect(waitUntil(timeout: 2) {
            broadcasterOutput.playoutDelays.last == RoomTiming.maximumPlayoutDelayNanos
                && listener.playoutDelays.last == RoomTiming.maximumPlayoutDelayNanos
                && broadcasterOutput.resyncCommandCount == 1
                && listener.resyncCommandCount == 1
        })
        #expect(broadcasterOutput.resyncCutovers.last == listener.resyncCutovers.last)
    }

    @Test("The first listener can raise timing when capture starts before receivers join")
    func captureBeforeJoinStillAllowsInitialTimingAdaptation() throws {
        let ready = DispatchSemaphore(value: 0)
        let state = PortState()
        let host = HostServer(
            roomName: "Capture-before-join timing test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                ready.signal()
            },
            localParticipantID: "loopback-peer-107"
        )
        try host.start()
        defer { host.stop() }
        guard ready.wait(timeout: .now() + 3) == .success, let port = state.port else {
            throw LoopbackTestError.hostDidNotStart
        }

        let samples = [Int16](
            repeating: 0,
            count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
        )
        host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos())

        let broadcasterOutput = HeadlessLoopbackPeer(index: 107)
        let firstListener = HeadlessLoopbackPeer(index: 108)
        try broadcasterOutput.start(hostPort: port)
        try firstListener.start(hostPort: port)
        defer {
            broadcasterOutput.stop()
            firstListener.stop()
        }
        guard broadcasterOutput.waitUntilJoined(timeout: 3),
              firstListener.waitUntilJoined(timeout: 3)
        else { throw LoopbackTestError.peerDidNotJoin }

        host.acceptAudio(
            samples: samples,
            captureTimeNanos: MonotonicClock.nowNanos() + 20_000_000
        )
        #expect(waitUntil(timeout: 2) {
            broadcasterOutput.packetCount >= 1 && firstListener.packetCount >= 1
        })

        firstListener.recommendPlayoutDelay(RoomTiming.maximumPlayoutDelayNanos)
        firstListener.sendPing()
        #expect(firstListener.waitForPong(timeout: 2))
        #expect(waitUntil(timeout: 2) {
            broadcasterOutput.playoutDelays.last == RoomTiming.maximumPlayoutDelayNanos
                && firstListener.playoutDelays.last == RoomTiming.maximumPlayoutDelayNanos
                && broadcasterOutput.resyncCommandCount == 1
                && firstListener.resyncCommandCount == 1
        })
        #expect(broadcasterOutput.resyncCutovers.last == firstListener.resyncCutovers.last)
    }

    @Test("A listener joining after broadcaster playback begins inherits the active timeline")
    func lateListenerCannotRetimeActiveBroadcaster() throws {
        let ready = DispatchSemaphore(value: 0)
        let state = PortState()
        let host = HostServer(
            roomName: "Late-listener timing test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                ready.signal()
            },
            localParticipantID: "loopback-peer-109"
        )
        try host.start()
        defer { host.stop() }
        guard ready.wait(timeout: .now() + 3) == .success, let port = state.port else {
            throw LoopbackTestError.hostDidNotStart
        }

        let broadcasterOutput = HeadlessLoopbackPeer(index: 109)
        try broadcasterOutput.start(hostPort: port)
        defer { broadcasterOutput.stop() }
        guard broadcasterOutput.waitUntilJoined(timeout: 3) else {
            throw LoopbackTestError.peerDidNotJoin
        }

        let samples = [Int16](
            repeating: 0,
            count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
        )
        let playbackStart = MonotonicClock.nowNanos()
        host.acceptAudio(samples: samples, captureTimeNanos: playbackStart)
        #expect(waitUntil(timeout: 2) { broadcasterOutput.packetCount == 1 })

        let lateListener = HeadlessLoopbackPeer(index: 110)
        try lateListener.start(hostPort: port)
        defer { lateListener.stop() }
        guard lateListener.waitUntilJoined(timeout: 3) else {
            throw LoopbackTestError.peerDidNotJoin
        }

        host.acceptAudio(
            samples: samples,
            captureTimeNanos: playbackStart + 20_000_000
        )
        #expect(waitUntil(timeout: 2) { lateListener.packetCount >= 1 })
        #expect(lateListener.playoutDelays.last == RoomTiming.defaultPlayoutDelayNanos)

        lateListener.recommendPlayoutDelay(RoomTiming.maximumPlayoutDelayNanos)
        lateListener.sendPing()
        #expect(lateListener.waitForPong(timeout: 2))
        Thread.sleep(forTimeInterval: 0.1)

        #expect(lateListener.playoutDelays.last == RoomTiming.defaultPlayoutDelayNanos)
        #expect(broadcasterOutput.playoutDelays.last == RoomTiming.defaultPlayoutDelayNanos)
        #expect(lateListener.resyncCommandCount == 0)
        #expect(broadcasterOutput.resyncCommandCount == 0)

        let packetsBeforeRecommendation = lateListener.packetCount
        host.acceptAudio(
            samples: samples,
            captureTimeNanos: playbackStart + 40_000_000
        )
        #expect(waitUntil(timeout: 2) {
            lateListener.packetCount > packetsBeforeRecommendation
        })
    }

    private func runRoom(
        peerCount: Int,
        linkBitsPerSecond: UInt64?,
        policy: HostServer.AudioBackpressurePolicy
    ) throws -> RoomMeasurements {
        let hostReady = DispatchSemaphore(value: 0)
        let state = PortState()
        let shaper = linkBitsPerSecond.map(FluidLinkShaper.init(bitsPerSecond:))
        let host = HostServer(
            roomName: "Loopback test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                hostReady.signal()
            },
            outboundSend: shaper.map { shaper in
                { connection, data, isComplete, completion in
                    shaper.send(
                        data,
                        over: connection,
                        isComplete: isComplete,
                        completion: completion
                    )
                }
            },
            audioBackpressurePolicy: policy
        )
        try host.start()
        guard hostReady.wait(timeout: .now() + 3) == .success,
              let hostPort = state.port
        else {
            host.stop()
            throw LoopbackTestError.hostDidNotStart
        }

        var peers = [HeadlessLoopbackPeer]()
        do {
            for index in 0..<peerCount {
                let peer = HeadlessLoopbackPeer(index: index)
                try peer.start(hostPort: hostPort)
                peers.append(peer)
            }
            guard peers.allSatisfy({ $0.waitUntilJoined(timeout: 3) }) else {
                throw LoopbackTestError.peerDidNotJoin
            }

            // Let the host's outbound UDP connections reach ready before capture starts.
            Thread.sleep(forTimeInterval: 0.1)
            let packetsPerCallback = 4
            let expectedPacketCount = 200
            let samples = [Int16](
                repeating: 0,
                count: packetsPerCallback
                    * Int(AudioPacket.framesPerPacket)
                    * Int(AudioPacket.channelCount)
            )

            for callbackIndex in 0..<(expectedPacketCount / packetsPerCallback) {
                let now = MonotonicClock.nowNanos()
                host.acceptAudio(
                    samples: samples,
                    captureTimeNanos: now - 20_000_000
                )
                if callbackIndex.isMultiple(of: 5) {
                    peers.forEach { $0.sendPing() }
                }
                Thread.sleep(forTimeInterval: 0.020)
            }

            let receivedEnough = waitUntil(timeout: 5) {
                peers.allSatisfy { $0.lastSequence == UInt32(expectedPacketCount - 1) }
            }
            guard receivedEnough else {
                throw LoopbackTestError.audioDidNotDrain(peers.map(\.packetCount))
            }

            let snapshots = peers.map { $0.snapshot() }
            let commonSequence = snapshots.compactMap(\.lastSequence).min()
            guard let commonSequence else {
                throw LoopbackTestError.noAudioReceived
            }
            let finalArrivals = try snapshots.map { snapshot in
                guard let arrival = snapshot.arrivals[commonSequence] else {
                    throw LoopbackTestError.missingCommonPacket(commonSequence)
                }
                return arrival
            }
            let finalAges = finalArrivals.map { $0.arrivedNanos - $0.captureNanos }
            let offsets = snapshots.compactMap(\.clockOffsetNanos)
            let maximumArrivalSkew = (UInt32(0)...commonSequence).compactMap { sequence -> UInt64? in
                let arrivalTimes = snapshots.compactMap { $0.arrivals[sequence]?.arrivedNanos }
                guard arrivalTimes.count == snapshots.count,
                      let first = arrivalTimes.min(),
                      let last = arrivalTimes.max()
                else { return nil }
                return last - first
            }.max() ?? 0

            for (peer, snapshot) in zip(peers, snapshots)
            where snapshot.audibleLatenessNanos > SynchronizedPlayer.hardResyncThresholdNanos {
                peer.reportSync(latenessNanos: snapshot.audibleLatenessNanos)
            }
            _ = waitUntil(timeout: 1) {
                zip(peers, snapshots).allSatisfy { peer, snapshot in
                    snapshot.audibleLatenessNanos <= SynchronizedPlayer.hardResyncThresholdNanos
                        || peer.resyncCommandCount > 0
                }
            }
            let resyncCommandsReceived = peers.map(\.resyncCommandCount).reduce(0, +)

            peers.forEach { $0.stop() }
            host.stop()
            return RoomMeasurements(
                maximumFinalAgeNanos: finalAges.max() ?? 0,
                maximumPacketArrivalSkewNanos: maximumArrivalSkew,
                maximumAudibleLatenessNanos: snapshots.map(\.audibleLatenessNanos).max() ?? 0,
                clockOffsetSpreadNanos: offsetSpread(offsets),
                minimumPacketsReceived: snapshots.map(\.packetCount).min() ?? 0,
                resyncCommandsReceived: resyncCommandsReceived
            )
        } catch {
            peers.forEach { $0.stop() }
            host.stop()
            throw error
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.010)
        }
        return condition()
    }

    private func offsetSpread(_ offsets: [Int64]) -> UInt64 {
        guard let minimum = offsets.min(), let maximum = offsets.max() else { return 0 }
        return UInt64(maximum - minimum)
    }
}

private final class HeadlessLoopbackPeer {
    private let queue: DispatchQueue
    private let index: Int
    private let participantID: String
    private let joined = DispatchSemaphore(value: 0)
    private let pongReceived = DispatchSemaphore(value: 0)
    private let clock = ClockSynchronizer()
    private let controlDecoder = ControlLineDecoder()
    private var udpListener: NWListener?
    private var videoListener: NWListener?
    private var control: NWConnection?
    private var acceptedAudio = [NWConnection]()
    private var acceptedVideo = [NWConnection]()
    private var arrivals = [UInt32: PacketArrival]()
    private var receivedResyncCommands = 0
    private var receivedResyncCutovers = [UInt64]()
    private var receivedPlaybackStates = [Bool]()
    private var receivedRoomPlaybackStates = [Bool]()
    private var receivedPlayoutDelays = [UInt64]()
    private var receivedLevels = [(volume: Double, muted: Bool)]()

    init(index: Int, participantID: String? = nil) {
        self.index = index
        self.participantID = participantID ?? "loopback-peer-\(index)"
        self.queue = DispatchQueue(label: "in.werai.tests.loopback-peer.\(index)")
    }

    var packetCount: Int { queue.sync { arrivals.count } }
    var lastSequence: UInt32? { queue.sync { arrivals.keys.max() } }
    var resyncCommandCount: Int { queue.sync { receivedResyncCommands } }
    var resyncCutovers: [UInt64] { queue.sync { receivedResyncCutovers } }
    var playbackStates: [Bool] { queue.sync { receivedPlaybackStates } }
    var roomPlaybackStates: [Bool] { queue.sync { receivedRoomPlaybackStates } }
    var playoutDelays: [UInt64] { queue.sync { receivedPlayoutDelays } }
    var levels: [(volume: Double, muted: Bool)] { queue.sync { receivedLevels } }

    func start(hostPort: NWEndpoint.Port) throws {
        let udp = try NWListener(using: .udp, on: .any)
        udp.newConnectionHandler = { [weak self] connection in
            self?.acceptAudio(connection)
        }
        let udpPort = try start(udp, kind: "UDP")
        udpListener = udp

        let video = try NWListener(using: .tcp, on: .any)
        video.newConnectionHandler = { [weak self] connection in
            self?.acceptVideo(connection)
        }
        let videoPort = try start(video, kind: "video")
        videoListener = video

        let control = NWConnection(host: "127.0.0.1", port: hostPort, using: .tcp)
        self.control = control
        receiveControl(from: control)
        control.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            let join = ControlMessage(
                type: "join",
                udpPort: udpPort.rawValue,
                videoPort: videoPort.rawValue,
                displayName: "Loopback peer \(self.index)",
                participantID: self.participantID
            )
            self.send(join)
        }
        control.start(queue: queue)
    }

    func waitUntilJoined(timeout: TimeInterval) -> Bool {
        joined.wait(timeout: .now() + timeout) == .success
    }

    func sendPing() {
        queue.async { [weak self] in
            guard let self else { return }
            self.send(self.clock.makePing(at: MonotonicClock.nowNanos()))
        }
    }

    func waitForPong(timeout: TimeInterval) -> Bool {
        pongReceived.wait(timeout: .now() + timeout) == .success
    }

    func recommendPlayoutDelay(_ nanos: UInt64) {
        queue.async { [weak self] in
            self?.send(ControlMessage(type: "sync_report", playoutDelayNanos: nanos))
        }
    }

    func reportSync(latenessNanos: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.send(ControlMessage(
                type: "sync_status",
                participantID: self.participantID,
                syncReport: PlaybackSyncReport(
                    measuredAtNanos: MonotonicClock.nowNanos(),
                    latenessNanos: latenessNanos,
                    latePacketCount: 1,
                    resyncCount: 0
                )
            ))
        }
    }

    func setRoomPlayback(playing: Bool) {
        sendMediaCommand(playing ? .play : .pause)
    }

    func sendMediaCommand(_ command: RoomMediaCommand) {
        queue.async { [weak self] in
            self?.send(ControlMessage(
                type: "media_command",
                mediaCommand: command
            ))
        }
    }

    func requestResync(participantID: String?) {
        queue.async { [weak self] in
            self?.send(ControlMessage(type: "resync_request", targetID: participantID))
        }
    }

    func setLevel(volume: Double, muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.send(ControlMessage(
                type: "set_level",
                targetID: self.participantID,
                volume: volume,
                muted: muted
            ))
        }
    }

    func snapshot() -> PeerSnapshot {
        queue.sync {
            PeerSnapshot(
                arrivals: arrivals,
                lastSequence: arrivals.keys.max(),
                packetCount: arrivals.count,
                clockOffsetNanos: clock.offsetNanos,
                audibleLatenessNanos: VirtualAudioSink.audibleLateness(
                    for: arrivals,
                    clockOffsetNanos: clock.offsetNanos ?? 0
                )
            )
        }
    }

    func stop() {
        queue.sync {
            control?.cancel()
            udpListener?.cancel()
            videoListener?.cancel()
            acceptedAudio.forEach { $0.cancel() }
            acceptedVideo.forEach { $0.cancel() }
            control = nil
            udpListener = nil
            videoListener = nil
            acceptedAudio.removeAll()
            acceptedVideo.removeAll()
        }
    }

    private func start(_ listener: NWListener, kind: String) throws -> NWEndpoint.Port {
        let ready = DispatchSemaphore(value: 0)
        let portState = PortState()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port {
                portState.set(port)
                ready.signal()
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let port = portState.port else {
            listener.cancel()
            throw LoopbackTestError.listenerDidNotStart(kind)
        }
        return port
    }

    private func receiveControl(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                for message in self.controlDecoder.append(data) {
                    if message.type == "welcome" {
                        self.joined.signal()
                    } else if message.type == "pong" {
                        self.clock.acceptPong(message, receivedAt: MonotonicClock.nowNanos())
                        self.pongReceived.signal()
                    } else if message.type == "resync" {
                        self.receivedResyncCommands += 1
                        if let cutover = message.hostNanos {
                            self.receivedResyncCutovers.append(cutover)
                        }
                    } else if message.type == "sync_timing",
                              let delay = message.playoutDelayNanos {
                        self.receivedPlayoutDelays.append(delay)
                    } else if message.type == "now_playing",
                              let isPlaying = message.nowPlaying?.isPlaying {
                        self.receivedPlaybackStates.append(isPlaying)
                    } else if message.type == "room_playback",
                              let isPlaying = message.isPlaying {
                        self.receivedRoomPlaybackStates.append(isPlaying)
                    } else if message.type == "level",
                              let volume = message.volume,
                              let muted = message.muted {
                        self.receivedLevels.append((volume, muted))
                    }
                }
            }
            if !complete, error == nil {
                self.receiveControl(from: connection)
            }
        }
    }

    private func acceptAudio(_ connection: NWConnection) {
        acceptedAudio.append(connection)
        connection.start(queue: queue)

        func receiveNext() {
            connection.receiveMessage { [weak self] data, _, _, error in
                if let self, let data, let packet = AudioPacket(data: data) {
                    self.arrivals[packet.sequence] = PacketArrival(
                        captureNanos: packet.captureTimeNanos,
                        arrivedNanos: MonotonicClock.nowNanos()
                    )
                }
                if error == nil { receiveNext() }
            }
        }
        receiveNext()
    }

    private func acceptVideo(_ connection: NWConnection) {
        acceptedVideo.append(connection)
        connection.start(queue: queue)

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, complete, error in
                if !complete, error == nil { receiveNext() }
            }
        }
        receiveNext()
    }

    private func send(_ message: ControlMessage) {
        guard let data = try? message.encodedLine() else { return }
        control?.send(content: data, completion: .contentProcessed { _ in })
    }
}

private final class LockedMediaCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues = [RoomMediaCommand]()

    var values: [RoomMediaCommand] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: RoomMediaCommand) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}

private final class ReceiverRestartObservations: @unchecked Sendable {
    struct Level: Equatable {
        let volume: Double
        let muted: Bool
    }

    private let participantID: String
    private let lock = NSLock()
    private var storedConnectedCount = 0
    private var storedIsSearching = false
    private var storedLatestLevel: Level?

    init(participantID: String) {
        self.participantID = participantID
    }

    var connectedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedConnectedCount
    }

    var isSearching: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedIsSearching
    }

    var latestLevel: Level? {
        lock.lock()
        defer { lock.unlock() }
        return storedLatestLevel
    }

    func record(status: ReceiverStatus) {
        lock.lock()
        if status == .connected {
            storedConnectedCount += 1
            storedIsSearching = false
        } else if status == .searching {
            storedIsSearching = true
        }
        lock.unlock()
    }

    func record(participants: [RoomParticipant]) {
        let participant = participants.first { $0.id == participantID }
        lock.lock()
        storedLatestLevel = participant.map {
            Level(volume: $0.volume, muted: $0.isMuted)
        }
        lock.unlock()
    }

    func clearParticipants() {
        lock.lock()
        storedLatestLevel = nil
        lock.unlock()
    }
}

private final class FluidLinkShaper: @unchecked Sendable {
    private let bitsPerSecond: UInt64
    private let lock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "in.werai.tests.fluid-link")
    private var nextAvailableNanos: UInt64 = 0

    init(bitsPerSecond: UInt64) {
        self.bitsPerSecond = bitsPerSecond
    }

    func send(
        _ data: Data,
        over connection: NWConnection,
        isComplete: Bool,
        completion: @escaping (NWError?) -> Void
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let transmissionNanos = max(1, UInt64(data.count) * 8 * 1_000_000_000 / bitsPerSecond)
        lock.lock()
        let startsAt = max(now, nextAvailableNanos)
        let deliversAt = startsAt + transmissionNanos
        nextAvailableNanos = deliversAt
        lock.unlock()

        deliveryQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deliversAt)) {
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed(completion)
            )
        }
    }
}

private final class PortState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPort: NWEndpoint.Port?

    var port: NWEndpoint.Port? {
        lock.lock()
        defer { lock.unlock() }
        return storedPort
    }

    func set(_ port: NWEndpoint.Port) {
        lock.lock()
        storedPort = port
        lock.unlock()
    }
}

private struct PacketArrival {
    let captureNanos: UInt64
    let arrivedNanos: UInt64
}

private struct PeerSnapshot {
    let arrivals: [UInt32: PacketArrival]
    let lastSequence: UInt32?
    let packetCount: Int
    let clockOffsetNanos: Int64?
    let audibleLatenessNanos: UInt64
}

private struct RoomMeasurements {
    let maximumFinalAgeNanos: UInt64
    let maximumPacketArrivalSkewNanos: UInt64
    let maximumAudibleLatenessNanos: UInt64
    let clockOffsetSpreadNanos: UInt64
    let minimumPacketsReceived: Int
    let resyncCommandsReceived: Int
}

private enum VirtualAudioSink {
    static func audibleLateness(
        for arrivals: [UInt32: PacketArrival],
        clockOffsetNanos: Int64
    ) -> UInt64 {
        let packetDurationNanos: UInt64 = 5_000_000
        var playbackTailNanos: UInt64?
        var previousSequence: UInt32?
        var finalLatenessNanos: UInt64 = 0

        for sequence in arrivals.keys.sorted() {
            guard let packet = arrivals[sequence] else { continue }
            let desiredAudibleNanos = subtractSigned(packet.captureNanos, clockOffsetNanos)
                + SynchronizedPlayer.targetLatencyNanos

            if playbackTailNanos == nil {
                // This matches SynchronizedPlayer's initial 25 ms lateness guard.
                guard desiredAudibleNanos > packet.arrivedNanos + 25_000_000 else { continue }
                playbackTailNanos = desiredAudibleNanos + packetDurationNanos
                previousSequence = sequence
                continue
            }

            if let previousSequence, sequence > previousSequence + 1 {
                let concealedPackets = UInt64(sequence - previousSequence - 1)
                playbackTailNanos = (playbackTailNanos ?? 0) + concealedPackets * packetDurationNanos
            }
            let packetStartsNanos = max(playbackTailNanos ?? 0, packet.arrivedNanos)
            finalLatenessNanos = packetStartsNanos > desiredAudibleNanos
                ? packetStartsNanos - desiredAudibleNanos
                : 0
            playbackTailNanos = packetStartsNanos + packetDurationNanos
            previousSequence = sequence
        }
        return finalLatenessNanos
    }

    private static func subtractSigned(_ value: UInt64, _ delta: Int64) -> UInt64 {
        if delta >= 0 {
            return value > UInt64(delta) ? value - UInt64(delta) : 0
        }
        return value + UInt64(-delta)
    }
}

private enum LoopbackTestError: Error {
    case hostDidNotStart
    case peerDidNotJoin
    case listenerDidNotStart(String)
    case audioDidNotDrain([Int])
    case noAudioReceived
    case missingCommonPacket(UInt32)
}
