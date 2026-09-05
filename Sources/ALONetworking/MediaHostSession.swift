import Foundation
import Network
import ALOCore

/// Media-only publisher adapter. Every method and callback belongs to `queue`,
/// which MUST also own the attached SecurePeerChannels. Call attach directly in
/// onAuthenticated, before the channel releases any coalesced payloads.
/// Ownership comes exclusively from the application's currentBroadcaster callback.
/// Authentication alone never permits a participant to publish or change playback.
public final class MediaHostSession {
    public struct Broadcaster: Equatable, Sendable {
        public let peerID: UUID
        public let epoch: UInt64
        public init(peerID: UUID, epoch: UInt64) { self.peerID = peerID; self.epoch = epoch }
    }

    public struct Callbacks {
        public var currentBroadcaster: () -> Broadcaster?
        /// A trusted current/future timeline, never reconstructed from receiver input.
        /// Renewal requires a future playback time. This callback must not block.
        public var currentAnchor: (UUID, MediaStreamIdentifier, UInt64) -> MediaStreamAnchor?
        public var resync: (UUID, MediaStreamIdentifier, UInt64?) -> Void
        public var requestKeyframe: (UUID, MediaStreamIdentifier, UInt64?) -> Void
        /// Only structurally valid, bounded AnnotationWireMessage payloads arrive here.
        /// Return false when unsupported; the connection then closes explicitly.
        public var annotation: (AuthenticatedChannelCredentials, Data) -> Bool
        public var peerDetached: (UUID) -> Void

        public init(currentBroadcaster: @escaping () -> Broadcaster?,
                    currentAnchor: @escaping (UUID, MediaStreamIdentifier, UInt64) -> MediaStreamAnchor?,
                    resync: @escaping (UUID, MediaStreamIdentifier, UInt64?) -> Void = { _, _, _ in },
                    requestKeyframe: @escaping (UUID, MediaStreamIdentifier, UInt64?) -> Void = { _, _, _ in },
                    annotation: @escaping (AuthenticatedChannelCredentials, Data) -> Bool = { _, _ in false },
                    peerDetached: @escaping (UUID) -> Void = { _ in }) {
            self.currentBroadcaster = currentBroadcaster; self.currentAnchor = currentAnchor
            self.resync = resync; self.requestKeyframe = requestKeyframe
            self.annotation = annotation; self.peerDetached = peerDetached
        }
    }

    typealias ControlSend = (Data, @escaping (Result<Void, Error>) -> Void) -> Void
    typealias DatagramSend = (Data, UUID, @escaping (Bool) -> Void) -> Void
    private final class Lease {
        let ticket: MediaSubscriptionTicket
        let deadline: TimeInterval
        var validated = false
        var anchorSending = false
        var refreshNeeded = false
        var cutover: UInt64?
        var proposedAnchor: MediaStreamAnchor?
        var audioInFlight = false
        init(_ ticket: MediaSubscriptionTicket, now: TimeInterval) {
            self.ticket = ticket; deadline = min(ticket.expiresAt, now + 10)
        }
        var stream: MediaStreamIdentifier { .init(ticket: ticket) }
    }
    private struct Output {
        let id = UUID()
        let bytes: Data
        let deadline: TimeInterval
        let completion: (() -> Void)?
    }
    private final class Peer {
        let credentials: AuthenticatedChannelCredentials
        let send: ControlSend
        let close: () -> Void
        var active: Lease?, pending: Lease?
        var outputs: [Output] = []
        var sending = false
        var recentRequests: [UUID: TimeInterval] = [:]
        var controlTimes: [TimeInterval] = [], pingTimes: [TimeInterval] = [], annotationTimes: [TimeInterval] = []
        var annotationBytes: [(time: TimeInterval, count: Int)] = []
        init(credentials: AuthenticatedChannelCredentials, send: @escaping ControlSend, close: @escaping () -> Void) {
            self.credentials = credentials; self.send = send; self.close = close
        }
    }

    public let roomID: UUID
    public let localPeerID: UUID
    private let queue: DispatchQueue
    private let executorKey = DispatchSpecificKey<UInt8>()
    private let callbacks: Callbacks
    private let nowNanos: () -> UInt64
    private let registry: MediaSubscriptionRegistry
    private let sendDatagram: DatagramSend
    private let cancelDatagram: (UUID) -> Void
    private var publisher: SecureMediaDatagramPublisher?
    private var port: UInt16?
    private var peers: [UUID: Peer] = [:]
    private var generation: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var stopped = false

