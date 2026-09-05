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
                          oversleep: UInt64) throws -> SimulatedRoomResult {
        let wire = SimulatedAudioWire(bitsPerSecond: rate)
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
            }, audioSendNowNanos: { wire.now }, audioBackpressurePolicy: policy)
        defer { controls.stop(); host.stop() }
        try host.start()
        try #require(hostReady.wait(timeout: .now() + 3) == .success, "Real host listener did not start")
        try controls.join(count: count)

        // The source clock is anchored only after real handshakes finish. Real
        // elapsed time thereafter never advances this clock or the wire events.
        let anchor = MonotonicClock.nowNanos()
        wire.setNow(anchor)
        let sourceStart = anchor - 20_000_000
        let samples = [Int16](repeating: 1_024, count: 4 * 240 * 2)
        var captureWake = anchor
        for callback in 0..<50 {
            let nominalDeadline = anchor + UInt64(callback) * 20_000_000
            // Match the positive-wait oversleep/catch-up model: callbacks whose
            // deadlines were missed run together, without another injected wait.
            if captureWake < nominalDeadline { captureWake = nominalDeadline + oversleep }
            advance(wire, through: captureWake, host: host)
            host.acceptAudio(samples: samples, captureTimeNanos: nominalDeadline - 20_000_000)
            _ = host.audioSenderSnapshot() // Completes real packetization/enqueue at this event time.
        }
        advance(wire, through: anchor + 5_000_000_000, host: host)
        let state = wire.snapshot
        let senders = host.audioSenderSnapshot()
        let ports = controls.ports
        try #require(state.eventsRemaining == 0)
        try #require(state.invalidEndpoints == 0)
        try #require(senders.count == count && Set(senders.map(\.udpPort)) == Set(ports))
        try #require(Set(state.submitted.keys) == Set(ports))
        try #require(senders.allSatisfy { $0.inFlight == 0 && $0.pending == 0 })
        for sender in senders {
            #expect(sender.enqueued == 200)
            #expect(sender.sent == UInt64(state.submitted[sender.udpPort]?.count ?? 0))
            #expect(sender.sent + sender.expiredWait + sender.expiredAge + sender.admissionRejected + sender.replaced
                + sender.discardedBoundary == sender.enqueued)
            #expect(sender.discardedBoundary == 0)
        }

        var finalAges: [UInt64] = [], allAges: [UInt64] = [], deadlineMisses: [UInt64] = []
        var counts: [Int] = []
        var shared: Set<UInt32>?
        var reportedPeers: Set<String> = []
        for port in ports {
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
            // This is a transport deadline measurement, not a renderer model:
            // actual arrival minus the packet's own shared playout deadline.
            let deadlineMiss = arrivals.values.map { arrival -> UInt64 in
                let deadline = arrival.packet.captureTimeNanos + SynchronizedPlayer.targetLatencyNanos
                return arrival.arrivedAt > deadline ? arrival.arrivedAt - deadline : 0
            }.max() ?? 0
            deadlineMisses.append(deadlineMiss)
            shared = shared.map { $0.intersection(arrivals.keys) } ?? Set(arrivals.keys)
            switch policy {
            case .unbounded: #expect(last == 199)
            case .boundedLatest:
                // 16 packets at 5ms = the sender's 80ms pending-expiry budget.
                // Expired terminal audio is allowed, premature cessation is not.
                #expect(last >= 183)
                let boundaries = [sourceStart] + arrivals.values.map { $0.packet.captureTimeNanos }.sorted()
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
            maximumSkew: skew, resyncs: reportedPeers.count)
        print("Virtual real-host peers=\(count) rate=\(rate.map(String.init) ?? "direct") policy=\(policy) wake=\(oversleep / 1_000_000)ms: \(result)")
        return result
    }

    private func advance(_ wire: SimulatedAudioWire, through deadline: UInt64, host: HostServer) {
        while let event = wire.takeNext(through: deadline) {
            wire.deliver(event)
            event.completion(nil)
            // The callback invokes the real sender. Its queue hop can schedule
            // another wire event, which must be observed before advancing time.
            _ = host.audioSenderSnapshot()
        }
        wire.setNow(deadline)
    }

}

private struct SimulatedRoomResult {
    let finalAge: UInt64
    let maximumAge: UInt64
    let maximumDeadlineMiss: UInt64
    let minimumPackets: Int
    let maximumSkew: UInt64
    let resyncs: Int
}

/// Models the link, not HostServer's queue. Every scheduled event originated
/// from a real outboundSend and returns that exact production completion.
private final class SimulatedAudioWire: @unchecked Sendable {
    struct Arrival { let packet: AudioPacket; let admittedAt: UInt64; let arrivedAt: UInt64 }
    struct Event {
        let time: UInt64
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
    private var current = MonotonicClock.nowNanos()
    private var linkAvailable: UInt64 = 0
    private var nextOrder = 0
    private var events: [Event] = []
    private var submitted: [UInt16: [UInt32]] = [:]
    private var arrivals: [UInt16: [UInt32: Arrival]] = [:]
    private var invalidEndpoints = 0
    init(bitsPerSecond: UInt64?) { self.bitsPerSecond = bitsPerSecond }
    var now: UInt64 { lock.withLock { current } }
    func setNow(_ value: UInt64) { lock.withLock { current = value } }
    var snapshot: Snapshot { lock.withLock {
        Snapshot(submitted: submitted, arrivals: arrivals, eventsRemaining: events.count,
            invalidEndpoints: invalidEndpoints)
    } }

    func submit(packet: AudioPacket, byteCount: Int, endpoint: NWEndpoint,
                completion: @escaping (NWError?) -> Void) {
        lock.withLock {
            guard case .hostPort(_, let port) = endpoint else { invalidEndpoints += 1; return }
            let delivery: UInt64
            if let rate = bitsPerSecond {
                // Ceiling division preserves the specified aggregate wire rate.
                let duration = (UInt64(byteCount) * 8 * 1_000_000_000 + rate - 1) / rate
                linkAvailable = max(current, linkAvailable) + duration
                delivery = linkAvailable + 1_000_000
            } else {
                // Ideal fast-link baseline, not an OS scheduler reproduction.
                // Separate burst tests inject 60ms production callback stalls.
                delivery = current + 1_000_000
            }
            submitted[port.rawValue, default: []].append(packet.sequence)
            events.append(Event(time: delivery, order: nextOrder, port: port.rawValue,
                packet: packet, admittedAt: current, completion: completion))
            nextOrder += 1
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
            admittedAt: event.admittedAt, arrivedAt: event.time)
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
    private var stopped = false
    var ports: [UInt16] { lock.withLock { controls.keys.sorted() } }
    func setHostPort(_ port: NWEndpoint.Port) { lock.withLock { hostPort = port } }

    func join(count: Int) throws {
        let storedHostPort: NWEndpoint.Port? = lock.withLock { self.hostPort }
        let hostPort = try #require(storedHostPort)
        let videoPort = try listen(using: .tcp)
        for index in 0..<count {
            let udpPort = try listen(using: .udp)
            let id = "virtual-peer-\(index)"
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
