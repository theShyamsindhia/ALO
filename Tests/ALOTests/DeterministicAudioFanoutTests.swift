import Foundation
import Network
import Testing
import ALOCore
@testable import ALO

/// Complements the real UDP loopback tests. Only capture wake times and audio
/// transport delivery/completion times are virtual; HostServer, its packetizer,
/// its queue policy, and the TCP join/report/resync path are production code.
@Suite("Deterministic real-host audio fan-out", .serialized)
struct DeterministicAudioFanoutTests {
    @Test func otherPeerCompletionReconsidersEligibleNonIdlePendingPeer() throws {
        let wire = MissedRefillWire()
        let controls = SimulationControlPeers()
        let ready = DispatchSemaphore(value: 0)
        let host = HostServer(roomName: "FIFO missed refill", advertise: false,
            listenerReadyHandler: { controls.setHostPort($0); ready.signal() },
            outboundSend: { connection, data, complete, completion in
                if let packet = AudioPacket(data: data), case .hostPort(_, let port) = connection.endpoint {
                    wire.submit(port: port.rawValue, packet: packet, completion: completion)
                } else {
                    connection.send(content: data, isComplete: complete, completion: .contentProcessed(completion))
                }
            }, audioSendNowNanos: { wire.now },
            audioAdmissionObservationForTesting: { wire.observe($0) },
            audioBackpressurePolicy: .boundedLatest(maxInFlight: 8))
        defer { controls.stop(); host.stop() }
        try host.start()
        try #require(ready.wait(timeout: .now() + 3) == .success)
        try controls.join(count: 2)
        let weak = try #require(controls.peerIndices.first { $0.value == 0 }?.key)
        let other = try #require(controls.peerIndices.first { $0.value == 1 }?.key)
        let anchor = MonotonicClock.nowNanos()
        func at(_ ms: UInt64) { wire.setNow(anchor + ms * 1_000_000) }
        func complete(_ port: UInt16, _ sequence: UInt32, _ ms: UInt64) throws {
            at(ms)
            try wire.complete(port: port, sequence: sequence)
            _ = host.audioSenderSnapshot()
        }
        at(0)
        host.acceptAudio(samples: [Int16](repeating: 1_024, count: 3 * 240 * 2), captureTimeNanos: anchor - 15_000_000)
        try #require(host.audioSenderSnapshot().allSatisfy { $0.sent == 3 && $0.inFlight == 3 })
        // Per-peer callbacks remain FIFO. No reversed callback or extra-owner delay.
        try complete(other, 0, 5)
        try complete(weak, 0, 10)
        try complete(other, 1, 15)
        try complete(other, 2, 25)
        try complete(weak, 1, 120)
        at(195)
        let pendingCapture = anchor + 165_000_000
        host.acceptAudio(samples: [Int16](repeating: 1_024, count: 240 * 2), captureTimeNanos: pendingCapture)
        let before = try #require(host.audioSenderSnapshot().first { $0.udpPort == weak })
        try #require(before.sent == 3 && before.inFlight == 1 && before.pending == 1)
        let refused = try #require(wire.observations.last { $0.port == weak && $0.captureNanos == pendingCapture })
        try #require(refused.decision == .deferred && refused.recentInterval == 110_000_000)
        try #require(refused.captureAge == 30_000_000 && refused.admissionBudget == 225_000_000)
        try complete(other, 3, 201)
        let missed = try #require(host.audioSenderSnapshot().first { $0.udpPort == weak })
        #expect(missed.sent == 4, "Other-peer completion should reconsider an eligible non-idle pending peer")

        // Same-clock production-gate control, not a copied eligibility predicate.
        // Adding a successor wakes drainAudio without altering the old packet's
        // timestamp, clock, in-flight count, or remaining budget.
        host.acceptAudio(samples: [Int16](repeating: 1_024, count: 240 * 2), captureTimeNanos: anchor + 196_000_000)
        _ = host.audioSenderSnapshot()
        let admitted = try #require(wire.observations.first {
            $0.port == weak && $0.captureNanos == pendingCapture && $0.decision == .admitted
        })
        try #require(admitted.ownerNanos == anchor + 201_000_000)
        try #require(admitted.inFlight == 1 && admitted.captureAge == 36_000_000)
        try #require(admitted.queueResidence == 6_000_000 && admitted.admissionBudget == 225_000_000)
        try #require(admitted.recentInterval == 0 && admitted.estimatedDuration == 0)
        try #require(admitted.unfinishedInterval == 81_000_000)
        try #require(wire.sequences(port: weak) == [0, 1, 2, 3])
        try complete(other, 4, 202)
        try complete(weak, 2, 202)
        try complete(weak, 3, 203)
        try complete(weak, 4, 204)
        for sender in host.audioSenderSnapshot() {
            #expect(sender.enqueued == 5 && sender.sent == 5 && sender.inFlight == 0 && sender.pending == 0)
            #expect(sender.expiredWait + sender.expiredAge + sender.admissionRejected + sender.replaced + sender.discardedBoundary == 0)
            #expect(wire.sequences(port: sender.udpPort) == [0, 1, 2, 3, 4])
        }
        #expect(wire.remaining == 0)
        print("FIFO missed-refill control: sentAfterOther=\(missed.sent), actual same-clock gate admitted captureAge=\(admitted.captureAge), unfinished=\(admitted.unfinishedInterval), inFlight=\(admitted.inFlight), budget=\(admitted.admissionBudget); all10 sends completed FIFO")
    }
    @Test func recordedTimingKeepsArrivalSeparateFromCompletion() throws {
        let wire = SimulatedAudioWire(bitsPerSecond: 4_000_000, recordedTiming: true)
        let origin: UInt64 = 1_000_000_000
        wire.setNow(origin)
        let packet = AudioPacket(sequence: 0, frameIndex: 0,
            captureTimeNanos: origin, samples: [1, -1])
        wire.submit(packet: packet, byteCount: 100,
            endpoint: .hostPort(host: "127.0.0.1", port: 12345), completion: { _ in })
        let event = try #require(wire.takeNext(through: origin + 100_000_000))
        #expect(event.arrivalTime - origin == 200_000 + 1_000_000
            + RecordedFanoutTiming.dispatchLatenessNanos[0])
        #expect(event.time - event.arrivalTime == RecordedFanoutTiming.completionDelayNanos[0])
        wire.deliver(event)
        #expect(wire.snapshot.arrivals[12345]?[0]?.arrivedAt == event.arrivalTime)
    }

    @Test func recordedUnevenDispatchPreservesListenerFloor() throws {
        #expect(RecordedFanoutTiming.captureWakeNanos.count == 50)
        #expect(RecordedFanoutTiming.dispatchLatenessNanos.count == 542)
        #expect(RecordedFanoutTiming.completionDelayNanos.count == 542)
        // Replay observed timing, not observed sender decisions. The real host
        // still determines which packets enter the link and which expire.
        let baseline = try simulate(peers: 8, rate: 4_000_000,
            policy: .boundedLatest(maxInFlight: 8), oversleep: 0,
            includesControlTraffic: true)
        let replay = try simulate(peers: 8, rate: 4_000_000,
            policy: .boundedLatest(maxInFlight: 8), oversleep: 0,
            includesControlTraffic: true, recordedTiming: true)
        #expect(baseline.minimumPackets >= 50)
        #expect(baseline.maximumAge < SynchronizedPlayer.targetLatencyNanos)
        #expect(replay.minimumPackets >= 50,
            "The unchanged live listener floor must survive recorded uneven dispatch")
        #expect(replay.maximumAge < SynchronizedPlayer.targetLatencyNanos)
    }

    @Test(arguments: [UInt64(1), 7, 23, 41])
    func irregularAudioDispatchWithPongBandwidthReservationPreservesListenerFloor(seed: UInt64) throws {
        // CI 34127177462 observed 23ms shaper dispatch lateness and one peer
        // receiving 46/200 despite complete delivery of every submitted packet.
        // This seeded stress is not an exact replay: CI retained distributions,
        // not the full sequence of callback times. Keep the live floor intact.
        let room = try simulate(peers: 8, rate: 4_000_000,
            policy: .boundedLatest(maxInFlight: 8), oversleep: 0,
            irregularDispatchSeed: seed, includesControlTraffic: true,
            allocationTrace: seed == 7 ? RefillAllocationTrace() : nil)
        #expect(room.maximumAge < SynchronizedPlayer.targetLatencyNanos)
        #expect(room.minimumPackets >= 50,
            "Irregular audio dispatch with reserved pong bandwidth must preserve the live per-listener floor")
    }

    @Test func pongBandwidthReservationConsumesSpecifiedWireTime() throws {
        let baseline = SimulatedAudioWire(bitsPerSecond: 4_000_000)
        let reserved = SimulatedAudioWire(bitsPerSecond: 4_000_000)
        let origin: UInt64 = 1_000_000_000
        baseline.setNow(origin); reserved.setNow(origin)
        for _ in 0..<8 { reserved.reserveControlBytes(90) }
        let packet = AudioPacket(sequence: 0, frameIndex: 0, captureTimeNanos: origin, samples: [1, -1])
        for wire in [baseline, reserved] {
            wire.submit(packet: packet, byteCount: 100,
                endpoint: .hostPort(host: "127.0.0.1", port: 12345), completion: { _ in })
        }
        let direct = try #require(baseline.takeNext(through: origin + 10_000_000))
        let delayed = try #require(reserved.takeNext(through: origin + 10_000_000))
        // 8×90B×8 /4Mb/s =1.44ms, not1.44 microseconds. This verifies
        // serialization only; no control-delivery/completion events are modeled.
        #expect(delayed.time - direct.time == 1_440_000)
    }

    @Test func batchedSharedLinkCompletionsDoNotStarveOneListener() throws {
        let room = try simulate(peers: 8, rate: 4_000_000,
            policy: .boundedLatest(maxInFlight: 8), oversleep: 0,
            callbackQuantumNanos: 25_000_000)
        #expect(room.maximumAge < SynchronizedPlayer.targetLatencyNanos)
        // Full-suite runs measured a 57-packet minimum with batched callbacks;
        // retain the established 50-packet live CI contract as the invariant.
        #expect(room.minimumPackets >= 50,
            "Batched callbacks must retain the same strict per-listener floor as the live timing gate")
    }

    @Test func delayedCaptureAndBatchedCompletionsPreserveEveryListenerFloor() throws {
        let room = try simulate(peers: 8, rate: 4_000_000,
            policy: .boundedLatest(maxInFlight: 8), oversleep: 35_000_000,
            callbackQuantumNanos: 25_000_000)
        #expect(room.maximumAge < SynchronizedPlayer.targetLatencyNanos)
        #expect(room.minimumPackets >= 50,
            "Capture catch-up and batched completions must not starve one listener")
    }

    @Test func callbackBatchingDoesNotDependOnMachineUptime() throws {
        var elapsedDeliveries: [UInt64] = []
        for origin in [UInt64(1_000_000_000), 1_000_012_345, 1_024_000_000] {
            let wire = SimulatedAudioWire(bitsPerSecond: 4_000_000, callbackQuantumNanos: 25_000_000)
            wire.setNow(origin)
            let packet = AudioPacket(sequence: 0, frameIndex: 0, captureTimeNanos: origin, samples: [1, -1])
            wire.submit(packet: packet, byteCount: 100,
                        endpoint: .hostPort(host: "127.0.0.1", port: 12345), completion: { _ in })
            let event = try #require(wire.takeNext(through: origin + 25_000_000))
            elapsedDeliveries.append(event.time - origin)
        }
        #expect(elapsedDeliveries == [25_000_000, 25_000_000, 25_000_000])
    }

    @Test func lateJoinerDoesNotStarveExistingListeners() throws {
        let room = try simulate(peers: 8, rate: 4_000_000,
            policy: .boundedLatest(maxInFlight: 8), oversleep: 0,
            callbackQuantumNanos: 25_000_000, lateJoinAtCallback: 25)
        #expect(room.maximumAge < SynchronizedPlayer.targetLatencyNanos)
        let existingCounts = room.packetCountsByParticipant
            .filter { $0.key != "virtual-peer-7" }.map(\.value)
        // Under the full parallel suite the established-peer minimum measured
        // 59. The release contract is the same strict 50-packet live CI floor.
        #expect(existingCounts.min() ?? 0 >= 50,
            "A late listener must not reduce established listeners below the strict CI floor")
    }

    @Test(arguments: [UInt64(70_000_000), 110_000_000])
    func delayedCaptureStillFitsTheSharedLinkBudget(wakeOversleep: UInt64) throws {
        let room = try simulate(peers: 8, rate: 4_000_000,
            policy: .boundedLatest(maxInFlight: 8), oversleep: wakeOversleep)
        #expect(room.maximumAge < SynchronizedPlayer.targetLatencyNanos)
        #expect(room.minimumPackets >= 50)
    }

    @Test(arguments: [UInt64(0), 35_000_000])
    func realSenderPreservesFastLinksAndBoundsSharedLinkDelay(wakeOversleep: UInt64) throws {
        let bounded = HostServer.AudioBackpressurePolicy.boundedLatest(maxInFlight: 8)
        let direct = try simulate(peers: 8, rate: nil, policy: .unbounded, oversleep: wakeOversleep)
        let directBounded = try simulate(peers: 8, rate: nil, policy: bounded, oversleep: wakeOversleep)
        let shapedOne = try simulate(peers: 1, rate: 4_000_000, policy: bounded, oversleep: wakeOversleep)
        let unboundedEight = try simulate(peers: 8, rate: 4_000_000, policy: .unbounded, oversleep: wakeOversleep)
        let boundedEight = try simulate(peers: 8, rate: 4_000_000, policy: bounded, oversleep: wakeOversleep)

        #expect(direct.finalAge < 100_000_000)
        #expect(direct.maximumDeadlineMiss < 50_000_000)
        #expect(direct.minimumPackets >= 190)
        #expect(directBounded.finalAge < 100_000_000)
        #expect(directBounded.maximumDeadlineMiss < 50_000_000)
        #expect(directBounded.minimumPackets >= 190)
        #expect(shapedOne.finalAge < 100_000_000)
        #expect(unboundedEight.finalAge > shapedOne.finalAge + 1_000_000_000)
        #expect(unboundedEight.finalAge > SynchronizedPlayer.targetLatencyNanos)
        #expect(unboundedEight.maximumDeadlineMiss > 1_000_000_000)
        #expect(unboundedEight.minimumPackets >= 190)
        #expect(unboundedEight.maximumSkew > 5_000_000)
        #expect(unboundedEight.resyncs > 0)
        #expect(boundedEight.finalAge < SynchronizedPlayer.targetLatencyNanos)
        #expect(boundedEight.maximumAge < SynchronizedPlayer.targetLatencyNanos)
        #expect(boundedEight.maximumDeadlineMiss < 100_000_000)
        #expect(boundedEight.minimumPackets >= 50)
        #expect(boundedEight.minimumPackets < unboundedEight.minimumPackets)
    }

    private func simulate(peers count: Int, rate: UInt64?, policy: HostServer.AudioBackpressurePolicy,
                          oversleep: UInt64, callbackQuantumNanos: UInt64? = nil,
                          lateJoinAtCallback: Int? = nil, irregularDispatchSeed: UInt64? = nil,
                          includesControlTraffic: Bool = false,
                          recordedTiming: Bool = false,
                          allocationTrace: RefillAllocationTrace? = nil) throws -> SimulatedRoomResult {
        let wire = SimulatedAudioWire(bitsPerSecond: rate, callbackQuantumNanos: callbackQuantumNanos,
            irregularDispatchSeed: irregularDispatchSeed, recordedTiming: recordedTiming)
        let controls = SimulationControlPeers()
        let hostReady = DispatchSemaphore(value: 0)
        let host = HostServer(roomName: "Virtual-time real host", advertise: false,
            listenerReadyHandler: { port in controls.setHostPort(port); hostReady.signal() },
            outboundSend: { connection, bytes, complete, completion in
                if let packet = AudioPacket(data: bytes) {
                    wire.submit(packet: packet, byteCount: bytes.count, endpoint: connection.endpoint,
                        completion: completion)
                } else {
                    connection.send(content: bytes, isComplete: complete,
                        completion: .contentProcessed(completion))
                }
            }, audioSendNowNanos: { wire.now },
            audioAdmissionObservationForTesting: allocationTrace.map { trace in { trace.observe($0) } },
            audioBackpressurePolicy: policy)
        defer { controls.stop(); host.stop() }
        try host.start()
        try #require(hostReady.wait(timeout: .now() + 3) == .success, "Real host listener did not start")
        try controls.join(count: lateJoinAtCallback == nil ? count : count - 1)

        // The source clock is anchored only after real handshakes finish. Real
        // elapsed time thereafter never advances this clock or the wire events.
        let anchor = MonotonicClock.nowNanos()
        wire.setNow(anchor)
        let sourceStart = anchor - 20_000_000
        let samples = [Int16](repeating: 1_024, count: 4 * 240 * 2)
        var captureWake = anchor
        for callback in 0..<50 {
            if callback == lateJoinAtCallback { try controls.join(count: 1) }
            let nominalDeadline = anchor + UInt64(callback) * 20_000_000
            // Match the positive-wait oversleep/catch-up model: callbacks whose
            // deadlines were missed run together, without another injected wait.
            if captureWake < nominalDeadline { captureWake = nominalDeadline + oversleep }
            if recordedTiming {
                captureWake = nominalDeadline + RecordedFanoutTiming.captureWakeNanos[callback]
            }
            advance(wire, through: captureWake, host: host, allocationTrace: allocationTrace)
            allocationTrace?.beginCapture()
            host.acceptAudio(samples: samples, captureTimeNanos: nominalDeadline - 20_000_000)
            _ = host.audioSenderSnapshot() // Completes real packetization/enqueue at this event time.
            if includesControlTraffic && callback.isMultiple(of: 5) {
                // The live fixture pings every peer on this cadence. Reserve
                // the actual encoded pong bytes on the same aggregate link;
                // these are explicit bandwidth reservations, not synthetic
                // audio or a model of control dispatch/completion scheduling.
                for peer in 0..<count {
                    let pong = ControlMessage(type: "pong", id: UInt64(callback * count + peer),
                        clientNanos: nominalDeadline, hostNanos: nominalDeadline)
                    wire.reserveControlBytes(try pong.encodedLine().count)
                }
            }
        }
        advance(wire, through: anchor + 5_000_000_000, host: host, allocationTrace: allocationTrace)
        let state = wire.snapshot
        let senders = host.audioSenderSnapshot()
        let ports = controls.ports
        if let allocationTrace {
            #expect(allocationTrace.sentCounts == state.submitted.mapValues { $0.count })
            #expect(!allocationTrace.overflowed)
            #expect(allocationTrace.maximumAdmissionsPerPeerRound == 1,
                "Actual production completion rounds must grant at most one packet per peer")
            #expect(allocationTrace.roundMetadataValid,
                "Actual completion admissions must identify a bounded round")
            allocationTrace.report(peers: controls.peerIndices)
        }
        try #require(state.eventsRemaining == 0)
        try #require(state.invalidEndpoints == 0)
        try #require(senders.count == count && Set(senders.map(\.udpPort)) == Set(ports))
        try #require(Set(state.submitted.keys) == Set(ports))
        try #require(senders.allSatisfy { $0.inFlight == 0 && $0.pending == 0 })
        for sender in senders {
            let expectedPackets = sender.participantID == "virtual-peer-\(count - 1)"
                ? UInt64((50 - (lateJoinAtCallback ?? 0)) * 4) : 200
            #expect(sender.enqueued == expectedPackets)
            #expect(sender.sent == UInt64(state.submitted[sender.udpPort]?.count ?? 0))
            #expect(sender.sent + sender.expiredWait + sender.expiredAge + sender.admissionRejected + sender.replaced
                + sender.discardedBoundary == sender.enqueued)
            #expect(sender.discardedBoundary == 0)
        }

        var finalAges: [UInt64] = [], allAges: [UInt64] = [], deadlineMisses: [UInt64] = []
        var counts: [Int] = []
        var packetCountsByParticipant: [String: Int] = [:]
        var shared: Set<UInt32>?
        var reportedPeers: Set<String> = []
        for port in ports {
            let sender = try #require(senders.first(where: { $0.udpPort == port }))
            let arrivals = try #require(state.arrivals[port])
            try #require(!arrivals.isEmpty)
            #expect(Set(arrivals.keys) == Set(state.submitted[port] ?? []))
            #expect(arrivals.values.allSatisfy {
                $0.packet.frameIndex == UInt64($0.packet.sequence) * 240
                    && $0.packet.captureTimeNanos == sourceStart + UInt64($0.packet.sequence) * 5_000_000
            })
            let last = try #require(arrivals.keys.max())
            let final = try #require(arrivals[last])
            finalAges.append(final.arrivedAt - final.packet.captureTimeNanos)
            allAges += arrivals.values.map { $0.arrivedAt - $0.packet.captureTimeNanos }
            if case .boundedLatest = policy, let worst = arrivals.values.max(by: {
                $0.arrivedAt - $0.packet.captureTimeNanos < $1.arrivedAt - $1.packet.captureTimeNanos
            }), worst.arrivedAt - worst.packet.captureTimeNanos >= SynchronizedPlayer.targetLatencyNanos {
                print("Virtual late packet port=\(port) sequence=\(worst.packet.sequence): capture-to-admission=\(worst.admittedAt - worst.packet.captureTimeNanos)ns, admission-to-delivery=\(worst.arrivedAt - worst.admittedAt)ns, total=\(worst.arrivedAt - worst.packet.captureTimeNanos)ns")
            }
            counts.append(arrivals.count)
            packetCountsByParticipant[sender.participantID] = arrivals.count
            // This is a transport deadline measurement, not a renderer model:
            // actual arrival minus the packet's own shared playout deadline.
            let deadlineMiss = arrivals.values.map { arrival -> UInt64 in
                let deadline = arrival.packet.captureTimeNanos + SynchronizedPlayer.targetLatencyNanos
                return arrival.arrivedAt > deadline ? arrival.arrivedAt - deadline : 0
            }.max() ?? 0
            deadlineMisses.append(deadlineMiss)
            if sender.participantID != "virtual-peer-\(count - 1)" || lateJoinAtCallback == nil {
                shared = shared.map { $0.intersection(arrivals.keys) } ?? Set(arrivals.keys)
            }
            switch policy {
            case .unbounded: #expect(last == 199)
            case .boundedLatest:
                // This policy intentionally drops a tail that can no longer
                // fit its delivery budget. Continuity is the invariant: the
                // stream may shed packets, but it cannot leave a long hole.
                let firstCapture: UInt64
                if sender.participantID == "virtual-peer-\(count - 1)", let lateJoinAtCallback {
                    firstCapture = sourceStart + UInt64(lateJoinAtCallback) * 20_000_000
                } else {
                    firstCapture = sourceStart
                }
                let boundaries = [firstCapture] + arrivals.values.map { $0.packet.captureTimeNanos }.sorted()
                    + [sourceStart + 1_000_000_000]
                #expect(zip(boundaries, boundaries.dropFirst()).allSatisfy { $1 - $0 <= 200_000_000 })
            }
            if deadlineMiss > SynchronizedPlayer.hardResyncThresholdNanos {
                reportedPeers.insert(try controls.report(lateness: deadlineMiss, port: port))
            }
        }
        // The negative control also traverses the real TCP report/resync path.
        // These are liveness waits, not inputs to any simulated timing metric.
        try controls.requireResyncs(for: reportedPeers)
        let common = try #require(shared)
        try #require(!common.isEmpty)
        let skew = common.map { sequence -> UInt64 in
            let times = ports.compactMap { state.arrivals[$0]?[sequence]?.arrivedAt }
            return (times.max() ?? 0) - (times.min() ?? 0)
        }.max() ?? 0
        let result = SimulatedRoomResult(finalAge: finalAges.max() ?? 0, maximumAge: allAges.max() ?? 0,
            maximumDeadlineMiss: deadlineMisses.max() ?? 0, minimumPackets: counts.min() ?? 0,
            maximumPackets: counts.max() ?? 0, maximumSkew: skew, resyncs: reportedPeers.count,
            packetCountsByParticipant: packetCountsByParticipant)
        print("Virtual real-host peers=\(count) rate=\(rate.map(String.init) ?? "direct") policy=\(policy) wake=\(oversleep / 1_000_000)ms dispatchSeed=\(irregularDispatchSeed.map(String.init) ?? "none") mixedControl=\(includesControlTraffic) recordedTiming=\(recordedTiming): \(result); senderAccounting=\(senders)")
        return result
    }

    private func advance(_ wire: SimulatedAudioWire, through deadline: UInt64, host: HostServer,
                         allocationTrace: RefillAllocationTrace? = nil) {
        while let event = wire.takeNext(through: deadline) {
            wire.deliver(event)
            allocationTrace?.beginCompletion()
            event.completion(nil)
            // The callback invokes the real sender. Its queue hop can schedule
            // another wire event, which must be observed before advancing time.
            _ = host.audioSenderSnapshot()
        }
        wire.setNow(deadline)
    }

}