    public convenience init(roomID: UUID, localPeerID: UUID, queue: DispatchQueue,
                            callbacks: Callbacks) throws {
        let registry = MediaSubscriptionRegistry(limits: .init(maximumSubscriptions: 64, maximumPending: 32, maximumPerPeer: 2))
        let publisher = try SecureMediaDatagramPublisher(registry: registry, queue: queue)
        self.init(roomID: roomID, localPeerID: localPeerID, queue: queue, callbacks: callbacks,
                  registry: registry, nowNanos: MonotonicClock.nowNanos,
                  sendDatagram: { data, session, completion in
                      publisher.send(payload: data, sessionID: session, channel: .audio, completion: completion)
                  }, cancelDatagram: { publisher.cancel(sessionID: $0) })
        self.publisher = publisher
        publisher.onReady = { [weak self] in self?.publisherReady(port: $0.rawValue) }
        publisher.onSubscriptionValidated = { [weak self] in self?.subscriptionValidated($0) }
        publisher.onState = { [weak self] state in
            if state == .failed || state == .cancelled { self?.stop() }
        }
    }

    /// Internal deterministic transport seam. Production always uses the concrete
    /// publisher above; test callers must perform registry proofs before validation.
    init(roomID: UUID, localPeerID: UUID, queue: DispatchQueue, callbacks: Callbacks,
         registry: MediaSubscriptionRegistry, nowNanos: @escaping () -> UInt64,
         sendDatagram: @escaping DatagramSend, cancelDatagram: @escaping (UUID) -> Void) {
        self.roomID = roomID; self.localPeerID = localPeerID; self.queue = queue
        self.callbacks = callbacks; self.registry = registry; self.nowNanos = nowNanos
        self.sendDatagram = sendDatagram; self.cancelDatagram = cancelDatagram
        queue.setSpecific(key: executorKey, value: 1)
    }
    deinit { timer?.cancel(); publisher?.stop(); queue.setSpecific(key: executorKey, value: nil) }
    private func assertQueue() { dispatchPrecondition(condition: .onQueue(queue)) }
    private var now: TimeInterval { TimeInterval(nowNanos()) / 1_000_000_000 }

    public func start() {
        assertQueue()
        guard timer == nil, !stopped else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume(); publisher?.start()
    }

    public func stop() {
        assertQueue()
        guard !stopped else { return }
        stopped = true; port = nil; timer?.cancel(); timer = nil
        for id in Array(peers.keys) { detach(connectionID: id) }
        registry.cancelAll(); publisher?.stop()
    }

    /// The credential instance must be the live instance issued by this channel.
    /// A different queue is rejected without installing a deferred payload handler.
    public func attach(channel: SecurePeerChannel, credentials: AuthenticatedChannelCredentials) throws {
        assertQueue()
        var result: Result<Void, Error> = .failure(SecureTransportError.invalidState)
        channel.withAuthenticatedCredentials { [self] actual in
            guard DispatchQueue.getSpecific(key: executorKey) == 1 else { return }
            result = Result {
                let actual = try actual.get()
                guard actual === credentials else { throw SecureTransportError.invalidCredentials }
                try addPeer(credentials: credentials, send: { channel.send(payload: $0, completion: $1) }, close: { channel.cancel() })
                let priorState = channel.onState
                channel.onState = { [weak self] state in
                    if case .failed = state { self?.detach(connectionID: credentials.connectionID) }
                    if state == .cancelled { self?.detach(connectionID: credentials.connectionID) }
                    priorState?(state)
                }
                channel.onPayload = { [weak self] in self?.receive($0, connectionID: credentials.connectionID) }
            }
        }
        try result.get()
    }

    func addPeer(credentials: AuthenticatedChannelCredentials, send: @escaping ControlSend,
                 close: @escaping () -> Void) throws {
        assertQueue()
        guard !stopped, credentials.isActive, credentials.roomID == roomID, credentials.localPeerID == localPeerID,
              credentials.localRole == .responder, credentials.channelRole == .mediaControl,
              credentials.negotiated.wireVersion == 2,
              credentials.negotiated.initiatorCapabilities.contains(.receiveAudio),
              credentials.negotiated.responderCapabilities.contains(.broadcast) else {
            throw SecureTransportError.invalidCredentials
        }
        guard peers.count < 32, peers[credentials.connectionID] == nil,
              !peers.values.contains(where: { $0.credentials.remotePeerID == credentials.remotePeerID }) else {
            throw SecureTransportError.capacity
        }
        peers[credentials.connectionID] = Peer(credentials: credentials, send: send, close: close)
    }

