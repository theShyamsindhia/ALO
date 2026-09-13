import Foundation
import ALONetworking

enum RoomCanvasAppEvent {
    case snapshot(RoomCanvasSnapshot?, hosting: Bool)
    case image(Data?, RoomCanvasImage?)
    case state(RoomCanvasViewerState)
    case rejection(AnnotationRejection)
}

/// Owns the canvas's serial executor. Admission installs handlers inline on the
/// mesh executor; all state, image hashing and recovery run on this separate queue.
final class RoomCanvasBridge: @unchecked Sendable {
    typealias Open = (UUID, @escaping (Result<(SecurePeerChannel, AuthenticatedPeer), Error>) -> Void) -> Void
    let roomID: UUID
    let localID: UUID
    private let isPublic: Bool
    private let queue = DispatchQueue(label: "alo.room-canvas", qos: .userInitiated)
    private let admissionLock = NSLock()
    private var admissionTarget: (UUID, UUID)? // canvas ID, generation; lock protected
    private var generation = UUID()
    private var stopped = false
    private var host: RoomCanvasHostCoordinator?
    private var viewer: RoomCanvasViewerCoordinator?
    private var viewerChannel: RoomCanvasChannel?
    private var peers: [UUID: RoomCanvasChannel] = [:]
    private var open: Open?
    private var advertise: ((RoomCanvasAdvertisement?) -> Void)?
    private var changed: ((RoomCanvasAppEvent, UUID) -> Void)?
    private var timer: DispatchSourceTimer?
    private var opening = false
    private var attempts = 0
    private var retryAt: UInt64?

    init(roomID: UUID, localID: UUID, isPublic: Bool) {
        self.roomID = roomID; self.localID = localID; self.isPublic = isPublic
    }

    deinit { timer?.cancel(); peers.values.forEach { $0.cancel() }; viewerChannel?.cancel() }

    func configure(open: @escaping Open, advertise: @escaping (RoomCanvasAdvertisement?) -> Void) {
        queue.async { self.open = open; self.advertise = advertise }
    }

    func observe(_ changed: @escaping (RoomCanvasAppEvent, UUID) -> Void) {
        queue.async { self.changed = changed }
    }

    func host(_ image: PreparedRoomCanvasImage, generation: UUID) {
        queue.async {
            guard !self.stopped else { return }
            self.retire()
            self.generation = generation
            do {
                let host = try RoomCanvasHostCoordinator(roomID: self.roomID, ownerID: self.localID,
                    image: image.descriptor, bytes: image.bytes, isPublicRoom: self.isPublic)
                self.host = host
                host.onSnapshot = { [weak self] snapshot in self?.emit(.snapshot(snapshot, hosting: true), generation) }
                host.onLocalRejection = { [weak self] _, reason in self?.emit(.rejection(reason), generation) }
                self.admissionLock.withLock { self.admissionTarget = (host.canvasID, generation) }
                self.advertise?(.init(canvasID: host.canvasID, imageName: image.descriptor.name))
                self.emit(.snapshot(host.snapshot(nowNanos: MonotonicClock.nowNanos()), hosting: true), generation)
                self.emit(.image(image.bytes, image.descriptor), generation)
                self.emit(.state(.ready), generation)
                self.startTimer()
            } catch { self.emit(.state(.interrupted(error.localizedDescription)), generation) }
        }
    }

    func join(ownerID: UUID, canvasID: UUID, generation: UUID) {
        queue.async {
            guard !self.stopped, ownerID != self.localID else { return }
            self.retire(); self.generation = generation
            let viewer = RoomCanvasViewerCoordinator(roomID: self.roomID, canvasID: canvasID,
                                                     localID: self.localID, ownerID: ownerID)
            self.viewer = viewer
            viewer.onSnapshot = { [weak self] snapshot in self?.emit(.snapshot(snapshot, hosting: false), generation) }
            viewer.onImage = { [weak self, weak viewer] bytes in
                self?.emit(.image(bytes, viewer?.snapshot?.image), generation)
            }
            viewer.onRejection = { [weak self] _, reason in self?.emit(.rejection(reason), generation) }
            viewer.onState = { [weak self] state in
                guard let self, self.generation == generation else { return }
                if state == .ready { self.attempts = 0; self.retryAt = nil }
                if case .interrupted = state { self.scheduleRetry() }
                if state == .ended || state == .left { self.retryAt = nil }
                self.emit(.state(state), generation)
            }
            self.emit(.snapshot(nil, hosting: false), generation)
            self.emit(.image(nil, nil), generation)
            self.emit(.state(.connecting), generation)
            self.startTimer(); self.connectViewer()
        }
    }

    func replaceImage(_ image: PreparedRoomCanvasImage, generation: UUID) {
        queue.async {
            guard self.generation == generation, let host = self.host, !self.stopped else { return }
            do {
                try host.replaceImage(image.descriptor, bytes: image.bytes, nowNanos: MonotonicClock.nowNanos())
                self.advertise?(.init(canvasID: host.canvasID, imageName: image.descriptor.name))
                self.emit(.image(image.bytes, image.descriptor), generation)
            } catch { self.emit(.state(.interrupted(error.localizedDescription)), generation) }
        }
    }