private final class RefillAllocationTrace: @unchecked Sendable {
    struct Admission {
        let context: Int
        let value: HostServer.AudioAdmissionObservation
        let sentBefore: Int
    }
    private let lock = NSLock()
    private var context = 0
    private var isCompletion = false
    private var counts: [UInt16: Int] = [:]
    private var admissions: [Admission] = []
    private var dropped = false
    var sentCounts: [UInt16: Int] { lock.withLock { counts } }
    var overflowed: Bool { lock.withLock { dropped } }
    var roundMetadataValid: Bool {
        lock.withLock {
            !admissions.isEmpty && admissions.allSatisfy {
                $0.value.completionRound.map { (0..<8).contains($0) } == true
            }
        }
    }
    var maximumAdmissionsPerPeerRound: Int {
        lock.withLock {
            Dictionary(grouping: admissions) {
                "\($0.context):\($0.value.completionRound ?? -1):\($0.value.port)"
            }.values.map(\.count).max() ?? 0
        }
    }
    func beginCapture() { lock.withLock { isCompletion = false } }
    func beginCompletion() { lock.withLock { context += 1; isCompletion = true } }
    func observe(_ value: HostServer.AudioAdmissionObservation) {
        guard value.decision == .admitted else { return }
        lock.withLock {
            let before = counts[value.port, default: 0]
            counts[value.port] = before + 1
            if isCompletion {
                if admissions.count < 8_000 {
                    admissions.append(.init(context: context, value: value, sentBefore: before))
                } else { dropped = true }
            }
        }
    }
    func report(peers: [UInt16: Int]) {
        let snapshot = lock.withLock { admissions }
        var inversions = 0
        var sameRoundInversions = 0
        for (index, later) in snapshot.enumerated() where later.value.queueResidence > 0
            && later.value.inFlight > 0 && !later.value.fanoutIdle {
            for earlier in snapshot[..<index].reversed() {
                guard earlier.context == later.context else { break }
                // An intervening B admission changes its gate inputs, so do not
                // use that pair as proof B was eligible before A's extra slot.
                if earlier.value.port == later.value.port { break }
                guard earlier.value.ownerNanos == later.value.ownerNanos,
                      !earlier.value.fanoutIdle,
                      earlier.sentBefore > later.sentBefore else { continue }
                inversions += 1
                if earlier.value.completionRound == later.value.completionRound { sameRoundInversions += 1 }
                if inversions <= 20 {
                    print("Refill allocation inversion context=\(later.context) earlierPeer=\(peers[earlier.value.port] ?? -1) sentBefore=\(earlier.sentBefore) laterPeer=\(peers[later.value.port] ?? -1) sentBefore=\(later.sentBefore) laterResidence=\(later.value.queueResidence) laterInFlight=\(later.value.inFlight) laterAge=\(later.value.captureAge) sameClock=1 actualGateAdmitted=1")
                }
            }
        }
        print("Refill allocation trace retained=\(snapshot.count) overflow=\(overflowed) sameCompletionInversions=\(inversions) sameRoundInversions=\(sameRoundInversions) maximumAdmissionsPerPeerRound=\(maximumAdmissionsPerPeerRound); actual production observations")
    }
}

