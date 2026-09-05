import Foundation
import ALOCore
import ALOAppleMedia
import ALONetworking

/// One viewer's annotations on its admitted broadcaster media connection.
/// Transport work remains inline on that channel; UI work uses one bounded batch
/// hop. Annotation failures retire this extension, never the audio connection.
final class SecureMacAnnotationViewer: @unchecked Sendable {
    private enum Event: Sendable {
        case snapshot(AnnotationSnapshot?)
        case event(AnnotationEvent)
        case rejection(UUID, AnnotationRejection)
        case metadata(CaptureMetadataWireMessage)
        case disabled
    }

    private final class Binding: @unchecked Sendable {
        let id = UUID()
        let channel: SecurePeerChannel
        let receiver: MediaReceiverSession
        var bridge: BoundedMediaEventBridge<Event>!
        // Access these only through channel.withAuthenticatedCredentials.
        var coordinator: AnnotationViewerCoordinator?
        var sourceID: UUID?
        var metadataTime: UInt64?
        var disabled = false
        var incomingBytes = 0

        init(channel: SecurePeerChannel, receiver: MediaReceiverSession) {
            self.channel = channel
            self.receiver = receiver
        }
    }

    private let localID: UUID
    private let presenterID: UUID
    private let lock = NSLock()
    private var binding: Binding?
    private var stopped = false
    @MainActor private var presentation: AnnotationPresentationController?
    @MainActor private var presentationBindingID: UUID?
    @MainActor private var participantNames: [String: String] = [:]
    @MainActor private let onScene: (AnnotationSceneModel?) -> Void

    @MainActor
    init(localID: UUID, presenterID: UUID, onScene: @escaping (AnnotationSceneModel?) -> Void) {
        self.localID = localID
        self.presenterID = presenterID
        self.onScene = onScene
    }

    /// Invoke inline inside MediaReceiverSession.attach's completion before any
    /// coalesced media-channel payloads are delivered to the receiver callbacks.
    func attach(channel: SecurePeerChannel, receiver: MediaReceiverSession) {
        channel.withAuthenticatedCredentials { [weak self] result in
            guard let self else { return }
            guard let credentials = try? result.get(),
                  credentials.localPeerID == self.localID, credentials.remotePeerID == self.presenterID else { return }
            let next = Binding(channel: channel, receiver: receiver)
            let token = next.id
            next.bridge = BoundedMediaEventBridge(maximumEvents: 128, maximumBytes: 16 * 1_024 * 1_024,
                schedule: { action in DispatchQueue.main.async(execute: action) },
                receive: { [weak self] events in
                    MainActor.assumeIsolated { self?.deliver(events, bindingID: token) }
                }, overflow: { [weak self] in
                    MainActor.assumeIsolated { self?.bridgeOverflow(bindingID: token) }
                })
            let admitted: (Bool, Binding?) = self.lock.withLock {
                guard !self.stopped else { return (false, nil) }
                let old = self.binding
                self.binding = next
                return (true, old)
            }
            guard admitted.0 else { next.bridge.close(); return }
            if let previous = admitted.1 { self.retire(previous) }
            next.bridge.submit(.snapshot(nil))
            do {
                let coordinator = try AnnotationViewerCoordinator(credentials: credentials,
                    send: { [weak receiver] bytes, completion in
                        guard let receiver else { completion(.failure(SecureTransportError.invalidState)); return }
                        receiver.sendAnnotation(bytes, completion: completion)
                    }, close: { [weak self, weak next] _ in
                        guard let self, let next else { return }
                        self.disable(next)
                    })
                next.coordinator = coordinator
                coordinator.onSnapshot = { [weak self, weak next] snapshot in
                    guard let self, let next, self.isCurrent(next), !next.disabled else { return }
                    if next.sourceID != snapshot?.sessionID { next.metadataTime = nil }
                    next.sourceID = snapshot?.sessionID
                    let bytes: Int
                    if let snapshot {
                        guard let encoded = try? JSONEncoder().encode(snapshot),
                              encoded.count <= AnnotationSnapshotChunk.maximumSnapshotBytes else {
                            self.disable(next); return
                        }
                        bytes = encoded.count
                    } else { bytes = 0 }
                    next.bridge.submit(.snapshot(snapshot), byteCount: bytes)
                }
                coordinator.onEvent = { [weak self, weak next] event in
                    guard let self, let next, self.isCurrent(next), !next.disabled else { return }
                    next.bridge.submit(.event(event), byteCount: next.incomingBytes)
                }
                coordinator.onRejection = { [weak self, weak next] id, reason in
                    guard let self, let next, self.isCurrent(next), !next.disabled else { return }
                    next.bridge.submit(.rejection(id, reason), byteCount: next.incomingBytes)
                }
                coordinator.onSupportChanged = { [weak self, weak next] supported in
                    guard let self, let next, !supported else { return }
                    self.disable(next)
                }
                coordinator.start()
            } catch { self.disable(next) }
        }
    }

    /// Returning true consumes this optional extension even after it has failed,
    /// allowing the admitted media receiver to keep playing independent audio.
    func receiveAnnotation(_ bytes: Data) -> Bool {
        guard let current = currentBinding() else { return true }
        current.channel.withAuthenticatedCredentials { [weak self, weak current] result in
            guard let self, let current, self.isCurrent(current), !current.disabled else { return }
            guard (try? result.get()) != nil, bytes.count <= AnnotationWireMessage.maximumWireBytes else {
                self.disable(current); return
            }
            current.incomingBytes = bytes.count
            defer { current.incomingBytes = 0 }
            current.coordinator?.receive(bytes, nowNanos: MonotonicClock.nowNanos())
        }
        return true
    }