    public func detach(connectionID: UUID) {
        assertQueue()
        guard let peer = peers.removeValue(forKey: connectionID) else { return }
        revoke(peer.active); revoke(peer.pending); peer.outputs.removeAll()
        peer.close(); callbacks.peerDetached(connectionID)
    }

    func publisherReady(port: UInt16) { assertQueue(); if !stopped, port != 0 { self.port = port } }

    /// Called only by the publisher after its authenticated same-flow proof.
    func subscriptionValidated(_ sessionID: UUID) {
        assertQueue(); tick()
        for peer in Array(peers.values) {
            guard let lease = peer.pending, lease.ticket.sessionID == sessionID else { continue }
            lease.validated = true; sendAnchor(peer, lease: lease)
        }
    }

    func receive(_ bytes: Data, connectionID: UUID) {
        assertQueue(); tick()
        guard let peer = peers[connectionID] else { return }
        let message: MediaControlWireMessage
        do { message = try MediaControlWireMessage(encoded: bytes) }
        catch {
            guard bytes.count <= AnnotationWireMessage.maximumWireBytes,
                  (try? AnnotationWireMessage(encoded: bytes)) != nil,
                  annotationBudget(peer, bytes: bytes.count), callbacks.annotation(peer.credentials, bytes) else {
                detach(connectionID: connectionID); return
            }
            return
        }
        if case let .clockPing(id, clientTime) = message {
            guard budget(&peer.pingTimes, maximum: 8) else { return }
            send(.clockPong(id: id, clientTimeNanos: clientTime, hostTimeNanos: nowNanos()), to: peer)
            return
        }
        guard budget(&peer.controlTimes, maximum: 8) else { detach(connectionID: connectionID); return }
        switch message {
        case let .subscribe(id, epoch, channels):
            guard remember(id, peer: peer) else { return }
            guard localEpoch == epoch else { reject(id, .staleSession, peer); return }
            guard !channels.isEmpty, channels.isSubset(of: [.audio, .timing]) else { reject(id, .denied, peer); return }
            grant(id, channels: channels, epoch: epoch, peer: peer)
        case let .renew(id, stream):
            guard remember(id, peer: peer) else { return }
            guard let active = peer.active, active.stream == stream, localEpoch == stream.broadcasterEpoch else {
                reject(id, .staleSession, peer); return
            }
            grant(id, channels: active.ticket.channels, epoch: stream.broadcasterEpoch, peer: peer)
        case let .anchorReady(stream, frameIndex, captureTime, playbackTime):
            let time = nowNanos()
            guard let lease = peer.pending, lease.stream == stream, lease.validated,
                  let anchor = lease.proposedAnchor, anchor.frameIndex == frameIndex,
                  anchor.captureTimeNanos == captureTime, anchor.hostPlaybackTimeNanos == playbackTime,
                  lease.deadline > now, localEpoch == stream.broadcasterEpoch,
                  playbackTime >= time || time - playbackTime <= MediaControlWireMessage.maximumAnchorAgeNanos,
                  peer.active == nil || playbackTime > time else { return }
            lease.cutover = playbackTime
            advance(peer)
        case .cancel(let stream):
            if peer.pending?.stream == stream { revoke(peer.pending); peer.pending = nil }
            if peer.active?.stream == stream { revoke(peer.active); peer.active = nil }
        case let .resync(id, stream, minimum):
            guard remember(id, peer: peer) else { return }
            guard let lease = validatedLease(stream, peer: peer) else { reject(id, .staleSession, peer); return }
            callbacks.resync(peer.credentials.remotePeerID, stream, minimum)
            sendAnchor(peer, lease: lease)
        case let .requestKeyframe(id, stream, minimum):
            guard remember(id, peer: peer) else { return }
            guard validatedLease(stream, peer: peer) != nil else { reject(id, .staleSession, peer); return }
            guard peer.credentials.negotiated.initiatorCapabilities.contains(.receiveVideo) else {
                reject(id, .denied, peer); return
            }
            callbacks.requestKeyframe(peer.credentials.remotePeerID, stream, minimum)
        default: detach(connectionID: connectionID)
        }
    }

