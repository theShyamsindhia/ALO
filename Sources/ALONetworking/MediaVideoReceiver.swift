import Foundation
import ALOCore

public enum VideoReceiverState: Equatable, Sendable { case connecting, active, recovering, stopped }
public struct VideoReceiverCallbacks {
    public var frame: (VideoFrame, MediaStreamIdentifier, UInt64) -> Void
    public var state: (VideoReceiverState) -> Void
    public init(frame: @escaping (VideoFrame, MediaStreamIdentifier, UInt64) -> Void,
                state: @escaping (VideoReceiverState) -> Void = { _ in }) {
        self.frame = frame; self.state = state
    }
}
public typealias VideoChannelOpener = (@escaping (Result<SecurePeerChannel, Error>) -> Void) -> Void

final class MediaVideoConnection {
    let credentials: AuthenticatedChannelCredentials
    let send: MediaVideoHost.Send
    let close: () -> Void
    var payload: ((Data) -> Void)?
    var failed: (() -> Void)?
    init(credentials: AuthenticatedChannelCredentials, send: @escaping MediaVideoHost.Send, close: @escaping () -> Void) {
        self.credentials = credentials; self.send = send; self.close = close
    }
    static func attach(_ channel: SecurePeerChannel, queue: DispatchQueue,
                       completion: @escaping (Result<MediaVideoConnection, Error>) -> Void) {
        channel.withAuthenticatedCredentials { result in
            do {
                guard channel.mediaExecutor === queue else { throw SecureTransportError.invalidState }
                let connection = MediaVideoConnection(credentials: try result.get(),
                    send: { channel.send(payload: $0, completion: $1) }, close: { channel.cancel() })
                channel.onPayload = { [weak connection] in connection?.payload?($0) }
                channel.onState = { [weak connection] state in
                    if case .failed = state { connection?.failed?() }
                    if state == .cancelled { connection?.failed?() }
                }
                completion(.success(connection))
            } catch {
                channel.cancel()
                // A mismatched channel executes this closure on its own queue.
                // Never mutate the video receiver from that foreign executor.
                queue.async { completion(.failure(error)) }
            }
        }
    }
}

final class MediaVideoReceiver {
    typealias Open = (@escaping (Result<MediaVideoConnection, Error>) -> Void) -> Void
    private struct Selection: Equatable {
        let stream: MediaStreamIdentifier
        let captureFloor: UInt64
        let generation: UInt64
    }
    private final class Link {
        let id = UUID()
        let selection: Selection
        let connection: MediaVideoConnection
        let deadline: UInt64
        var bound = false
        var awaitingIDR = true
        var assembler = MediaVideoAssembler()
        var lastProgress: UInt64
        var heartbeatSequence: UInt64 = 0
        var pongInFlight = false
        init(selection: Selection, connection: MediaVideoConnection, now: UInt64) {
            self.selection = selection; self.connection = connection
            deadline = now + MediaVideoWire.frameDeadlineNanos; lastProgress = now
        }
    }
    private let credentials: AuthenticatedChannelCredentials
    private let open: Open
    private let callbacks: VideoReceiverCallbacks
    private let authorized: (MediaStreamIdentifier) -> Bool
    private let requestIDR: (UInt64) -> Void
    private let now: () -> UInt64
    private var selection: Selection?
    private var active: Link?, candidate: Link?
    private var opening: UUID?
    private var openingDeadline: UInt64 = 0
    private var retryAt: UInt64 = 0
    private var attempts = 0
    private var stopped = false
    private var lastCapture: UInt64?
    private var lastIDRRequest: UInt64?

