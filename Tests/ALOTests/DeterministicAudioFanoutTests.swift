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
    @Test(arguments: [false, true])
    func recoveryDoesNotSkipAdmissibleAcquisitionDelayedIntermediate(includeFreshTail: Bool) throws {
        let wire = SimulatedAudioWire(bitsPerSecond: nil, fixedLatencyNanos: 130_000_000)
        let controls = SimulationControlPeers()
        let evidence = MissedRefillWire()
        let ready = DispatchSemaphore(value: 0)
        let host = HostServer(roomName: "Recovery prefix barrier", advertise: false,
            listenerReadyHandler: { controls.setHostPort($0); ready.signal() },
            outboundSend: { connection, data, complete, completion in
                if let packet = AudioPacket(data: data) {
                    wire.submit(packet: packet, byteCount: data.count, endpoint: connection.endpoint, completion: completion)
                } else { connection.send(content: data, isComplete: complete, completion: .contentProcessed(completion)) }
            }, audioSendNowNanos: { wire.now }, audioAdmissionObservationForTesting: { evidence.observe($0) },
            audioBackpressurePolicy: .boundedLatest(maxInFlight: 2))
        defer { controls.stop(); host.stop() }
        try host.start(); try #require(ready.wait(timeout: .now() + 3) == .success)
        try controls.join(count: 1)
        let port = try #require(controls.ports.first)
        let anchor = MonotonicClock.nowNanos()
        func pulse(at ms: UInt64, capture: UInt64) {
            advance(wire, through: anchor + ms * 1_000_000, host: host)
            host.acceptAudio(samples: [Int16](repeating: 1_024, count: 480),
                captureTimeNanos: anchor + capture * 1_000_000)
            _ = host.audioSenderSnapshot()
        }
        pulse(at: 71, capture: 66); pulse(at: 75, capture: 70)
        pulse(at: 150, capture: 101)
        try #require(host.audioSenderSnapshot().first?.inFlight == 2)
        try #require(host.audioSenderSnapshot().first?.pending == 1)
        advance(wire, through: anchor + 201_000_000, host: host)
        try #require(wire.snapshot.arrivals[port]?.count == 1)
        let head = try #require(evidence.observations.last)
        try #require(head.decision == .deferred && !head.fanoutIdle && head.inFlight == 1)
        try #require(head.captureAge == 100_000_000 && head.queueResidence == 51_000_000)
        try #require(head.projectedCompletion == 130_000_000 && head.admissionBudget == 225_000_000)
        // B would pass the unchanged admission gate (90 + 130 < 225),
        // but is excluded from recovery selection by acquisition age90 >=80.
        // C must not make that otherwise-admissible intermediate disappear.
        pulse(at: 201, capture: 111)
        try #require(host.audioSenderSnapshot().first?.pending == 2)
        if includeFreshTail { pulse(at: 201, capture: 131) }
        let held = try #require(host.audioSenderSnapshot().first)
        #expect(held.replaced == 0 && held.sent == 2)
        #expect(held.pending == (includeFreshTail ? 3 : 2))
        #expect(wire.snapshot.submitted[port] == [0, 1])
        advance(wire, through: anchor + 500_000_000, host: host)
        let final = try #require(host.audioSenderSnapshot().first)
        let arrivals = wire.snapshot.arrivals[port, default: [:]]
        // At205 the remaining warm send completes; true whole-fanout idle
        // clears history and A/B are delivered FIFO. Any C expires normally.
        #expect(wire.snapshot.submitted[port] == [0, 1, 2, 3])
        #expect(arrivals[3] != nil, "Fresh tail must not replace an admissible intermediate")
        #expect(final.sent == 4 && final.replaced == 0)
        #expect(final.expiredWait == (includeFreshTail ? 1 : 0))
        #expect(final.enqueued == final.sent + final.expiredWait + final.replaced)
        #expect(final.expiredAge == 0 && final.admissionRejected == 0)
        #expect(final.inFlight == 0 && final.pending == 0 && wire.snapshot.eventsRemaining == 0)
        #expect(UInt64(arrivals.count) == final.sent)
        for arrival in arrivals.values {
            #expect(arrival.arrivedAt - arrival.admittedAt == 130_000_000)
            #expect(arrival.arrivedAt - arrival.packet.captureTimeNanos < SynchronizedPlayer.targetLatencyNanos)
        }
    }
    @Test func extendedMeasuredTimingRetainsListenerFloor() throws {
        let trace = RecordedFairRoundTiming.extendedOriginal
        try #require(trace.wakes.count == 50 && trace.dispatchLate.count == 2033)
        try #require(trace.completionDelay.count == trace.dispatchLate.count && trace.controls.count == 80)
        let room = try simulate(peers: 8, rate: 4_000_000, policy: .boundedLatest(maxInFlight: 8),
            oversleep: 0, globalTiming: trace)
        #expect(room.minimumPackets >= 50)
        #expect(room.maximumAge < SynchronizedPlayer.targetLatencyNanos)
    }
    @Test(arguments: [false, true])
    func pipelineCanonicalYoungerPreservesEligibleFIFO(includeYounger: Bool) throws {
        let wire = SimulatedAudioWire(bitsPerSecond: nil, fixedLatencyNanos: 150_000_000)
        let controls = SimulationControlPeers()
        let evidence = MissedRefillWire()
        let ready = DispatchSemaphore(value: 0)
        let host = HostServer(roomName: "Pipeline canonical FIFO", advertise: false,
            listenerReadyHandler: { controls.setHostPort($0); ready.signal() },
            outboundSend: { connection, data, complete, completion in
                if let packet = AudioPacket(data: data) {
                    wire.submit(packet: packet, byteCount: data.count, endpoint: connection.endpoint, completion: completion)
                } else { connection.send(content: data, isComplete: complete, completion: .contentProcessed(completion)) }
            }, audioSendNowNanos: { wire.now }, audioAdmissionObservationForTesting: { evidence.observe($0) },
            audioBackpressurePolicy: .boundedLatest(maxInFlight: 8))
        defer { controls.stop(); host.stop() }
        try host.start(); try #require(ready.wait(timeout: .now() + 3) == .success)
        try controls.join(count: 1)
        let port = try #require(controls.ports.first)
        let anchor = MonotonicClock.nowNanos()
        for ms in [UInt64(0), 10, 20] {
            advance(wire, through: anchor + ms * 1_000_000, host: host)
            host.acceptAudio(samples: [Int16](repeating: 1_024, count: 480), captureTimeNanos: anchor + ms * 1_000_000 - 5_000_000)
            _ = host.audioSenderSnapshot()
        }
        advance(wire, through: anchor + 161_000_000, host: host)
        try #require(wire.snapshot.arrivals[port]?.count == 2)
        try #require(host.audioSenderSnapshot().first?.inFlight == 1)
        // Include a second eligible younger packet to pin remaining tail order.
        let count = includeYounger ? 3 : 1
        host.acceptAudio(samples: [Int16](repeating: 1_024, count: count * 480), captureTimeNanos: anchor + 85_000_000)
        let state = try #require(host.audioSenderSnapshot().first)
        let head = try #require(evidence.observations.first {
            $0.ownerNanos == anchor + 161_000_000 && $0.captureNanos == anchor + 85_000_000
        })
        try #require(head.estimatedDuration == 150_000_000 && head.completionGrowth == 0 && head.projectedCompletion == 150_000_000)
        #expect(head.decision == .deferred && head.captureAge == 76_000_000)
        if includeYounger {
            #expect(wire.snapshot.submitted[port] == [0, 1, 2, 4, 5])
            #expect(state.replaced == 1 && state.sent == 5 && state.pending == 0)
            let younger = try #require(evidence.observations.first {
                $0.ownerNanos == anchor + 161_000_000 && $0.captureNanos == anchor + 90_000_000 && $0.decision == .admitted
            })
            #expect(younger.supersededPrefixCount == 1 && younger.captureAge == 71_000_000)
        } else {
            #expect(wire.snapshot.submitted[port] == [0, 1, 2])
            #expect(state.replaced == 0 && state.sent == 3 && state.pending == 1)
        }
        advance(wire, through: anchor + 500_000_000, host: host)
        let final = try #require(host.audioSenderSnapshot().first)
        let arrivals = wire.snapshot.arrivals[port, default: [:]]
        #expect(final.enqueued == final.sent + final.replaced)
        #expect(final.pending == 0 && final.inFlight == 0 && wire.snapshot.eventsRemaining == 0)
        #expect(final.expiredAge == 0 && final.expiredWait == 0 && final.admissionRejected == 0)
        #expect(UInt64(arrivals.count) == final.sent)
        #expect(wire.snapshot.submitted[port] == (includeYounger ? [0, 1, 2, 4, 5] : [0, 1, 2, 3]))
        for arrival in arrivals.values {
            #expect(arrival.arrivedAt - arrival.admittedAt == 150_000_000)
            #expect(arrival.arrivedAt - arrival.packet.captureTimeNanos < SynchronizedPlayer.targetLatencyNanos)
        }
    }

    @Test func submissionLedgerRejectsDuplicateAndFallsBackOnOutOfOrderCompletion() throws {
        let wire = MissedRefillWire()
        let controls = SimulationControlPeers()
        let ready = DispatchSemaphore(value: 0)
        let host = HostServer(roomName: "Submission ledger", advertise: false,
            listenerReadyHandler: { controls.setHostPort($0); ready.signal() },
            outboundSend: { connection, data, complete, completion in
                if let packet = AudioPacket(data: data), case .hostPort(_, let port) = connection.endpoint {
                    wire.submit(port: port.rawValue, packet: packet, completion: completion)
                } else { connection.send(content: data, isComplete: complete, completion: .contentProcessed(completion)) }
            }, audioSendNowNanos: { wire.now }, audioAdmissionObservationForTesting: { wire.observe($0) },
            audioBackpressurePolicy: .boundedLatest(maxInFlight: 3))
        defer { controls.stop(); host.stop() }
        try host.start(); try #require(ready.wait(timeout: .now() + 3) == .success)
        try controls.join(count: 1)
        let port = try #require(controls.ports.first)
        let anchor = MonotonicClock.nowNanos()
        func at(_ ms: UInt64) { wire.setNow(anchor + ms * 1_000_000) }
        func pulse(_ ms: UInt64, _ count: Int) {
            at(ms)
            host.acceptAudio(samples: [Int16](repeating: 1_024, count: count * 480), captureTimeNanos: wire.now - UInt64(count) * 5_000_000)
            _ = host.audioSenderSnapshot()
        }
        pulse(0, 2)
        // Deliver the actual captured callback out of order, then twice. This
        // is a defensive transport-contract test, not a native-ordering claim.
        let callback = try wire.takeCapturedCompletion(port: port, sequence: 1)
        at(10); callback(nil); _ = host.audioSenderSnapshot()
        pulse(11, 1)
        try #require(host.audioSenderSnapshot().first?.inFlight == 2)
        at(12); callback(nil); _ = host.audioSenderSnapshot()
        #expect(host.audioSenderSnapshot().first?.inFlight == 2)
        pulse(13, 1)
        let fallback = try #require(wire.observations.last)
        #expect(!fallback.cadenceOrderValid && fallback.submissionLedgerCount == 2 && fallback.inFlight == 2)
        #expect(fallback.completionGrowth == max(fallback.recentInterval, fallback.unfinishedInterval))
        for (sequence, ms) in [(UInt32(0), UInt64(20)), (2, 21), (3, 22)] {
            at(ms); try wire.complete(port: port, sequence: sequence); _ = host.audioSenderSnapshot()
        }
        pulse(23, 1)
        let recovered = try #require(wire.observations.last)
        #expect(recovered.fanoutIdle && recovered.cadenceOrderValid && recovered.submissionLedgerCount == 0)
        at(24); try wire.complete(port: port, sequence: 4); _ = host.audioSenderSnapshot()
        #expect(host.audioSenderSnapshot().first?.inFlight == 0 && wire.remaining == 0)
        #expect(wire.observations.allSatisfy { $0.submissionLedgerCount == $0.inFlight && $0.submissionLedgerCount <= 3 })
    }
    @Test func knownSerializedServiceShedsMeasuredBurstAndRecovers() throws {
        let wire = SimulatedAudioWire(bitsPerSecond: nil, serializedServiceNanos: 100_000_000)
        let controls = SimulationControlPeers()
        let evidence = MissedRefillWire()
        let ready = DispatchSemaphore(value: 0)
        let host = HostServer(roomName: "Known serialized service", advertise: false,
            listenerReadyHandler: { controls.setHostPort($0); ready.signal() },
            outboundSend: { connection, data, complete, completion in
                if let packet = AudioPacket(data: data) {
                    wire.submit(packet: packet, byteCount: data.count, endpoint: connection.endpoint, completion: completion)
                } else {
                    connection.send(content: data, isComplete: complete, completion: .contentProcessed(completion))
                }
            }, audioSendNowNanos: { wire.now },
            audioAdmissionObservationForTesting: { evidence.observe($0) },
            audioBackpressurePolicy: .boundedLatest(maxInFlight: 8))
        defer { controls.stop(); host.stop() }
        try host.start()
        try #require(ready.wait(timeout: .now() + 3) == .success)
        try controls.join(count: 1)
        let port = try #require(controls.ports.first)
        let anchor = MonotonicClock.nowNanos()
        func pulse(_ ms: UInt64, _ count: Int) {
            let now = anchor + ms * 1_000_000
            advance(wire, through: now, host: host)
            host.acceptAudio(samples: [Int16](repeating: 1_024, count: count * 240 * 2),
                captureTimeNanos: now - UInt64(count) * 5_000_000)
            _ = host.audioSenderSnapshot()
        }
        // Warm with real serialized sends, not injected estimator samples.
        // None of these bootstrap packets violates its source deadline.
        pulse(0, 1); pulse(50, 1); pulse(150, 1)
        advance(wire, through: anchor + 201_000_000, host: host)
        let warm = wire.snapshot
        try #require(warm.submitted[port] == [0, 1, 2])
        try #require(warm.arrivals[port]?[0]?.arrivedAt == anchor + 100_000_000)
        try #require(warm.arrivals[port]?[1]?.arrivedAt == anchor + 200_000_000)
        try #require(host.audioSenderSnapshot().first?.inFlight == 1)
        pulse(201, 7)
        let gate = try #require(evidence.observations.first { $0.ownerNanos == anchor + 201_000_000 })
        try #require(!gate.fanoutIdle && gate.estimatedDuration == 150_000_000 && gate.recentInterval == 100_000_000)
        advance(wire, through: anchor + 301_000_000, host: host)
        let measured = try #require(host.audioSenderSnapshot().first)
        #expect(measured.enqueued == 10 && measured.sent < 10, "Known serialized capacity requires measured-burst shedding")
        #expect(measured.pending == 0 && measured.inFlight == 0)
        pulse(301, 1)
        advance(wire, through: anchor + 1_300_000_000, host: host)
        let state = try #require(host.audioSenderSnapshot().first)
        let final = wire.snapshot
        let arrivals = final.arrivals[port, default: [:]]
        #expect(arrivals[10] != nil, "Fresh work recovers after real outstanding service drains")
        #expect(final.eventsRemaining == 0 && final.invalidEndpoints == 0 && state.pending == 0 && state.inFlight == 0)
        #expect(UInt64(arrivals.count) == state.sent)
        #expect(state.enqueued == state.sent + state.expiredWait + state.expiredAge + state.replaced + state.admissionRejected)
        for arrival in arrivals.values {
            #expect(arrival.arrivedAt - arrival.packet.captureTimeNanos < SynchronizedPlayer.targetLatencyNanos)
        }
        print("serialized control sent=\(state.sent) wait=\(state.expiredWait) replaced=\(state.replaced) rejected=\(state.admissionRejected)")
    }
    @Test(arguments: [UInt64(0), 179, 181])
    func fixedLatencyPipelineDeliversSevenPackets(finalPhase: UInt64) throws {
        // Predeclared equal-workload burst control and two paced phases straddle
        // the80ms pending-residence boundary. No adaptive timing or sample reuse.
        let wire = SimulatedAudioWire(bitsPerSecond: nil, fixedLatencyNanos: 100_000_000)
        let controls = SimulationControlPeers()
        let evidence = MissedRefillWire() // Observation storage only; never supplies completions.
        let ready = DispatchSemaphore(value: 0)
        let host = HostServer(roomName: "Fixed-latency pipeline", advertise: false,
            listenerReadyHandler: { controls.setHostPort($0); ready.signal() },
            outboundSend: { connection, data, complete, completion in
                if let packet = AudioPacket(data: data) {
                    wire.submit(packet: packet, byteCount: data.count,
                        endpoint: connection.endpoint, completion: completion)
                } else {
                    connection.send(content: data, isComplete: complete, completion: .contentProcessed(completion))
                }
            }, audioSendNowNanos: { wire.now },
            audioAdmissionObservationForTesting: { evidence.observe($0) },
            audioBackpressurePolicy: .boundedLatest(maxInFlight: 8))
        defer { controls.stop(); host.stop() }
        try host.start()
        try #require(ready.wait(timeout: .now() + 3) == .success)
        try controls.join(count: 1)
        let port = try #require(controls.ports.first)
        let anchor = MonotonicClock.nowNanos()
        let pulses: [(UInt64, Int)] = finalPhase == 0 ? [(0, 7)] : [(0, 2), (80, 2), (160, 2), (finalPhase, 1)]
        for (ms, count) in pulses {
            let now = anchor + ms * 1_000_000
            advance(wire, through: now, host: host)
            host.acceptAudio(samples: [Int16](repeating: 1_024, count: count * 240 * 2),
                captureTimeNanos: now - UInt64(count) * 5_000_000)
            let state = try #require(host.audioSenderSnapshot().first)
            #expect(state.inFlight <= 8)
            print("pipeline pulse phase=\(finalPhase) at=\(ms) sent=\(state.sent) inFlight=\(state.inFlight) pending=\(state.pending)")
        }
        advance(wire, through: anchor + 600_000_000, host: host)
        let state = try #require(host.audioSenderSnapshot().first)
        let snapshot = wire.snapshot
        let arrivals = snapshot.arrivals[port, default: [:]]
        try #require(snapshot.invalidEndpoints == 0 && snapshot.eventsRemaining == 0)
        try #require(state.enqueued == 7 && state.pending == 0 && state.inFlight == 0)
        try #require(UInt64(arrivals.count) == state.sent)
        #expect(state.enqueued == state.sent + state.expiredWait + state.expiredAge + state.replaced + state.admissionRejected)
        for arrival in arrivals.values {
            try #require(arrival.arrivedAt - arrival.admittedAt == 100_000_000,
                "The independently pipelined path has fixed actual per-send sojourn")
            #expect(arrival.arrivedAt - arrival.packet.captureTimeNanos < SynchronizedPlayer.targetLatencyNanos)
            print("pipeline wire phase=\(finalPhase) seq=\(arrival.packet.sequence) admitted=\(arrival.admittedAt - anchor) completed=\(arrival.arrivedAt - anchor)")
        }
        if finalPhase != 0 {
            // Observe the actual last assessment, without requiring a blocked
            // old head that a future scheduler correction may already admit.
            let actual = try #require(evidence.observations.last {
                $0.ownerNanos == anchor + finalPhase * 1_000_000
            })
            try #require(!actual.fanoutIdle && actual.inFlight > 0 && actual.inFlight < 8)
            try #require(actual.captureNanos <= actual.ownerNanos)
            #expect(actual.captureAge == actual.ownerNanos - actual.captureNanos)
            #expect(actual.admissionBudget == 225_000_000)
            #expect(actual.estimatedDuration == 100_000_000)
            print("pipeline gate phase=\(finalPhase) capture=\(actual.captureNanos - anchor) age=\(actual.captureAge) decision=\(actual.decision) inFlight=\(actual.inFlight) duration=\(actual.estimatedDuration) recent=\(actual.recentInterval) unfinished=\(actual.unfinishedInterval)")
        }
        print("pipeline final phase=\(finalPhase) received=\(arrivals.count) wait=\(state.expiredWait) age=\(state.expiredAge) replaced=\(state.replaced) rejected=\(state.admissionRejected)")
        #expect(arrivals.count == 7, "All seven source packets fit the fixed100ms pipeline and original source deadline")
    }
    @Test(arguments: [false, true])
    func conservativeBurstHistoryRetainsOriginalFIFO(hasEligibleYounger: Bool) throws {
        let wire = MissedRefillWire()
        let controls = SimulationControlPeers()
        let ready = DispatchSemaphore(value: 0)
        let host = HostServer(roomName: "Canonical younger FIFO", advertise: false,
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
            at(ms); try wire.complete(port: port, sequence: sequence)
            _ = host.audioSenderSnapshot()
        }
        at(0)
        host.acceptAudio(samples: [Int16](repeating: 1_024, count: 3 * 240 * 2), captureTimeNanos: anchor - 15_000_000)
        try #require(host.audioSenderSnapshot().allSatisfy { $0.sent == 3 && $0.inFlight == 3 })
        try complete(other, 0, 5)
        try complete(weak, 0, 10)
        try complete(other, 1, 15)
        try complete(other, 2, 25)
        try complete(weak, 1, 110)
        at(185)
        let added = hasEligibleYounger ? 4 : 2
        host.acceptAudio(samples: [Int16](repeating: 1_024, count: added * 240 * 2),
            captureTimeNanos: anchor + 155_000_000)
        let snapshot = try #require(host.audioSenderSnapshot().first { $0.udpPort == weak })
        try #require(wire.observations.contains {
            $0.port == weak && $0.captureNanos == anchor + 155_000_000
                && $0.decision == .deferred && $0.recentInterval == 100_000_000 && $0.inFlight == 1
        })
        // Identical old workload, intentionally migrated predicate expectation:
        // oldest outstanding age185 + growth100 *2 =385ms, not the former
        // max(duration110, interval100 *2). No retained younger can pass.
        #expect(wire.sequences(port: weak) == [0, 1, 2])
        #expect(snapshot.sent == 3 && snapshot.replaced == 0 && snapshot.pending == added)
        let blocked = try #require(wire.observations.last { $0.port == weak && $0.ownerNanos == anchor + 185_000_000 })
        #expect(blocked.projectedCompletion == 385_000_000 && blocked.completionGrowth == 100_000_000)
        #expect(snapshot.expiredWait == 0 && snapshot.expiredAge == 0 && snapshot.admissionRejected == 0)
        #expect(snapshot.enqueued == snapshot.sent + UInt64(snapshot.pending) + snapshot.replaced)
        for index in 0..<added { try complete(other, UInt32(3 + index), UInt64(186 + index)) }
        try complete(weak, 2, 190)
        do {
            // All other sends have completed too: the existing full-fanout
            // idle reset clears old service evidence and admits BOTH retained
            // packets. The earlier185ms no-trim assertion remains unchanged.
            #expect(wire.sequences(port: weak) == Array(UInt32(0)..<UInt32(3 + added)))
            let idleAdmission = try #require(wire.observations.first {
                $0.port == weak && $0.captureNanos == anchor + 155_000_000
                    && $0.ownerNanos == anchor + 190_000_000 && $0.decision == .admitted
            })
            #expect(idleAdmission.fanoutIdle && idleAdmission.inFlight == 0)
            #expect(idleAdmission.estimatedDuration == 0 && idleAdmission.recentInterval == 0)
            #expect(idleAdmission.lastCompletion == nil)
            for index in 0..<added { try complete(weak, UInt32(3 + index), UInt64(191 + index)) }
            let final = try #require(host.audioSenderSnapshot().first { $0.udpPort == weak })
            #expect(final.enqueued == UInt64(3 + added) && final.sent == UInt64(3 + added) && final.replaced == 0)
            #expect(final.inFlight == 0 && final.pending == 0 && wire.remaining == 0)
        }
    }
    @Test func failedTimingDoesNotBlockCanonicalEligibleYoungerPacket() throws {
        let trace = RecordedFairRoundTiming.failed
        try #require(trace.wakes.count == 50 && trace.dispatchLate.count == 541)
        try #require(trace.completionDelay.count == trace.dispatchLate.count && trace.controls.count == 108)
        let room = try simulate(peers: 8, rate: 4_000_000,
            policy: .boundedLatest(maxInFlight: 8), oversleep: 0,
            globalTiming: trace, rejectHeadOfLineDeferral: true)
        #expect(room.minimumPackets >= 50)
        #expect(room.maximumAge < SynchronizedPlayer.targetLatencyNanos)
    }
    @Test func independentSlowPathDoesNotReduceHealthyDelivery() throws {
        // Seven independent fast paths and one independently serialized 400 kbps
        // path. No shared link reservation or global dispatch ordering couples
        // the slow peer to the others. The sender/gates/accounting are real.
        let room = try simulate(peers: 8, rate: nil,
            policy: .boundedLatest(maxInFlight: 8), oversleep: 0,
            independentSlowPeerRate: 400_000)
        for peer in 1..<8 {
            #expect(room.packetCountsByParticipant["virtual-peer-\(peer)"] == 200,
                "An independently slow peer must not cost healthy listeners source packets")
        }
        let slowCount = try #require(room.packetCountsByParticipant["virtual-peer-0"])
        #expect(slowCount > 0 && slowCount < 200,
            "The independent slow path must actually exercise bounded shedding")
        #expect(room.maximumAge < SynchronizedPlayer.targetLatencyNanos)

    }
    @Test(arguments: [false, true])
    func otherPeerCompletionRespectsCanonicalEligibility(pacedThirdSubmission: Bool) throws {
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
        let initialCount = pacedThirdSubmission ? 2 : 3
        host.acceptAudio(samples: [Int16](repeating: 1_024, count: initialCount * 240 * 2), captureTimeNanos: anchor - UInt64(initialCount) * 5_000_000)
        try #require(host.audioSenderSnapshot().allSatisfy { $0.sent == UInt64(initialCount) && $0.inFlight == initialCount })
        // Per-peer callbacks remain FIFO. No reversed callback or extra-owner delay.
        try complete(other, 0, 5)
        try complete(weak, 0, 10)
        try complete(other, 1, 15)
        if pacedThirdSubmission {
            at(75)
            host.acceptAudio(samples: [Int16](repeating: 1_024, count: 480), captureTimeNanos: anchor + 70_000_000)
            try #require(host.audioSenderSnapshot().allSatisfy { $0.sent == 3 })
            let paced = try #require(wire.observations.first {
                $0.port == weak && $0.ownerNanos == anchor + 75_000_000 && $0.decision == .admitted
            })
            try #require(paced.projectedCompletion == 205_000_000 && paced.inFlight == 1)
            try complete(other, 2, 85)
        } else {
            try complete(other, 2, 25)
        }
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
        #expect(missed.sent == (pacedThirdSubmission ? 4 : 3),
            "Other-peer completion must reconsider the peer, but only admit a canonically eligible head")
        let reconsidered = try #require(wire.observations.last {
            $0.port == weak && $0.captureNanos == pendingCapture && $0.ownerNanos == anchor + 201_000_000
        })
        #expect(reconsidered.projectedCompletion == (pacedThirdSubmission ? 138_000_000 : 363_000_000))
        #expect(reconsidered.completionGrowth == (pacedThirdSubmission ? 6_000_000 : 81_000_000))
        #expect(reconsidered.decision == (pacedThirdSubmission ? .admitted : .deferred))

        // Same-clock production-gate control, not a copied eligibility predicate.
        // Adding a successor wakes drainAudio without altering the old packet's
        // timestamp, clock, in-flight count, or remaining budget.
        host.acceptAudio(samples: [Int16](repeating: 1_024, count: 240 * 2), captureTimeNanos: anchor + 196_000_000)
        _ = host.audioSenderSnapshot()
        let assessed = try #require(wire.observations.last {
            $0.port == weak && $0.captureNanos == pendingCapture && $0.ownerNanos == anchor + 201_000_000
        })
        try #require(assessed.inFlight == 1 && assessed.captureAge == 36_000_000)
        try #require(assessed.queueResidence == 6_000_000 && assessed.admissionBudget == 225_000_000)
        try #require(assessed.recentInterval == 0 && assessed.estimatedDuration == 0)
        try #require(assessed.unfinishedInterval == 81_000_000)
        #expect(assessed.decision == (pacedThirdSubmission ? .admitted : .deferred))
        // The new successor also fits in the paced case:126+6*3=144ms
        // versus220ms remaining. Preserve its actual immediate admission.
        #expect(wire.sequences(port: weak) == (pacedThirdSubmission ? [0, 1, 2, 3, 4] : [0, 1, 2]))
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
        print("FIFO refill paced=\(pacedThirdSubmission): sentAfterOther=\(missed.sent), same-clock decision=\(assessed.decision), projection=\(assessed.projectedCompletion), age=\(assessed.captureAge); all10 sends completed FIFO")
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

    @Test(arguments: Array(UInt64(0)..<UInt64(32)) + [UInt64(41)])
    func predeclaredDispatchSeedRangePreservesEveryListenerFloor(seed: UInt64) throws {
        // Fixed exhaustive range declared before candidate evaluation, not a
        // selected passing subset or a retry policy. Keep the original four
        // seeds separately for direct comparison with earlier evidence.
        let room = try simulate(peers: 8, rate: 4_000_000,
            policy: .boundedLatest(maxInFlight: 8), oversleep: 0,
            irregularDispatchSeed: seed, includesControlTraffic: true, conciseOutput: true)
        #expect(room.minimumPackets >= 50)
        #expect(room.maximumAge < SynchronizedPlayer.targetLatencyNanos)
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
                          allocationTrace: RefillAllocationTrace? = nil,
                          globalTiming: RecordedFairRoundTiming.Trace? = nil,
                          independentSlowPeerRate: UInt64? = nil,
                          rejectHeadOfLineDeferral: Bool = false,
                          conciseOutput: Bool = false) throws -> SimulatedRoomResult {
        let wire = SimulatedAudioWire(bitsPerSecond: rate, callbackQuantumNanos: callbackQuantumNanos,
            irregularDispatchSeed: irregularDispatchSeed, recordedTiming: recordedTiming, globalTiming: globalTiming)
        let controls = SimulationControlPeers()
        let globalEvidence = globalTiming != nil ? GlobalGateEvidence() : nil
        let admissionObserver: ((HostServer.AudioAdmissionObservation) -> Void)? =
            allocationTrace != nil || globalEvidence != nil ? { value in
                allocationTrace?.observe(value)
                globalEvidence?.observe(value)
            } : nil
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
            audioAdmissionObservationForTesting: admissionObserver,
            audioBackpressurePolicy: policy)
        defer { controls.stop(); host.stop() }
        try host.start()
        try #require(hostReady.wait(timeout: .now() + 3) == .success, "Real host listener did not start")
        try controls.join(count: lateJoinAtCallback == nil ? count : count - 1)
        if let independentSlowPeerRate {
            try #require(rate == nil && globalTiming == nil && !recordedTiming)
            let slowPort = try #require(controls.peerIndices.first { $0.value == 0 }?.key)
            wire.configureIndependentSlowPath(port: slowPort, rate: independentSlowPeerRate)
        }

        // The source clock is anchored only after real handshakes finish. Real
        // elapsed time thereafter never advances this clock or the wire events.
        let anchor = MonotonicClock.nowNanos()
        wire.setNow(anchor)
        wire.configureGlobalControls(anchor: anchor)
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
            if let globalTiming { captureWake = nominalDeadline + globalTiming.wakes[callback] }
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
        if let globalTiming {
            globalEvidence?.dump(name: globalTiming.name, anchor: anchor, peers: controls.peerIndices)
            try #require(globalEvidence?.overflowed == false)
            print("Global FIFO trace \(globalTiming.name): consumed=\(state.globalSamplesConsumed)/\(globalTiming.dispatchLate.count), exhausted=\(state.globalSamplesExhausted), controls=\(state.globalControlsConsumed)/\(globalTiming.controls.count); finite workload replay, not exact CI execution")
            let exhausted = state.globalSamplesExhausted
            try #require(!exhausted,
                "Finite timing sample exhaustion is an inconclusive replay prerequisite, not an audio-policy RED")
            try #require(state.globalControlsConsumed == globalTiming.controls.count)
            if rejectHeadOfLineDeferral {
                let witnesses = try #require(globalEvidence?.headOfLineCount)
                #expect(witnesses == 0,
                    "A deferred head must not block a fresh retained younger packet passing the canonical gate at the same time and credit count")
            }
        }
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
        if conciseOutput {
            print("Fixed seed=\(irregularDispatchSeed.map(String.init) ?? "none") minimum=\(result.minimumPackets) maximum=\(result.maximumPackets) maxAge=\(result.maximumAge) maxDeadlineMiss=\(result.maximumDeadlineMiss) counts=\(result.packetCountsByParticipant.sorted { $0.key < $1.key }.map(\.value))")
        } else {
            print("Virtual real-host peers=\(count) rate=\(rate.map(String.init) ?? "direct") policy=\(policy) wake=\(oversleep / 1_000_000)ms dispatchSeed=\(irregularDispatchSeed.map(String.init) ?? "none") mixedControl=\(includesControlTraffic) recordedTiming=\(recordedTiming): \(result); senderAccounting=\(senders)")
        }
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

