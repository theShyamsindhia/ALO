import Foundation
import ALOCore

/// Executor-confined companion to MediaHostSession; audio subscriptions remain
/// the authority, and a failure here closes only the affected video channel.
final class MediaVideoHost {
    typealias Send = (Data, @escaping (Result<Void, Error>) -> Void) -> Void
    final class Peer {
        let credentials: AuthenticatedChannelCredentials
        let send: Send
        let close: () -> Void
        let deadline: UInt64
        var stream: MediaStreamIdentifier?
        var queue = VideoSendQueue()
        var sequence: UInt64 = 0
        var inFlight: (data: Data, offset: Int, deadline: UInt64)?
        var operation: UUID?
        var lastKeyframeRequest: UInt64?
        init(credentials: AuthenticatedChannelCredentials, send: @escaping Send, close: @escaping () -> Void, now: UInt64) {
            self.credentials = credentials; self.send = send; self.close = close
            deadline = now + MediaVideoWire.frameDeadlineNanos
        }
    }
    private let authorize: (AuthenticatedChannelCredentials, MediaStreamIdentifier) -> UInt64?
    private let requestKeyframe: (UUID, MediaStreamIdentifier, UInt64?) -> Void
    private let now: () -> UInt64
    private(set) var peers: [UUID: Peer] = [:]
    private var enabled = false

    init(authorize: @escaping (AuthenticatedChannelCredentials, MediaStreamIdentifier) -> UInt64?,
         requestKeyframe: @escaping (UUID, MediaStreamIdentifier, UInt64?) -> Void, now: @escaping () -> UInt64) {
        self.authorize = authorize; self.requestKeyframe = requestKeyframe; self.now = now
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { stop() }
    }
    func stop() { for id in Array(peers.keys) { remove(id) } }
    func requireKeyframe() {
        for peer in Array(peers.values) {
            peer.queue.reset()
            if peer.operation == nil { requestIDR(peer) }
        }
    }
    func add(credentials: AuthenticatedChannelCredentials, send: @escaping Send, close: @escaping () -> Void) throws {
        guard enabled, credentials.isActive, credentials.localRole == .responder,
              credentials.channelRole == .video, credentials.negotiated.wireVersion == 2,
              credentials.negotiated.initiatorCapabilities.contains(.receiveVideo),
              credentials.negotiated.responderCapabilities.contains(.broadcast) else { throw SecureTransportError.invalidCredentials }
        guard peers.count < 64, peers[credentials.connectionID] == nil,
              peers.values.filter({ $0.credentials.remotePeerID == credentials.remotePeerID }).count < 2 else {
            throw SecureTransportError.capacity
        }
        peers[credentials.connectionID] = Peer(credentials: credentials, send: send, close: close, now: now())
    }
    func remove(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.queue.reset(); peer.inFlight = nil; peer.operation = nil; peer.close()
    }
    func receive(_ data: Data, from id: UUID) {
        guard let peer = peers[id] else { return }
        do {
            guard peer.stream == nil, peer.deadline > now() else { throw SecureTransportError.invalidState }
            let stream = try MediaVideoWire.decodeBinding(data, accepted: false)
            guard authorize(peer.credentials, stream) != nil else { throw SecureTransportError.invalidCredentials }
            peer.stream = stream
            let operation = UUID(); peer.operation = operation
            peer.send(try MediaVideoWire.binding(stream, accepted: true)) { [weak self, weak peer] result in
                guard let self, let peer, self.peers[id] === peer, peer.operation == operation else { return }
                guard case .success = result, peer.deadline > self.now() else { self.remove(id); return }
                peer.operation = nil; self.requestIDR(peer); self.drain(peer)
            }
        } catch { remove(id) }
    }
    func publish(_ frame: VideoFrame) {
        tick()
        guard enabled, MediaVideoWire.validate(frame) else { return }
        for peer in Array(peers.values) {
            guard let stream = peer.stream, let floor = authorize(peer.credentials, stream), frame.captureTimeNanos >= floor else { continue }
            peer.queue.append(frame, nowNanos: now()); drain(peer)
            if peer.operation == nil, peer.queue.requiresKeyframe { requestIDR(peer) }
        }
    }
    func tick() {
        let time = now()
        for peer in Array(peers.values) {
            let invalid = !peer.credentials.isActive ||
                (peer.stream == nil && time >= peer.deadline) ||
                (peer.operation != nil && peer.inFlight == nil && time >= peer.deadline) ||
                peer.stream.map({ authorize(peer.credentials, $0) == nil }) == true ||
                peer.inFlight.map({ time >= $0.deadline }) == true
            if invalid { remove(peer.credentials.connectionID) }
        }
    }
    private func requestIDR(_ peer: Peer) {
        guard let stream = peer.stream, let floor = authorize(peer.credentials, stream) else { return }
        let time = now()
        guard peer.lastKeyframeRequest.map({ time >= $0 && time - $0 >= 250_000_000 }) ?? true else { return }
        peer.lastKeyframeRequest = time
        requestKeyframe(peer.credentials.remotePeerID, stream, floor)
    }
    private func drain(_ peer: Peer) {
        guard peers[peer.credentials.connectionID] === peer, peer.operation == nil,
              let stream = peer.stream, authorize(peer.credentials, stream) != nil else { return }
        if peer.inFlight == nil {
            guard let entry = peer.queue.takeNext(nowNanos: now()) else {
                if peer.queue.requiresKeyframe { requestIDR(peer) }; return
            }
            guard peer.sequence < .max else { remove(peer.credentials.connectionID); return }
            peer.sequence += 1
            peer.inFlight = (entry.frame.encoded(), 0, now() + MediaVideoWire.frameDeadlineNanos)
        }
        guard let frame = peer.inFlight else { return }
        guard frame.deadline > now() else { remove(peer.credentials.connectionID); return }
        let operation = UUID(); peer.operation = operation
        peer.send(MediaVideoWire.chunk(frame.data, sequence: peer.sequence, offset: frame.offset)) { [weak self, weak peer] result in
            guard let self, let peer, self.peers[peer.credentials.connectionID] === peer, peer.operation == operation else { return }
            guard case .success = result, frame.deadline > self.now() else { self.remove(peer.credentials.connectionID); return }
            peer.operation = nil
            let next = frame.offset + MediaVideoWire.chunkBytes
            peer.inFlight = next >= frame.data.count ? nil : (frame.data, next, frame.deadline)
            self.drain(peer)
        }
    }
}
