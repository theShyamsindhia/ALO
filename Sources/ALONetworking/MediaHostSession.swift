import Foundation
import Network
import ALOCore

/// Media-only publisher adapter. Callbacks and channel operations belong to
/// `queue`, which MUST also own the attached SecurePeerChannels. Lifecycle methods
/// and submitAudio marshal to that executor. Call attach directly in
/// onAuthenticated, before the channel releases any coalesced payloads.
/// Ownership comes exclusively from the application's currentBroadcaster callback.
/// Authentication alone never permits a participant to publish or change playback.
public final class MediaHostSession: @unchecked Sendable {
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
    typealias AudioRetry = (@escaping () -> Void) -> Void
    private struct PendingAudio {
        let packet: AudioPacket
        let enqueuedAt: UInt64
    }
    private static let maximumPendingAudio = 16
    private static let maximumAudioWait: UInt64 = 80_000_000
    private final class Lease {
        let ticket: MediaSubscriptionTicket
        let deadline: TimeInterval
        var validated = false
        var anchorSending = false
        var refreshNeeded = false
        var cutover: UInt64?
        var proposedAnchor: MediaStreamAnchor?
        var audioInFlight = false
        var pendingAudio: [PendingAudio] = []
        init(_ ticket: MediaSubscriptionTicket, now: TimeInterval) {
            self.ticket = ticket; deadline = min(ticket.expiresAt, now + 10)
        }
        var stream: MediaStreamIdentifier { .init(ticket: ticket) }
    }
    private struct Output {
        let id = UUID()
        let bytes: Data
        let deadline: TimeInterval
        let completion: ((Result<Void, Error>) -> Void)?
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
    private let scheduleAudioRetry: AudioRetry
    private var publisher: SecureMediaDatagramPublisher?
    private var port: UInt16?
    private var peers: [UUID: Peer] = [:]
    private var generation: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private let ingressLock = NSLock()
    private var ingress: [PendingAudio] = []
    private var ingressScheduled = false
    private var ingressStopped = false
    private var videoIngress = VideoSendQueue()
    private var videoIngressScheduled = false
    private lazy var videoHost = MediaVideoHost(authorize: { [weak self] credentials, stream in
        self?.videoCaptureFloor(credentials: credentials, stream: stream)
    }, requestKeyframe: callbacks.requestKeyframe, now: nowNanos)

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
         sendDatagram: @escaping DatagramSend, cancelDatagram: @escaping (UUID) -> Void,
         scheduleAudioRetry: AudioRetry? = nil) {
        self.roomID = roomID; self.localPeerID = localPeerID; self.queue = queue
        self.callbacks = callbacks; self.registry = registry; self.nowNanos = nowNanos
        self.sendDatagram = sendDatagram; self.cancelDatagram = cancelDatagram
        self.scheduleAudioRetry = scheduleAudioRetry ?? { retry in queue.asyncAfter(deadline: .now() + .milliseconds(5), execute: retry) }
        queue.setSpecific(key: executorKey, value: 1)
    }
    deinit { timer?.cancel(); publisher?.stop(); queue.setSpecific(key: executorKey, value: nil) }
    private func assertQueue() { dispatchPrecondition(condition: .onQueue(queue)) }
    private var now: TimeInterval { TimeInterval(nowNanos()) / 1_000_000_000 }

