import Darwin
import Foundation
import Network
import Testing
@testable import ALO
@testable import ALOCore

@Suite("Single-Mac room integration", .serialized)
struct LoopbackRoomScaleTests {
    @Test("Broadcaster diagnostics detect remote screen lateness received over the control connection")
    func remoteScreenTimingReachesBroadcasterDiagnostics() throws {
        let ready = DispatchSemaphore(value: 0)
        let ports = PortState()
        let host = HostServer(roomName: "Remote screen timing", advertise: false,
            listenerReadyHandler: { ports.set($0); ready.signal() })
        try host.start()
        defer { host.stop() }
        try #require(ready.wait(timeout: .now() + 3) == .success)
        let port = try #require(ports.port)
        let peer = HeadlessLoopbackPeer(index: 720)
        try peer.start(hostPort: port)
        defer { peer.stop() }
        try #require(peer.waitUntilJoined(timeout: 3))
        host.setVideoEnabled(true)
        // Absolute peer time deliberately differs from the broadcaster epoch.
        // Only the relative ages/misses in screenTiming may determine health.
        peer.sendRawControl(Data("""
        {"type":"sync_status","participantID":"loopback-peer-720","syncReport":{"measuredAtNanos":1,"latenessNanos":0,"latePacketCount":0,"resyncCount":0,"driftNanos":2000000,"driftSampleAgeNanos":20000000,"screenTiming":{"latestHandoffAgeNanos":20000000,"latestDeadlineMissNanos":150000000}}}

        """.utf8))
        try #require(waitUntil(timeout: 3) { host.diagnosticsSnapshot().reportingListenerCount == 1 })
        func result() -> DiagnosticCheckResult {
            DiagnosticRoomContext(isActive: true, role: .broadcaster,
                participantCount: 2, remotePeerCount: 1, syncLabel: "Broadcasting",
                audioIsRendering: true, hasBroadcaster: true,
                timing: SessionTimingDiagnostics(receiver: nil, host: host.diagnosticsSnapshot())).result
        }
        #expect(result().outcome == .warning,
            "Healthy audio cannot conceal a current remote screen handoff miss")
        let cases: [(PlaybackScreenTimingReport?, DiagnosticOutcome)] = [
            (.init(latestHandoffAgeNanos: 20_000_000, latestDeadlineMissNanos: 0), .passed),
            (.init(latestHandoffAgeNanos: 20_000_000, latestDeadlineMissNanos: 0,
                   oldestPendingDeadlineMissNanos: 150_000_000), .warning),
            (.init(latestHandoffAgeNanos: 10_000_000_000, latestDeadlineMissNanos: 150_000_000), .passed),
            (.init(), .warning),
            (nil, .warning)
        ]
        for (screen, expected) in cases {
            let report = PlaybackSyncReport(measuredAtNanos: 1, latenessNanos: 0,
                latePacketCount: 0, resyncCount: 0, driftNanos: 2_000_000,
                driftSampleAgeNanos: 20_000_000, screenTiming: screen)
            peer.sendRawControl(try ControlMessage(type: "sync_status",
                participantID: "loopback-peer-720", syncReport: report).encodedLine())
            try #require(waitUntil(timeout: 3) { host.diagnosticsSnapshot().listeners.first?.screenTiming == screen })
            #expect(result().outcome == expected)
        }
        #expect(result().detail.contains("screen timing unverified"))
        #expect(result().detail.contains("not a physical display or lip-sync measurement"))
        host.setVideoEnabled(false)
        try #require(waitUntil(timeout: 3) { !host.diagnosticsSnapshot().videoEnabled })
        #expect(result().outcome == .passed, "Audio-only rooms do not require screen telemetry")
        let previousScreen = PlaybackScreenTimingReport(latestHandoffAgeNanos: 10_000_000_000,
            latestDeadlineMissNanos: 0)
        peer.sendRawControl(try ControlMessage(type: "sync_status", participantID: "loopback-peer-720",
            syncReport: PlaybackSyncReport(measuredAtNanos: 1, latenessNanos: 0,
                latePacketCount: 0, resyncCount: 0, driftNanos: 2_000_000,
                driftSampleAgeNanos: 20_000_000, screenTiming: previousScreen)).encodedLine())
        try #require(waitUntil(timeout: 3) { host.diagnosticsSnapshot().listeners.first?.screenTiming == previousScreen })
        host.setVideoEnabled(true)
        try #require(waitUntil(timeout: 3) { host.diagnosticsSnapshot().videoEnabled })
        #expect(result().outcome == .warning,
            "Enabling a new share invalidates cached screen proof without waiting for the next peer report")
        #expect(host.diagnosticsSnapshot().listeners.first?.driftMilliseconds == 2,
            "Video rearming must preserve the independent audio report")
    }

    @Test("A late listener's rising network RTT cannot repeatedly reset every output", arguments: [UInt64(10_000_000), 150_000_000])
    func lateListenerNetworkDelayCannotMasqueradeAsHardwareLatency(outputLatency: UInt64) throws {
        let ready = DispatchSemaphore(value: 0)
        let ports = PortState()
        let host = HostServer(roomName: "Outlier join", advertise: false,
            listenerReadyHandler: { ports.set($0); ready.signal() },
            localParticipantID: "stable-output")
        try host.start()
        defer { host.stop() }
        try #require(ready.wait(timeout: .now() + 3) == .success)
        let port = try #require(ports.port)
        let stable = HeadlessLoopbackPeer(index: 900, participantID: "stable-output")
        let outlier = HeadlessLoopbackPeer(index: 901, participantID: "outlier")
        defer { outlier.stop(); stable.stop() }
        try stable.start(hostPort: port)
        try #require(stable.waitUntilJoined(timeout: 3))
        let samples = [Int16](repeating: 512, count: 480)
        host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos())
        try #require(waitUntil(timeout: 2) { stable.packetCount > 0 })
        try outlier.start(hostPort: port)
        try #require(outlier.waitUntilJoined(timeout: 3))
        let initialResyncs = stable.resyncCommandCount
        let initialBuffer = host.diagnosticsSnapshot().groupBufferMilliseconds
        let initialTimingChanges = host.diagnosticsSnapshot().roomTimingChangeCount
        // Same physical output, progressively delayed control traffic. Use the
        // exact report calculation used by Receiver, not a fabricated zero floor.
        for rtt: UInt64 in [300_000_000, 450_000_000, 600_000_000, 800_000_000] {
            outlier.reportTiming(recommendation: 600_000_000,
                hardwareFloor: RoomTiming.outputLatencyFloor(outputLatency, roundTripNanos: rtt))
            outlier.sendPing()
            try #require(outlier.waitForPong(timeout: 2))
        }
        // Barrier on the healthy peer's independent TCP stream: its own pong
        // must follow all earlier cutovers enqueued by the host.
        stable.sendPing()
        try #require(stable.waitForPong(timeout: 2))
        let hardwareFloor = RoomTiming.outputLatencyFloor(outputLatency)
        let needsHardwareCutover = Double(hardwareFloor) / 1_000_000 > initialBuffer
        #expect(stable.resyncCommandCount == initialResyncs + (needsHardwareCutover ? 1 : 0),
            "A late outlier's network delay was treated as room-wide hardware latency")
        let expectedBuffer = needsHardwareCutover ? Double(RoomTiming.liveIncreasePlayoutDelay(required: hardwareFloor)) / 1_000_000 : initialBuffer
        #expect(host.diagnosticsSnapshot().groupBufferMilliseconds == expectedBuffer)
        let diagnostics = host.diagnosticsSnapshot()
        #expect(diagnostics.roomTimingChangeCount == initialTimingChanges + (needsHardwareCutover ? 1 : 0))
        let outlierReport = try #require(diagnostics.listeners.first { $0.peerID == "outlier" })
        #expect(!outlierReport.isTimingEligible)
        #expect(outlierReport.recommendedBufferMilliseconds == 600)
        #expect(outlierReport.hardwareFloorMilliseconds == Double(hardwareFloor) / 1_000_000)
    }

    @Test("Settling hardware latency from one joiner requires at most one shared cutover")
    func lateHardwareCalibrationDoesNotCauseRepeatedCutovers() throws {
        let ready = DispatchSemaphore(value: 0)
        let ports = PortState()
        let host = HostServer(roomName: "Hardware settling", advertise: false,
            listenerReadyHandler: { ports.set($0); ready.signal() }, localParticipantID: "stable-output")
        try host.start()
        defer { host.stop() }
        try #require(ready.wait(timeout: .now() + 3) == .success)
        let port = try #require(ports.port)
        let stable = HeadlessLoopbackPeer(index: 902, participantID: "stable-output")
        let outlier = HeadlessLoopbackPeer(index: 903, participantID: "outlier")
        defer { outlier.stop(); stable.stop() }
        try stable.start(hostPort: port)
        try #require(stable.waitUntilJoined(timeout: 3))
        host.acceptAudio(samples: [Int16](repeating: 512, count: 480), captureTimeNanos: MonotonicClock.nowNanos())
        try #require(waitUntil(timeout: 2) { stable.packetCount > 0 })
        try outlier.start(hostPort: port)
        try #require(outlier.waitUntilJoined(timeout: 3))
        for floor: UInt64 in [300_000_000, 305_000_000, 310_000_000, 315_000_000] {
            outlier.reportTiming(recommendation: floor, hardwareFloor: floor)
            outlier.sendPing()
            try #require(outlier.waitForPong(timeout: 2))
        }
        stable.sendPing()
        try #require(stable.waitForPong(timeout: 2))
        #expect(stable.resyncCommandCount == 1)
        #expect(host.diagnosticsSnapshot().groupBufferMilliseconds == 350)
        #expect(host.diagnosticsSnapshot().roomTimingChangeCount == 1)

        // A pause must not discard the settling allowance and cause another
        // all-room restart for the next small hardware report after resume.
        host.setNowPlaying(NowPlayingMedia(title: "Calibration", isPlaying: false))
        outlier.reportTiming(recommendation: 315_000_000, hardwareFloor: 315_000_000)
        outlier.sendPing()
        try #require(outlier.waitForPong(timeout: 2))
        host.setNowPlaying(NowPlayingMedia(title: "Calibration", isPlaying: true))
        stable.sendPing()
        try #require(stable.waitForPong(timeout: 2))
        let afterResume = stable.resyncCommandCount
        outlier.reportTiming(recommendation: 320_000_000, hardwareFloor: 320_000_000)
        outlier.sendPing()
        try #require(outlier.waitForPong(timeout: 2))
        stable.sendPing()
        try #require(stable.waitForPong(timeout: 2))
        #expect(stable.resyncCommandCount == afterResume,
            "Pause discarded the calibration allowance and resumed audio restarted again")
    }

    @Test("Live music, voice and chat survive repeated listener restarts", .timeLimit(.minutes(1)))
    func mixedTrafficSurvivesListenerRestarts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-mixed-scenario-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let room = RoomConfiguration(name: "Isolated mixed traffic scenario")
        var devices = [ScenarioMeshDevice]()
        var listeners = [HeadlessLoopbackPeer]()
        defer {
            listeners.forEach { $0.stop() }
            devices.forEach { try? $0.stop() }
        }
        let a = try ScenarioMeshDevice(id: "a", room: room, directory: root.appendingPathComponent("a"))
        devices.append(a)

        let ready = DispatchSemaphore(value: 0)
        let portState = PortState()
        let host = HostServer(
            roomName: room.name, advertise: false,
            listenerReadyHandler: { port in portState.set(port); ready.signal() }
        )
        try host.start()
        defer { host.stop() }
        try #require(ready.wait(timeout: .now() + 3) == .success)
        let port = try #require(portState.port)

        // Capture keeps running while the test waits for joins, chat, calls and
        // disk flushes. Four 5 ms packets per callback reproduce capture bursts.
        let captureQueue = DispatchQueue(label: "in.werai.tests.scenario-capture")
        let capture = DispatchSource.makeTimerSource(queue: captureQueue)
        let samples = [Int16](repeating: 1_024, count: 4 * 240 * 2)
        capture.schedule(deadline: .now(), repeating: .milliseconds(20))
        capture.setEventHandler {
            host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos() - 20_000_000)
        }
        capture.resume()
        defer { capture.cancel(); captureQueue.sync {} }
        Thread.sleep(forTimeInterval: 0.15) // Broadcast exists before any listener.

        let b = try ScenarioMeshDevice(id: "b", room: room, directory: root.appendingPathComponent("b"))
        devices.append(b)
        try a.connect(to: b)
        let stable = HeadlessLoopbackPeer(index: 800, participantID: "b", expectedSample: 1_024)
        listeners.append(stable)
        try stable.start(hostPort: port)
        try #require(stable.waitUntilJoined(timeout: 3))
        try scenarioEventually("first late listener receives music") { stable.packetCount >= 20 }
        let timelineStart = MonotonicClock.nowNanos()
        var expectedChat = Set<String>()

        for cycle in 0..<3 {
            let c = try ScenarioMeshDevice(id: "c", room: room, directory: root.appendingPathComponent("c"))
            devices.append(c)
            try a.connect(to: c)
            try b.connect(to: c)
            let rejoined = HeadlessLoopbackPeer(index: 810 + cycle, participantID: "c", expectedSample: 1_024)
            listeners.append(rejoined)
            try rejoined.start(hostPort: port)
            try #require(rejoined.waitUntilJoined(timeout: 3))
            try scenarioEventually("cycle \(cycle): three-member mesh") {
                [a, b, c].allSatisfy { $0.observation.read { $0.participants == ["a", "b", "c"] } }
            }
            try scenarioEventually("cycle \(cycle): rejoin receives existing broadcast") {
                rejoined.packetCount >= 20
            }

            // Simulate a listener reporting wireless-output headroom while the
            // established listener must keep its original room timeline.
            let bufferBefore = host.diagnosticsSnapshot().groupBufferMilliseconds
            rejoined.recommendPlayoutDelay(600_000_000)
            rejoined.sendPing()
            try #require(rejoined.waitForPong(timeout: 2))
            #expect(host.diagnosticsSnapshot().groupBufferMilliseconds == bufferBefore)

            let stableBaseline = stable.packetCount
            let rejoinBaseline = rejoined.packetCount
            let voiceSession = "scenario-voice-\(cycle)"
            let voiceData = Data(repeating: 0x12, count: 960 * 2)
            for index in 0..<20 {
                let source = index.isMultiple(of: 2) ? a : c
                let text = "cycle-\(cycle)-chat-\(index)"
                expectedChat.insert(text)
                source.control.publishChat(text)
                let kind: WalkieTalkieKind = index == 0 ? .began : (index == 19 ? .ended : .audio)
                a.control.publishWalkieTalkie(WalkieTalkieMessage(
                    kind: kind, senderID: "a", senderName: "a", targetID: "b",
                    sessionID: voiceSession, sequence: UInt64(index), sampleRate: 48_000,
                    pcm16Mono: kind == .audio ? voiceData : nil
                ))
                Thread.sleep(forTimeInterval: 0.020)
            }
            try scenarioEventually("cycle \(cycle): mixed chat converges") {
                [a, b, c].allSatisfy { device in
                    device.observation.read { Set($0.replica.chatEvents.compactMap(\.text)) == expectedChat }
                }
            }
            try scenarioEventually("cycle \(cycle): voice end received") {
                b.observation.read { $0.voice.contains { $0.sessionID == voiceSession && $0.kind == .ended } }
            }
            let heard = b.observation.read { $0.voice.filter { $0.sessionID == voiceSession && $0.kind == .audio } }
            #expect(heard.count == 18)
            #expect(heard.map(\.sequence) == Array(1...18).map(UInt64.init))
            #expect(heard.allSatisfy { $0.pcm16Mono == voiceData && $0.resolvedSampleRate == 48_000 })
            #expect(c.observation.read { $0.voice.isEmpty }, "Targeted voice leaked to another device")
            try scenarioEventually("cycle \(cycle): media continues after talking") {
                stable.packetCount > stableBaseline + 60 && rejoined.packetCount > rejoinBaseline + 60
            }
            Thread.sleep(forTimeInterval: 1.5) // Exercise the historical 3–5 second stall window.
            #expect(rejoined.corruptedPacketCount == 0)

            rejoined.stop()
            try c.stop()
            #expect(try c.persistedChat() == expectedChat)
            let beforeLeave = stable.packetCount
            try scenarioEventually("cycle \(cycle): survivor keeps receiving after peer leaves") {
                stable.packetCount > beforeLeave + 30
            }
        }

        let snapshot = stable.snapshot()
        let arrivals = snapshot.arrivals.values.filter { $0.arrivedNanos >= timelineStart }
            .sorted { $0.arrivedNanos < $1.arrivedNanos }
        try #require(arrivals.count > 800, "The scenario must run beyond the historic stall window")
        let gaps = zip(arrivals, arrivals.dropFirst()).map { $1.arrivedNanos - $0.arrivedNanos }
        let ages = arrivals.map { $0.arrivedNanos - $0.captureNanos }.sorted()
        let maximumGap = gaps.max() ?? 0
        let ageP95 = ages[(ages.count - 1) * 95 / 100]
        #expect(maximumGap < 400_000_000, "Healthy listener stopped receiving during peer churn")
        #expect(ageP95 < 200_000_000, "Media backlog grew under simultaneous control traffic")
        #expect(stable.corruptedPacketCount == 0)
        #expect(devices.allSatisfy { $0.observation.read { $0.downgrades == 0 } })
        print("Mixed traffic: \(arrivals.count) packets, max gap \(maximumGap / 1_000_000) ms, p95 age \(ageP95 / 1_000_000) ms, 3 rejoins, \(expectedChat.count) durable messages")
    }

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

    @Test("Observational timer-only controls isolate source wake scheduling before and after fan-out")
    func timerOnlyCaptureSchedulingDiagnostic() throws {
        func control(_ phase: String) throws {
            let probe = TimerOnlyCaptureProbe()
            let samples = try probe.measure()
            try #require(samples.count == 50)
            #expect(samples.allSatisfy { $0.returnedNanos >= $0.scheduledNanos })
            #expect(samples.allSatisfy { $0.clockStatus == 0 && $0.cpuNanos >= 0 })
            #expect(samples.allSatisfy { $0.waitFailures == 0 })
            let wake = AudioCompletionLatencies()
            samples.forEach { wake.record($0.returnedNanos - $0.scheduledNanos) }
            print("Timer-only source \(phase): wake [\(wake.summary)], elapsed=\(samples.last?.returnedNanos ?? 0)ns, threadCPU=\(samples.last?.cpuNanos ?? 0)ns")
            // Bounded numeric trace; these are relative monotonic deadlines and
            // cumulative current-thread CPU, not wall-clock dates or a pass gate.
            print("Timer-only source \(phase) samples [scheduledNs,returnedNs,cpuNs,waitCalls,lastMachStatus,clockStatus]: \(samples.map { "[\($0.scheduledNanos),\($0.returnedNanos),\($0.cpuNanos),\($0.waitCalls),\($0.lastWaitStatus),\($0.clockStatus)]" }.joined(separator: ","))")
        }
        try control("before")
        let loaded = try runRoom(peerCount: 8, linkBitsPerSecond: nil, policy: .unbounded,
            schedulerOversleep: 0, deferredPCM: false)
        #expect(loaded.minimumPacketsReceived >= 190)
        print("Timer-only comparison loaded capture age [\(loaded.captureCallbackAgeSummary)] (includes the normal 20ms captured chunk)")
        try control("after")
    }

    @Test("Observational A/B separates colocated receiver PCM work from capture scheduling")
    func receiverPCMPlacementCaptureAB() throws {
        let inline = try runRoom(peerCount: 8, linkBitsPerSecond: nil, policy: .unbounded,
            schedulerOversleep: 0, deferredPCM: false)
        let deferred = try runRoom(peerCount: 8, linkBitsPerSecond: nil, policy: .unbounded,
            schedulerOversleep: 0, deferredPCM: true)
        #expect(inline.minimumPacketsReceived >= 190 && deferred.minimumPacketsReceived >= 190)
        // This comparison does not change or replace the existing live gate.
        // Compare source ages, not a pass flag based on a cheaper receive path.
        print("Receiver PCM A/B capture ages: inline [\(inline.captureCallbackAgeSummary)]; deferred [\(deferred.captureCallbackAgeSummary)]")
        print("Receiver PCM A/B maximum callback-entry ages: inline \(inline.maximumReceiveEntryAgeNanos / 1_000_000)ms; deferred \(deferred.maximumReceiveEntryAgeNanos / 1_000_000)ms")
    }

    @Test("Deferred PCM validation rejects malformed, corrupt, duplicate and overflowing input")
    func deferredPCMValidationIsBoundedAndDoesNotAcceptInvalidAudio() {
        func packet(_ sequence: UInt32, sample: Int16 = 0) -> Data {
            AudioPacket(sequence: sequence, frameIndex: UInt64(sequence) * 240,
                captureTimeNanos: 1, samples: [Int16](repeating: sample, count: 480)).encoded()
        }
        var valid = DeferredPCMReceipts()
        #expect(valid.append(packet(0), arrivedAt: 2) != nil)
        #expect(valid.validate(expectedSample: 0).isValid)
        #expect(valid.validate(expectedSample: 1).invalidPCM == 1,
            "A valid header does not prove the expected PCM payload")
        var corrupted = DeferredPCMReceipts()
        _ = corrupted.append(packet(0, sample: 7), arrivedAt: 2)
        #expect(corrupted.validate(expectedSample: 0).invalidPCM == 1)
        #expect(!corrupted.validate(expectedSample: 0).isValid)
        var malformed = DeferredPCMReceipts()
        #expect(malformed.append(packet(0).dropLast(), arrivedAt: 2) == nil)
        #expect(malformed.validate(expectedSample: 0).malformed == 1)
        #expect(!malformed.validate(expectedSample: 0).isValid)
        var duplicate = valid
        _ = duplicate.append(packet(0), arrivedAt: 3)
        #expect(duplicate.validate(expectedSample: 0).duplicates == 1)
        #expect(!duplicate.validate(expectedSample: 0).isValid)
        var overflow = DeferredPCMReceipts()
        for sequence in UInt32(0)...200 { _ = overflow.append(packet(sequence), arrivedAt: 2) }
        #expect(overflow.count == 200)
        #expect(overflow.validate(expectedSample: 0).overflow == 1)
        #expect(!overflow.validate(expectedSample: 0).isValid)
    }

    @Test("Bounded fan-out prevents live room latency growth", arguments: [0.0, 0.035])
    func boundedFanoutPreventsRoomScaleDelay(schedulerOversleep: TimeInterval) throws {
        let boundedPolicy = HostServer.AudioBackpressurePolicy.boundedLatest(maxInFlight: 8)
        // This baseline isolates actual Network.framework delivery with no imposed
        // link bottleneck. An intentional catch-up burst can exceed eight in-flight
        // packets even on localhost; the separate bounded baseline records that tradeoff.
        let directEight = try runRoom(peerCount: 8, linkBitsPerSecond: nil, policy: .unbounded, schedulerOversleep: schedulerOversleep)
        let directBoundedEight = try runRoom(peerCount: 8, linkBitsPerSecond: nil, policy: boundedPolicy, schedulerOversleep: schedulerOversleep)
        let shapedOne = try runRoom(peerCount: 1, linkBitsPerSecond: 4_000_000, policy: boundedPolicy, schedulerOversleep: schedulerOversleep)
        let unboundedEight = try runRoom(peerCount: 8, linkBitsPerSecond: 4_000_000, policy: .unbounded, schedulerOversleep: schedulerOversleep)
        let boundedEight = try runRoom(peerCount: 8, linkBitsPerSecond: 4_000_000, policy: boundedPolicy, schedulerOversleep: schedulerOversleep)

        print("Injected capture wake oversleep: \(schedulerOversleep * 1_000) ms")
        print("Direct 8-peer final packet age: \(directEight.maximumFinalAgeNanos / 1_000_000) ms")
        print("Direct bounded 8-peer final packet age: \(directBoundedEight.maximumFinalAgeNanos / 1_000_000) ms")
        print("Direct bounded 8-peer audible lateness: \(directBoundedEight.maximumAudibleLatenessNanos / 1_000_000) ms")
        print("Direct bounded packets delivered per peer: \(directBoundedEight.minimumPacketsReceived) / 200; maximum dropped: \(200 - directBoundedEight.minimumPacketsReceived)")
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

        // Preserve the production bounded-8 guarantee on normal uncongested
        // capture. Under injected late wakes, catch-up bursts may exceed eight
        // packets before sends complete; keep latency bounded and report loss.
        #expect(directBoundedEight.maximumFinalAgeNanos < 100_000_000)
        #expect(directBoundedEight.maximumAudibleLatenessNanos < 50_000_000)
        if schedulerOversleep == 0 {
            #expect(directBoundedEight.minimumPacketsReceived >= 190)
        }

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
        #expect(boundedEight.maximumPacketAgeNanos < SynchronizedPlayer.targetLatencyNanos)
        #expect(boundedEight.maximumAudibleLatenessNanos < 100_000_000)
        #expect(boundedEight.minimumPacketsReceived >= 50)
        #expect(boundedEight.minimumPacketsReceived < unboundedEight.minimumPacketsReceived)
    }

    @Test("Drain completion follows submitted audio, not an expired terminal capture")
    func expiredTerminalCaptureDoesNotPreventSubmittedAudioDraining() {
        let ledger = AudioSubmissionLedger()
        let port: UInt16 = 12_345
        // The sender expiry regression separately proves capture 8...11 can
        // expire unsent. Every packet that DID enter the transport must arrive.
        for sequence: UInt32 in 0..<8 {
            ledger.submitted(port: port, sequence: sequence)
            ledger.completed(port: port, sequence: sequence, error: nil)
        }
        let submitted = ledger.snapshot
        #expect(submitted.isComplete)
        #expect(submitted.matchesReceived([port: Set(0..<8)]))
        #expect(!submitted.matchesReceived([port: Set(0..<7)]), "Missing submitted audio must fail")
        #expect(!submitted.matchesReceived([:]), "An empty/disconnected receiver cannot pass")
        #expect(!AudioSubmissionLedger().snapshot.isComplete, "No audio is not a successful drain")
        ledger.submitted(port: port, sequence: 12)
        #expect(!ledger.snapshot.isComplete, "Outstanding transport work must not look drained")
        ledger.completed(port: port, sequence: 12, error: .posix(.EIO))
        #expect(!ledger.snapshot.isComplete, "Failed sends cannot be hidden as intentional expiry")
    }

    @Test("Audio transport instrumentation validates headers without decoding PCM")
    func audioProbeHeaderValidationAndCost() throws {
        let encoded = AudioPacket(sequence: 73, frameIndex: 0, captureTimeNanos: 1,
            samples: [Int16](repeating: 42, count: 480)).encoded()
        #expect(AudioProbeHeader.sequence(in: encoded) == 73)
        #expect(AudioProbeHeader.read(in: encoded)?.captureTimeNanos == 1)
        var prefixed = Data([0, 0, 0])
        prefixed.append(encoded)
        #expect(AudioProbeHeader.sequence(in: prefixed.dropFirst(3)) == 73)
        #expect(AudioProbeHeader.sequence(in: encoded.dropLast()) == nil)
        for offset in [0, 4, 6, 28, 32] {
            var invalid = encoded
            invalid[offset] = 0
            #expect(AudioProbeHeader.sequence(in: invalid) == nil)
        }
        let iterations = 1_600
        var fullChecksum: UInt32 = 0
        let fullStart = MonotonicClock.nowNanos()
        for _ in 0..<iterations { fullChecksum &+= try #require(AudioPacket(data: encoded)).sequence }
        let fullDuration = MonotonicClock.nowNanos() - fullStart
        var headerChecksum: UInt32 = 0
        let headerStart = MonotonicClock.nowNanos()
        for _ in 0..<iterations { headerChecksum &+= try #require(AudioProbeHeader.sequence(in: encoded)) }
        let headerDuration = MonotonicClock.nowNanos() - headerStart
        #expect(headerChecksum == fullChecksum)
        print("Audio probe for1600 sends: full PCM decode \(fullDuration / 1_000_000)ms, header-only \(headerDuration / 1_000_000)ms")
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

        let recommendation = min(
            RoomTiming.maximumPlayoutDelayNanos,
            RoomTiming.defaultPlayoutDelayNanos + 40_000_000
        )
        let establishedDelay = RoomTiming.liveIncreasePlayoutDelay(required: recommendation)
        existingPeer.recommendPlayoutDelay(recommendation)
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
        let captureClock = LoopbackCaptureClock()
        let host = HostServer(
            roomName: "Late-listener timing test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                ready.signal()
            },
            audioSendNowNanos: { captureClock.now },
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
        host.acceptAudio(samples: samples, captureTimeNanos: captureClock.now)
        #expect(waitUntil(timeout: 2) { broadcasterOutput.packetCount == 1 })

        let lateListener = HeadlessLoopbackPeer(index: 110)
        try lateListener.start(hostPort: port)
        defer { lateListener.stop() }
        guard lateListener.waitUntilJoined(timeout: 3) else {
            throw LoopbackTestError.peerDidNotJoin
        }

        host.acceptAudio(
            samples: samples,
            captureTimeNanos: captureClock.advance(by: 20_000_000)
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
            captureTimeNanos: captureClock.advance(by: 20_000_000)
        )
        #expect(waitUntil(timeout: 2) {
            lateListener.packetCount > packetsBeforeRecommendation
        })
    }

    private func runRoom(
        peerCount: Int,
        linkBitsPerSecond: UInt64?,
        policy: HostServer.AudioBackpressurePolicy,
        schedulerOversleep: TimeInterval,
        deferredPCM: Bool = false
    ) throws -> RoomMeasurements {
        // This headless fixture has no active audio device. Request precise
        // scheduling only while measuring live capture/transport, as a real
        // audio session would; do not let background throttling become network
        // delay. End the activity on success and on every error path.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Measure live room audio delivery at the capture rate"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let hostReady = DispatchSemaphore(value: 0)
        let state = PortState()
        let shaper = linkBitsPerSecond.map(FluidLinkShaper.init(bitsPerSecond:))
        let completionLatencies = AudioCompletionLatencies()
        let captureCallbackAges = AudioCompletionLatencies()
        let captureToAdmissionAges = AudioCompletionLatencies()
        defer {
            print("Fixture scheduler: peers=\(peerCount), link=\(linkBitsPerSecond.map(String.init) ?? "unshaped"), policy=\(policy), deferredPCM=\(deferredPCM), injectedWake=\(schedulerOversleep * 1_000)ms; capture callback age [\(captureCallbackAges.summary)]; capture-to-outbound-admission age [\(captureToAdmissionAges.summary)]; shaper dispatch lateness [\(shaper?.dispatchLatenessSummary ?? "not shaped")]")
        }
        let submissions = AudioSubmissionLedger()
        let host = HostServer(
            roomName: "Loopback test \(UUID().uuidString)",
            advertise: false,
            listenerReadyHandler: { port in
                state.set(port)
                hostReady.signal()
            },
            outboundSend: { connection, data, isComplete, completion in
                let header = AudioProbeHeader.read(in: data)
                let sequence = header?.sequence
                if let header {
                    let admittedAt = MonotonicClock.nowNanos()
                    captureToAdmissionAges.record(admittedAt > header.captureTimeNanos
                        ? admittedAt - header.captureTimeNanos : 0)
                }
                let destinationPort: UInt16?
                if case .hostPort(_, let port) = connection.endpoint {
                    destinationPort = port.rawValue
                } else { destinationPort = nil }
                if let sequence {
                    submissions.submitted(port: destinationPort, sequence: sequence)
                }
                let started = MonotonicClock.nowNanos()
                let measuredCompletion: (NWError?) -> Void = { error in
                    if let sequence {
                        completionLatencies.record(MonotonicClock.nowNanos() - started)
                        submissions.completed(port: destinationPort, sequence: sequence, error: error)
                    }
                    completion(error)
                }
                if let shaper {
                    shaper.send(
                        data,
                        over: connection,
                        isComplete: isComplete,
                        completion: measuredCompletion
                    )
                } else {
                    connection.send(content: data, contentContext: .defaultMessage,
                        isComplete: isComplete, completion: .contentProcessed(measuredCompletion))
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
                let peer = HeadlessLoopbackPeer(index: index, deferredPCM: deferredPCM)
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

            // Keep the offered source at 48 kHz even if a runner wakes late.
            // Capture timestamps follow the nominal 20 ms sample timeline;
            // missed callback deadlines catch up without another relative sleep.
            let callbackDurationNanos: UInt64 = 20_000_000
            let captureWakeDelays = AudioCompletionLatencies()
            // Match both production capture backends rather than inheriting the
            // Swift Testing worker's priority. This does not suppress OS stalls.
            let sourceQueue = DispatchQueue(label: "in.werai.tests.fanout-capture", qos: .userInteractive)
            let sourceTimeline = CaptureTimeline()
            let sourceFinished = DispatchSemaphore(value: 0)
            let capturePeers = peers
            sourceQueue.async {
                let captureAnchorNanos = sourceTimeline.start()
                defer { sourceFinished.signal() }
                for callbackIndex in 0..<(expectedPacketCount / packetsPerCallback) {
                    let callbackDeadlineNanos = captureAnchorNanos + UInt64(callbackIndex) * callbackDurationNanos
                    let now = MonotonicClock.nowNanos()
                    if now < callbackDeadlineNanos {
                        // Preserve monotonic source deadlines without Foundation
                        // relative-sleep coalescing; keep the injected late wake.
                        let wakeDeadline = callbackDeadlineNanos + UInt64(schedulerOversleep * 1_000_000_000)
                        while MonotonicClock.nowNanos() < wakeDeadline {
                            _ = mach_wait_until(MonotonicClock.nanosToTicks(wakeDeadline))
                        }
                    }
                    let wokeAt = MonotonicClock.nowNanos()
                    captureWakeDelays.record(wokeAt > callbackDeadlineNanos ? wokeAt - callbackDeadlineNanos : 0)
                    let captureTimeNanos = callbackDeadlineNanos - callbackDurationNanos
                    captureCallbackAges.record(MonotonicClock.nowNanos() - captureTimeNanos)
                    host.acceptAudio(samples: samples, captureTimeNanos: captureTimeNanos)
                    if callbackIndex.isMultiple(of: 5) {
                        capturePeers.forEach { $0.sendPing() }
                    }
                }
            }
            sourceFinished.wait()
            let captureAnchorNanos = sourceTimeline.anchorNanos
            print("Capture wake delay: peers=\(peerCount), policy=\(policy), injected=\(schedulerOversleep * 1_000)ms, \(captureWakeDelays.summary)")

            let expectedIDs = Set((0..<peerCount).map { "loopback-peer-\($0)" })
            let peerPorts = try peers.map { try #require($0.audioPort) }
            let expectedPorts = Set(peerPorts)
            try #require(expectedPorts.count == peerCount, "Every receiver must have a distinct live UDP listener")
            let drainDeadline = Date().addingTimeInterval(5)
            // The queue barrier follows every capture callback. A bounded sender
            // may expire the terminal capture without ever submitting it; only
            // the outbound ledger can say which datagrams the receiver owes us.
            let senderDrained = waitUntil(timeout: max(0, drainDeadline.timeIntervalSinceNow)) {
                let senders = host.audioSenderSnapshot()
                return senders.count == peerCount
                    && Set(senders.map(\.participantID)) == expectedIDs
                    && Set(senders.map(\.udpPort)) == expectedPorts
                    && senders.allSatisfy { $0.inFlight == 0 && $0.pending == 0 }
                    && submissions.snapshot.isComplete
            }
            print("Audio send completion latency: peers=\(peerCount), link=\(linkBitsPerSecond.map(String.init) ?? "unshaped"), policy=\(policy), \(completionLatencies.summary)")
            guard senderDrained else {
                print("Audio sender drain timeout: \(host.audioSenderSnapshot()); ledger=\(submissions.snapshot)")
                throw LoopbackTestError.audioDidNotDrain(peers.map(\.packetCount))
            }
            let submitted = submissions.snapshot
            let drainedSenders = host.audioSenderSnapshot()
            print("Audio sender drained: \(drainedSenders)")
            for sender in drainedSenders {
                #expect(sender.enqueued == UInt64(expectedPacketCount))
                #expect(sender.sent + sender.expiredWait + sender.expiredAge + sender.admissionRejected
                    + sender.replaced + sender.discardedBoundary == sender.enqueued,
                    "Every captured packet must be accounted for at sender quiescence")
                #expect(sender.sent == UInt64(submitted.submitted[sender.udpPort]?.count ?? 0))
                #expect(sender.discardedBoundary == 0,
                    "This steady capture scenario must not hide an accidental timeline reset")
            }
            let receivedEnough = waitUntil(timeout: max(0, drainDeadline.timeIntervalSinceNow)) {
                let received = Dictionary(uniqueKeysWithValues: zip(peerPorts, peers).map {
                    ($0.0, Set($0.1.snapshot().arrivals.keys))
                })
                return submitted.matchesReceived(received)
            }
            guard receivedEnough else {
                print("Audio receiver drain timeout: submitted=\(submitted); received=\(zip(peerPorts, peers).map { ($0.0, $0.1.snapshot().arrivals.keys.sorted()) })")
                throw LoopbackTestError.audioDidNotDrain(peers.map(\.packetCount))
            }

            if deferredPCM {
                for peer in peers {
                    // Copy only bounded raw receipts across the queue barrier;
                    // all PCM decoding and validation runs on this test worker,
                    // after capture and delivery, never on a network queue.
                    let receipts = peer.deferredPCMReceipts()
                    let validation = receipts.validate(expectedSample: 0)
                    print("Deferred PCM validation: \(validation)")
                    try #require(validation.isValid, "Invalid deferred audio must never be accepted")
                    try #require(validation.decoded == peer.packetCount)
                }
            }
            let snapshots = peers.map { $0.snapshot() }
            let finalArrivals = try snapshots.map { snapshot in
                guard let lastSequence = snapshot.lastSequence,
                      let arrival = snapshot.arrivals[lastSequence] else {
                    throw LoopbackTestError.noAudioReceived
                }
                switch policy {
                case .unbounded:
                    #expect(lastSequence == UInt32(expectedPacketCount - 1))
                case .boundedLatest:
                    // Permit at most the 16-packet/80ms terminal tail to expire.
                    // A stopped or intermittently silent sender must still fail.
                    #expect(lastSequence >= UInt32(expectedPacketCount - 17))
                    let sourceTimes = snapshot.arrivals.values.map(\.captureNanos).sorted()
                    let sourceStart = captureAnchorNanos - callbackDurationNanos
                    let sourceEnd = sourceStart + UInt64(expectedPacketCount) * 5_000_000
                    let boundaries = [sourceStart] + sourceTimes + [sourceEnd]
                    let maximumGap = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }.max() ?? 0
                    #expect(maximumGap <= 200_000_000, "Bounded sender stopped making source-timeline progress")
                }
                return arrival
            }
            let finalAges = finalArrivals.map { $0.arrivedNanos - $0.captureNanos }
            let maximumPacketAge = snapshots.flatMap { $0.arrivals.values }.map {
                $0.arrivedNanos - $0.captureNanos
            }.max() ?? 0
            let maximumReceiveEntryAge = snapshots.flatMap { $0.arrivals.values }.compactMap { arrival in
                arrival.receiveEntryNanos.map { $0 - arrival.captureNanos }
            }.max() ?? 0
            print("Audio actual final sequences: \(snapshots.compactMap(\.lastSequence)); maximum packet age: \(maximumPacketAge / 1_000_000)ms")
            let offsets = snapshots.compactMap(\.clockOffsetNanos)
            let commonSequences = snapshots.dropFirst().reduce(Set(snapshots[0].arrivals.keys)) {
                $0.intersection($1.arrivals.keys)
            }
            try #require(!commonSequences.isEmpty, "No common packet exists for cross-peer skew measurement")
            let maximumArrivalSkew = commonSequences.compactMap { sequence -> UInt64? in
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
                maximumPacketAgeNanos: maximumPacketAge,
                maximumPacketArrivalSkewNanos: maximumArrivalSkew,
                maximumAudibleLatenessNanos: snapshots.map(\.audibleLatenessNanos).max() ?? 0,
                clockOffsetSpreadNanos: offsetSpread(offsets),
                minimumPacketsReceived: snapshots.map(\.packetCount).min() ?? 0,
                resyncCommandsReceived: resyncCommandsReceived,
                captureCallbackAgeSummary: captureCallbackAges.summary,
                maximumReceiveEntryAgeNanos: maximumReceiveEntryAge
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
    private let expectedSample: Int16?
    private let deferredPCM: Bool
    private var deferredReceipts = DeferredPCMReceipts()
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
    private var corruptedPackets = 0

    init(index: Int, participantID: String? = nil, expectedSample: Int16? = nil, deferredPCM: Bool = false) {
        self.index = index
        self.participantID = participantID ?? "loopback-peer-\(index)"
        self.expectedSample = expectedSample
        self.deferredPCM = deferredPCM
        self.queue = DispatchQueue(label: "in.werai.tests.loopback-peer.\(index)", qos: .userInteractive)
    }

    var packetCount: Int { queue.sync { arrivals.count } }
    var audioPort: UInt16? { queue.sync { udpListener?.port?.rawValue } }
    var corruptedPacketCount: Int { queue.sync { corruptedPackets } }
    var lastSequence: UInt32? { queue.sync { arrivals.keys.max() } }
    var resyncCommandCount: Int { queue.sync { receivedResyncCommands } }
    var resyncCutovers: [UInt64] { queue.sync { receivedResyncCutovers } }
    var playbackStates: [Bool] { queue.sync { receivedPlaybackStates } }
    var roomPlaybackStates: [Bool] { queue.sync { receivedRoomPlaybackStates } }
    var playoutDelays: [UInt64] { queue.sync { receivedPlayoutDelays } }
    var levels: [(volume: Double, muted: Bool)] { queue.sync { receivedLevels } }
    func deferredPCMReceipts() -> DeferredPCMReceipts { queue.sync { deferredReceipts } }

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
            guard let self else { return }
            switch state {
            case .waiting(let error), .failed(let error):
                print("Loopback peer \(self.index) control \(state): host=127.0.0.1:\(hostPort), UDP=\(udpPort), video=\(videoPort), error=\(error)")
                return
            case .ready: break
            default: return
            }
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
        let didJoin = joined.wait(timeout: .now() + timeout) == .success
        if !didJoin {
            queue.sync {
                print("Loopback peer \(index) join timed out: control=\(String(describing: control?.state)), endpoint=\(String(describing: control?.endpoint)), UDP=\(String(describing: udpListener?.port)), video=\(String(describing: videoListener?.port))")
            }
        }
        return didJoin
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

    func reportTiming(recommendation: UInt64, hardwareFloor: UInt64) {
        queue.async { [weak self] in
            self?.send(ControlMessage(type: "sync_report", playoutDelayNanos: recommendation,
                outputLatencyPlayoutFloorNanos: hardwareFloor))
        }
    }

    func sendRawControl(_ data: Data) {
        queue.async {
            self.control?.send(content: data, contentContext: .defaultMessage,
                isComplete: false, completion: .contentProcessed { _ in })
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
                let enteredAt = MonotonicClock.nowNanos()
                if let self, let data {
                    if self.deferredPCM {
                        if let receipt = self.deferredReceipts.append(data, arrivedAt: enteredAt) {
                            self.arrivals[receipt.sequence] = receipt.arrival
                        }
                    } else if let packet = AudioPacket(data: data) {
                        if let expected = self.expectedSample,
                           packet.samples.isEmpty || packet.samples.contains(where: { $0 != expected }) {
                            self.corruptedPackets += 1
                        }
                        self.arrivals[packet.sequence] = PacketArrival(
                            captureNanos: packet.captureTimeNanos,
                            arrivedNanos: MonotonicClock.nowNanos(), receiveEntryNanos: enteredAt
                        )
                    }
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
        control?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let self, let error {
                print("Loopback peer \(self.index) \(message.type) send failed: \(error), endpoint=\(String(describing: self.control?.endpoint))")
            }
        })
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

private final class AudioSubmissionLedger: @unchecked Sendable {
    struct Snapshot {
        var submitted: [UInt16: Set<UInt32>] = [:]
        var successful: [UInt16: Set<UInt32>] = [:]
        var failures: [String] = []

        var isComplete: Bool {
            !submitted.isEmpty && failures.isEmpty && submitted == successful
        }
        func matchesReceived(_ received: [UInt16: Set<UInt32>]) -> Bool {
            isComplete && successful == received
        }
    }
    private let lock = NSLock()
    private var state = Snapshot()
    var snapshot: Snapshot { lock.withLock { state } }

    func submitted(port: UInt16?, sequence: UInt32) {
        lock.withLock {
            guard let port else {
                state.failures.append("Audio submitted without a UDP destination port")
                return
            }
            if !state.submitted[port, default: []].insert(sequence).inserted {
                state.failures.append("Duplicate audio submission on \(port): \(sequence)")
            }
        }
    }
    func completed(port: UInt16?, sequence: UInt32, error: NWError?) {
        lock.withLock {
            guard let port else { return }
            if let error {
                state.failures.append("Audio send failed on \(port), sequence \(sequence): \(error)")
            } else {
                state.successful[port, default: []].insert(sequence)
            }
        }
    }
}

private final class LoopbackCaptureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = MonotonicClock.nowNanos()
    var now: UInt64 { lock.withLock { value } }
    func advance(by nanos: UInt64) -> UInt64 {
        lock.withLock { value += nanos; return value }
    }
}

/// Matches runRoom's nominal source executor and wait loop, with no host,
/// connections, PCM processing or ping callbacks during either control.
private final class TimerOnlyCaptureProbe: @unchecked Sendable {
    struct Sample {
        let scheduledNanos: UInt64
        let returnedNanos: UInt64
        let cpuNanos: Int64
        let waitCalls: Int
        let lastWaitStatus: kern_return_t
        let waitFailures: Int
        let clockStatus: Int32
    }
    private let lock = NSLock()
    private var samples: [Sample] = []

    func measure() throws -> [Sample] {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Measure timer-only source scheduling")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let finished = DispatchSemaphore(value: 0)
        let sourceQueue = DispatchQueue(label: "in.werai.tests.timer-only-capture", qos: .userInteractive)
        sourceQueue.async {
            defer { finished.signal() }
            var cpuAnchor = timespec()
            let initialClockStatus = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpuAnchor)
            let anchor = MonotonicClock.nowNanos()
            for index in 0..<50 {
                let deadline = anchor + UInt64(index) * 20_000_000
                var calls = 0
                var lastStatus: kern_return_t = KERN_SUCCESS
                var failures = 0
                while MonotonicClock.nowNanos() < deadline {
                    lastStatus = mach_wait_until(MonotonicClock.nanosToTicks(deadline))
                    calls += 1
                    if lastStatus != KERN_SUCCESS { failures += 1 }
                }
                let returned = MonotonicClock.nowNanos()
                var cpuNow = timespec()
                let clockStatus = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpuNow)
                let cpuElapsed = Int64(cpuNow.tv_sec - cpuAnchor.tv_sec) * 1_000_000_000
                    + Int64(cpuNow.tv_nsec - cpuAnchor.tv_nsec)
                self.lock.withLock {
                    self.samples.append(Sample(scheduledNanos: deadline - anchor,
                        returnedNanos: returned - anchor, cpuNanos: cpuElapsed,
                        waitCalls: calls, lastWaitStatus: lastStatus, waitFailures: failures,
                        clockStatus: initialClockStatus == 0 ? clockStatus : initialClockStatus))
                }
            }
        }
        try #require(finished.wait(timeout: .now() + 5) == .success,
            "Timer-only control failed to finish its one-second source timeline")
        return lock.withLock { samples }
    }
}