private final class MissedRefillWire: @unchecked Sendable {
    private let lock = NSLock()
    private var clock: UInt64 = 0
    private var callbacks: [UInt16: [(UInt32, (NWError?) -> Void)]] = [:]
    private var submitted: [UInt16: [UInt32]] = [:]
    private var evidence: [HostServer.AudioAdmissionObservation] = []
    var now: UInt64 { lock.withLock { clock } }
    var remaining: Int { lock.withLock { callbacks.values.reduce(0) { $0 + $1.count } } }
    var observations: [HostServer.AudioAdmissionObservation] { lock.withLock { evidence } }
    func setNow(_ value: UInt64) { lock.withLock { clock = value } }
    func observe(_ value: HostServer.AudioAdmissionObservation) { lock.withLock { evidence.append(value) } }
    func sequences(port: UInt16) -> [UInt32] { lock.withLock { submitted[port, default: []] } }
    func submit(port: UInt16, packet: AudioPacket, completion: @escaping (NWError?) -> Void) {
        lock.withLock {
            submitted[port, default: []].append(packet.sequence)
            callbacks[port, default: []].append((packet.sequence, completion))
        }
    }
    func complete(port: UInt16, sequence: UInt32) throws {
        let first = lock.withLock { callbacks[port]?.first }
        let entry = try #require(first)
        try #require(entry.0 == sequence, "Completion order must remain FIFO")
        lock.withLock { _ = callbacks[port]?.removeFirst() }
        entry.1(nil)
    }
}

