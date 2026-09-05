import Foundation
import ALOCore

/// Serial media-channel-owned viewer replica. It never accepts annotation events
/// from another room participant: only this admitted broadcaster connection.
public final class AnnotationViewerCoordinator {
    public var onSnapshot: ((AnnotationSnapshot?) -> Void)?
    public var onEvent: ((AnnotationEvent) -> Void)?
    public var onRejection: ((UUID, AnnotationRejection) -> Void)?
    public var onSupportChanged: ((Bool) -> Void)?
    private let credentials: AuthenticatedChannelCredentials
    private let output: AnnotationReliableOutput
    private var assembler = AnnotationSnapshotAssembler()
    private var replica = AnnotationReplica()
    private var sessionID: UUID?
    private var supported = false
    private var receivedHello = false
    private var requestingSnapshot = false
    private var closed = false

    public init(credentials: AuthenticatedChannelCredentials, send: @escaping AnnotationHostCoordinator.Send,
                close: @escaping (Error) -> Void) throws {
        guard credentials.isActive, credentials.localRole == .initiator, credentials.channelRole == .mediaControl,
              credentials.negotiated.initiatorCapabilities.contains(.receiveVideo) else {
            throw SecureTransportError.invalidCredentials
        }
        self.credentials = credentials
        output = AnnotationReliableOutput(send: send, close: close)
    }

    public func start() { output.enqueue(.hello(capabilities: [AnnotationWireMessage.capability])) }

    public func receive(_ data: Data, nowNanos: UInt64) {
        guard !closed else { return }
        guard credentials.isActive else { cancel(); return }
        do {
            switch try AnnotationWireMessage(encoded: data) {
            case .hello(let capabilities):
                guard !receivedHello else { throw SecureTransportError.invalidState }
                receivedHello = true
                supported = capabilities.contains(AnnotationWireMessage.capability)
                onSupportChanged?(supported)
            case .snapshotChunk(let chunk):
                guard supported else { throw SecureTransportError.unsupportedProtocol }
                if let snapshot = try assembler.append(chunk, nowNanos: nowNanos) {
                    guard snapshot.presenterID == credentials.remotePeerID.uuidString else {
                        throw SecureTransportError.wrongContext
                    }
                    sessionID = snapshot.sessionID
                    replica.apply(snapshot)
                    requestingSnapshot = false
                    onSnapshot?(snapshot)
                }
            case .event(let event):
                guard supported else { throw SecureTransportError.unsupportedProtocol }
                guard !requestingSnapshot else { return }
                guard event.sessionID == sessionID, replica.apply(event) else { requestSnapshot(); return }
                onEvent?(event)
            case .rejection(let commandID, let reason):
                guard supported else { throw SecureTransportError.unsupportedProtocol }
                onRejection?(commandID, reason)
            case .ended(let ended):
                guard supported else { throw SecureTransportError.unsupportedProtocol }
                if sessionID == ended {
                    assembler.reset(); replica = AnnotationReplica(); sessionID = nil
                    requestingSnapshot = false
                    onSnapshot?(nil)
                }
            default: throw SecureTransportError.invalidState
            }
        } catch {
            output.fail(error)
            cancel()
        }
    }

    public func send(_ command: AnnotationCommand) {
        guard !closed, credentials.isActive, supported, !requestingSnapshot, command.sessionID == sessionID else {
            onRejection?(command.id, .wrongSession); return
        }
        output.enqueue(.command(command))
    }

    public func requestSnapshot() {
        guard !closed, credentials.isActive, supported, !requestingSnapshot else { return }
        requestingSnapshot = true
        output.enqueue(.requestSnapshot)
    }

    public func cancel() {
        guard !closed else { return }
        closed = true; supported = false; sessionID = nil
        assembler.reset(); replica = AnnotationReplica(); output.cancel()
        onSnapshot?(nil); onSupportChanged?(false)
    }
}
