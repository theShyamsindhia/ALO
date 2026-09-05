import Foundation
import Network

public enum SecureMediaTransportState: Equatable, Sendable {
    case idle, connecting, validating, active, failed, cancelled
}

/// Publisher owns this registry and its listener lifecycle. All registry access must use
/// this serial queue. Per-flow queues have one outstanding send and at most eight pending
/// datagrams, with expiry; one slow receiver cannot accumulate work for another receiver.
public final class SecureMediaDatagramPublisher: @unchecked Sendable {
    public static let serviceType = "_alo-data._udp"
    public var onReady: ((NWEndpoint.Port) -> Void)?
    public var onState: ((SecureMediaTransportState) -> Void)?
    public var onSubscriptionValidated: ((UUID) -> Void)?
    private struct Packet { let bytes: Data; let expiresAt: TimeInterval }
    private final class Flow {
        let id = UUID()
        let connection: NWConnection
        let deadline: TimeInterval
        var sessionID: UUID?
        var probe: Data?, challenge: Data?, response: Data?, confirmation: Data?
        var validated = false
        var pending = [Packet]()
        var sending = false
        var cancelled = false
        init(connection: NWConnection, now: TimeInterval) { self.connection = connection; deadline = now + 10 }
    }
    private let registry: MediaSubscriptionRegistry
    private let listener: NWListener
    private let queue: DispatchQueue
    private var flows: [UUID: Flow] = [:]
    private var sessions: [UUID: UUID] = [:]
    private var generation: UInt64 = 0
    private var started = false, stopped = false
    private var sweeper: DispatchSourceTimer?
    private var admissions = [TimeInterval]()
    private let now: () -> TimeInterval

