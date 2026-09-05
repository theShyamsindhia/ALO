import CoreGraphics
import Foundation
import ALOCore
import ALOAppleMedia
import ALONetworking

/// Presenter annotations exist independently of subscriber admission. All
/// authority mutations use the mesh's media executor, including local gestures.
final class SecureMacAnnotationHost: @unchecked Sendable {
    private enum Work: Sendable {
        case initialize, begin(UUID), end, capture, tick, snapshot
        case command(AnnotationCommand)
    }
    private enum Event: Sendable {
        case snapshot(AnnotationSnapshot?), event(AnnotationEvent)
        case rejection(UUID, AnnotationRejection)
        case metadata(CapturedFrameMetadata, CGSize, UUID)
        case disabled
    }
    private struct Capture: Sendable {
        let metadata: CapturedFrameMetadata
        let frameSize: CGSize
        let generation: UUID
    }
    private final class Peer {
        let credentials: AuthenticatedChannelCredentials
        weak var host: MediaHostSession?
        var supported = false
        var metadataInFlight = false
        init(credentials: AuthenticatedChannelCredentials, host: MediaHostSession) {
            self.credentials = credentials
            self.host = host
        }
    }
    private final class Session: @unchecked Sendable {
        let id = UUID()
        let schedule: (@escaping @Sendable () -> Void) -> Void
        var work: BoundedMediaEventBridge<Work>!
        var events: BoundedMediaEventBridge<Event>!
        var timer: DispatchSourceTimer?
        // The remaining fields belong to the mesh media executor.
        var coordinator: AnnotationHostCoordinator?
        var peers: [UUID: Peer] = [:]
        var generation: UUID?
        var sourceID: UUID?
        var latestWireMetadata: CaptureMetadataWireMessage?
        var replica = AnnotationReplica()
        var disabled = false
        init(schedule: @escaping (@escaping @Sendable () -> Void) -> Void) { self.schedule = schedule }
    }

    private let roomID: UUID
    private let presenterID: UUID
    private let isPublic: Bool
    private let lock = NSLock()
    private var session: Session?
    private var stopped = false
    private var desiredGeneration: UUID?
    private var pendingCapture: Capture?
    private var captureQueued = false
    @MainActor private var presentation: AnnotationPresentationController?
    @MainActor private var participantNames: [String: String] = [:]
    @MainActor private let onScene: (AnnotationSceneModel?) -> Void
    @MainActor private let makeOverlay: @MainActor (AnnotationSceneModel) -> any AnnotationOverlayPresenting

    @MainActor
    init(roomID: UUID, presenterID: UUID, isPublic: Bool,
         onScene: @escaping (AnnotationSceneModel?) -> Void,
         makeOverlay: @escaping @MainActor (AnnotationSceneModel) -> any AnnotationOverlayPresenting = {
             AnnotationOverlayController(model: $0)
         }) {
        self.roomID = roomID
        self.presenterID = presenterID
        self.isPublic = isPublic
        self.onScene = onScene
        self.makeOverlay = makeOverlay
    }

    @MainActor
    func start(mesh: MeshControlPlane) {
        start(scheduling: { action in mesh.performMediaWork(action) })
    }