private final class GlobalGateEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HostServer.AudioAdmissionObservation] = []
    private var dropped = false
    var overflowed: Bool { lock.withLock { dropped } }
    var headOfLineCount: Int { lock.withLock { values.filter { $0.youngerCandidate != nil }.count } }
    func observe(_ value: HostServer.AudioAdmissionObservation) {
        lock.withLock {
            if values.count < 12_000 { values.append(value) } else { dropped = true }
        }
    }
    func dump(name: String, anchor: UInt64, peers: [UInt16: Int]) {
        let snapshot = lock.withLock { values }
        func captureOffset(_ value: UInt64) -> String {
            value >= anchor ? String(value - anchor) : "-\(anchor - value)"
        }
        print("Global gate evidence \(name) retained=\(snapshot.count) overflow=\(overflowed); name,peer,ownerOffset,age,budget,duration,recent,unfinished,inFlight,pending,decision,round,residence,supersededPrefixCount")
        for v in snapshot {
            print("globalgate,\(name),\(peers[v.port] ?? -1),\(v.ownerNanos - anchor),\(v.captureAge),\(v.admissionBudget),\(v.estimatedDuration),\(v.recentInterval),\(v.unfinishedInterval),\(v.inFlight),\(v.pending),\(v.decision.rawValue),\(v.completionRound ?? -1),\(v.queueResidence),\(v.supersededPrefixCount)")
            if let younger = v.youngerCandidate {
                print("globalhol,\(name),\(peers[v.port] ?? -1),\(v.ownerNanos - anchor),\(captureOffset(v.captureNanos)),\(captureOffset(younger.captureNanos)),\(younger.pendingIndex),\(younger.pendingCount),\(v.ownerNanos - younger.enqueuedNanos),\(v.inFlight)")
            }
        }
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
    func takeCapturedCompletion(port: UInt16, sequence: UInt32) throws -> (NWError?) -> Void {
        let callback = lock.withLock { () -> ((NWError?) -> Void)? in
            guard let index = callbacks[port]?.firstIndex(where: { $0.0 == sequence }) else { return nil }
            return callbacks[port]?.remove(at: index).1
        }
        return try #require(callback)
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
        let globalSamplesConsumed: Int
        let globalSamplesExhausted: Bool
        let globalControlsConsumed: Int
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
    private let globalTiming: RecordedFairRoundTiming.Trace?
    private var globalSamplesExhausted = false
    private var globalControls: [(time: UInt64, bytes: Int)] = []
    private var globalControlIndex = 0
    private var lastCompletionByPort: [UInt16: UInt64] = [:]
    private var independentSlowPath: (port: UInt16, rate: UInt64, available: UInt64)?
    private let fixedLatencyNanos: UInt64?
    private let serializedServiceNanos: UInt64?
    init(bitsPerSecond: UInt64?, callbackQuantumNanos: UInt64? = nil,
         irregularDispatchSeed: UInt64? = nil, recordedTiming: Bool = false,
         globalTiming: RecordedFairRoundTiming.Trace? = nil, fixedLatencyNanos: UInt64? = nil,
         serializedServiceNanos: UInt64? = nil) {
        precondition(fixedLatencyNanos == nil || serializedServiceNanos == nil)
        precondition((fixedLatencyNanos == nil && serializedServiceNanos == nil) || (bitsPerSecond == nil && callbackQuantumNanos == nil
            && irregularDispatchSeed == nil && !recordedTiming && globalTiming == nil))
        self.fixedLatencyNanos = fixedLatencyNanos
        self.serializedServiceNanos = serializedServiceNanos
        self.bitsPerSecond = bitsPerSecond
        self.callbackQuantumNanos = callbackQuantumNanos
        self.dispatchRandomState = irregularDispatchSeed
        self.recordedTiming = recordedTiming
        self.globalTiming = globalTiming
    }
    func configureGlobalControls(anchor: UInt64) {
        lock.withLock {
            globalControls = globalTiming?.controls.map { (anchor + $0.offset, $0.bytes) } ?? []
        }
    }
    func configureIndependentSlowPath(port: UInt16, rate: UInt64) {
        precondition(rate > 0 && bitsPerSecond == nil && globalTiming == nil)
        lock.withLock { independentSlowPath = (port, rate, 0) }
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
            invalidEndpoints: invalidEndpoints, globalSamplesConsumed: nextOrder,
            globalSamplesExhausted: globalSamplesExhausted, globalControlsConsumed: globalControlIndex)
    } }

    func submit(packet: AudioPacket, byteCount: Int, endpoint: NWEndpoint,
                completion: @escaping (NWError?) -> Void) {
        lock.withLock {
            guard case .hostPort(_, let port) = endpoint else { invalidEndpoints += 1; return }
            if let globalTiming, nextOrder >= globalTiming.dispatchLate.count {
                globalSamplesExhausted = true
                return // No invented/cycled sample; caller fails the explicit prerequisite.
            }
            var delivery: UInt64
            if let fixedLatencyNanos {
                // Independent concurrent transport: no shared service queue.
                delivery = current + fixedLatencyNanos
            } else if let serializedServiceNanos {
                linkAvailable = max(current, linkAvailable) + serializedServiceNanos
                delivery = linkAvailable
            } else if var slow = independentSlowPath, slow.port == port.rawValue {
                let duration = (UInt64(byteCount) * 8 * 1_000_000_000 + slow.rate - 1) / slow.rate
                slow.available = max(current, slow.available) + duration
                independentSlowPath = slow
                delivery = slow.available + 1_000_000
            } else if let rate = bitsPerSecond {
                // Ceiling division preserves the specified aggregate wire rate.
                let duration = (UInt64(byteCount) * 8 * 1_000_000_000 + rate - 1) / rate
                linkAvailable = max(current, linkAvailable) + duration
                let serializedDelivery = linkAvailable + (globalTiming == nil ? 1_000_000 : 0)
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
            var actualArrivalTime = arrivalTime
            if let globalTiming {
                delivery = max(lastDispatch, delivery + globalTiming.dispatchLate[nextOrder])
                lastDispatch = delivery
                actualArrivalTime = delivery
                delivery = max(delivery + globalTiming.completionDelay[nextOrder],
                    lastCompletionByPort[port.rawValue] ?? 0)
                lastCompletionByPort[port.rawValue] = delivery
            }
            if recordedTiming {
                let index = nextOrder % RecordedFanoutTiming.completionDelayNanos.count
                delivery += RecordedFanoutTiming.completionDelayNanos[index]
                delivery = max(delivery, lastCompletionByPort[port.rawValue] ?? 0)
                lastCompletionByPort[port.rawValue] = delivery
            }
            submitted[port.rawValue, default: []].append(packet.sequence)
            events.append(Event(time: delivery, arrivalTime: actualArrivalTime, order: nextOrder, port: port.rawValue,
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
            while globalControlIndex < globalControls.count {
                let control = globalControls[globalControlIndex]
                guard control.time <= deadline,
                      control.time <= (events.map(\.time).min() ?? UInt64.max) else { break }
                current = control.time
                if let rate = bitsPerSecond {
                    let duration = (UInt64(control.bytes) * 8 * 1_000_000_000 + rate - 1) / rate
                    linkAvailable = max(current, linkAvailable) + duration
                }
                globalControlIndex += 1
            }
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