    public init(registry: MediaSubscriptionRegistry, queue: DispatchQueue, port: NWEndpoint.Port = .any,
                serviceName: String? = nil, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.registry = registry; self.queue = queue; self.now = now
        listener = try NWListener(using: SecureNetworkParameters.udp(), on: port)
        if let serviceName { listener.service = NWListener.Service(name: serviceName, type: Self.serviceType) }
    }
    public func start() {
        queue.async {
            guard !self.started, !self.stopped else { return }
            self.started = true; self.generation += 1; let generation = self.generation
            self.onState?(.connecting)
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == generation, !self.stopped else { connection.cancel(); return }
                self.accept(connection, generation: generation)
            }
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == generation, !self.stopped else { return }
                switch state {
                case .ready: if let port = self.listener.port { self.onState?(.active); self.onReady?(port) }
                case .failed: self.stopOnQueue(failed: true)
                default: break
                }
            }
            let sweeper = DispatchSource.makeTimerSource(queue: self.queue)
            sweeper.schedule(deadline: .now() + 1, repeating: 1)
            sweeper.setEventHandler { [weak self] in self?.sweep(generation: generation) }
            self.sweeper = sweeper; sweeper.resume()
            self.listener.start(queue: self.queue)
        }
    }
    public func stop() { queue.async { self.stopOnQueue(failed: false) } }
    private func stopOnQueue(failed: Bool) {
        guard !stopped else { return }
        stopped = true; generation += 1; sweeper?.cancel(); sweeper = nil
        listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil; listener.cancel()
        for flow in Array(flows.values) { remove(flow) }
        registry.cancelAll(); onState?(failed ? .failed : .cancelled)
    }

    /// Completion reports whether the bounded local queue accepted the packet. UDP delivery
    /// remains best-effort. Expired or overfull audio is dropped without moving room timing.
    public func send(payload: Data, sessionID: UUID, channel: DatagramChannel,
                     completion: ((Bool) -> Void)? = nil) {
        queue.async {
            guard !self.stopped, let id = self.sessions[sessionID], let flow = self.flows[id], flow.validated,
                  payload.count <= SecureDatagram.maximumPayloadSize else { completion?(false); return }
            let now = self.now()
            flow.pending.removeAll { $0.expiresAt <= now }
            guard flow.pending.count < 8 else { completion?(false); return }
            do {
                let packet = try self.registry.sealMedia(payload, sessionID: sessionID, acceptedFlowID: flow.id, channel: channel, now: now)
                let lifetime: TimeInterval = channel == .timing ? 0.5 : (channel == .voice ? 0.08 : 0.05)
                // Enqueue regardless of whether the caller observes completion.
                // Optional chaining skips argument evaluation when it is nil.
                let accepted = self.enqueue(packet, flow: flow, expiresAt: now + lifetime)
                completion?(accepted)
            } catch {
                // Invalid caller input must not revoke an otherwise healthy subscription.
                if !self.registry.containsLiveSubscription(sessionID: sessionID, now: now) { self.remove(flow) }
                completion?(false)
            }
        }
    }
    public func cancel(sessionID: UUID) {
        queue.async {
            if let id = self.sessions[sessionID], let flow = self.flows[id] { self.remove(flow) }
            self.registry.cancel(sessionID: sessionID)
        }
    }
    private func accept(_ connection: NWConnection, generation: UInt64) {
        let time = now(); admissions.removeAll { time - $0 >= 1 }
        guard flows.count < 64, flows.values.filter({ !$0.validated }).count < 16, admissions.count < 32 else {
            connection.cancel(); return
        }
        admissions.append(time)
        let flow = Flow(connection: connection, now: time); flows[flow.id] = flow
        connection.stateUpdateHandler = { [weak self, weak flow] state in
            guard let self, let flow, self.generation == generation, !flow.cancelled else { return }
            switch state { case .failed, .cancelled: self.remove(flow); default: break }
        }
        connection.start(queue: queue); receive(flow, generation: generation)
    }
    private func receive(_ flow: Flow, generation: UInt64) {
        flow.connection.receiveMessage { [weak self, weak flow] data, _, _, error in
            guard let self, let flow, self.generation == generation, !flow.cancelled, !self.stopped else { return }
            if error != nil { self.remove(flow); return }
            if let data, data.count == MediaReturnPathProof.packetSize {
                self.processProof(data, flow: flow)
            }
            if !flow.cancelled { self.receive(flow, generation: generation) }
        }
    }
    private func processProof(_ data: Data, flow: Flow) {
        // Session bytes are only a bounded lookup hint until the registry verifies the MAC.
        let b = Array(data.dropFirst(8).prefix(16))
        let session = UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        guard flow.sessionID == nil || flow.sessionID == session else { return }
        do {
            if data[data.startIndex + 5] == 1, !flow.validated {
                if data == flow.probe, let challenge = flow.challenge {
                    _ = enqueue(challenge, flow: flow, expiresAt: flow.deadline); return
                }
                let challenge = try registry.receiveProbe(data, sessionID: session, acceptedFlowID: flow.id, now: now())
                flow.sessionID = session; flow.probe = data; flow.challenge = challenge
                _ = enqueue(challenge, flow: flow, expiresAt: flow.deadline)
            } else if data[data.startIndex + 5] == 3 {
                if flow.validated, data == flow.response, let confirmation = flow.confirmation {
                    _ = enqueue(confirmation, flow: flow, expiresAt: now() + 1); return
                }
                guard !flow.validated, flow.sessionID == session else { return }
                let confirmation = try registry.confirmReturnPathResponse(data, sessionID: session, acceptedFlowID: flow.id, now: now())
                flow.response = data; flow.confirmation = confirmation; flow.validated = true
                sessions[session] = flow.id
                _ = enqueue(confirmation, flow: flow, expiresAt: now() + 1)
                onSubscriptionValidated?(session)
            }
        } catch { /* Bad unauthenticated packets cannot tear down another admitted flow. */ }
    }
    @discardableResult private func enqueue(_ data: Data, flow: Flow, expiresAt: TimeInterval) -> Bool {
        guard !flow.cancelled, data.count <= SecureDatagram.maximumSize else { return false }
        flow.pending.removeAll { $0.expiresAt <= now() }
        guard flow.pending.count < 8 else { return false }
        flow.pending.append(Packet(bytes: data, expiresAt: expiresAt)); drain(flow)
        return true
    }
    private func drain(_ flow: Flow) {
        guard !flow.cancelled, !flow.sending else { return }
        flow.pending.removeAll { $0.expiresAt <= now() }
        guard !flow.pending.isEmpty else { return }
        let packet = flow.pending.removeFirst(); flow.sending = true
        let generation = self.generation
        flow.connection.send(content: packet.bytes, completion: .contentProcessed { [weak self, weak flow] error in
            guard let self, let flow, self.generation == generation, !flow.cancelled else { return }
            flow.sending = false
            if error != nil { self.remove(flow) } else { self.drain(flow) }
        })
    }
    private func sweep(generation: UInt64) {
        guard self.generation == generation, !stopped else { return }
        let time = now(); registry.expire(now: time)
        for flow in Array(flows.values) {
            if (!flow.validated && time >= flow.deadline) ||
                flow.sessionID.map({ !registry.containsLiveSubscription(sessionID: $0, now: time) }) == true { remove(flow) }
        }
    }
    private func remove(_ flow: Flow) {
        guard !flow.cancelled else { return }
        flow.cancelled = true; flow.pending.removeAll(); flow.connection.stateUpdateHandler = nil; flow.connection.cancel()
        flows.removeValue(forKey: flow.id)
        if let session = flow.sessionID, sessions[session] == flow.id { sessions.removeValue(forKey: session) }
        if let session = flow.sessionID { registry.cancel(sessionID: session) }
    }
}