private struct SimulatedRoomResult {
    let finalAge: UInt64
    let maximumAge: UInt64
    let maximumDeadlineMiss: UInt64
    let minimumPackets: Int
    let maximumPackets: Int
    let maximumSkew: UInt64
    let resyncs: Int
    let packetCountsByParticipant: [String: Int]
}

/// Models the link, not HostServer's queue. Every scheduled event originated
/// from a real outboundSend and returns that exact production completion.
private final class SimulatedAudioWire: @unchecked Sendable {
    struct Arrival { let packet: AudioPacket; let admittedAt: UInt64; let arrivedAt: UInt64 }
    struct Event {
        let time: UInt64
        let arrivalTime: UInt64
        let order: Int
        let port: UInt16
        let packet: AudioPacket
        let admittedAt: UInt64
        let completion: (NWError?) -> Void
    }
    struct Snapshot {
        let submitted: [UInt16: [UInt32]]
        let arrivals: [UInt16: [UInt32: Arrival]]
        let eventsRemaining: Int
        let invalidEndpoints: Int
    }
    private let lock = NSLock()
    private let bitsPerSecond: UInt64?
    private let callbackQuantumNanos: UInt64?
    private var current = MonotonicClock.nowNanos()
    private var callbackEpoch: UInt64?
    private var linkAvailable: UInt64 = 0
    private var nextOrder = 0
    private var events: [Event] = []
    private var submitted: [UInt16: [UInt32]] = [:]
    private var arrivals: [UInt16: [UInt32: Arrival]] = [:]
    private var invalidEndpoints = 0
    private var dispatchRandomState: UInt64?
    private var lastDispatch: UInt64 = 0
    private let recordedTiming: Bool
    private var lastCompletionByPort: [UInt16: UInt64] = [:]
    init(bitsPerSecond: UInt64?, callbackQuantumNanos: UInt64? = nil,
         irregularDispatchSeed: UInt64? = nil, recordedTiming: Bool = false) {
        self.bitsPerSecond = bitsPerSecond
        self.callbackQuantumNanos = callbackQuantumNanos
        self.dispatchRandomState = irregularDispatchSeed
        self.recordedTiming = recordedTiming
    }
    var now: UInt64 { lock.withLock { current } }
    func setNow(_ value: UInt64) { lock.withLock {
        // Batch phase belongs to this virtual run, never to machine uptime.
        // Quantizing absolute monotonic time silently randomized the 25ms
        // callback phase on each run and changed established-listener counts.
        if callbackEpoch == nil { callbackEpoch = value }
        current = value
    } }
    var snapshot: Snapshot { lock.withLock {
        Snapshot(submitted: submitted, arrivals: arrivals, eventsRemaining: events.count,
            invalidEndpoints: invalidEndpoints)
    } }

