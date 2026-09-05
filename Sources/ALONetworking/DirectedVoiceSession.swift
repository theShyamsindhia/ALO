import Foundation
import Network

/// Directed E2E voice, independent of the room broadcaster and media timeline.
/// The receiver dials the transmitter; only an ongoing explicit local request
/// and its immutable recipient snapshot may grant a voice-only UDP ticket.
/// There are deliberately no microphone or implicit consent APIs here.
public final class DirectedVoiceSession: @unchecked Sendable {
    public enum State: Equatable, Sendable { case connecting, active, recovering, stopped }
    public struct Callbacks {
        public var pcm: (UUID, VoiceSessionIdentifier, UInt64, UInt64, Data, UInt64) -> Void
        public var state: (UUID, State) -> Void
        /// Unexpected publisher failure only, once on the voice executor after
        /// revocation. Apps must clear readiness and stop any local microphone;
        /// a later retry needs a new runtime and an explicit local user action.
        public var failed: (Error) -> Void
        public init(pcm: @escaping (UUID, VoiceSessionIdentifier, UInt64, UInt64, Data, UInt64) -> Void,
                    state: @escaping (UUID, State) -> Void = { _, _ in }, failed: @escaping (Error) -> Void = { _ in }) {
            self.pcm = pcm; self.state = state; self.failed = failed
        }
    }
    typealias Open = (UUID, @escaping (Result<VoiceControlConnection, Error>) -> Void) -> Void
    typealias Subscribe = (NWEndpoint, AuthenticatedChannelCredentials, MediaSubscriptionTicket,
                          @escaping (SecureMediaTransportState) -> Void, @escaping (Data) -> Void) throws -> (() -> Void)
    private struct Transmission { let session: VoiceSessionIdentifier; let recipients: Set<UUID> }
    private struct QueuedPCM { let packet: DirectedVoiceWire.Packet; let enqueued: UInt64 }
    private final class SendLease {
        let ticket: MediaSubscriptionTicket
        var validated = false
        var packets: [QueuedPCM] = []
        var busy = false
        init(_ ticket: MediaSubscriptionTicket) { self.ticket = ticket }
    }
    private final class HostPeer {
        let connection: VoiceControlConnection
        let deadline: UInt64
        var session: VoiceSessionIdentifier?
        var active: SendLease?, pending: SendLease?
        var pendingDeadline: UInt64 = 0
        var requests: [UUID: UInt64] = [:]
        init(_ connection: VoiceControlConnection, now: UInt64) { self.connection = connection; deadline = now + 5_000_000_000 }
    }
    private final class ReceiveLease {
        let ticket: MediaSubscriptionTicket
        let deadline: UInt64
        let expires: UInt64
        var cancel: (() -> Void)?
        init(_ ticket: MediaSubscriptionTicket, now: UInt64) {
            self.ticket = ticket; deadline = now + 8_000_000_000
            expires = now + UInt64(ticket.validForSeconds * 1_000_000_000)
        }
    }
    private final class Receiver {
        let peerID: UUID
        let session: VoiceSessionIdentifier
        var connection: VoiceControlConnection?
        var active: ReceiveLease?, pending: ReceiveLease?
        var opening: UUID?
        var openDeadline: UInt64 = 0
        var request: (id: UUID, deadline: UInt64)?
        var retryAt: UInt64 = 0
        var attempts = 0
        var nextPing: UInt64 = 0
        var pingID: UInt64 = 0
        var outstandingPing: UInt64?
        var lastPong: UInt64 = 0
        var highestSequence: UInt64?
        var recent = Set<UInt64>()
        init(peerID: UUID, session: VoiceSessionIdentifier) { self.peerID = peerID; self.session = session }
    }

