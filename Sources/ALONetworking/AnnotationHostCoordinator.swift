import Foundation
import ALOCore

/// Own on the same serial queue as the admitted media channels. The application
/// multiplexes annotation messages alongside media subscription/control messages.
/// The authenticated channel supplies the actor; payloads never supply identity.
public final class AnnotationHostCoordinator {
    public typealias Send = (Data, @escaping (Result<Void, Error>) -> Void) -> Void
    private final class Peer {
        let credentials: AuthenticatedChannelCredentials
        let output: AnnotationReliableOutput
        var supported = false
        var lastSnapshotRequest: UInt64?
        var snapshotPending = false
        init(credentials: AuthenticatedChannelCredentials, send: @escaping Send, close: @escaping (Error) -> Void) {
            self.credentials = credentials
            output = AnnotationReliableOutput(send: send, close: close)
        }
    }
    public let roomID: UUID
    public let presenterID: UUID
    public var onSnapshot: ((AnnotationSnapshot?) -> Void)?
    public var onEvent: ((AnnotationEvent) -> Void)?
    public var onLocalRejection: ((UUID, AnnotationRejection) -> Void)?
    private let isPublicRoom: Bool
    private var authority: AnnotationAuthority?
    private var peers: [UUID: Peer] = [:]
    private var pendingEvents: [AnnotationEvent] = []
    private var publishing = false

    public init(roomID: UUID, presenterID: UUID, isPublicRoom: Bool) {
        self.roomID = roomID; self.presenterID = presenterID; self.isPublicRoom = isPublicRoom
    }

    /// Every source change/restart must call this, even when selecting the same window.
    public func beginSource(nowNanos: UInt64) {
        endSource()
        let next = AnnotationAuthority(presenterID: presenterID.uuidString, isPublicRoom: isPublicRoom)
        authority = next
        let snapshot = next.snapshot(nowNanos: nowNanos)
        onSnapshot?(snapshot)
        for peer in peers.values where peer.supported { sendSnapshot(to: peer, nowNanos: nowNanos) }
    }

    public func endSource() {
        if let authority {
            for peer in peers.values where peer.supported { peer.output.enqueue(.ended(sessionID: authority.sessionID)) }
        }
        authority = nil
        onSnapshot?(nil)
    }

    public func addPeer(credentials: AuthenticatedChannelCredentials, send: @escaping Send,
                        close: @escaping (Error) -> Void) throws {
        guard credentials.isActive, credentials.roomID == roomID, credentials.localPeerID == presenterID,
              credentials.localRole == .responder, credentials.channelRole == .mediaControl,
              credentials.negotiated.initiatorCapabilities.contains(.receiveVideo) else {
            throw SecureTransportError.invalidCredentials
        }
        guard peers[credentials.connectionID] == nil, peers.count < 64 else { throw SecureTransportError.capacity }
        let peer = Peer(credentials: credentials, send: send, close: close)
        peers[credentials.connectionID] = peer
        peer.output.enqueue(.hello(capabilities: [AnnotationWireMessage.capability]))
    }

    public func removePeer(connectionID: UUID, nowNanos: UInt64) {
        guard let peer = peers.removeValue(forKey: connectionID) else { return }
        peer.output.cancel()
        // Another admitted connection for the same actor may still own its gesture.
        let actor = peer.credentials.remotePeerID
        guard !peers.values.contains(where: { $0.credentials.remotePeerID == actor && $0.credentials.isActive }) else { return }
        if var authority {
            let events = authority.disconnect(actorID: actor.uuidString, nowNanos: nowNanos)
            self.authority = authority
            publish(events)
        }
    }

    public func receive(_ data: Data, connectionID: UUID, nowNanos: UInt64) {
        guard let peer = peers[connectionID] else { return }
        guard peer.credentials.isActive else { removePeer(connectionID: connectionID, nowNanos: nowNanos); return }
        do {
            switch try AnnotationWireMessage(encoded: data) {
            case .hello(let capabilities):
                guard !peer.supported else { throw SecureTransportError.invalidState }
                peer.supported = capabilities.contains(AnnotationWireMessage.capability)
                if peer.supported { sendSnapshot(to: peer, nowNanos: nowNanos) }
            case .command(let command):
                guard peer.supported else { throw SecureTransportError.unsupportedProtocol }
                guard var authority else {
                    peer.output.enqueue(.rejection(commandID: command.id, reason: .wrongSession)); return
                }
                let result = authority.process(command, actorID: peer.credentials.remotePeerID.uuidString, nowNanos: nowNanos)
                self.authority = authority
                publish(result.events)
                if let reason = result.rejection { peer.output.enqueue(.rejection(commandID: command.id, reason: reason)) }
            case .requestSnapshot:
                guard peer.supported else { throw SecureTransportError.unsupportedProtocol }
                if let last = peer.lastSnapshotRequest, nowNanos < last || nowNanos - last < 1_000_000_000 {
                    // Coalesce retries without tearing down this peer's media.
                    // tick sends one current snapshot when the window opens.
                    peer.snapshotPending = true
                    return
                }
                peer.lastSnapshotRequest = nowNanos
                peer.snapshotPending = false
                sendSnapshot(to: peer, nowNanos: nowNanos)
            default: throw SecureTransportError.invalidState
            }
        } catch {
            peer.output.fail(error)
            removePeer(connectionID: connectionID, nowNanos: nowNanos)
        }
    }

