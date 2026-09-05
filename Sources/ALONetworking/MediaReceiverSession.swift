import Foundation
import Network
import ALOCore

struct AnnotationTrafficBudget {
    private struct Entry { let time: UInt64; let bytes: Int; let snapshot: Bool }
    private var entries: [Entry] = []
    private var head = 0
    private var eventBytes = 0, snapshotBytes = 0
    mutating func accept(bytes: Int, snapshot: Bool, now: UInt64) -> Bool {
        while head < entries.count {
            let entry = entries[head]
            guard now < entry.time || now - entry.time >= 1_000_000_000 else { break }
            if entry.snapshot { snapshotBytes -= entry.bytes } else { eventBytes -= entry.bytes }
            head += 1
        }
        if head > 256 && head * 2 >= entries.count { entries.removeFirst(head); head = 0 }
        let used = snapshot ? snapshotBytes : eventBytes
        let limit = snapshot ? 16 * 1_024 * 1_024 : 1_048_576
        guard bytes >= 0, entries.count - head < 2_048, bytes <= limit - used else { return false }
        entries.append(Entry(time: now, bytes: bytes, snapshot: snapshot))
        if snapshot { snapshotBytes += bytes } else { eventBytes += bytes }
        return true
    }
}

/// Receiver-only media adapter. Call attach directly from the admitted channel
/// callback, before any MainActor hop. Packet callbacks run on its serial executor:
/// the app must use a bounded output bridge, not an unbounded Task per packet.
/// This adapter never starts audio hardware, voice capture, or microphone consent.
public final class MediaReceiverSession: @unchecked Sendable {
    public struct Selection: Equatable, Sendable {
        public let roomID: UUID, localPeerID: UUID, broadcasterPeerID: UUID
        public let broadcasterEpoch: UInt64
        public init(roomID: UUID, localPeerID: UUID, broadcasterPeerID: UUID, broadcasterEpoch: UInt64) {
            self.roomID = roomID; self.localPeerID = localPeerID
            self.broadcasterPeerID = broadcasterPeerID; self.broadcasterEpoch = broadcasterEpoch
        }
    }
    public struct ClockSnapshot: Equatable, Sendable {
        public let offsetNanos: Int64
        public let sampledAtLocalNanos: UInt64
        public let roundTripNanos: UInt64
    }
    public struct Preparation: Equatable, Sendable {
        public let id: UUID
        public let lifecycleGeneration: UInt64
        public let anchor: MediaStreamAnchor
        public let clock: ClockSnapshot
    }
    public enum State: Equatable, Sendable { case synchronizing, preparing, active, paused, recovering, stopped, failed }
    public struct Callbacks {
        /// Prepare the future timeline without tearing down the live predecessor.
        /// Complete its token only when the output engine can accept that timeline.
        public var prepareAnchor: (Preparation) -> Void
        /// Immediately precedes startup packet delivery: schedule future playback,
        /// not an immediate audible switch. This is not a network send completion.
        public var anchorCommitted: (Preparation) -> Void
        public var audio: (AudioPacket, MediaStreamIdentifier, UInt64) -> Void
        public var state: (State) -> Void
        public var clock: (ClockSnapshot) -> Void
        public var paused: (MediaStreamIdentifier, UInt64) -> Void
        public var annotation: (Data) -> Bool
        /// Opt-in extension: only <=4KiB JSON envelopes named alo.capture-metadata
        /// arrive. The delegate MUST validate its schema; no metadata authority or
        /// implemented metadata wire profile is implied by this routing hook.
        public var metadata: (Data) -> Bool
        public init(prepareAnchor: @escaping (Preparation) -> Void,
                    anchorCommitted: @escaping (Preparation) -> Void = { _ in },
                    audio: @escaping (AudioPacket, MediaStreamIdentifier, UInt64) -> Void,
                    state: @escaping (State) -> Void = { _ in }, clock: @escaping (ClockSnapshot) -> Void = { _ in },
                    paused: @escaping (MediaStreamIdentifier, UInt64) -> Void = { _, _ in },
                    annotation: @escaping (Data) -> Bool = { _ in false }, metadata: @escaping (Data) -> Bool = { _ in false }) {
            self.prepareAnchor = prepareAnchor; self.anchorCommitted = anchorCommitted; self.audio = audio
            self.state = state; self.clock = clock; self.paused = paused; self.annotation = annotation; self.metadata = metadata
        }
    }
    typealias ControlSend = (Data, @escaping (Result<Void, Error>) -> Void) -> Void
    typealias EndpointResolver = (UInt16, @escaping (Result<NWEndpoint, Error>) -> Void) -> Void
    typealias SubscriberFactory = (NWEndpoint, MediaSubscriptionTicket,
        @escaping (SecureMediaTransportState) -> Void, @escaping (DatagramChannel, Data) -> Void) throws -> (() -> Void)
    private final class Lease {
        let ticket: MediaSubscriptionTicket
        let expires: UInt64, renewAt: UInt64, setupDeadline: UInt64
        var cancel: (() -> Void)?
        var preparation: Preparation?, deferredAnchor: MediaStreamAnchor?
        var committedPreparation: Preparation?
        var retryAnchorAt: UInt64?
        var prepared = false, acknowledged = false, pathValidated = false
        var startup: [UInt64: AudioPacket] = [:]
        var lastData: UInt64 = 0
        init(ticket: MediaSubscriptionTicket, now: UInt64) {
            self.ticket = ticket
            let lifetime = UInt64(ticket.validForSeconds * 1_000_000_000)
            expires = now + lifetime; renewAt = now + lifetime * 2 / 3; setupDeadline = min(expires, now + 8_000_000_000)
        }
        var stream: MediaStreamIdentifier { .init(ticket: ticket) }
    }
    private struct Request { let id: UUID; let deadline: UInt64 }
    private struct Output {
        let id = UUID()
        let bytes: Data
        let deadline: UInt64
        let completion: ((Result<Void, Error>) -> Void)?
    }
    public let expected: Selection
    private let credentials: AuthenticatedChannelCredentials
    private let queue: DispatchQueue
    private let callbacks: Callbacks
    private let nowNanos: () -> UInt64
    private let sendControl: ControlSend
    private let resolveEndpoint: EndpointResolver
    private let makeSubscriber: SubscriberFactory
    private let closeControl: () -> Void
    private let startedAt: UInt64
    private var channel: SecurePeerChannel?, timer: DispatchSourceTimer?
    private let clock = ClockSynchronizer()
    private var probes: [UInt64: UInt64] = [:]
    private var lastPing: UInt64?, lastPong: UInt64?
    private var active: Lease?, pending: Lease?, request: Request?
    private var extraRequests: [UUID: UInt64] = [:]
    private var outputs: [Output] = []
    private var sending = false, stopped = false
    private var state: State = .synchronizing
    private var generation: UInt64 = 1, lastSequence: UInt64 = 0, nextAttempt: UInt64 = 0
    private var recentFrames: [UInt64: AudioPacket] = [:]
    private var retiredFrameFloor: UInt64?
    private var controlTimes: [UInt64] = [], auxiliaryTimes: [UInt64] = [], requestTimes: [UInt64] = []
    private var annotationTraffic = AnnotationTrafficBudget()
    private var rawTraffic = RawMediaTrafficBudget()
    private var annotationDisabled = false, metadataDisabled = false
    private var timingSample: (report: MediaReceiverTimingReport, sampledAt: UInt64)?
    private var lastTimingSent: UInt64?
    private var timingSentStreams = Set<UUID>()
    private var videoReceiver: MediaVideoReceiver?
    private var videoPreparation: Preparation?