private final class CaptureTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var anchor: UInt64 = 0
    var anchorNanos: UInt64 { lock.withLock { anchor } }
    func start() -> UInt64 {
        lock.withLock { anchor = MonotonicClock.nowNanos(); return anchor }
    }
}

/// At most 200 full datagrams per peer. Header admission is provisional: the
/// completed batch must pass full PCM validation before a run can be accepted.
private struct DeferredPCMReceipts {
    struct Validation: CustomStringConvertible {
        let decoded: Int
        let malformed: Int
        let invalidPCM: Int
        let duplicates: Int
        let overflow: Int
        var isValid: Bool { decoded > 0 && malformed == 0 && invalidPCM == 0 && duplicates == 0 && overflow == 0 }
        var description: String {
            "decoded=\(decoded), malformed=\(malformed), invalidPCM=\(invalidPCM), duplicates=\(duplicates), overflow=\(overflow)"
        }
    }
    private struct Raw {
        let data: Data
        let header: AudioProbeHeader
    }
    private var raw: [Raw] = []
    private var sequences: Set<UInt32> = []
    private var malformed = 0
    private var duplicates = 0
    private var overflow = 0
    var count: Int { raw.count }

    mutating func append(_ data: Data, arrivedAt: UInt64) -> (sequence: UInt32, arrival: PacketArrival)? {
        guard let header = AudioProbeHeader.read(in: data) else { malformed += 1; return nil }
        guard raw.count < 200 else { overflow += 1; return nil }
        raw.append(Raw(data: data, header: header))
        guard sequences.insert(header.sequence).inserted else { duplicates += 1; return nil }
        return (header.sequence, PacketArrival(captureNanos: header.captureTimeNanos,
            arrivedNanos: arrivedAt, receiveEntryNanos: arrivedAt))
    }