    public func processLocal(_ command: AnnotationCommand, nowNanos: UInt64) {
        guard var authority else { onLocalRejection?(command.id, .wrongSession); return }
        let result = authority.process(command, actorID: presenterID.uuidString, nowNanos: nowNanos)
        self.authority = authority
        publish(result.events)
        if let reason = result.rejection { onLocalRejection?(command.id, reason) }
    }

    /// Call periodically while sharing, including when no packets arrive, for TTL/lease expiry.
    public func tick(nowNanos: UInt64) {
        for id in peers.keys.filter({ peers[$0]?.credentials.isActive == false }) {
            removePeer(connectionID: id, nowNanos: nowNanos)
        }
        for peer in Array(peers.values) where peer.supported && peer.snapshotPending {
            if let last = peer.lastSnapshotRequest, nowNanos < last || nowNanos - last < 1_000_000_000 { continue }
            peer.snapshotPending = false
            peer.lastSnapshotRequest = nowNanos
            sendSnapshot(to: peer, nowNanos: nowNanos)
        }
        guard var authority else { return }
        let events = authority.advance(nowNanos: nowNanos)
        self.authority = authority
        publish(events)
    }

    private func publish(_ events: [AnnotationEvent]) {
        pendingEvents.append(contentsOf: events)
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        while !pendingEvents.isEmpty {
            let event = pendingEvents.removeFirst()
            guard authority?.sessionID == event.sessionID else { continue }
            onEvent?(event)
            // Observers can stop/restart capture synchronously. Neither this
            // event nor queued events from that retired source may follow the
            // replacement snapshot onto the media-control channel.
            guard authority?.sessionID == event.sessionID else { continue }
            // A synchronous failure callback may remove a peer and publish
            // cleanup events. Queue those after every observer receives this
            // revision; never let nested publication jump ahead of it.
            for peer in Array(peers.values) where peer.supported && peer.credentials.isActive {
                guard authority?.sessionID == event.sessionID else { break }
                peer.output.enqueue(.event(event))
            }
        }
    }

    private func sendSnapshot(to peer: Peer, nowNanos: UInt64) {
        guard let authority else { return }
        do {
            for chunk in try AnnotationSnapshotChunk.split(authority.snapshot(nowNanos: nowNanos)) {
                peer.output.enqueue(.snapshotChunk(chunk))
            }
        } catch { peer.output.fail(error) }
    }
}

/// No silent loss of ends/deletes/policy commands: on overflow the affected
/// channel explicitly fails and reconnects for a fresh snapshot. Other peers
/// have independent queues. Transport completion must return on its owning queue.
final class AnnotationReliableOutput {
    private let send: AnnotationHostCoordinator.Send
    private let close: (Error) -> Void
    private var pending: [Data] = []
    private var queuedBytes = 0
    private var sending = false
    private var cancelled = false
    init(send: @escaping AnnotationHostCoordinator.Send, close: @escaping (Error) -> Void) {
        self.send = send; self.close = close
    }
    func enqueue(_ message: AnnotationWireMessage) {
        guard !cancelled else { return }
        do {
            let data = try message.encoded()
            guard pending.count < 128, queuedBytes <= 12 * 1_024 * 1_024 - data.count else {
                throw SecureTransportError.capacity
            }
            queuedBytes += data.count; pending.append(data)
            drain()
        } catch { fail(error) }
    }
    func cancel() { cancelled = true; pending.removeAll(); queuedBytes = 0 }
    func fail(_ error: Error) {
        guard !cancelled else { return }
        cancel(); close(error)
    }
    private func drain() {
        guard !cancelled, !sending, !pending.isEmpty else { return }
        let data = pending.removeFirst()
        sending = true
        send(data) { [weak self] result in
            guard let self, !self.cancelled else { return }
            self.queuedBytes -= data.count; self.sending = false
            switch result { case .success: self.drain(); case .failure(let error): self.fail(error) }
        }
    }
}
