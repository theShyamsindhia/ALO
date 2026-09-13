import Foundation

public enum RoomCanvasViewerState: Equatable, Sendable {
    case connecting
    case loadingImage(Double)
    case ready
    case interrupted(String)
    case ended
    case left
}

/// Confined to its canvas executor, like RoomCanvasHostCoordinator. The app
/// reconnects the transport; this object retains the last authoritative state
/// and recovers it through a checkpoint, never by replaying uncertain gestures.
public final class RoomCanvasViewerCoordinator {
    public let roomID: UUID
    public let canvasID: UUID
    public let localID: UUID
    public let ownerID: UUID
    public var onSnapshot: ((RoomCanvasSnapshot?) -> Void)?
    /// Integrity-verified bytes. The app must also validate PNG decoding and
    /// dimensions against the snapshot before showing them as an image.
    public var onImage: ((Data?) -> Void)?
    public var onState: ((RoomCanvasViewerState) -> Void)?
    public var onRejection: ((UUID, AnnotationRejection) -> Void)?
    public private(set) var state: RoomCanvasViewerState = .connecting
    public private(set) var imageBytes: Data?
    public var snapshot: RoomCanvasSnapshot? { replica.snapshot }
    private var replica: RoomCanvasReplica
    private var credentials: AuthenticatedChannelCredentials?
    private var send: ((RoomCanvasMessage) -> Void)?
    private var close: (() -> Void)?
    private var checkpoint = RoomCanvasPayloadAssembler()
    private var image = RoomCanvasPayloadAssembler()
    private var imageDescriptor: RoomCanvasImage?
    private var waitingForCheckpoint: UInt64?
    private var waitingForImage: UInt64?
    private var lastSequence: UInt64 = 0
    private var stopped = false

    public init(roomID: UUID, canvasID: UUID, localID: UUID, ownerID: UUID) {
        self.roomID = roomID; self.canvasID = canvasID; self.localID = localID; self.ownerID = ownerID
        replica = RoomCanvasReplica(roomID: roomID, canvasID: canvasID, ownerID: ownerID)
    }

    public func connect(credentials: AuthenticatedChannelCredentials, nowNanos: UInt64,
                        send: @escaping (RoomCanvasMessage) -> Void, close: @escaping () -> Void) throws {
        guard !stopped, !replica.ended else { throw RoomCanvasError.ended }
        try RoomCanvasChannel.validate(credentials, roomID: roomID, localID: localID, peerID: ownerID)
        guard credentials.localRole == .initiator else { throw SecureTransportError.wrongContext }
        detach()
        self.credentials = credentials; self.send = send; self.close = close
        checkpoint.reset(); image.reset()
        waitingForCheckpoint = nowNanos; waitingForImage = nil
        setState(.connecting)
        send(.join)
    }

    public func disconnected(connectionID: UUID, reason: String) {
        guard credentials?.connectionID == connectionID, !stopped, !replica.ended else { return }
        interrupt(reason)
    }