    func validate(expectedSample: Int16) -> Validation {
        var invalid = 0
        var decoded = 0
        for receipt in raw {
            guard let packet = AudioPacket(data: receipt.data),
                  packet.sequence == receipt.header.sequence,
                  packet.captureTimeNanos == receipt.header.captureTimeNanos,
                  !packet.samples.isEmpty,
                  packet.samples.allSatisfy({ $0 == expectedSample }) else {
                invalid += 1
                continue
            }
            decoded += 1
        }
        return Validation(decoded: decoded, malformed: malformed, invalidPCM: invalid,
            duplicates: duplicates, overflow: overflow)
    }
}

private struct AudioProbeHeader {
    let sequence: UInt32
    let captureTimeNanos: UInt64

    static func sequence(in data: Data) -> UInt32? { read(in: data)?.sequence }

    /// Inspect only the wire header on the sender queue. Receiver tests still
    /// decode/validate the complete PCM payload, as the real receiver does.
    static func read(in data: Data) -> AudioProbeHeader? {
        guard data.count >= 36 else { return nil }
        return data.withUnsafeBytes { bytes in
            guard bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian == 0x5745_5241,
                  bytes[4] == 1,
                  bytes.loadUnaligned(fromByteOffset: 6, as: UInt16.self).littleEndian == AudioPacket.channelCount,
                  bytes.loadUnaligned(fromByteOffset: 28, as: UInt32.self).littleEndian == AudioPacket.sampleRate
            else { return nil }
            let frames = bytes.loadUnaligned(fromByteOffset: 32, as: UInt16.self).littleEndian
            guard frames > 0, frames <= AudioPacket.framesPerPacket,
                  data.count == 36 + Int(frames) * Int(AudioPacket.channelCount) * 2 else { return nil }
            return AudioProbeHeader(sequence: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian,
                captureTimeNanos: bytes.loadUnaligned(fromByteOffset: 20, as: UInt64.self).littleEndian)
        }
    }
}

