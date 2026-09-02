import Foundation
import Network
import Testing
@testable import WERAI
@testable import WERAICore

@Suite("Single-Mac room integration", .serialized)
struct LoopbackRoomScaleTests {
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
        let delayed = SynchronizedPlayer.sustainedDriftThresholdNanos + 30_000_000

        let firstDelayedCheck = recovery.shouldResynchronize(latenessNanos: delayed)
        let secondDelayedCheck = recovery.shouldResynchronize(latenessNanos: delayed)
        let thirdDelayedCheck = recovery.shouldResynchronize(latenessNanos: delayed)
        #expect(!firstDelayedCheck)
        #expect(!secondDelayedCheck)
        #expect(thirdDelayedCheck)

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
        #expect(peer.resyncCommandCount == 0)
        host.setNowPlaying(NowPlayingMedia(title: "Test source", isPlaying: false))
        #expect(waitUntil(timeout: 2) { peer.playbackStates.contains(false) })
        #expect(waitUntil(timeout: 2) { observer.roomPlaybackStates.contains(false) })
        #expect(waitUntil(timeout: 2) {
            peer.resyncCommandCount == 1 && observer.resyncCommandCount == 1
        })

        peer.setRoomPlayback(playing: true)
        #expect(commandReceived.wait(timeout: .now() + 2) == .success)
        #expect(requestedCommands.values == [.pause, .play])
        #expect(peer.resyncCommandCount == 1)
        host.setNowPlaying(NowPlayingMedia(title: "Test source", isPlaying: true))
        #expect(waitUntil(timeout: 2) { observer.playbackStates.contains(true) })
        #expect(waitUntil(timeout: 2) { peer.roomPlaybackStates.contains(true) })
        #expect(waitUntil(timeout: 2) {
            peer.resyncCommandCount == 2 && observer.resyncCommandCount == 2
        })

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

    @Test("Manual resync aligns listeners without interrupting the broadcaster")
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
            requester.resyncCommandCount == 0
                && target.resyncCommandCount == 2
                && healthyPeer.resyncCommandCount == 1
        })
        let targetCutover = try #require(target.resyncCutovers.last)
        let healthyCutover = try #require(healthyPeer.resyncCutovers.last)
        #expect(targetCutover == healthyCutover)

        // Even a direct request cannot reset the broadcaster's loopback output.
        target.requestResync(participantID: "loopback-peer-201")
        Thread.sleep(forTimeInterval: 0.1)
        #expect(requester.resyncCommandCount == 0)
    }

    @Test("Broadcaster system playback is the authoritative room state")
    func broadcasterSystemPlaybackDrivesRoomWithoutALOCommand() throws {
        let hostReady = DispatchSemaphore(value: 0)
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
                return true
            }
        )
        try host.start()
        defer { host.stop() }
        guard hostReady.wait(timeout: .now() + 3) == .success,
              let hostPort = state.port
        else { throw LoopbackTestError.hostDidNotStart }

        let listener = HeadlessLoopbackPeer(index: 351)
        try listener.start(hostPort: hostPort)
        defer { listener.stop() }
        guard listener.waitUntilJoined(timeout: 3) else { throw LoopbackTestError.peerDidNotJoin }

        // These are NowPlayingMonitor updates caused by media keys acting on the
        // broadcaster's player directly. No ALO command is involved.
        host.setNowPlaying(NowPlayingMedia(title: "System source", isPlaying: false))
        #expect(waitUntil(timeout: 2) { listener.roomPlaybackStates.last == false })
        #expect(listener.resyncCommandCount == 1)

        host.setNowPlaying(NowPlayingMedia(title: "System source", isPlaying: true))
        #expect(waitUntil(timeout: 2) { listener.roomPlaybackStates.last == true })
        #expect(waitUntil(timeout: 2) { listener.resyncCommandCount == 2 })
        #expect(requestedCommands.values.isEmpty)
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

    @Test("A room that starts empty does not let its first late joiner retime the active timeline")
    func firstLateJoinerCannotRetimeActiveTimeline() throws {
        let ready = DispatchSemaphore(value: 0)
        let state = PortState()
        let host = HostServer(
            roomName: "Empty timing test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in state.set(port); ready.signal() }
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

        let peer = HeadlessLoopbackPeer(index: 103)
        try peer.start(hostPort: port)
        defer { peer.stop() }
        guard peer.waitUntilJoined(timeout: 3) else { throw LoopbackTestError.peerDidNotJoin }
        #expect(waitUntil(timeout: 2) {
            peer.playoutDelays.last == RoomTiming.defaultPlayoutDelayNanos
        })

        peer.recommendPlayoutDelay(RoomTiming.maximumPlayoutDelayNanos)
        peer.sendPing()
        #expect(peer.waitForPong(timeout: 2))
        Thread.sleep(forTimeInterval: 0.05)
        #expect(peer.playoutDelays.last == RoomTiming.defaultPlayoutDelayNanos)
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

    init(index: Int) {
        self.index = index
        self.queue = DispatchQueue(label: "in.werai.tests.loopback-peer.\(index)")
    }

    var packetCount: Int { queue.sync { arrivals.count } }
    var lastSequence: UInt32? { queue.sync { arrivals.keys.max() } }
    var resyncCommandCount: Int { queue.sync { receivedResyncCommands } }
    var resyncCutovers: [UInt64] { queue.sync { receivedResyncCutovers } }
    var playbackStates: [Bool] { queue.sync { receivedPlaybackStates } }
    var roomPlaybackStates: [Bool] { queue.sync { receivedRoomPlaybackStates } }
    var playoutDelays: [UInt64] { queue.sync { receivedPlayoutDelays } }

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
                participantID: "loopback-peer-\(self.index)"
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
                participantID: "loopback-peer-\(self.index)",
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