    /// Refreshes the trusted timeline without changing the active ticket. A running
    /// refresh supplies startup audio immediately; the receiver must prepare its
    /// renderer before resuming playout. Readiness ACK commits initial/replacement
    /// tickets, not every refresh. Paused tickets may ACK without audio warmup.
    public func refreshTimeline() {
        assertQueue(); tick()
        for peer in Array(peers.values) {
            if let active = peer.active { sendAnchor(peer, lease: active) }
            if let pending = peer.pending, pending.validated { sendAnchor(peer, lease: pending) }
        }
    }

    /// Queue-confined: the caller must bound its capture-to-host queue crossing.
    /// One enqueue in flight per lease prevents a slow UDP peer retaining audio.
    public func publishAudio(_ packet: AudioPacket) {
        assertQueue(); tick()
        guard !stopped, localEpoch != nil, !packet.samples.isEmpty,
              packet.samples.count <= Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount),
              packet.samples.count.isMultiple(of: Int(AudioPacket.channelCount)),
              packet.captureTimeNanos <= UInt64(Int64.max) else { return }
        let bytes = packet.encoded()
        for peer in Array(peers.values) {
            for lease in [peer.active, peer.pending].compactMap({ $0 }) {
                // A validated pending path needs startup data before the receiver
                // can acknowledge readiness. Its predecessor remains live until ACK.
                guard lease.validated, let anchor = lease.proposedAnchor,
                      anchor.state == .running, packet.frameIndex >= anchor.frameIndex, packet.captureTimeNanos >= anchor.captureTimeNanos,
                      lease.ticket.channels.contains(.audio), !lease.audioInFlight else { continue }
                lease.audioInFlight = true
                sendDatagram(bytes, lease.ticket.sessionID) { [weak self, weak lease] _ in
                    self?.assertQueue(); lease?.audioInFlight = false
                }
            }
        }
    }

    public func sendAnnotation(_ bytes: Data, connectionID: UUID) {
        assertQueue(); tick()
        guard let peer = peers[connectionID], (try? AnnotationWireMessage(encoded: bytes)) != nil else { return }
        enqueue(bytes, peer: peer)
    }

    private var localEpoch: UInt64? {
        guard let owner = callbacks.currentBroadcaster(), owner.peerID == localPeerID, owner.epoch < .max else { return nil }
        return owner.epoch
    }
    private func validatedLease(_ stream: MediaStreamIdentifier, peer: Peer) -> Lease? {
        guard localEpoch == stream.broadcasterEpoch else { return nil }
        return [peer.active, peer.pending].compactMap { $0 }.first { $0.stream == stream && $0.validated }
    }
    private func budget(_ times: inout [TimeInterval], maximum: Int) -> Bool {
        let time = now; times.removeAll { time - $0 >= 1 || time < $0 }
        guard times.count < maximum else { return false }; times.append(time); return true
    }
    private func annotationBudget(_ peer: Peer, bytes: Int) -> Bool {
        let time = now
        peer.annotationBytes.removeAll { time - $0.time >= 1 || time < $0.time }
        guard peer.annotationBytes.reduce(0, { $0 + $1.count }) + bytes <= 262_144,
              budget(&peer.annotationTimes, maximum: 64) else { return false }
        peer.annotationBytes.append((time, bytes)); return true
    }
    private func remember(_ id: UUID, peer: Peer) -> Bool {
        peer.recentRequests = peer.recentRequests.filter { $0.value > now }
        guard peer.recentRequests[id] == nil, peer.recentRequests.count < 64 else { reject(id, .busy, peer); return false }
        peer.recentRequests[id] = now + 30; return true
    }
    private func grant(_ id: UUID, channels: Set<DatagramChannel>, epoch: UInt64, peer: Peer) {
        guard let port else { reject(id, .unavailable, peer); return }
        guard peer.pending == nil, generation < UInt64.max - 1 else { reject(id, .busy, peer); return }
        do {
            generation += 1
            let ticket = try registry.reserveAdmittedSubscription(credentials: peer.credentials, broadcasterEpoch: epoch,
                generation: generation, channels: channels, now: now, lifetime: 30)
            peer.pending = Lease(ticket, now: now)
            send(.subscribed(requestID: id, ticket: ticket, udpPort: port), to: peer)
        } catch { reject(id, .busy, peer) }
    }
    private func sendAnchor(_ peer: Peer, lease: Lease) {
        guard lease.validated, localEpoch == lease.ticket.broadcasterEpoch,
              registry.containsLiveSubscription(sessionID: lease.ticket.sessionID, now: now) else { return }
        if lease.anchorSending {
            if peer.active === lease { lease.refreshNeeded = true }
            return
        }
        // Do not move an already announced pending cutover while its predecessor is live.
        if peer.pending === lease, lease.proposedAnchor != nil { return }
        let time = nowNanos()
        guard let anchor = callbacks.currentAnchor(peer.credentials.remotePeerID, lease.stream, time),
              anchor.stream == lease.stream, anchor.issuedAtHostNanos <= time,
              time - anchor.issuedAtHostNanos <= MediaControlWireMessage.maximumAnchorAgeNanos,
              peer.active == nil || peer.active === lease || anchor.hostPlaybackTimeNanos > time,
              let bytes = try? MediaControlWireMessage.anchor(anchor).encoded() else { return }
        lease.anchorSending = true; lease.proposedAnchor = anchor
        enqueue(bytes, peer: peer) { [weak self, weak peer, weak lease] in
            guard let self, let peer, let lease,
                  self.peers[peer.credentials.connectionID] === peer else { return }
            lease.anchorSending = false
            // Sending is not an acknowledgment. Only anchorReady may commit a pending lease.
            if lease.refreshNeeded {
                lease.refreshNeeded = false; self.sendAnchor(peer, lease: lease)
            }
        }
    }
    private func advance(_ peer: Peer) {
        guard let pending = peer.pending, let cutover = pending.cutover,
              peer.active == nil || nowNanos() >= cutover else { return }
        revoke(peer.active); peer.active = pending; peer.pending = nil
    }
    private func revoke(_ lease: Lease?) {
        guard let lease else { return }
        registry.cancel(sessionID: lease.ticket.sessionID) // Immediate revocation on owning queue.
        cancelDatagram(lease.ticket.sessionID)
    }
    func tick() {
        assertQueue()
        let time = now, epoch = localEpoch
        for peer in Array(peers.values) {
            if !peer.credentials.isActive || peer.outputs.first.map({ $0.deadline <= time }) == true {
                detach(connectionID: peer.credentials.connectionID); continue
            }
            if let active = peer.active, active.ticket.expiresAt <= time || active.ticket.broadcasterEpoch != epoch {
                revoke(active); peer.active = nil
            }
            if let pending = peer.pending,
               pending.ticket.expiresAt <= time || pending.ticket.broadcasterEpoch != epoch ||
                (pending.cutover == nil && pending.deadline <= time) {
                revoke(pending); peer.pending = nil
            }
            advance(peer)
        }
        registry.expire(now: time)
    }
    private func reject(_ id: UUID, _ reason: MediaControlWireMessage.Rejection, _ peer: Peer) {
        send(.rejected(requestID: id, reason: reason), to: peer)
    }
    private func send(_ message: MediaControlWireMessage, to peer: Peer) {
        guard let bytes = try? message.encoded() else { return }; enqueue(bytes, peer: peer)
    }
    private func enqueue(_ bytes: Data, peer: Peer, completion: (() -> Void)? = nil) {
        guard peers[peer.credentials.connectionID] === peer else { return }
        guard peer.outputs.count < 8, peer.outputs.reduce(0, { $0 + $1.bytes.count }) + bytes.count <= 262_144 else {
            detach(connectionID: peer.credentials.connectionID); return
        }
        peer.outputs.append(Output(bytes: bytes, deadline: now + 2, completion: completion)); drain(peer)
    }
    private func drain(_ peer: Peer) {
        guard !peer.sending, let output = peer.outputs.first else { return }
        peer.sending = true
        peer.send(output.bytes) { [weak self, weak peer] result in
            guard let self, let peer else { return }; self.assertQueue()
            guard self.peers[peer.credentials.connectionID] === peer, peer.outputs.first?.id == output.id else { return }
            guard case .success = result, output.deadline > self.now else {
                self.detach(connectionID: peer.credentials.connectionID); return
            }
            peer.outputs.removeFirst(); peer.sending = false; output.completion?(); self.drain(peer)
        }
    }
}