    init(credentials: AuthenticatedChannelCredentials, open: @escaping Open, callbacks: VideoReceiverCallbacks,
         authorized: @escaping (MediaStreamIdentifier) -> Bool, requestIDR: @escaping (UInt64) -> Void,
         now: @escaping () -> UInt64) {
        self.credentials = credentials; self.open = open; self.callbacks = callbacks
        self.authorized = authorized; self.requestIDR = requestIDR; self.now = now
    }
    func select(stream: MediaStreamIdentifier, captureFloor: UInt64, generation: UInt64) {
        guard !stopped else { return }
        let next = Selection(stream: stream, captureFloor: captureFloor, generation: generation)
        guard next != selection else { return }
        selection = next; opening = nil
        let oldCandidate = candidate; candidate = nil; oldCandidate?.connection.close()
        retryAt = now(); attempts = 0; tick()
    }
    func suspend() {
        selection = nil; opening = nil
        let links = [active, candidate].compactMap { $0 }; active = nil; candidate = nil
        for link in links { link.connection.close() }
        callbacks.state(.stopped)
    }
    func stop() { guard !stopped else { return }; stopped = true; suspend() }
    func tick() {
        guard !stopped, credentials.isActive, let selection else { return }
        if !authorized(selection.stream) { suspend(); return }
        let time = now()
        if opening != nil, time >= openingDeadline { opening = nil; retry() }
        if let active, !active.connection.credentials.isActive || !authorized(active.selection.stream) || active.assembler.expired(now: time) ||
            (time >= active.lastProgress && time - active.lastProgress >= MediaVideoWire.frameDeadlineNanos) {
            fail(active)
        }
        if let candidate, time >= candidate.deadline || !candidate.connection.credentials.isActive || candidate.assembler.expired(now: time) {
            fail(candidate)
        }
        let needsConnection = active == nil || active?.selection != selection
        guard needsConnection, candidate == nil, opening == nil, time >= retryAt else { return }
        let operation = UUID(); opening = operation
        openingDeadline = time + MediaVideoWire.openDeadlineNanos
        callbacks.state(active == nil ? (attempts == 0 ? .connecting : .recovering) : .active)
        open { [weak self] result in
            guard let self, !self.stopped, self.opening == operation, self.selection == selection,
                  self.authorized(selection.stream) else {
                if case .success(let connection) = result { connection.close() }; return
            }
            self.opening = nil
            do {
                let connection = try result.get(), peer = connection.credentials
                guard peer.isActive, peer.roomID == self.credentials.roomID,
                      peer.localPeerID == self.credentials.localPeerID, peer.remotePeerID == self.credentials.remotePeerID,
                      peer.channelRole == .video, peer.localRole == .initiator, peer.negotiated.wireVersion == 2,
                      peer.negotiated.initiatorCapabilities.contains(.receiveVideo),
                      peer.negotiated.responderCapabilities.contains(.broadcast) else {
                    connection.close(); throw SecureTransportError.invalidCredentials
                }
                let link = Link(selection: selection, connection: connection, now: self.now()); self.candidate = link
                connection.payload = { [weak self, weak link] data in if let link { self?.receive(data, link: link) } }
                connection.failed = { [weak self, weak link] in if let link { self?.fail(link) } }
                connection.send(try MediaVideoWire.binding(selection.stream, accepted: false)) { [weak self, weak link] result in
                    if case .failure = result, let link { self?.fail(link) }
                }
            } catch { self.retry() }
        }
    }
    private func receive(_ data: Data, link: Link) {
        guard !stopped, active === link || candidate === link else { return }
        guard credentials.isActive, link.connection.credentials.isActive, authorized(link.selection.stream) else { fail(link); return }
        do {
            if !link.bound {
                guard try MediaVideoWire.decodeBinding(data, accepted: true) == link.selection.stream else { throw SecureTransportError.wrongContext }
                link.bound = true; link.lastProgress = now(); requestKeyframe(link); return
            }
            if let nonce = MediaVideoWire.heartbeatNonce(data, reply: false) {
                guard nonce > link.heartbeatSequence, !link.pongInFlight else { throw SecureTransportError.replay }
                link.heartbeatSequence = nonce; link.lastProgress = now(); link.pongInFlight = true
                link.connection.send(MediaVideoWire.heartbeat(nonce, reply: true)) { [weak self, weak link] result in
                    guard let self, let link, self.active === link || self.candidate === link else { return }
                    link.pongInFlight = false
                    if case .failure = result { self.fail(link) }
                }
                return
            }
            let assembled = try link.assembler.append(data, now: now())
            link.lastProgress = now()
            guard let frame = assembled else { return }
            guard frame.captureTimeNanos >= link.selection.captureFloor else { return }
            if link.awaitingIDR {
                guard frame.isKeyframe, !frame.parameterSet1.isEmpty, !frame.parameterSet2.isEmpty else { requestKeyframe(link); return }
                link.awaitingIDR = false
            }
            if candidate === link {
                let old = active; active = link; candidate = nil; attempts = 0
                old?.connection.close(); callbacks.state(.active)
            }
            guard lastCapture.map({ frame.captureTimeNanos > $0 }) ?? true else { return }
            lastCapture = frame.captureTimeNanos
            callbacks.frame(frame, link.selection.stream, link.selection.generation)
        } catch { fail(link) }
    }
    private func requestKeyframe(_ link: Link) {
        let time = now()
        guard lastIDRRequest.map({ time >= $0 && time - $0 >= 250_000_000 }) ?? true else { return }
        lastIDRRequest = time; requestIDR(link.selection.captureFloor)
    }
    private func fail(_ link: Link) {
        guard active === link || candidate === link else { return }
        if active === link { active = nil }
        if candidate === link { candidate = nil }
        link.connection.close(); retry()
    }
    private func retry() {
        attempts = min(attempts + 1, 6)
        retryAt = now() + UInt64(min(15, 0.5 * pow(2, Double(attempts - 1))) * 1_000_000_000)
        callbacks.state(active == nil ? .recovering : .active)
    }
}
