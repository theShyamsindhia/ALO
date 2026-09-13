import Foundation
import CryptoKit

/// Whole payloads stay whole until the connection streams them. Drawing
/// updates never re-send an image or compete with media annotation messages.
public enum RoomCanvasTransmission: Sendable {
    case message(RoomCanvasMessage)
    case checkpoint(RoomCanvasSnapshot)
    case image(Data, RoomCanvasImage)
    case end
}

extension RoomCanvasChannel {
    public func send(_ transmission: RoomCanvasTransmission) {
        switch transmission {
        case .message(let message): send(message)
        case .checkpoint(let snapshot): sendCheckpoint(snapshot)
        case .image(let bytes, let descriptor): sendImage(bytes, descriptor: descriptor)
        case .end: finish()
        }
    }
}

/// All methods and callbacks belong to one dedicated canvas executor shared
/// by this host's connections. Send/close callbacks must enqueue work rather
/// than synchronously re-enter this coordinator (as RoomCanvasChannel does).
public final class RoomCanvasHostCoordinator {
    public typealias Send = (RoomCanvasTransmission) -> Void
    private final class Peer {
        let credentials: AuthenticatedChannelCredentials
        let send: Send
        let close: () -> Void
        let admittedAt: UInt64
        var joined = false
        var lastCheckpoint: UInt64?
        var checkpointPending = false
        var lastImage: (Data, UInt64)?
        init(credentials: AuthenticatedChannelCredentials, nowNanos: UInt64,
             send: @escaping Send, close: @escaping () -> Void) {
            self.credentials = credentials; admittedAt = nowNanos; self.send = send; self.close = close
        }
    }
    public let roomID: UUID
    public let canvasID: UUID
    public let ownerID: UUID
    public var onSnapshot: ((RoomCanvasSnapshot?) -> Void)?
    public var onLocalRejection: ((UUID, AnnotationRejection) -> Void)?
    private var authority: RoomCanvasAuthority
    private var image: RoomCanvasImage
    private var imageBytes: Data
    private var peers: [UUID: Peer] = [:]
    public private(set) var ended = false

    public init(roomID: UUID, canvasID: UUID = UUID(), ownerID: UUID,
                image: RoomCanvasImage, bytes: Data, isPublicRoom: Bool) throws {
        try Self.validateImage(image, bytes: bytes)
        self.roomID = roomID; self.canvasID = canvasID; self.ownerID = ownerID
        self.image = image; imageBytes = bytes
        authority = try RoomCanvasAuthority(roomID: roomID, canvasID: canvasID, ownerID: ownerID,
                                            image: image, isPublicRoom: isPublicRoom)
    }

    public func snapshot(nowNanos: UInt64) -> RoomCanvasSnapshot? { authority.snapshot(nowNanos: nowNanos) }

    public func addPeer(credentials: AuthenticatedChannelCredentials, nowNanos: UInt64,
                        send: @escaping Send, close: @escaping () -> Void) throws {
        guard !ended else { throw RoomCanvasError.ended }
        try RoomCanvasChannel.validate(credentials, roomID: roomID, localID: ownerID, peerID: credentials.remotePeerID)
        guard credentials.localRole == .responder else { throw SecureTransportError.wrongContext }
        guard peers[credentials.connectionID] == nil else { throw SecureTransportError.invalidState }
        // Replace a disconnected/retried installation without allowing its old
        // close callback to remove the new connection or leave a live gesture.
        for (id, peer) in peers where peer.credentials.remotePeerID == credentials.remotePeerID {
            removePeer(connectionID: id, nowNanos: nowNanos)
        }
        guard peers.count < 63 else { throw SecureTransportError.capacity }
        peers[credentials.connectionID] = Peer(credentials: credentials, nowNanos: nowNanos, send: send, close: close)
    }

    public func removePeer(connectionID: UUID, nowNanos: UInt64) {
        guard let peer = peers.removeValue(forKey: connectionID) else { return }
        peer.close()
        if peer.joined && !ended {
            authority.disconnect(peer.credentials.remotePeerID, nowNanos: nowNanos)
            publish(nowNanos: nowNanos)
        }
    }