    /// Inline on openMediaChannel's completion executor; handlers are installed
    /// before this completion fires. Deferred attachment cannot recover early data.
    public static func attach(channel: SecurePeerChannel, expected: Selection, callbacks: Callbacks,
                              completion: @escaping (Result<MediaReceiverSession, Error>) -> Void) {
        channel.withAuthenticatedCredentials { result in
            do {
                let credentials = try result.get(), queue = channel.mediaExecutor
                let receiver = try MediaReceiverSession(expected: expected, credentials: credentials, queue: queue,
                    callbacks: callbacks, nowNanos: MonotonicClock.nowNanos,
                    sendControl: { channel.send(payload: $0, completion: $1) },
                    resolveEndpoint: { port, reply in
                        guard let port = NWEndpoint.Port(rawValue: port) else { reply(.failure(SecureTransportError.malformed)); return }
                        channel.withAuthenticatedDatagramEndpoint(port: port, completion: reply)
                    }, makeSubscriber: { endpoint, ticket, state, payload in
                        let subscriber = try SecureMediaDatagramSubscriber(endpoint: endpoint, credentials: credentials, ticket: ticket, queue: queue)
                        subscriber.onState = state; subscriber.onPayload = payload; subscriber.start()
                        return { subscriber.cancel() }
                    }, closeControl: { channel.cancel() })
                receiver.channel = channel
                let priorState = channel.onState
                channel.onState = { [weak receiver] value in
                    if case .failed(let error) = value { receiver?.stopOnQueue(failed: true, error: error) }
                    if value == .cancelled { receiver?.stopOnQueue(failed: true) }
                    priorState?(value)
                }
                channel.onPayload = { [weak receiver] in receiver?.receive($0) }
                completion(.success(receiver)); receiver.startOnQueue()
            } catch { channel.cancel(); completion(.failure(error)) }
        }
    }
    /// Deterministic transport seam. Production creation is only via attach.
    init(expected: Selection, credentials: AuthenticatedChannelCredentials, queue: DispatchQueue,
         callbacks: Callbacks, nowNanos: @escaping () -> UInt64, sendControl: @escaping ControlSend,
         resolveEndpoint: @escaping EndpointResolver, makeSubscriber: @escaping SubscriberFactory,
         closeControl: @escaping () -> Void) throws {
        guard credentials.isActive, credentials.localRole == .initiator, credentials.channelRole == .mediaControl,
              credentials.negotiated.wireVersion == 2, credentials.roomID == expected.roomID,
              credentials.localPeerID == expected.localPeerID, credentials.remotePeerID == expected.broadcasterPeerID,
              expected.broadcasterEpoch < .max, credentials.negotiated.initiatorCapabilities.contains(.receiveAudio),
              credentials.negotiated.responderCapabilities.contains(.broadcast) else { throw SecureTransportError.invalidCredentials }
        self.expected = expected; self.credentials = credentials; self.queue = queue; self.callbacks = callbacks
        self.nowNanos = nowNanos; self.sendControl = sendControl; self.resolveEndpoint = resolveEndpoint
        self.makeSubscriber = makeSubscriber; self.closeControl = closeControl; startedAt = nowNanos()
    }
    deinit { timer?.cancel(); active?.cancel?(); pending?.cancel?(); channel?.cancel() }
    private func assertQueue() { dispatchPrecondition(condition: .onQueue(queue)) }
    /// Stop also when the trusted room/broadcaster selection changes. Remote
    /// epochs never mutate expected. A stopped instance cannot be restarted.
    public func stop() { queue.async { self.stopOnQueue(failed: false) } }
    public func completePreparation(id: UUID, ready: Bool) { queue.async { self.completePreparationOnQueue(id: id, ready: ready) } }
    public func resynchronize(minimumCaptureTimeNanos: UInt64? = nil) { queue.async { self.requestRecovery(keyframe: false, minimum: minimumCaptureTimeNanos) } }
    public func requestKeyframe(minimumCaptureTimeNanos: UInt64? = nil) { queue.async { self.requestRecovery(keyframe: true, minimum: minimumCaptureTimeNanos) } }
    /// Capture a fresh output/route sample before startup, or during the first
    /// preparation before rejecting insufficient lead. First-lease reports send
    /// immediately; later measurements coalesce to at most one per second.
    public func updateTiming(_ report: MediaReceiverTimingReport) {
        queue.async { self.updateTimingOnQueue(report) }
    }
    func updateTimingOnQueue(_ report: MediaReceiverTimingReport) {
        assertQueue(); guard !stopped, (try? report.validate()) != nil else { return }
        timingSample = (report, nowNanos()); sendTimingIfReady()
    }
    private func sendTimingIfReady(preferred: Lease? = nil) {
        guard !stopped, let sample = timingSample else { return }
        let time = nowNanos()
        guard time >= sample.sampledAt, let report = sample.report.aged(by: time - sample.sampledAt),
              let lease = preferred ?? [pending, active].compactMap({ $0 }).first(where: { $0.preparation != nil }),
              live(lease), lease.preparation != nil else { return }
        let first = !timingSentStreams.contains(lease.ticket.sessionID)
        guard first || (lastTimingSent.map({ time >= $0 && time - $0 >= 1_000_000_000 }) ?? true) else { return }
        timingSentStreams = timingSentStreams.intersection(Set([active, pending].compactMap { $0?.ticket.sessionID }))
        timingSentStreams.insert(lease.ticket.sessionID); lastTimingSent = time
        send(.timingReport(stream: lease.stream, report: report))
    }
    /// The opener must return the admitted `.video` channel inline from
    /// MeshControlPlane.openMediaChannel's completion, before hopping executors.
    /// Video owns its retry/decoder path; its failures never stop audio.
    public func startVideo(openChannel: @escaping VideoChannelOpener, callbacks: VideoReceiverCallbacks) {
        queue.async {
            guard !self.stopped, self.credentials.negotiated.initiatorCapabilities.contains(.receiveVideo) else {
                callbacks.state(.stopped); return
            }
            self.videoReceiver?.stop()
            let mediaQueue = self.queue
            let video = MediaVideoReceiver(credentials: self.credentials, open: { reply in
                openChannel { result in
                    switch result {
                    case .success(let channel): MediaVideoConnection.attach(channel, queue: mediaQueue, completion: reply)
                    case .failure(let error): mediaQueue.async { reply(.failure(error)) }
                    }
                }
            }, callbacks: callbacks, authorized: { [weak self] stream in
                guard let self, !self.stopped, let lease = self.lease(stream) else { return false }
                return lease.expires > self.nowNanos() && lease.pathValidated
            }, requestIDR: { [weak self] floor in self?.requestRecovery(keyframe: true, minimum: floor) }, now: self.nowNanos)
            self.videoReceiver = video
            if let preparation = self.videoPreparation {
                video.select(stream: preparation.anchor.stream, captureFloor: preparation.anchor.captureTimeNanos,
                             generation: preparation.lifecycleGeneration)
            }
        }
    }
    public func stopVideo() {
        queue.async { self.videoReceiver?.stop(); self.videoReceiver = nil }
    }
    /// Completion runs on the media executor after the reliable send completes,
    /// or exactly once with failure when validation, cancellation or expiry wins.
    public func sendAnnotation(_ bytes: Data, completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async {
            guard bytes.count <= AnnotationWireMessage.maximumWireBytes,
                  (try? AnnotationWireMessage(encoded: bytes)) != nil else {
                completion?(.failure(SecureTransportError.malformed)); return
            }
            self.enqueue(bytes, completion: completion)
        }
    }
    func startOnQueue() {
        assertQueue(); guard timer == nil, !stopped else { return }
        callbacks.state(.synchronizing)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume(); tick()
    }
    private func transition(_ value: State) { guard state != value else { return }; state = value; callbacks.state(value) }
    func stopOnQueue(failed: Bool, error: Error = SecurePeerChannelError.cancelled) {
        assertQueue(); guard !stopped else { return }
        stopped = true; generation &+= 1; timer?.cancel(); timer = nil
        videoReceiver?.stop(); videoReceiver = nil; videoPreparation = nil
        timingSample = nil; timingSentStreams.removeAll(); lastTimingSent = nil
        retire(active); retire(pending); active = nil; pending = nil
        let abandoned = outputs; outputs.removeAll()
        request = nil; extraRequests.removeAll(); probes.removeAll(); recentFrames.removeAll(); annotationTraffic = AnnotationTrafficBudget()
        clock.reset(); closeControl(); transition(failed ? .failed : .stopped)
        for output in abandoned { output.completion?(.failure(error)) }
    }
    private func retire(_ lease: Lease?) {
        guard let lease else { return }; credentials.retireSubscriberTicket(lease.ticket)
        lease.cancel?(); lease.cancel = nil; lease.startup.removeAll()
    }
    private func discardPending() {
        guard let pending else { return }
        send(.cancel(stream: pending.stream)); retire(pending); self.pending = nil
        nextAttempt = nowNanos() + 1_000_000_000
        transition(active == nil ? .recovering : (active?.committedPreparation?.anchor.state == .paused ? .paused : .active))
    }
    func tick() {
        assertQueue(); guard !stopped else { return }
        let now = nowNanos()
        guard credentials.isActive, outputs.first.map({ $0.deadline > now }) ?? true else { stopOnQueue(failed: true); return }
        probes = probes.filter { now >= $0.value && now - $0.value < 2_000_000_000 }
        extraRequests = extraRequests.filter { $0.value > now }
        sendTimingIfReady()
        let progress = lastPong ?? startedAt
        if now >= progress, now - progress > 10_000_000_000 { stopOnQueue(failed: true); return }
        if (request?.deadline ?? .max) <= now { request = nil; nextAttempt = now + 1_000_000_000; transition(.recovering) }
        if let active, active.expires <= now { retire(active); self.active = nil; transition(.recovering) }
        if let pending, pending.expires <= now || (!pending.acknowledged && pending.setupDeadline <= now) { discardPending() }
        if let active, let retry = active.retryAnchorAt, now >= retry {
            active.retryAnchorAt = nil; requestRecovery(keyframe: false, minimum: nil)
        }
        videoReceiver?.tick()
        let interval: UInt64 = clock.isReady ? 1_000_000_000 : 250_000_000
        if probes.count < 8, lastPing.map({ now >= $0 && now - $0 >= interval }) ?? true {
            let ping = clock.makePing(at: now)
            if let id = ping.id { probes[id] = now; lastPing = now; send(.clockPing(id: id, clientTimeNanos: now)) }
        }
        guard freshClock() != nil else { return }
        let stalled = active.map { $0.committedPreparation?.anchor.state == .running && now >= $0.lastData && now - $0.lastData > 3_000_000_000 } ?? false
        if request == nil, pending == nil, now >= nextAttempt, active == nil || now >= active!.renewAt || stalled {
            let id = UUID(); request = Request(id: id, deadline: now + 8_000_000_000)
            if let active { send(.renew(requestID: id, stream: active.stream)) }
            else { send(.subscribe(requestID: id, broadcasterEpoch: expected.broadcasterEpoch, channels: [.audio])) }
        }
        for lease in [active, pending].compactMap({ $0 }) {
            if let anchor = lease.deferredAnchor { lease.deferredAnchor = nil; propose(anchor, lease: lease) }
        }
        advance()
    }
    private func freshClock() -> ClockSnapshot? {
        let now = nowNanos()
        guard clock.isReady, let lastPong, now >= lastPong, now - lastPong <= 5_000_000_000,
              let offset = clock.offsetNanos(at: now), let rtt = clock.bestRoundTripNanos else { return nil }
        return ClockSnapshot(offsetNanos: offset, sampledAtLocalNanos: now, roundTripNanos: rtt)
    }
    private func hostTime(local: UInt64, offset: Int64) -> UInt64? {
        if offset >= 0 { let value = local.addingReportingOverflow(UInt64(offset)); return value.overflow ? nil : value.partialValue }
        return local >= offset.magnitude ? local - offset.magnitude : nil
    }
    private func localTime(host: UInt64, offset: Int64) -> UInt64? {
        if offset >= 0 { return host >= UInt64(offset) ? host - UInt64(offset) : nil }
        let value = host.addingReportingOverflow(offset.magnitude); return value.overflow ? nil : value.partialValue
    }
    private func live(_ lease: Lease) -> Bool { !stopped && credentials.isActive && (active === lease || pending === lease) }
    private func lease(_ stream: MediaStreamIdentifier) -> Lease? { [active, pending].compactMap { $0 }.first { $0.stream == stream } }
    func receive(_ bytes: Data) {
        assertQueue(); guard !stopped else { return }
        guard credentials.isActive else { stopOnQueue(failed: true); return }
        guard rawTraffic.accept(bytes.count, now: nowNanos()) else { stopOnQueue(failed: true); return }
        let message: MediaControlWireMessage
        do { message = try MediaControlWireMessage(encoded: bytes) }
        catch {
            guard let kind = MediaOptionalExtension.classify(bytes) else { stopOnQueue(failed: true); return }
            if kind == .annotation {
                guard !annotationDisabled else { return }
                guard bytes.count <= AnnotationWireMessage.maximumWireBytes,
                      let annotation = try? AnnotationWireMessage(encoded: bytes) else { annotationDisabled = true; return }
                let now = nowNanos()
                // Up to 32 participants can each publish a 30 Hz gesture. Byte
                // and message bounds also cover snapshot/control overhead.
                let isSnapshot: Bool
                if case .snapshotChunk = annotation { isSnapshot = true } else { isSnapshot = false }
                guard annotationTraffic.accept(bytes: bytes.count, snapshot: isSnapshot, now: now) else {
                    annotationDisabled = true; return
                }
                if callbacks.annotation(bytes) { return }
                annotationDisabled = true; return
            }
            guard !metadataDisabled else { return }
            guard bytes.count <= CaptureMetadataWireMessage.maximumWireBytes,
                  budget(&auxiliaryTimes, limit: 16), callbacks.metadata(bytes) else { metadataDisabled = true; return }
            return
        }
        guard budget(&controlTimes, limit: 32) else { stopOnQueue(failed: true); return }
        switch message {
        case let .clockPong(id, client, host):
            let now = nowNanos()
            guard probes.removeValue(forKey: id) == client, now >= client, now - client <= 2_000_000_000,
                  clock.acceptPong(ControlMessage(type: "pong", id: id, clientNanos: client, hostNanos: host), receivedAt: now) else { return }
            lastPong = now; if let snapshot = freshClock() { callbacks.clock(snapshot) }; tick()
        case let .subscribed(id, ticket, port): grant(id: id, ticket: ticket, port: port)
        case .anchor(let anchor): if let lease = lease(anchor.stream) { propose(anchor, lease: lease) }
        case let .pause(stream, capture):
            guard let lease = lease(stream) else { return }
            lease.startup.removeAll(); lease.prepared = false; lease.acknowledged = false; lease.preparation = nil
            lease.committedPreparation = nil
            callbacks.paused(stream, capture); transition(.paused)
        case let .rejected(id, _):
            if request?.id == id { request = nil; nextAttempt = nowNanos() + 1_000_000_000; transition(active == nil ? .recovering : .active) }
            extraRequests.removeValue(forKey: id)
        default: stopOnQueue(failed: true)
        }
    }
    private func grant(id: UUID, ticket: MediaSubscriptionTicket, port: UInt16) {
        guard request?.id == id, request!.deadline > nowNanos(), pending == nil else { return }
        guard ticket.roomID == expected.roomID, ticket.senderID == expected.broadcasterPeerID,
              ticket.receiverID == expected.localPeerID, ticket.broadcasterEpoch == expected.broadcasterEpoch,
              ticket.channels == [.audio], ticket.subscriptionSequence > lastSequence,
              ticket.sessionID != active?.ticket.sessionID else { stopOnQueue(failed: true); return }
        do { try credentials.validate(ticket: ticket, subscriber: true) } catch { stopOnQueue(failed: true); return }
        request = nil; lastSequence = ticket.subscriptionSequence
        let lease = Lease(ticket: ticket, now: nowNanos()); pending = lease; transition(active == nil ? .preparing : .active)
        let token = generation
        resolveEndpoint(port) { [weak self, weak lease] result in
            guard let self, let lease, self.generation == token, self.live(lease) else { return }; self.assertQueue()
            do {
                lease.cancel = try self.makeSubscriber(try result.get(), ticket, { [weak self, weak lease] state in
                    guard let self, let lease, self.generation == token, self.live(lease) else { return }
                    self.datagramState(state, lease: lease)
                }, { [weak self, weak lease] channel, bytes in
                    guard let self, let lease, self.generation == token, self.live(lease) else { return }
                    self.datagram(channel, bytes: bytes, lease: lease)
                })
            } catch { self.discardPending() }
        }
    }
    private func datagramState(_ state: SecureMediaTransportState, lease: Lease) {
        assertQueue()
        if state == .active { lease.pathValidated = true; acknowledgeIfReady(lease) }
        if state == .failed || state == .cancelled {
            if pending === lease { discardPending() }
            else { retire(lease); active = nil; transition(.recovering); nextAttempt = nowNanos() + 1_000_000_000; advance() }
        }
    }
    private func propose(_ anchor: MediaStreamAnchor, lease: Lease) {
        guard live(lease) else { return }
        guard let snapshot = freshClock(), let hostNow = hostTime(local: nowNanos(), offset: snapshot.offsetNanos) else { lease.deferredAnchor = anchor; return }
        let tolerance = min(100_000_000, snapshot.roundTripNanos / 2 + 10_000_000)
        guard anchor.issuedAtHostNanos <= hostNow + tolerance,
              hostNow <= anchor.issuedAtHostNanos || hostNow - anchor.issuedAtHostNanos <= MediaControlWireMessage.maximumAnchorAgeNanos,
              active == nil || active === lease || anchor.state == .paused || anchor.hostPlaybackTimeNanos > hostNow + 20_000_000 else {
            if pending === lease { discardPending() }; return
        }
        if lease.preparation?.anchor == anchor { return }
        lease.preparation = Preparation(id: UUID(), lifecycleGeneration: generation, anchor: anchor, clock: snapshot)
        lease.prepared = false; lease.acknowledged = false
        lease.startup = lease.startup.filter { $0.value.frameIndex >= anchor.frameIndex && $0.value.captureTimeNanos >= anchor.captureTimeNanos }
        sendTimingIfReady(preferred: lease)
        if let preparation = lease.preparation { callbacks.prepareAnchor(preparation) }
    }
    func completePreparationOnQueue(id: UUID, ready: Bool) {
        assertQueue(); guard !stopped else { return }
        guard let lease = [active, pending].compactMap({ $0 }).first(where: { $0.preparation?.id == id }),
              lease.preparation?.lifecycleGeneration == generation else { return }
        if !ready {
            if pending === lease { discardPending() }
            else if let committed = lease.committedPreparation {
                lease.preparation = committed; lease.prepared = true; lease.acknowledged = true
                lease.startup.removeAll(); lease.deferredAnchor = nil
                lease.retryAnchorAt = nowNanos() + 1_000_000_000
                transition(committed.anchor.state == .paused ? .paused : .active)
            }
            return
        }
        lease.prepared = true; acknowledgeIfReady(lease)
    }
    private func warmupReady(_ lease: Lease) -> Bool {
        var end: UInt64?, frames: UInt64 = 0
        for packet in lease.startup.values.sorted(by: { $0.frameIndex < $1.frameIndex }) {
            if end != packet.frameIndex { frames = 0 }
            frames += UInt64(packet.frameCount); end = packet.frameIndex + UInt64(packet.frameCount)
            if frames >= 960 { return true }
        }
        return false
    }
    private func acknowledgeIfReady(_ lease: Lease) {
        guard live(lease), lease.pathValidated, lease.prepared, !lease.acknowledged, let preparation = lease.preparation,
              preparation.anchor.state == .paused || warmupReady(lease),
              let snapshot = freshClock(), let hostNow = hostTime(local: nowNanos(), offset: snapshot.offsetNanos),
              lease === active || lease.setupDeadline > nowNanos() else { return }
        let anchor = preparation.anchor
        guard active == nil || active === lease || anchor.state == .paused || anchor.hostPlaybackTimeNanos > hostNow + 20_000_000 else { discardPending(); return }
        lease.acknowledged = true
        lease.committedPreparation = preparation; lease.retryAnchorAt = nil
        send(.anchorReady(stream: lease.stream, frameIndex: anchor.frameIndex, captureTimeNanos: anchor.captureTimeNanos, hostPlaybackTimeNanos: anchor.hostPlaybackTimeNanos))
        guard !stopped else { return }
        videoPreparation = preparation
        videoReceiver?.select(stream: lease.stream, captureFloor: anchor.captureTimeNanos, generation: generation)
        callbacks.anchorCommitted(preparation)
        if anchor.state == .paused { callbacks.paused(lease.stream, anchor.captureTimeNanos) }
        else {
            let packets = lease.startup.values.sorted { $0.frameIndex < $1.frameIndex }; lease.startup.removeAll()
            for packet in packets { deliver(packet, lease: lease) }
        }
        if !stopped, active === lease, lease.preparation?.id == preparation.id {
            transition(anchor.state == .paused ? .paused : .active)
        }
        advance()
    }
    private func advance() {
        guard let pending, pending.acknowledged, let preparation = pending.preparation,
              let deadline = localTime(host: preparation.anchor.hostPlaybackTimeNanos, offset: preparation.clock.offsetNanos),
              active == nil || preparation.anchor.state == .paused || nowNanos() >= deadline else { return }
        let old = active; active = pending; self.pending = nil
        if let old { send(.cancel(stream: old.stream)); retire(old) }
        transition(preparation.anchor.state == .paused ? .paused : .active)
    }
    private func datagram(_ channel: DatagramChannel, bytes: Data, lease: Lease) {
        assertQueue()
        guard channel == .audio, let packet = AudioPacket(data: bytes), packet.captureTimeNanos <= UInt64(Int64.max),
              packet.frameIndex <= UInt64.max - UInt64(packet.frameCount) else { return }
        lease.lastData = nowNanos()
        if lease.committedPreparation?.anchor.state == .running { deliver(packet, lease: lease) }
        if lease.acknowledged { advance(); return }
        if let anchor = lease.preparation?.anchor {
            guard anchor.state == .running, packet.frameIndex >= anchor.frameIndex, packet.captureTimeNanos >= anchor.captureTimeNanos else { return }
        }
        lease.startup[packet.frameIndex] = packet
        while lease.startup.count > 8, let first = lease.startup.keys.min() { lease.startup.removeValue(forKey: first) }
        acknowledgeIfReady(lease)
    }
    private func deliver(_ packet: AudioPacket, lease: Lease) {
        guard live(lease), let anchor = lease.committedPreparation?.anchor, anchor.state == .running,
              let snapshot = freshClock(), let target = localTime(host: packet.captureTimeNanos + anchor.hostPlaybackTimeNanos - anchor.captureTimeNanos,
                                                                 offset: snapshot.offsetNanos) else { return }
        let now = nowNanos()
        guard target >= now || now - target <= 100_000_000,
              target <= now || target - now <= MediaControlWireMessage.maximumAnchorLeadNanos else { return }
        if let floor = retiredFrameFloor, packet.frameIndex <= floor { return }
        if let prior = recentFrames[packet.frameIndex] {
            if prior != packet, pending === lease { discardPending() }; return
        }
        recentFrames[packet.frameIndex] = packet
        while recentFrames.count > 256, let first = recentFrames.keys.min() {
            recentFrames.removeValue(forKey: first); retiredFrameFloor = max(retiredFrameFloor ?? 0, first)
        }
        callbacks.audio(packet, lease.stream, generation)
    }
    private func requestRecovery(keyframe: Bool, minimum: UInt64?) {
        guard !stopped, let active, extraRequests.count < 8, budget(&requestTimes, limit: 4) else { return }
        let id = UUID()
        let message: MediaControlWireMessage = keyframe
            ? .requestKeyframe(requestID: id, stream: active.stream, minimumCaptureTimeNanos: minimum)
            : .resync(requestID: id, stream: active.stream, minimumCaptureTimeNanos: minimum)
        guard (try? message.encoded()) != nil else { return }
        extraRequests[id] = nowNanos() + 2_000_000_000; send(message)
    }
    private func budget(_ times: inout [UInt64], limit: Int) -> Bool {
        let now = nowNanos(); times.removeAll { now < $0 || now - $0 >= 1_000_000_000 }
        guard times.count < limit else { return false }; times.append(now); return true
    }
    private func send(_ message: MediaControlWireMessage) {
        guard let bytes = try? message.encoded() else { stopOnQueue(failed: true); return }; enqueue(bytes)
    }
    private func enqueue(_ bytes: Data, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard !stopped else { completion?(.failure(SecurePeerChannelError.cancelled)); return }
        guard outputs.count < 8, outputs.reduce(0, { $0 + $1.bytes.count }) + bytes.count <= 262_144 else {
            completion?(.failure(SecureTransportError.capacity)); stopOnQueue(failed: true); return
        }
        outputs.append(Output(bytes: bytes, deadline: nowNanos() + 2_000_000_000, completion: completion)); drain()
    }
    private func drain() {
        guard !stopped, !sending, let output = outputs.first else { return }
        sending = true; let token = generation
        sendControl(output.bytes) { [weak self] result in
            guard let self, !self.stopped, self.generation == token, self.outputs.first?.id == output.id else { return }; self.assertQueue()
            if case .failure(let error) = result { self.stopOnQueue(failed: true, error: error); return }
            guard output.deadline > self.nowNanos() else {
                self.stopOnQueue(failed: true, error: SecurePeerChannelError.timedOut); return
            }
            self.outputs.removeFirst(); self.sending = false
            output.completion?(.success(())); self.drain()
        }
    }
}