    public func start() {
        if DispatchQueue.getSpecific(key: executorKey) != 1 { queue.async { self.start() }; return }
        assertQueue()
        guard timer == nil, !stopped else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume(); publisher?.start()
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: executorKey) != 1 { queue.async { self.stop() }; return }
        assertQueue()
        guard !stopped else { return }
        stopped = true; port = nil; timer?.cancel(); timer = nil
        ingressLock.withLock { ingressStopped = true; ingress.removeAll(); videoIngress.reset() }
        videoHost.setEnabled(false)
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
                    if case .failed(let error) = state { self?.detach(connectionID: credentials.connectionID, error: error) }
                    if state == .cancelled { self?.detach(connectionID: credentials.connectionID) }
                    priorState?(state)
                }
                channel.onPayload = { [weak self] in self?.receive($0, connectionID: credentials.connectionID) }
            }
        }
        try result.get()
    }

    /// Attach inline on the admitted video's executor. Its first payload binds
    /// it to a currently authorized audio lease for this same room and peer.
    public func attachVideo(channel: SecurePeerChannel, credentials: AuthenticatedChannelCredentials) throws {
        assertQueue()
        var result: Result<Void, Error> = .failure(SecureTransportError.invalidState)
        channel.withAuthenticatedCredentials { actual in
            guard DispatchQueue.getSpecific(key: self.executorKey) == 1 else { return }
            result = Result {
                guard try actual.get() === credentials, !self.stopped,
                      credentials.roomID == self.roomID, credentials.localPeerID == self.localPeerID else {
                    throw SecureTransportError.invalidCredentials
                }
                try self.addVideoPeer(credentials: credentials, send: { channel.send(payload: $0, completion: $1) },
                                      close: { channel.cancel() })
                let previous = channel.onState
                channel.onState = { [weak self] state in
                    if case .failed = state { self?.videoHost.remove(credentials.connectionID) }
                    if state == .cancelled { self?.videoHost.remove(credentials.connectionID) }
                    previous?(state)
                }
                channel.onPayload = { [weak self] in self?.receiveVideoBinding($0, connectionID: credentials.connectionID) }
            }
        }
        try result.get()
    }

    func addVideoPeer(credentials: AuthenticatedChannelCredentials, send: @escaping MediaVideoHost.Send,
                      close: @escaping () -> Void) throws {
        assertQueue()
        guard !stopped, credentials.roomID == roomID, credentials.localPeerID == localPeerID else {
            throw SecureTransportError.invalidCredentials
        }
        try videoHost.add(credentials: credentials, send: send, close: close)
    }
    func receiveVideoBinding(_ data: Data, connectionID: UUID) { assertQueue(); videoHost.receive(data, from: connectionID) }
    func removeVideoPeer(connectionID: UUID) { assertQueue(); videoHost.remove(connectionID) }

    public func setVideoEnabled(_ enabled: Bool) {
        if DispatchQueue.getSpecific(key: executorKey) != 1 { queue.async { self.setVideoEnabled(enabled) }; return }
        guard !stopped else { return }
        if !enabled { ingressLock.withLock { videoIngress.reset() } }
        videoHost.setEnabled(enabled)
    }

    public func submitVideo(_ frame: VideoFrame) {
        guard MediaVideoWire.validate(frame) else { return }
        let schedule = ingressLock.withLock { () -> Bool in
            guard !ingressStopped else { return false }
            videoIngress.append(frame, nowNanos: nowNanos())
            guard !videoIngressScheduled else { return false }
            videoIngressScheduled = true; return true
        }
        if schedule {
            queue.async {
                let batch = self.ingressLock.withLock { () -> (frames: [VideoFrame], needsKeyframe: Bool) in
                    var frames: [VideoFrame] = []
                    while let entry = self.videoIngress.takeNext(nowNanos: self.nowNanos()) { frames.append(entry.frame) }
                    self.videoIngressScheduled = false; return (frames, self.videoIngress.requiresKeyframe)
                }
                if batch.needsKeyframe { self.videoHost.requireKeyframe() }
                for frame in batch.frames { self.videoHost.publish(frame) }
            }
        }
    }

    private func videoCaptureFloor(credentials: AuthenticatedChannelCredentials, stream: MediaStreamIdentifier) -> UInt64? {
        guard !stopped, credentials.isActive, credentials.roomID == roomID, credentials.localPeerID == localPeerID,
              credentials.channelRole == .video, credentials.localRole == .responder,
              credentials.negotiated.initiatorCapabilities.contains(.receiveVideo),
              let peer = peers.values.first(where: { $0.credentials.remotePeerID == credentials.remotePeerID }),
              peer.credentials.isActive, peer.credentials.negotiated.initiatorCapabilities.contains(.receiveVideo),
              let lease = validatedLease(stream, peer: peer),
              registry.containsLiveSubscription(sessionID: stream.sessionID, now: now),
              let anchor = lease.proposedAnchor, anchor.state == .running else { return nil }
        return anchor.captureTimeNanos
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
        detach(connectionID: connectionID, error: SecurePeerChannelError.cancelled)
    }

    private func detach(connectionID: UUID, error: Error) {
        assertQueue()
        guard let peer = peers.removeValue(forKey: connectionID) else { return }
        revoke(peer.active); revoke(peer.pending)
        let outputs = peer.outputs; peer.outputs.removeAll()
        peer.close(); callbacks.peerDetached(connectionID)
        for output in outputs { output.completion?(.failure(error)) }
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
        if DispatchQueue.getSpecific(key: executorKey) != 1 { queue.async { self.refreshTimeline() }; return }
        assertQueue(); tick()
        for peer in Array(peers.values) {
            if let active = peer.active { sendAnchor(peer, lease: active) }
            if let pending = peer.pending, pending.validated { sendAnchor(peer, lease: pending) }
        }
    }

    /// Thread-safe capture bridge. At most one executor drain and 16 packets are
    /// retained; capture bursts do not create an unbounded queue of closures.
    public func submitAudio(_ packets: [AudioPacket]) {
        let shouldSchedule = ingressLock.withLock { () -> Bool in
            guard !ingressStopped else { return false }
            let time = nowNanos()
            ingress.removeAll { time < $0.enqueuedAt || time - $0.enqueuedAt >= Self.maximumAudioWait }
            for packet in packets.suffix(Self.maximumPendingAudio) {
                guard !packet.samples.isEmpty,
                      packet.samples.count <= Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount),
                      packet.samples.count.isMultiple(of: Int(AudioPacket.channelCount)),
                      packet.captureTimeNanos <= UInt64(Int64.max) else { continue }
                if ingress.count >= Self.maximumPendingAudio { ingress.removeFirst() }
                ingress.append(PendingAudio(packet: packet, enqueuedAt: time))
            }
            guard !ingressScheduled, !ingress.isEmpty else { return false }
            ingressScheduled = true; return true
        }
        if shouldSchedule { queue.async { self.drainIngress() } }
    }

    private func drainIngress() {
        assertQueue()
        let batch = ingressLock.withLock { () -> [PendingAudio] in
            let batch = ingress; ingress.removeAll(); ingressScheduled = false; return batch
        }
        let time = nowNanos()
        for item in batch where time >= item.enqueuedAt && time - item.enqueuedAt < Self.maximumAudioWait {
            publishAudio(item.packet, enqueuedAt: item.enqueuedAt)
        }
    }

    /// Queue-confined. Each lease preserves short bursts in a bounded FIFO while
    /// its publisher enqueue is outstanding; expired audio never drains later.
    public func publishAudio(_ packet: AudioPacket) {
        publishAudio(packet, enqueuedAt: nowNanos())
    }

    private func publishAudio(_ packet: AudioPacket, enqueuedAt: UInt64) {
        assertQueue(); tick()
        guard !stopped, localEpoch != nil, !packet.samples.isEmpty,
              packet.samples.count <= Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount),
              packet.samples.count.isMultiple(of: Int(AudioPacket.channelCount)),
              packet.captureTimeNanos <= UInt64(Int64.max) else { return }
        for peer in Array(peers.values) {
            for lease in [peer.active, peer.pending].compactMap({ $0 }) {
                // A validated pending path needs startup data before the receiver
                // can acknowledge readiness. Its predecessor remains live until ACK.
                guard lease.validated, let anchor = lease.proposedAnchor,
                      anchor.state == .running, packet.frameIndex >= anchor.frameIndex, packet.captureTimeNanos >= anchor.captureTimeNanos,
                      lease.ticket.channels.contains(.audio) else { continue }
                pruneAudio(lease)
                while lease.pendingAudio.count >= Self.maximumPendingAudio ||
                    lease.pendingAudio.first.map({ packet.captureTimeNanos >= $0.packet.captureTimeNanos &&
                        packet.captureTimeNanos - $0.packet.captureTimeNanos > Self.maximumAudioWait }) == true {
                    lease.pendingAudio.removeFirst()
                }
                lease.pendingAudio.append(PendingAudio(packet: packet, enqueuedAt: enqueuedAt))
                drainAudio(lease, peer: peer)
            }
        }
    }

    private func pruneAudio(_ lease: Lease) {
        let time = nowNanos()
        lease.pendingAudio.removeAll { item in
            guard let anchor = lease.proposedAnchor, anchor.state == .running,
                  item.packet.frameIndex >= anchor.frameIndex, item.packet.captureTimeNanos >= anchor.captureTimeNanos,
                  time >= item.enqueuedAt, time - item.enqueuedAt < Self.maximumAudioWait else { return true }
            let delay = anchor.hostPlaybackTimeNanos - anchor.captureTimeNanos
            let deadline = item.packet.captureTimeNanos.addingReportingOverflow(delay)
            return deadline.overflow || deadline.partialValue <= time
        }
    }

    private func drainAudio(_ lease: Lease, peer: Peer) {
        guard !stopped, peers[peer.credentials.connectionID] === peer, peer.credentials.isActive,
              peer.active === lease || peer.pending === lease,
              lease.ticket.broadcasterEpoch == localEpoch,
              registry.containsLiveSubscription(sessionID: lease.ticket.sessionID, now: now) else {
            lease.pendingAudio.removeAll(); return
        }
        pruneAudio(lease)
        guard !lease.audioInFlight, !lease.pendingAudio.isEmpty else { return }
        let item = lease.pendingAudio.removeFirst()
        lease.audioInFlight = true
        sendDatagram(item.packet.encoded(), lease.ticket.sessionID) { [weak self, weak lease, weak peer] accepted in
            guard let self, let lease, let peer else { return }; self.assertQueue()
            if !accepted, !self.stopped, self.peers[peer.credentials.connectionID] === peer,
               peer.credentials.isActive, peer.active === lease || peer.pending === lease,
               lease.ticket.broadcasterEpoch == self.localEpoch {
                // This completion reports queue admission, so false means no
                // datagram was enqueued. Preserve order through brief pressure
                // without retrying any packet already handed to the transport.
                if lease.pendingAudio.count >= Self.maximumPendingAudio { lease.pendingAudio.removeLast() }
                lease.pendingAudio.insert(item, at: 0)
                self.pruneAudio(lease)
                if !lease.pendingAudio.isEmpty {
                    self.scheduleAudioRetry { [weak self, weak lease, weak peer] in
                        guard let self, let lease, let peer else { return }; self.assertQueue()
                        lease.audioInFlight = false; self.drainAudio(lease, peer: peer)
                    }
                    return
                }
            }
            lease.audioInFlight = false; self.drainAudio(lease, peer: peer)
        }
    }

    /// Queue-confined. Completion reflects the reliable send, including terminal
    /// errors and cancellation; adding bytes to the local queue is not success.
    public func sendAnnotation(_ bytes: Data, connectionID: UUID,
                               completion: ((Result<Void, Error>) -> Void)? = nil) {
        assertQueue(); tick()
        guard let peer = peers[connectionID] else { completion?(.failure(SecurePeerChannelError.notAuthenticated)); return }
        guard (try? AnnotationWireMessage(encoded: bytes)) != nil else { completion?(.failure(SecureTransportError.malformed)); return }
        enqueue(bytes, peer: peer, completion: completion)
    }

    /// The validated DTO carries geometry only. The annotation coordinator owns
    /// source identity/permission and decides which admitted peers receive it.
    public func sendCaptureMetadata(_ metadata: CaptureMetadataWireMessage, connectionID: UUID,
                                     completion: ((Result<Void, Error>) -> Void)? = nil) {
        assertQueue(); tick()
        guard let peer = peers[connectionID] else { completion?(.failure(SecurePeerChannelError.notAuthenticated)); return }
        do { enqueue(try metadata.encoded(), peer: peer, completion: completion) }
        catch { completion?(.failure(error)) }
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
        enqueue(bytes, peer: peer) { [weak self, weak peer, weak lease] result in
            guard case .success = result else { return }
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
        lease.pendingAudio.removeAll()
        registry.cancel(sessionID: lease.ticket.sessionID) // Immediate revocation on owning queue.
        cancelDatagram(lease.ticket.sessionID)
    }
    func tick() {
        assertQueue()
        let time = now, epoch = localEpoch
        for peer in Array(peers.values) {
            if !peer.credentials.isActive || peer.outputs.first.map({ $0.deadline <= time }) == true {
                detach(connectionID: peer.credentials.connectionID, error: peer.credentials.isActive
                    ? SecurePeerChannelError.timedOut : SecurePeerChannelError.cancelled); continue
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
            for lease in [peer.active, peer.pending].compactMap({ $0 }) { pruneAudio(lease) }
        }
        registry.expire(now: time)
        videoHost.tick()
    }
    private func reject(_ id: UUID, _ reason: MediaControlWireMessage.Rejection, _ peer: Peer) {
        send(.rejected(requestID: id, reason: reason), to: peer)
    }
    private func send(_ message: MediaControlWireMessage, to peer: Peer) {
        guard let bytes = try? message.encoded() else { return }; enqueue(bytes, peer: peer)
    }
    private func enqueue(_ bytes: Data, peer: Peer, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard peers[peer.credentials.connectionID] === peer else { completion?(.failure(SecurePeerChannelError.cancelled)); return }
        guard peer.outputs.count < 8, peer.outputs.reduce(0, { $0 + $1.bytes.count }) + bytes.count <= 262_144 else {
            completion?(.failure(SecureTransportError.capacity)); detach(connectionID: peer.credentials.connectionID); return
        }
        peer.outputs.append(Output(bytes: bytes, deadline: now + 2, completion: completion)); drain(peer)
    }
    private func drain(_ peer: Peer) {
        guard !peer.sending, let output = peer.outputs.first else { return }
        peer.sending = true
        peer.send(output.bytes) { [weak self, weak peer] result in
            guard let self, let peer else { return }; self.assertQueue()
            guard self.peers[peer.credentials.connectionID] === peer, peer.outputs.first?.id == output.id else { return }
            if case .failure(let error) = result {
                self.detach(connectionID: peer.credentials.connectionID, error: error); return
            }
            guard output.deadline > self.now else {
                self.detach(connectionID: peer.credentials.connectionID, error: SecurePeerChannelError.timedOut); return
            }
            peer.outputs.removeFirst(); peer.sending = false; output.completion?(.success(())); self.drain(peer)
        }
    }
}