    public func receive(_ message: RoomCanvasMessage, connectionID: UUID, nowNanos: UInt64) {
        guard !ended, let peer = peers[connectionID] else { return }
        guard peer.credentials.isActive else { removePeer(connectionID: connectionID, nowNanos: nowNanos); return }
        do {
            if case .join = message {
                if peer.joined { requestCheckpoint(peer, nowNanos: nowNanos); return }
                try authority.join(peer.credentials.remotePeerID, nowNanos: nowNanos)
                // Existing participants get the join; the new participant gets
                // the full checkpoint, never an update against an unknown base.
                publish(nowNanos: nowNanos)
                peer.joined = true
                sendCheckpoint(peer, nowNanos: nowNanos)
                return
            }
            guard peer.joined else { throw SecureTransportError.invalidState }
            switch message {
            case .command(let command):
                let result = authority.process(command, from: peer.credentials.remotePeerID, nowNanos: nowNanos)
                publish(nowNanos: nowNanos)
                if let reason = result.rejection { peer.send(.message(.rejected(commandID: command.id, reason: reason))) }
            case .requestCheckpoint: requestCheckpoint(peer, nowNanos: nowNanos)
            case .requestImage(let digest):
                guard digest == image.sha256 else { requestCheckpoint(peer, nowNanos: nowNanos); return }
                if let (lastDigest, lastTime) = peer.lastImage, lastDigest == digest,
                   !Self.elapsed(nowNanos, since: lastTime, interval: 10_000_000_000) { return }
                peer.lastImage = (digest, nowNanos)
                peer.send(.image(imageBytes, image))
            default: throw SecureTransportError.invalidState
            }
        } catch { removePeer(connectionID: connectionID, nowNanos: nowNanos) }
    }

    public func processLocal(_ action: AnnotationAction, nowNanos: UInt64) {
        guard let snapshot = snapshot(nowNanos: nowNanos), !ended else { return }
        let sequence = snapshot.annotations.commandSequences[ownerID.uuidString] ?? 0
        guard sequence < UInt64.max - 1 else { return }
        let baseRevision: UInt64?
        if case .deleteObject(let id) = action { baseRevision = snapshot.annotations.objects.first(where: { $0.id == id })?.revision }
        else { baseRevision = nil }
        let command = AnnotationCommand(sessionID: snapshot.annotations.sessionID, sequence: sequence + 1,
                                        baseRevision: baseRevision, action: action)
        let result = authority.process(command, from: ownerID, nowNanos: nowNanos)
        publish(nowNanos: nowNanos)
        if let reason = result.rejection { onLocalRejection?(command.id, reason) }
    }

    public func replaceImage(_ image: RoomCanvasImage, bytes: Data, nowNanos: UInt64) throws {
        guard !ended else { throw RoomCanvasError.ended }
        try Self.validateImage(image, bytes: bytes)
        try authority.replaceImage(image, by: ownerID, nowNanos: nowNanos)
        self.image = image; imageBytes = bytes
        for peer in peers.values where peer.joined { sendCheckpoint(peer, nowNanos: nowNanos) }
        onSnapshot?(snapshot(nowNanos: nowNanos))
    }

    public func end() {
        guard !ended else { return }
        ended = true
        try? authority.end(by: ownerID)
        for peer in peers.values {
            if peer.joined { peer.send(.end) } else { peer.close() }
        }
        peers.removeAll(); imageBytes.removeAll()
        onSnapshot?(nil)
    }

    /// Tick even when nobody draws: incomplete joins and revoked memberships
    /// cannot retain connections, and coalesced checkpoints must eventually go.
    public func tick(nowNanos: UInt64) {
        for (id, peer) in peers {
            if !peer.credentials.isActive || (!peer.joined && Self.elapsed(nowNanos, since: peer.admittedAt, interval: 5_000_000_000)) {
                removePeer(connectionID: id, nowNanos: nowNanos)
            } else if peer.checkpointPending, peer.lastCheckpoint.map({ Self.elapsed(nowNanos, since: $0, interval: 1_000_000_000) }) ?? true {
                sendCheckpoint(peer, nowNanos: nowNanos)
            }
        }
    }

    private func requestCheckpoint(_ peer: Peer, nowNanos: UInt64) {
        if let last = peer.lastCheckpoint, !Self.elapsed(nowNanos, since: last, interval: 1_000_000_000) {
            peer.checkpointPending = true
        } else { sendCheckpoint(peer, nowNanos: nowNanos) }
    }

    private func sendCheckpoint(_ peer: Peer, nowNanos: UInt64) {
        guard let snapshot = snapshot(nowNanos: nowNanos) else { return }
        peer.lastCheckpoint = nowNanos; peer.checkpointPending = false
        peer.send(.checkpoint(snapshot))
    }

    private func publish(nowNanos: UInt64) {
        guard let update = authority.lastUpdate else { return }
        // A large owner policy change can finish many strokes at once. Fall
        // back to a bounded streamed checkpoint if one update doesn't fit.
        let fits = (try? RoomCanvasMessage.update(update).encoded(roomID: roomID, canvasID: canvasID)) != nil
        for peer in peers.values where peer.joined && peer.credentials.isActive {
            if fits { peer.send(.message(.update(update))) }
            else { sendCheckpoint(peer, nowNanos: nowNanos) }
        }
        onSnapshot?(snapshot(nowNanos: nowNanos))
    }

    private static func validateImage(_ image: RoomCanvasImage, bytes: Data) throws {
        guard image.isValid, bytes.count == image.byteCount, Data(SHA256.hash(data: bytes)) == image.sha256 else {
            throw RoomCanvasError.invalidImage
        }
    }

    private static func elapsed(_ now: UInt64, since: UInt64, interval: UInt64) -> Bool {
        now >= since && now - since >= interval
    }
}