private final class AudioCompletionLatencies: @unchecked Sendable {
    private let lock = NSLock()
    private var nanos: [UInt64] = []
    func record(_ value: UInt64) {
        lock.withLock { if nanos.count < 2_000 { nanos.append(value) } }
    }
    var summary: String {
        let values = lock.withLock { nanos.sorted() }
        guard !values.isEmpty else { return "no samples" }
        let median = values[(values.count - 1) / 2] / 1_000_000
        let p95 = values[(values.count - 1) * 95 / 100] / 1_000_000
        let maximum = (values.last ?? 0) / 1_000_000
        return "n=\(values.count), p50=\(median)ms, p95=\(p95)ms, max=\(maximum)ms"
    }
}

private final class FluidLinkShaper: @unchecked Sendable {
    private let bitsPerSecond: UInt64
    private let lock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "in.werai.tests.fluid-link", qos: .userInteractive)
    private let dispatchLatencies = AudioCompletionLatencies()
    var dispatchLatenessSummary: String { dispatchLatencies.summary }
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
            let executedAt = DispatchTime.now().uptimeNanoseconds
            self.dispatchLatencies.record(executedAt > deliversAt ? executedAt - deliversAt : 0)
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
    // Callback entry is observable; this is not a kernel wire-arrival timestamp.
    var receiveEntryNanos: UInt64? = nil
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
    let maximumPacketAgeNanos: UInt64
    let maximumPacketArrivalSkewNanos: UInt64
    let maximumAudibleLatenessNanos: UInt64
    let clockOffsetSpreadNanos: UInt64
    let minimumPacketsReceived: Int
    let resyncCommandsReceived: Int
    let captureCallbackAgeSummary: String
    let maximumReceiveEntryAgeNanos: UInt64
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