    func submit(packet: AudioPacket, byteCount: Int, endpoint: NWEndpoint,
                completion: @escaping (NWError?) -> Void) {
        lock.withLock {
            guard case .hostPort(_, let port) = endpoint else { invalidEndpoints += 1; return }
            var delivery: UInt64
            if let rate = bitsPerSecond {
                // Ceiling division preserves the specified aggregate wire rate.
                let duration = (UInt64(byteCount) * 8 * 1_000_000_000 + rate - 1) / rate
                linkAvailable = max(current, linkAvailable) + duration
                let serializedDelivery = linkAvailable + 1_000_000
                if let quantum = callbackQuantumNanos {
                    let epoch = callbackEpoch ?? current
                    let elapsed = serializedDelivery - epoch
                    delivery = epoch + ((elapsed + quantum - 1) / quantum) * quantum
                } else {
                    delivery = serializedDelivery
                }
            } else {
                // Ideal fast-link baseline, not an OS scheduler reproduction.
                // Separate burst tests inject 60ms production callback stalls.
                delivery = current + 1_000_000
            }
            if let state = dispatchRandomState {
                let next = state &* 6364136223846793005 &+ 1442695040888963407
                dispatchRandomState = next
                let lateness = (next >> 32) % 24 * 1_000_000
                // The live shaper has one serial dispatch queue. A late block
                // also delays the following blocks; never reverse wire order.
                delivery = max(lastDispatch, delivery + lateness)
                lastDispatch = delivery
            }
            if recordedTiming {
                // Repeat the complete trace if changed admission produces more
                // sends. A serial dispatch queue cannot reverse wire order.
                let index = nextOrder % RecordedFanoutTiming.dispatchLatenessNanos.count
                delivery = max(lastDispatch, delivery + RecordedFanoutTiming.dispatchLatenessNanos[index])
                lastDispatch = delivery
            }
            let arrivalTime = delivery
            if recordedTiming {
                let index = nextOrder % RecordedFanoutTiming.completionDelayNanos.count
                delivery += RecordedFanoutTiming.completionDelayNanos[index]
                delivery = max(delivery, lastCompletionByPort[port.rawValue] ?? 0)
                lastCompletionByPort[port.rawValue] = delivery
            }
            submitted[port.rawValue, default: []].append(packet.sequence)
            events.append(Event(time: delivery, arrivalTime: arrivalTime, order: nextOrder, port: port.rawValue,
                packet: packet, admittedAt: current, completion: completion))
            nextOrder += 1
        }
    }