    /// Executor injection exercises presenter-alone lifecycle without opening
    /// network listeners, requesting capture consent, or starting audio hardware.
    @MainActor
    func start(scheduling: @escaping (@escaping @Sendable () -> Void) -> Void, automaticTicks: Bool = true) {
        let next = Session(schedule: scheduling)
        next.work = BoundedMediaEventBridge(maximumEvents: 128, maximumBytes: 4 * 1_024 * 1_024,
            schedule: scheduling, receive: { [weak self, weak next] work in
                guard let self, let next else { return }
                for item in work where self.isCurrent(next) { self.process(item, session: next) }
            }, overflow: { [weak self, weak next] in
                guard let self, let next else { return }
                self.disable(next)
            })
        next.events = BoundedMediaEventBridge(maximumEvents: 128, maximumBytes: 16 * 1_024 * 1_024,
            schedule: { action in DispatchQueue.main.async(execute: action) },
            receive: { [weak self, weak next] events in
                guard let self, let next else { return }
                MainActor.assumeIsolated { self.deliver(events, session: next) }
            }, overflow: { [weak self, weak next] in
                guard let self, let next else { return }
                MainActor.assumeIsolated {
                    guard self.isCurrent(next) else { return }
                    self.clearPresentation()
                    next.schedule { [weak self, weak next] in
                        guard let self, let next else { return }
                        self.disable(next, publish: false)
                    }
                }
            })
        let accepted = lock.withLock {
            guard !stopped, session == nil else { return false }
            session = next
            return true
        }
        guard accepted else { next.work.close(); next.events.close(); return }
        next.work.submit(.initialize)
        if automaticTicks {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak next] in next?.work.submit(.tick) }
            next.timer = timer
            timer.resume()
        }
    }

    @MainActor
    func beginSource() -> UUID {
        let generation = UUID()
        let current = lock.withLock {
            guard !stopped else { return nil as Session? }
            desiredGeneration = generation
            pendingCapture = nil
            return session
        }
        current?.work.submit(.begin(generation))
        return generation
    }

    @MainActor
    func endSource() {
        let current = lock.withLock {
            desiredGeneration = nil
            pendingCapture = nil
            return stopped ? nil : session
        }
        current?.work.submit(.end)
    }

    /// Capture callbacks replace one latest metadata slot. There is never one
    /// unbounded actor task or work item per captured frame.
    func captureMetadata(_ metadata: CapturedFrameMetadata, frameSize: CGSize, generation: UUID) {
        let current = lock.withLock {
            guard !stopped, desiredGeneration == generation, let session else { return nil as Session? }
            if let previous = pendingCapture, previous.generation == generation,
               metadata.captureTimeNanos < previous.metadata.captureTimeNanos { return nil }
            pendingCapture = Capture(metadata: metadata, frameSize: frameSize, generation: generation)
            guard !captureQueued else { return nil }
            captureQueued = true
            return session
        }
        current?.work.submit(.capture)
    }

    /// Inline immediately after MediaHostSession admits this media-control peer.
    func attach(credentials: AuthenticatedChannelCredentials, mediaHost: MediaHostSession) {
        guard let current = currentSession(), !current.disabled else { return }
        ensureCoordinator(current)
        guard current.peers[credentials.connectionID] == nil else { return }
        let peer = Peer(credentials: credentials, host: mediaHost)
        current.peers[credentials.connectionID] = peer
        do {
            try current.coordinator?.addPeer(credentials: credentials,
                send: { [weak mediaHost] data, completion in
                    guard let mediaHost else { completion(.failure(SecureTransportError.invalidState)); return }
                    mediaHost.sendAnnotation(data, connectionID: credentials.connectionID, completion: completion)
                }, close: { [weak self, weak current] _ in
                    guard let self, let current else { return }
                    self.removePeer(credentials.connectionID, session: current)
                })
        } catch { current.peers.removeValue(forKey: credentials.connectionID) }
    }

    /// This optional extension always consumes its traffic. Invalid commands
    /// retire only that peer's annotation state, without closing its audio path.
    func receive(credentials: AuthenticatedChannelCredentials, _ data: Data) -> Bool {
        guard let current = currentSession(), !current.disabled,
              let peer = current.peers[credentials.connectionID], peer.credentials === credentials else { return true }
        current.coordinator?.receive(data, connectionID: credentials.connectionID, nowNanos: MonotonicClock.nowNanos())
        if current.peers[credentials.connectionID] === peer,
           case .hello(let capabilities) = try? AnnotationWireMessage(encoded: data) {
            peer.supported = capabilities.contains(AnnotationWireMessage.capability)
        }
        return true
    }

    func removePeer(connectionID: UUID) {
        guard let current = currentSession() else { return }
        removePeer(connectionID, session: current)
    }

    @MainActor
    func updateParticipants(_ names: [String: String]) {
        participantNames = Dictionary(uniqueKeysWithValues: names.keys.sorted().prefix(128).map {
            ($0, String(names[$0, default: "Participant"].prefix(128)))
        })
        presentation?.updateParticipants(participantNames)
    }

    func stop() {
        let retired: (Bool, Session?) = lock.withLock {
            guard !stopped else { return (false, nil) }
            stopped = true
            desiredGeneration = nil
            pendingCapture = nil
            let previous = session
            session = nil
            return (true, previous)
        }
        guard retired.0 else { return }
        if let previous = retired.1 {
            previous.timer?.cancel()
            previous.work.close()
            previous.events.close()
            previous.schedule { [self] in retire(previous) }
        }
        DispatchQueue.main.async { self.clearPresentation() }
    }

    private func currentSession() -> Session? { lock.withLock { stopped ? nil : session } }
    private func isCurrent(_ candidate: Session) -> Bool { lock.withLock { !stopped && session === candidate } }

    private func ensureCoordinator(_ current: Session) {
        guard current.coordinator == nil, !current.disabled else { return }
        let coordinator = AnnotationHostCoordinator(roomID: roomID, presenterID: presenterID, isPublicRoom: isPublic)
        current.coordinator = coordinator
        coordinator.onSnapshot = { [weak self, weak current] snapshot in
            guard let self, let current, self.isCurrent(current), !current.disabled else { return }
            current.sourceID = snapshot?.sessionID
            current.latestWireMetadata = nil
            current.replica = AnnotationReplica()
            if let snapshot { current.replica.apply(snapshot) }
            self.publish(.snapshot(snapshot), byteCount: snapshot.flatMap { try? JSONEncoder().encode($0).count } ?? 0, session: current)
        }
        coordinator.onEvent = { [weak self, weak current] event in
            guard let self, let current, self.isCurrent(current), !current.disabled else { return }
            _ = current.replica.apply(event)
            self.publish(.event(event), byteCount: (try? JSONEncoder().encode(event).count) ?? AnnotationWireMessage.maximumWireBytes, session: current)
        }
        coordinator.onLocalRejection = { [weak self, weak current] id, reason in
            guard let self, let current, self.isCurrent(current), !current.disabled else { return }
            self.publish(.rejection(id, reason), byteCount: 128, session: current)
        }
    }

    private func process(_ work: Work, session current: Session) {
        guard !current.disabled else { return }
        ensureCoordinator(current)
        switch work {
        case .initialize: break
        case .begin(let generation):
            current.generation = generation
            current.coordinator?.beginSource(nowNanos: MonotonicClock.nowNanos())
        case .end:
            current.generation = nil
            current.coordinator?.endSource()
        case .command(let command):
            current.coordinator?.processLocal(command, nowNanos: MonotonicClock.nowNanos())
        case .snapshot:
            guard let sourceID = current.sourceID else { return }
            let replica = current.replica
            let snapshot = AnnotationSnapshot(sessionID: sourceID, revision: replica.revision,
                presenterID: presenterID.uuidString, hostTimeNanos: MonotonicClock.nowNanos(), policy: replica.policy,
                objects: replica.objects.values.sorted { $0.revision < $1.revision },
                leases: Array(replica.leases.values), commandSequences: replica.commandSequences)
            publish(.snapshot(snapshot), byteCount: (try? JSONEncoder().encode(snapshot).count) ?? 0, session: current)
        case .capture:
            let capture = lock.withLock {
                defer { pendingCapture = nil; captureQueued = false }
                return pendingCapture
            }
            guard let capture, capture.generation == current.generation, let sourceID = current.sourceID else { return }
            if let previous = current.latestWireMetadata, capture.metadata.captureTimeNanos < previous.captureTimeNanos { return }
            if let next = try? CaptureMetadataWireMessage(sessionID: sourceID,
                metadata: capture.metadata, frameSize: capture.frameSize) {
                current.latestWireMetadata = next
            } else if let previous = current.latestWireMetadata {
                // A suspended capture can omit geometry. Retain the last valid
                // surface bounds but explicitly disable remote input, rather
                // than leave viewers annotating the previous live frame.
                var unavailable = previous.viewerMetadata
                unavailable.status = .unavailable
                unavailable.captureTimeNanos = capture.metadata.captureTimeNanos
                current.latestWireMetadata = try? CaptureMetadataWireMessage(sessionID: sourceID,
                    metadata: unavailable, frameSize: previous.frameSize)
            }
            publish(.metadata(capture.metadata, capture.frameSize, sourceID), byteCount: 256, session: current)
        case .tick:
            current.coordinator?.tick(nowNanos: MonotonicClock.nowNanos())
            broadcastMetadata(current)
        }
    }

    private func broadcastMetadata(_ current: Session) {
        guard let metadata = current.latestWireMetadata else { return }
        // At most 10 Hz and one metadata send in flight per peer. Repeat the
        // latest geometry so a late join receives it after snapshot assembly.
        for (id, peer) in Array(current.peers) where peer.supported && !peer.metadataInFlight {
            // MediaHostSession checks credential liveness on this executor.
            guard let host = peer.host else { removePeer(id, session: current); continue }
            peer.metadataInFlight = true
            host.sendCaptureMetadata(metadata, connectionID: id) { [weak self, weak current, weak peer] result in
                guard let self, let current, let peer, self.isCurrent(current), current.peers[id] === peer else { return }
                peer.metadataInFlight = false
                if case .failure = result { self.removePeer(id, session: current) }
            }
        }
    }

    private func removePeer(_ id: UUID, session current: Session) {
        guard current.peers.removeValue(forKey: id) != nil else { return }
        current.coordinator?.removePeer(connectionID: id, nowNanos: MonotonicClock.nowNanos())
    }

    private func publish(_ event: Event, byteCount: Int, session current: Session) {
        guard isCurrent(current), !current.disabled else { return }
        current.events.submit(event, byteCount: byteCount)
    }

    private func disable(_ current: Session, publish: Bool = true) {
        guard isCurrent(current), !current.disabled else { return }
        retire(current)
        if publish { current.events.submit(.disabled) }
    }

    private func retire(_ current: Session) {
        current.disabled = true
        current.timer?.cancel()
        current.work.close()
        current.coordinator?.endSource()
        for id in Array(current.peers.keys) { removePeer(id, session: current) }
        current.coordinator = nil
        current.latestWireMetadata = nil
        current.sourceID = nil
    }

    @MainActor
    private func deliver(_ events: [Event], session current: Session) {
        guard isCurrent(current) else { return }
        for event in events {
            guard isCurrent(current) else { return }
            switch event {
            case .snapshot(let snapshot):
                guard let snapshot else { presentation?.apply(snapshot: nil); onScene(nil); continue }
                if presentation == nil {
                    presentation = AnnotationPresentationController(localActorID: presenterID.uuidString,
                        presenterID: presenterID.uuidString,
                        send: { [weak current] command in
                            current?.work.submit(.command(command), byteCount: (try? JSONEncoder().encode(command).count) ?? 0)
                        }, requestSnapshot: { [weak current] in current?.work.submit(.snapshot) }, makeOverlay: makeOverlay)
                    presentation?.updateParticipants(participantNames)
                }
                presentation?.apply(snapshot: snapshot)
                onScene(presentation?.scene)
            case .event(let event): presentation?.apply(event: event)
            case .rejection(let id, let reason): presentation?.reject(commandID: id, reason: reason)
            case .metadata(let metadata, let size, let source):
                presentation?.apply(metadata: metadata, sessionID: source, frameSize: size)
            case .disabled: clearPresentation()
            }
        }
    }

    @MainActor
    private func clearPresentation() {
        presentation?.close()
        presentation = nil
        onScene(nil)
    }
}