/// Receiver-initiated UDP on the advertised datagram endpoint. Credentials and ticket must
/// come from the same admitted media-control channel. Owns retained per-channel replay state.
public final class SecureMediaDatagramSubscriber: @unchecked Sendable {
    public var onState: ((SecureMediaTransportState) -> Void)?
    public var onPayload: ((DatagramChannel, Data) -> Void)?
    private let connection: NWConnection
    private let credentials: AuthenticatedChannelCredentials
    private let ticket: MediaSubscriptionTicket
    private let queue: DispatchQueue
    private var state: SecureMediaTransportState = .idle
    private var generation: UInt64 = 0
    private var probe: Data?, response: Data?
    private var retries = 0
    private var openers: [DatagramChannel: DatagramOpener] = [:]
    private var timer: DispatchSourceTimer?
    private var deadline: TimeInterval = 0
    private let leaseDeadline: TimeInterval

    deinit {
        timer?.cancel()
        connection.cancel()
        credentials.retireSubscriberTicket(ticket)
    }

    public init(endpoint: NWEndpoint, credentials: AuthenticatedChannelCredentials, ticket: MediaSubscriptionTicket,
                queue: DispatchQueue) throws {
        if case .service(_, let type, _, _) = endpoint, type != SecureMediaDatagramPublisher.serviceType {
            throw SecureTransportError.wrongContext
        }
        try credentials.validate(ticket: ticket, subscriber: true)
        self.credentials = credentials; self.ticket = ticket; self.queue = queue
        leaseDeadline = ProcessInfo.processInfo.systemUptime + ticket.validForSeconds
        for channel in ticket.channels { openers[channel] = try credentials.makeSubscriberDatagramOpener(ticket: ticket, channel: channel) }
        connection = NWConnection(to: endpoint, using: SecureNetworkParameters.udp())
    }
    public func start() {
        queue.async {
            guard self.state == .idle else { return }
            self.generation += 1; let generation = self.generation
            self.transition(.connecting); self.deadline = ProcessInfo.processInfo.systemUptime + 15
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == generation, !self.terminal else { return }
                switch state {
                case .ready:
                    guard self.state == .connecting else { return }
                    do {
                        self.probe = try self.credentials.makeReturnPathProbe(ticket: self.ticket)
                        self.transition(.validating); self.deadline = ProcessInfo.processInfo.systemUptime + 5
                        self.transmitProof(); self.receive(generation: generation)
                    } catch { self.close(failed: true) }
                case .failed: self.close(failed: true)
                default: break
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, self.generation == generation, !self.terminal else { return }
                guard self.credentials.isActive else { self.close(failed: true); return }
                guard ProcessInfo.processInfo.systemUptime < self.leaseDeadline else { self.close(failed: true); return }
                if self.state != .active, ProcessInfo.processInfo.systemUptime >= self.deadline { self.close(failed: true) }
                else if self.state == .validating, self.retries < 3 { self.transmitProof() }
            }
            self.timer = timer; timer.resume(); self.connection.start(queue: self.queue)
        }
    }
    public func cancel() { queue.async { self.close(failed: false) } }
    private var terminal: Bool { state == .failed || state == .cancelled }
    private func transition(_ next: SecureMediaTransportState) { guard state != next else { return }; state = next; onState?(next) }
    private func close(failed: Bool) {
        guard !terminal else { return }
        generation += 1; timer?.cancel(); timer = nil; connection.stateUpdateHandler = nil; connection.cancel()
        credentials.retireSubscriberTicket(ticket)
        probe = nil; response = nil; openers.removeAll(); transition(failed ? .failed : .cancelled)
    }
    private func transmitProof() {
        guard let packet = response ?? probe, !terminal, retries < 3 else { return }
        retries += 1; let generation = self.generation
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == generation, !self.terminal else { return }
            if error != nil { self.close(failed: true) }
        })
    }
    private func receive(generation: UInt64) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.generation == generation, !self.terminal else { return }
            if error != nil { self.close(failed: true); return }
            if let data, data.count <= SecureDatagram.maximumSize { self.consume(data) }
            if !self.terminal { self.receive(generation: generation) }
        }
    }
    private func consume(_ data: Data) {
        do {
            if data.count == MediaReturnPathProof.packetSize, data.prefix(4) == Data([0x41,0x4c,0x4f,0x50]) {
                if data[data.startIndex + 5] == 2, state == .validating {
                    let response = try credentials.answerReturnPathChallenge(data, ticket: ticket)
                    if self.response == nil { self.response = response; retries = 0 }
                    guard self.response == response else { return }
                    transmitProof()
                } else if data[data.startIndex + 5] == 4, let response {
                    try credentials.verifyReturnPathConfirmation(data, response: response, ticket: ticket)
                    if state == .validating { transition(.active) }
                }
            } else if data.count >= 64, let channel = DatagramChannel(rawValue: data[data.startIndex + 5]),
                      let opener = openers[channel] {
                let payload = try opener.open(data)
                // Valid media itself also proves the publisher accepted the path response.
                if state == .validating, response != nil { transition(.active) }
                if state == .active { onPayload?(channel, payload) }
            }
        } catch { /* Authentication/replay failures are dropped, with replay state unchanged. */ }
    }
}