    func reserveControlBytes(_ byteCount: Int) {
        lock.withLock {
            guard let rate = bitsPerSecond else { return }
            let duration = (UInt64(byteCount) * 8 * 1_000_000_000 + rate - 1) / rate
            linkAvailable = max(current, linkAvailable) + duration
        }
    }

    func takeNext(through deadline: UInt64) -> Event? {
        lock.withLock {
            guard let index = events.indices.min(by: {
                (events[$0].time, events[$0].order) < (events[$1].time, events[$1].order)
            }), events[index].time <= deadline else { return nil }
            let event = events.remove(at: index)
            current = event.time
            return event
        }
    }
    func deliver(_ event: Event) { lock.withLock {
        arrivals[event.port, default: [:]][event.packet.sequence] = Arrival(packet: event.packet,
            admittedAt: event.admittedAt, arrivedAt: event.arrivalTime)
    } }
}

private final class SimulationControlPeers: @unchecked Sendable {
    private let joined = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "alo.tests.virtual-time-control")
    private var hostPort: NWEndpoint.Port?
    private var listeners: [NWListener] = []
    private var connections: [NWConnection] = []
    private var controls: [UInt16: (id: String, connection: NWConnection)] = [:]
    private var resyncEvents: [String: DispatchSemaphore] = [:]
    private var receivedResyncs: Set<String> = []
    private var nextPeerIndex = 0
    private var stopped = false
    var ports: [UInt16] { lock.withLock { controls.keys.sorted() } }
    var peerIndices: [UInt16: Int] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: controls.map { port, value in
                (port, Int(value.id.dropFirst("virtual-peer-".count))!)
            })
        }
    }
    func setHostPort(_ port: NWEndpoint.Port) { lock.withLock { hostPort = port } }

    func join(count: Int) throws {
        let storedHostPort: NWEndpoint.Port? = lock.withLock { self.hostPort }
        let hostPort = try #require(storedHostPort)
        let videoPort = try listen(using: .tcp)
        let firstIndex = lock.withLock { () -> Int in
            let first = nextPeerIndex
            nextPeerIndex += count
            return first
        }
        for offset in 0..<count {
            let udpPort = try listen(using: .udp)
            let id = "virtual-peer-\(firstIndex + offset)"
            let connection = NWConnection(host: "127.0.0.1", port: hostPort, using: .tcp)
            lock.withLock {
                connections.append(connection)
                controls[udpPort.rawValue] = (id, connection)
                resyncEvents[id] = DispatchSemaphore(value: 0)
            }
            receive(connection, decoder: ControlLineDecoder(), participantID: id)
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    let join = ControlMessage(type: "join", udpPort: udpPort.rawValue,
                        videoPort: videoPort.rawValue, displayName: id, participantID: id)
                    connection.send(content: try? join.encodedLine(), completion: .contentProcessed { _ in })
                }
            }
            connection.start(queue: queue)
            try #require(joined.wait(timeout: .now() + 3) == .success, "Real TCP media join failed")
        }
    }

    private func listen(using parameters: NWParameters) throws -> NWEndpoint.Port {
        let ready = DispatchSemaphore(value: 0)
        let listener = try NWListener(using: parameters, on: .any)
        lock.withLock { listeners.append(listener) }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let retain = self.lock.withLock { () -> Bool in
                guard !self.stopped else { return false }
                self.connections.append(connection)
                return true
            }
            guard retain else { connection.cancel(); return }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        try #require(ready.wait(timeout: .now() + 3) == .success)
        return try #require(listener.port)
    }

    private func receive(_ connection: NWConnection, decoder: ControlLineDecoder, participantID: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            if let bytes {
                for message in decoder.append(bytes) {
                    if message.type == "welcome" { self.joined.signal() }
                    if message.type == "resync" {
                        let event = self.lock.withLock {
                            self.receivedResyncs.insert(participantID)
                            return self.resyncEvents[participantID]
                        }
                        event?.signal()
                    }
                }
            }
            if !complete && error == nil {
                self.receive(connection, decoder: decoder, participantID: participantID)
            }
        }
    }

    func report(lateness: UInt64, port: UInt16) throws -> String {
        let peer = try #require(lock.withLock { controls[port] })
        let message = ControlMessage(type: "sync_status", participantID: peer.id,
            syncReport: PlaybackSyncReport(measuredAtNanos: MonotonicClock.nowNanos(),
                latenessNanos: lateness, latePacketCount: 1, resyncCount: 0))
        peer.connection.send(content: try message.encodedLine(), completion: .contentProcessed { _ in })
        return peer.id
    }
    func requireResyncs(for ids: Set<String>) throws {
        let deadline = DispatchTime.now() + 3
        for id in ids.sorted() {
            let event = try #require(lock.withLock { resyncEvents[id] })
            if !lock.withLock({ receivedResyncs.contains(id) }) {
                try #require(event.wait(timeout: deadline) == .success, "Missing real TCP resync for \(id)")
            }
        }
        #expect(lock.withLock { ids.isSubset(of: receivedResyncs) })
    }
    func stop() {
        let resources = lock.withLock { () -> ([NWListener], [NWConnection]) in
            stopped = true
            let result = (listeners, connections)
            listeners.removeAll(); connections.removeAll(); controls.removeAll()
            return result
        }
        for listener in resources.0 {
            listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
        }
        for connection in resources.1 { connection.stateUpdateHandler = nil; connection.cancel() }
        queue.sync {}
    }
}