    public let roomID: UUID
    public let localPeerID: UUID
    private let queue: DispatchQueue
    private let callbacks: Callbacks
    private let registry: MediaSubscriptionRegistry
    private let now: () -> UInt64
    private let open: Open
    private let subscribe: Subscribe
    private let sendDatagram: (Data, UUID, @escaping (Bool) -> Void) -> Void
    private let cancelDatagram: (UUID) -> Void
    private var publisher: SecureMediaDatagramPublisher?
    private var port: UInt16?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var transmission: Transmission?
    private var peers: [UUID: HostPeer] = [:]
    private var receivers: [UUID: Receiver] = [:]
    private var transportGeneration: UInt64 = 0
    private let ingressLock = NSLock()
    private var ingressSession: VoiceSessionIdentifier?
    private var nextSequence: UInt64 = 0
    private var ingress: [QueuedPCM] = []
    private var ingressScheduled = false
    private var seconds: TimeInterval { Double(now()) / 1_000_000_000 }

    convenience init(roomID: UUID, localPeerID: UUID, queue: DispatchQueue, callbacks: Callbacks,
                     open: @escaping Open) throws {
        let registry = MediaSubscriptionRegistry(limits: .init(maximumSubscriptions: 64, maximumPending: 32, maximumPerPeer: 2))
        let publisher = try SecureMediaDatagramPublisher(registry: registry, queue: queue)
        self.init(roomID: roomID, localPeerID: localPeerID, queue: queue, callbacks: callbacks,
            registry: registry, now: MonotonicClock.nowNanos, open: open,
            subscribe: { endpoint, credentials, ticket, state, pcm in
                let subscriber = try SecureMediaDatagramSubscriber(endpoint: endpoint, credentials: credentials, ticket: ticket, queue: queue)
                subscriber.onState = state
                subscriber.onPayload = { channel, bytes in if channel == .voice { pcm(bytes) } }
                subscriber.start(); return { subscriber.cancel() }
            }, sendDatagram: { publisher.send(payload: $0, sessionID: $1, channel: .voice, completion: $2) },
            cancelDatagram: { publisher.cancel(sessionID: $0) })
        self.publisher = publisher
        publisher.onReady = { [weak self] in self?.port = $0.rawValue }
        publisher.onSubscriptionValidated = { [weak self] in self?.validated($0) }
        publisher.onState = { [weak self] state in
            if state == .failed { self?.publisherFailed(SecurePeerChannelError.connectionFailed) }
            if state == .cancelled { self?.publisherFailed(SecurePeerChannelError.cancelled) }
        }
    }
    init(roomID: UUID, localPeerID: UUID, queue: DispatchQueue, callbacks: Callbacks,
         registry: MediaSubscriptionRegistry, now: @escaping () -> UInt64, open: @escaping Open,
         subscribe: @escaping Subscribe,
         sendDatagram: @escaping (Data, UUID, @escaping (Bool) -> Void) -> Void,
         cancelDatagram: @escaping (UUID) -> Void) {
        self.roomID = roomID; self.localPeerID = localPeerID; self.queue = queue; self.callbacks = callbacks
        self.registry = registry; self.now = now; self.open = open; self.subscribe = subscribe
        self.sendDatagram = sendDatagram; self.cancelDatagram = cancelDatagram
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
        publisher?.start()
    }
    /// Attach inline from MeshControlPlane's admitted-channel callback.
    public func attach(channel: SecurePeerChannel) {
        VoiceControlConnection.attach(channel, queue: queue) { [weak self] result in
            guard let self else { channel.cancel(); return }
            do { try self.addPeer(try result.get()) } catch { channel.cancel() }
        }
    }
    public func attach(channel: SecurePeerChannel, credentials: AuthenticatedChannelCredentials) {
        guard credentials.channelRole == .voiceControl else { channel.cancel(); return }
        channel.withAuthenticatedCredentials { [weak self] result in
            guard let self, (try? result.get()) === credentials else { channel.cancel(); return }
            self.attach(channel: channel)
        }
    }
    public func beginTransmitting(session: VoiceSessionIdentifier, recipients: Set<UUID>) {
        queue.async { self.beginOnQueue(session: session, recipients: recipients) }
    }
    func beginOnQueue(session: VoiceSessionIdentifier, recipients: Set<UUID>) {
        guard !stopped, session.isValid, !recipients.isEmpty, recipients.count <= 32, !recipients.contains(localPeerID) else { return }
        guard transmission?.session != session else { return } // Same intent cannot expand its recipients.
        for id in Array(peers.keys) { removePeer(id) }
        transmission = Transmission(session: session, recipients: recipients)
        ingressLock.withLock { ingressSession = session; nextSequence = 0; ingress.removeAll() }
    }
    public func endTransmitting(session: VoiceSessionIdentifier) {
        queue.async {
            guard self.transmission?.session == session else { return }
            self.transmission = nil
            self.ingressLock.withLock { self.ingressSession = nil; self.ingress.removeAll() }
            for id in Array(self.peers.keys) { self.removePeer(id) }
        }
    }
    /// Only call for an authenticated offer addressed to this local participant.
    /// Receiving audio never starts a microphone or reciprocal transmission.
    public func beginReceiving(from peerID: UUID, session: VoiceSessionIdentifier) {
        queue.async { self.receiveOnQueue(from: peerID, session: session) }
    }
    func receiveOnQueue(from peerID: UUID, session: VoiceSessionIdentifier) {
        guard !stopped, peerID != localPeerID, session.isValid else { return }
        if receivers[peerID]?.session == session { return }
        guard receivers[peerID] != nil || receivers.count < 32 else { return }
        if let old = receivers.removeValue(forKey: peerID) { retire(old) }
        receivers[peerID] = Receiver(peerID: peerID, session: session); tick()
    }
    public func endReceiving(from peerID: UUID, session: VoiceSessionIdentifier) {
        queue.async {
            guard let receiver = self.receivers[peerID], receiver.session == session else { return }
            self.receivers.removeValue(forKey: peerID); self.retire(receiver); self.callbacks.state(peerID, .stopped)
        }
    }
    /// Exactly 10 ms of 48 kHz mono little-endian Int16 PCM. At most eight fresh
    /// chunks and one drain job are retained across the real-time capture handoff.
    public func submitPCM16Mono(_ pcm: Data, captureTimeNanos: UInt64, session: VoiceSessionIdentifier) {
        guard pcm.count == DirectedVoiceWire.pcmBytes, captureTimeNanos <= UInt64(Int64.max) else { return }
        let schedule = ingressLock.withLock { () -> Bool in
            guard ingressSession == session, nextSequence < UInt64.max / 480 else { return false }
            let sequence = nextSequence; nextSequence += 1
            if ingress.count == 8 { ingress.removeFirst() }
            ingress.append(QueuedPCM(packet: .init(sequence: sequence, frameIndex: sequence * 480,
                captureTimeNanos: captureTimeNanos, pcm: pcm), enqueued: now()))
            guard !ingressScheduled else { return false }; ingressScheduled = true; return true
        }
        if schedule { queue.async { self.drainIngress() } }
    }
    public func stop() { queue.async { self.stopOnQueue() } }
    func publisherFailed(_ error: Error) { stopOnQueue(failure: error) }
    private func stopOnQueue(failure: Error? = nil) {
        guard !stopped else { return }; stopped = true; timer?.cancel(); timer = nil
        transmission = nil; ingressLock.withLock { ingressSession = nil; ingress.removeAll() }
        for id in Array(peers.keys) { removePeer(id) }
        let old = Array(receivers.values); receivers.removeAll()
        for receiver in old { retire(receiver); callbacks.state(receiver.peerID, .stopped) }
        registry.cancelAll(); publisher?.stop()
        if let failure { callbacks.failed(failure) }
    }
    func publisherReady(port: UInt16) { self.port = port }
    func addPeer(_ connection: VoiceControlConnection) throws {
        let credentials = connection.credentials
        guard !stopped, credentials.isActive, credentials.roomID == roomID, credentials.localPeerID == localPeerID,
              credentials.localRole == .responder, credentials.channelRole == .voiceControl,
              credentials.negotiated.initiatorCapabilities.contains(.voice), credentials.negotiated.responderCapabilities.contains(.voice),
              transmission?.recipients.contains(credentials.remotePeerID) == true else { throw SecureTransportError.invalidCredentials }
        guard peers.count < 32, !peers.values.contains(where: { $0.connection.credentials.remotePeerID == credentials.remotePeerID }) else {
            throw SecureTransportError.capacity
        }
        let peer = HostPeer(connection, now: now()), id = credentials.connectionID
        peers[id] = peer
        connection.payload = { [weak self, weak peer] message in if let peer { self?.receiveHost(message, peer: peer) } }
        connection.failed = { [weak self] in self?.removePeer(id) }
    }
    private func receiveHost(_ message: DirectedVoiceWire.Message, peer: HostPeer) {
        let credentials = peer.connection.credentials
        guard peers[credentials.connectionID] === peer, let transmission,
              transmission.recipients.contains(credentials.remotePeerID) else { removePeer(credentials.connectionID); return }
        switch message {
        case .ping(let id): peer.connection.send(.pong(id))
        case let .subscribe(id, session):
            guard session == transmission.session, peer.session == nil || peer.session == session,
                  peer.requests.count < 64, peer.requests[id] == nil, peer.pending == nil,
                  let port, transportGeneration < UInt64.max - 1 else { peer.connection.send(.reject(id)); return }
            peer.requests[id] = now() + 30_000_000_000; peer.session = session; transportGeneration += 1
            do {
                let ticket = try registry.reserveVoiceSubscription(credentials: credentials, session: session,
                    generation: transportGeneration, now: seconds)
                peer.pending = SendLease(ticket); peer.pendingDeadline = now() + 8_000_000_000
                peer.connection.send(.grant(id, session, ticket, port))
            } catch { peer.connection.send(.reject(id)) }
        case .ready(let id):
            guard let pending = peer.pending, pending.ticket.sessionID == id, pending.validated else { return }
            revoke(peer.active); peer.active = pending; peer.pending = nil
        default: removePeer(credentials.connectionID)
        }
    }
    func validated(_ sessionID: UUID) {
        for peer in peers.values where peer.pending?.ticket.sessionID == sessionID { peer.pending?.validated = true }
    }
    private func removePeer(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        revoke(peer.active); revoke(peer.pending); peer.connection.close()
    }
    private func revoke(_ lease: SendLease?) {
        guard let lease else { return }; lease.packets.removeAll(); registry.cancel(sessionID: lease.ticket.sessionID)
        cancelDatagram(lease.ticket.sessionID)
    }
    private func drainIngress() {
        let batch = ingressLock.withLock { () -> (VoiceSessionIdentifier?, [QueuedPCM]) in
            defer { ingress.removeAll(); ingressScheduled = false }; return (ingressSession, ingress)
        }
        guard !stopped, batch.0 == transmission?.session else { return }
        for item in batch.1 where fresh(item) {
            for peer in Array(peers.values) where peer.session == transmission?.session {
                for lease in [peer.active, peer.pending].compactMap({ $0 }) where lease.validated {
                    lease.packets.removeAll { !fresh($0) }
                    if lease.packets.count == 8 { lease.packets.removeFirst() }
                    lease.packets.append(item); drain(lease, peer: peer)
                }
            }
        }
    }
    private func fresh(_ item: QueuedPCM) -> Bool { now() >= item.enqueued && now() - item.enqueued < 80_000_000 }
    private func drain(_ lease: SendLease, peer: HostPeer) {
        guard !stopped, !lease.busy, peers[peer.connection.credentials.connectionID] === peer,
              peer.active === lease || peer.pending === lease else { return }
        lease.packets.removeAll { !fresh($0) }
        guard !lease.packets.isEmpty else { return }
        let item = lease.packets.removeFirst(); lease.busy = true
        sendDatagram(item.packet.encoded(), lease.ticket.sessionID) { [weak self, weak peer, weak lease] accepted in
            guard let self, let peer, let lease, self.peers[peer.connection.credentials.connectionID] === peer,
                  peer.active === lease || peer.pending === lease else { return }
            if !accepted, self.fresh(item) {
                if lease.packets.count == 8 { lease.packets.removeLast() }
                lease.packets.insert(item, at: 0)
                self.queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self, weak peer, weak lease] in
                    guard let self, let peer, let lease else { return }; lease.busy = false; self.drain(lease, peer: peer)
                }
            } else { lease.busy = false; self.drain(lease, peer: peer) }
        }
    }
    private func retire(_ lease: ReceiveLease?, credentials: AuthenticatedChannelCredentials?) {
        guard let lease else { return }; credentials?.retireSubscriberTicket(lease.ticket); lease.cancel?(); lease.cancel = nil
    }
    private func retire(_ receiver: Receiver) {
        receiver.opening = nil
        let connection = receiver.connection; receiver.connection = nil
        retire(receiver.active, credentials: connection?.credentials); retire(receiver.pending, credentials: connection?.credentials)
        receiver.active = nil; receiver.pending = nil; receiver.request = nil; connection?.close()
    }
    private func fail(_ receiver: Receiver) {
        guard receivers[receiver.peerID] === receiver else { return }
        retire(receiver); receiver.attempts = min(6, receiver.attempts + 1)
        receiver.retryAt = now() + UInt64(min(15, 0.5 * pow(2, Double(receiver.attempts - 1))) * 1_000_000_000)
        callbacks.state(receiver.peerID, .recovering)
    }
    func tick() {
        guard !stopped else { return }
        let time = now()
        for (id, peer) in Array(peers) {
            peer.requests = peer.requests.filter { $0.value > time }
            peer.connection.tick()
            guard peers[id] === peer else { continue }
            if !peer.connection.credentials.isActive || transmission?.recipients.contains(peer.connection.credentials.remotePeerID) != true ||
                (peer.session == nil && time >= peer.deadline) { removePeer(id); continue }
            if let pending = peer.pending, pending.ticket.expiresAt <= seconds || time >= peer.pendingDeadline {
                revoke(pending); peer.pending = nil
            }
            if let active = peer.active, active.ticket.expiresAt <= seconds { revoke(active); peer.active = nil }
            for lease in [peer.active, peer.pending].compactMap({ $0 }) { drain(lease, peer: peer) }
        }
        registry.expire(now: seconds)
        for receiver in Array(receivers.values) { tick(receiver, time: time) }
    }
    private func tick(_ receiver: Receiver, time: UInt64) {
        if receiver.opening != nil, time >= receiver.openDeadline { fail(receiver) }
        guard let connection = receiver.connection else {
            if receiver.opening == nil, time >= receiver.retryAt { open(receiver) }; return
        }
        connection.tick(); guard receiver.connection === connection else { return }
        if time < receiver.lastPong || time - receiver.lastPong >= 10_000_000_000 { fail(receiver); return }
        if let active = receiver.active, active.expires <= time { retire(active, credentials: connection.credentials); receiver.active = nil }
        if let pending = receiver.pending, pending.expires <= time || pending.deadline <= time {
            retire(pending, credentials: connection.credentials); receiver.pending = nil; receiver.retryAt = time + 1_000_000_000
        }
        if receiver.request.map({ $0.deadline <= time }) == true { receiver.request = nil; receiver.retryAt = time + 1_000_000_000 }
        if time >= receiver.nextPing, receiver.pingID < .max {
            receiver.pingID += 1; receiver.outstandingPing = receiver.pingID
            receiver.nextPing = time + 2_000_000_000; connection.send(.ping(receiver.pingID))
        }
        if receiver.request == nil, receiver.pending == nil, time >= receiver.retryAt,
           receiver.active == nil || receiver.active!.expires <= time + 10_000_000_000 {
            let id = UUID(); receiver.request = (id, time + 8_000_000_000)
            connection.send(.subscribe(id, receiver.session))
        }
    }
    private func open(_ receiver: Receiver) {
        let token = UUID(); receiver.opening = token; receiver.openDeadline = now() + 25_000_000_000
        callbacks.state(receiver.peerID, receiver.attempts == 0 ? .connecting : .recovering)
        open(receiver.peerID) { [weak self, weak receiver] result in
            guard let self, let receiver, !self.stopped, self.receivers[receiver.peerID] === receiver, receiver.opening == token else {
                if case .success(let connection) = result { connection.close() }; return
            }
            receiver.opening = nil
            do {
                let connection = try result.get(), credentials = connection.credentials
                guard credentials.isActive, credentials.roomID == self.roomID, credentials.localPeerID == self.localPeerID,
                      credentials.remotePeerID == receiver.peerID, credentials.localRole == .initiator,
                      credentials.channelRole == .voiceControl, credentials.negotiated.initiatorCapabilities.contains(.voice),
                      credentials.negotiated.responderCapabilities.contains(.voice) else {
                    connection.close(); throw SecureTransportError.invalidCredentials
                }
                receiver.connection = connection; receiver.lastPong = self.now(); receiver.nextPing = self.now()
                connection.failed = { [weak self, weak receiver] in if let receiver { self?.fail(receiver) } }
                connection.payload = { [weak self, weak receiver] message in if let receiver { self?.receive(message, receiver: receiver) } }
                self.tick(receiver, time: self.now())
            } catch { self.fail(receiver) }
        }
    }
    private func receive(_ message: DirectedVoiceWire.Message, receiver: Receiver) {
        guard receivers[receiver.peerID] === receiver, let connection = receiver.connection else { return }
        switch message {
        case .pong(let id):
            if receiver.outstandingPing == id { receiver.outstandingPing = nil; receiver.lastPong = now() }
        case .reject(let id):
            if receiver.request?.id == id { receiver.request = nil; receiver.retryAt = now() + 1_000_000_000 }
        case let .grant(id, session, ticket, port):
            guard receiver.request?.id == id, receiver.request!.deadline > now(), receiver.pending == nil,
                  session == receiver.session, ticket.roomID == roomID, ticket.senderID == receiver.peerID,
                  ticket.receiverID == localPeerID, ticket.channels == [.voice], ticket.broadcasterEpoch == session.generation else { fail(receiver); return }
            do { try connection.credentials.validate(ticket: ticket, subscriber: true) } catch { fail(receiver); return }
            receiver.request = nil
            let lease = ReceiveLease(ticket, now: now()); receiver.pending = lease
            connection.resolve(port) { [weak self, weak receiver, weak lease] result in
                guard let self, let receiver, let lease, self.receivers[receiver.peerID] === receiver,
                      receiver.connection === connection, receiver.pending === lease else { return }
                do {
                    let cancel = try self.subscribe(try result.get(), connection.credentials, ticket,
                        { [weak self, weak receiver, weak lease] state in
                            guard let self, let receiver, let lease, self.receivers[receiver.peerID] === receiver,
                                  receiver.active === lease || receiver.pending === lease else { return }
                            if state == .failed || state == .cancelled { self.fail(receiver) }
                        }, { [weak self, weak receiver, weak lease] bytes in
                            if let receiver, let lease { self?.receivePCM(bytes, receiver: receiver, lease: lease) }
                        })
                    if self.receivers[receiver.peerID] === receiver, receiver.connection === connection,
                       receiver.pending === lease || receiver.active === lease { lease.cancel = cancel }
                    else { cancel() }
                } catch { self.fail(receiver) }
            }
        default: fail(receiver)
        }
    }
    private func receivePCM(_ data: Data, receiver: Receiver, lease: ReceiveLease) {
        guard !stopped, receivers[receiver.peerID] === receiver, let connection = receiver.connection,
              connection.credentials.isActive, lease.expires > now(), receiver.active === lease || receiver.pending === lease else { return }
        let packet: DirectedVoiceWire.Packet
        do { packet = try .decode(data) } catch { fail(receiver); return }
        if receiver.pending === lease {
            let old = receiver.active; receiver.active = lease; receiver.pending = nil; receiver.attempts = 0
            connection.send(.ready(lease.ticket.sessionID)); retire(old, credentials: connection.credentials)
            callbacks.state(receiver.peerID, .active)
        }
        if let highest = receiver.highestSequence, packet.sequence < highest, highest - packet.sequence > 128 { return }
        guard receiver.recent.insert(packet.sequence).inserted else { return }
        receiver.highestSequence = max(receiver.highestSequence ?? 0, packet.sequence)
        let highest = receiver.highestSequence!
        receiver.recent = receiver.recent.filter { $0 >= highest || highest - $0 <= 128 }
        callbacks.pcm(receiver.peerID, receiver.session, packet.sequence, packet.frameIndex, packet.pcm, packet.captureTimeNanos)
    }
}