    func receiveMetadata(_ bytes: Data) -> Bool {
        guard let current = currentBinding() else { return true }
        current.channel.withAuthenticatedCredentials { [weak self, weak current] result in
            guard let self, let current, self.isCurrent(current), !current.disabled else { return }
            guard (try? result.get()) != nil else { self.disable(current); return }
            // Early/retired source metadata cannot establish source identity.
            guard let sourceID = current.sourceID else { return }
            do {
                let metadata = try CaptureMetadataWireMessage(encoded: bytes, expectedSessionID: sourceID,
                    notBeforeCaptureTimeNanos: current.metadataTime)
                current.metadataTime = metadata.captureTimeNanos
                current.bridge.submit(.metadata(metadata), byteCount: bytes.count)
            } catch SecureTransportError.wrongContext { return }
            catch SecureTransportError.replay { return }
            catch { self.disable(current) }
        }
        return true
    }

    @MainActor
    func updateParticipants(_ names: [String: String]) {
        participantNames = Dictionary(uniqueKeysWithValues: names.keys.sorted().prefix(128).map {
            ($0, String(names[$0, default: "Participant"].prefix(128)))
        })
        presentation?.updateParticipants(participantNames)
    }

    func stop() {
        let retired: (Bool, Binding?) = lock.withLock {
            guard !stopped else { return (false, nil) }
            stopped = true
            let old = binding
            binding = nil
            return (true, old)
        }
        guard retired.0 else { return }
        if let old = retired.1 { retire(old) }
        // Keep the owner alive until its final UI cleanup has run, even when
        // MeshSession drops its last reference immediately after stop().
        DispatchQueue.main.async { self.clearPresentation() }
    }

    /// A control connection failed, but the room receiver will redial. Retire
    /// this binding without making the wrapper terminal. A newly attached
    /// connection must not be erased by the old disconnect's queued UI cleanup.
    func disconnect() {
        let old: Binding? = lock.withLock {
            guard !stopped else { return nil }
            let old = binding
            binding = nil
            return old
        }
        guard let old else { return }
        retire(old)
        DispatchQueue.main.async {
            guard self.lock.withLock({ !self.stopped && self.binding == nil }) else { return }
            self.clearPresentation()
        }
    }

    private func currentBinding() -> Binding? { lock.withLock { stopped ? nil : binding } }
    private func isCurrent(_ candidate: Binding) -> Bool {
        lock.withLock { !stopped && binding === candidate }
    }

    private func retire(_ retired: Binding) {
        retired.bridge.close()
        retired.channel.withAuthenticatedCredentials { _ in
            retired.disabled = true
            retired.coordinator?.cancel()
            retired.coordinator = nil
        }
    }

    /// Must execute on this binding's channel executor.
    private func disable(_ current: Binding, publish: Bool = true) {
        guard isCurrent(current), !current.disabled else { return }
        current.disabled = true
        current.sourceID = nil
        current.metadataTime = nil
        current.coordinator?.cancel()
        current.coordinator = nil
        if publish { current.bridge.submit(.disabled) }
    }

    @MainActor
    private func deliver(_ events: [Event], bindingID: UUID) {
        guard let current = currentBinding(), current.id == bindingID else { return }
        if presentationBindingID != bindingID { clearPresentation(); presentationBindingID = bindingID }
        for event in events {
            guard isCurrent(current) else { return }
            switch event {
            case .snapshot(let snapshot):
                guard let snapshot else { presentation?.apply(snapshot: nil); onScene(nil); continue }
                if presentation == nil {
                    presentation = AnnotationPresentationController(localActorID: localID.uuidString,
                        presenterID: presenterID.uuidString,
                        send: { [weak self] command in self?.send(command, bindingID: bindingID) },
                        requestSnapshot: { [weak self] in self?.requestSnapshot(bindingID: bindingID) })
                    presentation?.updateParticipants(participantNames)
                }
                presentation?.apply(snapshot: snapshot)
                onScene(presentation?.scene)
            case .event(let event): presentation?.apply(event: event)
            case .rejection(let id, let reason): presentation?.reject(commandID: id, reason: reason)
            case .metadata(let metadata):
                presentation?.apply(metadata: metadata.viewerMetadata, sessionID: metadata.sessionID, frameSize: metadata.frameSize)
            case .disabled: clearPresentation()
            }
        }
    }

    private func send(_ command: AnnotationCommand, bindingID: UUID) {
        guard let current = currentBinding(), current.id == bindingID else { return }
        current.channel.withAuthenticatedCredentials { [weak self, weak current] result in
            guard let self, let current, self.isCurrent(current), !current.disabled else { return }
            guard (try? result.get()) != nil else { self.disable(current); return }
            current.coordinator?.send(command)
        }
    }

    private func requestSnapshot(bindingID: UUID) {
        guard let current = currentBinding(), current.id == bindingID else { return }
        current.channel.withAuthenticatedCredentials { [weak self, weak current] result in
            guard let self, let current, self.isCurrent(current), !current.disabled else { return }
            guard (try? result.get()) != nil else { self.disable(current); return }
            current.coordinator?.requestSnapshot()
        }
    }

    @MainActor
    private func bridgeOverflow(bindingID: UUID) {
        guard let current = currentBinding(), current.id == bindingID else { return }
        clearPresentation()
        current.channel.withAuthenticatedCredentials { [weak self, weak current] _ in
            guard let self, let current else { return }
            self.disable(current, publish: false)
        }
    }

    @MainActor
    private func clearPresentation() {
        presentation?.close()
        presentation = nil
        presentationBindingID = nil
        onScene(nil)
    }
}