    public func receive(_ message: RoomCanvasMessage, connectionID: UUID, nowNanos: UInt64) {
        guard !stopped, !replica.ended, let credentials, credentials.connectionID == connectionID else { return }
        guard credentials.isActive else { interrupt("Room access is no longer active."); return }
        do {
            switch message {
            case .checkpointChunk(let chunk):
                guard let data = try checkpoint.append(chunk, nowNanos: nowNanos) else { return }
                let next = try JSONDecoder().decode(RoomCanvasSnapshot.self, from: data)
                let epochChanged = snapshot?.annotations.sessionID != next.annotations.sessionID
                guard next.participants.contains(localID), replica.apply(next, from: ownerID) else {
                    throw SecureTransportError.wrongContext
                }
                // During recovery no commands are accepted until this sequence
                // is known. A changed image starts a different command epoch.
                if waitingForCheckpoint != nil || epochChanged {
                    lastSequence = next.annotations.commandSequences[localID.uuidString] ?? 0
                }
                waitingForCheckpoint = nil
                onSnapshot?(next)
                if imageDescriptor != next.image || imageBytes == nil {
                    if imageDescriptor != next.image || waitingForImage == nil {
                        imageDescriptor = next.image; imageBytes = nil
                        image = RoomCanvasPayloadAssembler(image: next.image)
                        waitingForImage = nowNanos
                        onImage?(nil)
                        self.send?(.requestImage(sha256: next.image.sha256))
                        setState(.loadingImage(0))
                    }
                } else { setState(.ready) }
            case .update(let update):
                if let current = snapshot, update.revision <= current.revision { return }
                guard waitingForCheckpoint == nil else { return }
                guard replica.apply(update, from: ownerID) else { requestCheckpoint(nowNanos: nowNanos); return }
                lastSequence = max(lastSequence, snapshot?.annotations.commandSequences[localID.uuidString] ?? 0)
                onSnapshot?(snapshot)
            case .imageChunk(let chunk):
                guard waitingForImage != nil, let descriptor = imageDescriptor else { throw SecureTransportError.invalidState }
                if let data = try image.append(chunk, nowNanos: nowNanos) {
                    imageBytes = data; waitingForImage = nil; onImage?(data)
                    if waitingForCheckpoint == nil { setState(.ready) }
                } else { setState(.loadingImage(Double(image.bufferedByteCount) / Double(descriptor.byteCount))) }
            case .rejected(let id, let reason): onRejection?(id, reason)
            case .ended:
                replica.end(from: ownerID)
                detach(); imageBytes = nil; imageDescriptor = nil
                checkpoint.reset(); image.reset(); waitingForImage = nil; waitingForCheckpoint = nil
                onImage?(nil); onSnapshot?(nil); setState(.ended)
            default: throw SecureTransportError.invalidState
            }
        } catch { interrupt("The canvas connection needs to recover: \(error.localizedDescription)") }
    }

    @discardableResult
    public func submit(_ action: AnnotationAction) -> UUID? {
        guard state == .ready, !stopped, !replica.ended, credentials?.isActive == true,
              waitingForCheckpoint == nil, let snapshot, lastSequence < UInt64.max - 1 else { return nil }
        lastSequence += 1
        let baseRevision: UInt64?
        if case .deleteObject(let id) = action { baseRevision = snapshot.annotations.objects.first(where: { $0.id == id })?.revision }
        else { baseRevision = nil }
        let command = AnnotationCommand(sessionID: snapshot.annotations.sessionID, sequence: lastSequence,
                                        baseRevision: baseRevision, action: action)
        send?(.command(command))
        return command.id
    }

    public func tick(nowNanos: UInt64) {
        guard credentials != nil, !stopped, !replica.ended else { return }
        guard credentials?.isActive == true else { interrupt("Room access is no longer active."); return }
        let expired = [waitingForCheckpoint, waitingForImage].compactMap { $0 }.contains {
            nowNanos >= $0 && nowNanos - $0 >= 10_000_000_000
        }
        if expired || checkpoint.expire(nowNanos: nowNanos) || image.expire(nowNanos: nowNanos) {
            interrupt("The canvas connection timed out. Reconnect to recover it.")
        }
    }

    /// Leaving is local; it never sends an owner-end command to other people.
    public func leave() {
        guard !stopped else { return }
        stopped = true; detach()
        checkpoint.reset(); image.reset(); imageBytes = nil; imageDescriptor = nil
        replica = RoomCanvasReplica(roomID: roomID, canvasID: canvasID, ownerID: ownerID)
        waitingForCheckpoint = nil; waitingForImage = nil
        onImage?(nil); onSnapshot?(nil); setState(.left)
    }

    private func requestCheckpoint(nowNanos: UInt64) {
        guard waitingForCheckpoint == nil else { return }
        waitingForCheckpoint = nowNanos
        setState(.connecting)
        send?(.requestCheckpoint)
    }

    private func interrupt(_ reason: String) {
        detach(); checkpoint.reset(); image.reset()
        waitingForCheckpoint = nil; waitingForImage = nil
        setState(.interrupted(reason))
    }

    private func detach() {
        let closing = close
        credentials = nil; send = nil; close = nil
        closing?()
    }

    private func setState(_ next: RoomCanvasViewerState) {
        guard next != state else { return }
        state = next; onState?(next)
    }
}