    /// Called before returning from MeshControlPlane's admission callback.
    func receive(_ channel: SecurePeerChannel, peer: AuthenticatedPeer) {
        guard let (canvasID, token) = admissionLock.withLock({ admissionTarget }) else { channel.cancel(); return }
        channel.withAuthenticatedCredentials { result in
            guard case .success(let credentials) = result else { channel.cancel(); return }
            RoomCanvasChannel.attach(channel, roomID: self.roomID, canvasID: canvasID,
                localID: self.localID, peerID: peer.nodeID, executor: self.queue) { result in
                guard case .success(let adapter) = result else { return }
                adapter.onMessage = { [weak self, weak adapter] message in
                    guard let self, let adapter, self.generation == token else { return }
                    self.host?.receive(message, connectionID: adapter.connectionID, nowNanos: MonotonicClock.nowNanos())
                }
                adapter.onClose = { [weak self, weak adapter] _ in
                    guard let self, let adapter, self.generation == token else { return }
                    self.peers.removeValue(forKey: adapter.connectionID)
                    self.host?.removePeer(connectionID: adapter.connectionID, nowNanos: MonotonicClock.nowNanos())
                }
                self.queue.async {
                    guard !self.stopped, self.generation == token, let host = self.host, host.canvasID == canvasID else {
                        adapter.cancel(); return
                    }
                    do {
                        self.peers[adapter.connectionID] = adapter
                        try host.addPeer(credentials: credentials, nowNanos: MonotonicClock.nowNanos(),
                            send: { [weak adapter] in adapter?.send($0) }, close: { [weak adapter] in adapter?.cancel() })
                    } catch { self.peers.removeValue(forKey: adapter.connectionID); adapter.cancel() }
                }
            }
        }
    }

    func submit(_ action: AnnotationAction, generation: UUID) {
        queue.async {
            guard !self.stopped, self.generation == generation else { return }
            if let host = self.host { host.processLocal(action, nowNanos: MonotonicClock.nowNanos()) }
            else { self.viewer?.submit(action) }
        }
    }

    func leave(generation: UUID) {
        queue.async { guard self.generation == generation else { return }; self.retire(); self.generation = UUID() }
    }

    func rejectImage(generation: UUID, reason: String) {
        queue.async {
            guard self.generation == generation else { return }
            self.retire()
            self.emit(.state(.interrupted(reason)), generation)
        }
    }

    func stop() { queue.async { self.stopped = true; self.retire(); self.changed = nil; self.generation = UUID() } }

    private func connectViewer() {
        guard !stopped, !opening, let viewer, let open, viewer.state != .ended, viewer.state != .left else { return }
        let token = generation
        opening = true; retryAt = nil; attempts += 1
        emit(.state(.connecting), token)
        open(viewer.ownerID) { result in
            switch result {
            case .failure(let error):
                self.queue.async {
                    guard self.generation == token else { return }
                    self.opening = false; self.scheduleRetry()
                    self.emit(.state(.interrupted(error.localizedDescription)), token)
                }
            case .success(let (channel, peer)):
                channel.withAuthenticatedCredentials { result in
                    guard case .success(let credentials) = result else {
                        channel.cancel()
                        self.queue.async {
                            guard self.generation == token else { return }
                            self.opening = false; self.scheduleRetry()
                            self.emit(.state(.interrupted("The canvas connection could not be authenticated.")), token)
                        }
                        return
                    }
                    RoomCanvasChannel.attach(channel, roomID: self.roomID, canvasID: viewer.canvasID,
                        localID: self.localID, peerID: viewer.ownerID, executor: self.queue) { result in
                        switch result {
                        case .failure(let error):
                            self.queue.async {
                                guard self.generation == token else { return }
                                self.opening = false; self.scheduleRetry()
                                self.emit(.state(.interrupted(error.localizedDescription)), token)
                            }
                        case .success(let adapter):
                            adapter.onMessage = { [weak self, weak adapter] message in
                                guard let self, let adapter, self.generation == token else { return }
                                self.viewer?.receive(message, connectionID: adapter.connectionID, nowNanos: MonotonicClock.nowNanos())
                            }
                            adapter.onClose = { [weak self, weak adapter] error in
                                guard let self, let adapter, self.generation == token else { return }
                                if self.viewerChannel === adapter { self.viewerChannel = nil }
                                self.viewer?.disconnected(connectionID: adapter.connectionID, reason: error.localizedDescription)
                            }
                            self.queue.async {
                                guard !self.stopped, self.generation == token, self.viewer === viewer, peer.nodeID == viewer.ownerID else {
                                    adapter.cancel(); return
                                }
                                self.opening = false
                                self.viewerChannel = adapter
                                do {
                                    try viewer.connect(credentials: credentials, nowNanos: MonotonicClock.nowNanos(),
                                        send: { [weak adapter] in adapter?.send($0) }, close: { [weak adapter] in adapter?.cancel() })
                                } catch { adapter.cancel(); self.scheduleRetry(); self.emit(.state(.interrupted(error.localizedDescription)), token) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func scheduleRetry() {
        guard !stopped, viewer != nil, attempts < 3 else { return }
        retryAt = MonotonicClock.nowNanos() + UInt64(max(1, attempts)) * 1_000_000_000
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let now = MonotonicClock.nowNanos()
            self.host?.tick(nowNanos: now); self.viewer?.tick(nowNanos: now)
            if let retryAt = self.retryAt, now >= retryAt { self.connectViewer() }
        }
        self.timer = timer; timer.resume()
    }

    private func retire() {
        admissionLock.withLock { admissionTarget = nil }
        host?.end(); host = nil // finish() owns draining connections until peer close/timeout
        peers.removeAll()
        viewer?.leave(); viewer = nil; viewerChannel?.cancel(); viewerChannel = nil
        advertise?(nil)
        timer?.cancel(); timer = nil; retryAt = nil; attempts = 0; opening = false
    }

    private func emit(_ event: RoomCanvasAppEvent, _ token: UUID) {
        guard generation == token else { return }
        changed?(event, token)
    }
}
