import Foundation
import ALOCore
import ALONetworking
import ALOAppleMedia
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

/// Secure rooms never construct HostServer or a reverse/plaintext local receiver.
/// The same tap packets feed authenticated subscribers and this Mac's shared
/// output engine. Receiver repair reads the capture timeline; it cannot retime
/// the broadcaster or restart healthy peers.
@MainActor
final class SecureMacMediaHost {
    private nonisolated let ingress = CaptureIngress()
    private var source: AudioSource?
    private var monitor: NowPlayingMonitor?
    private var playbackController: SystemPlaybackController?
    private var lifecycle = UUID()
    private var started = false
    private var automaticSyncEnabled = true
    private var shouldPauseSourceOnStop = false
    private var cleanup: Task<Void, Never>?
    private var videoPicker: ScreenContentPicker?
    private var videoCapture: ScreenVideoCapture?
    private var videoEncoder: VideoEncoder?
    private var videoDecoder: VideoDecoder?
    private var videoGeneration = UUID()
    private var annotations: SecureMacAnnotationHost?

    init() {}
    deinit { ingress.revoke() }

    func start(mesh: MeshControlPlane, room: RoomConfiguration, broadcaster: MeshBroadcaster,
               audioOutput: RoomAudioOutputEngine, nowPlaying: @escaping (NowPlayingMedia) -> Void,
               status: @escaping (String) -> Void, stopped: @escaping @Sendable (Error) -> Void,
               annotationScene: @escaping (AnnotationSceneModel?) -> Void = { _ in }) async throws {
        guard !started, cleanup == nil, room.transportPolicy == .secureV2,
              let roomID = UUID(uuidString: room.id), let peerID = UUID(uuidString: broadcaster.nodeID),
              broadcaster.epoch < .max else { throw SecureTransportError.invalidState }
        guard #available(macOS 14.2, *) else { throw ALOError("Synchronized broadcasting requires macOS 14.2 or newer.") }
        started = true
        let token = lifecycle
        let owner = MediaHostSession.Broadcaster(peerID: peerID, epoch: broadcaster.epoch)
        let ingress = self.ingress
        ingress.begin(owner: owner)
        let annotations = SecureMacAnnotationHost(roomID: roomID, presenterID: peerID,
                                                  isPublic: !room.isPrivate, onScene: annotationScene)
        annotations.start(mesh: mesh)
        self.annotations = annotations
        ingress.setAnnotations(annotations)
        do {
            let host: MediaHostSession = try await withCheckedThrowingContinuation { continuation in
                mesh.makeMediaHost(callbacks: .init(
                    currentBroadcaster: { ingress.currentBroadcaster },
                    currentAnchor: { _, stream, now in ingress.timeline.anchor(for: stream, issuedAtHostNanos: now) },
                    // Remote recovery never resets our local output or capture clock.
                    resync: { _, _, _ in },
                    requestKeyframe: { _, _, minimum in ingress.requestKeyframe(minimum) },
                    annotation: { credentials, bytes in ingress.annotationHost?.receive(credentials: credentials, bytes) ?? false },
                    peerDetached: { ingress.detachMediaPeer(connectionID: $0) },
                    timingReport: { peer, stream, report, now in
                        ingress.receiveTiming(peer: peer, stream: stream, report: report, now: now)
                    })) {
                        continuation.resume(with: $0)
                    }
            }
            guard lifecycle == token, !Task.isCancelled, ingress.isActive else { host.stop(); throw CancellationError() }
            guard host.localPeerID == peerID else { host.stop(); throw SecureTransportError.invalidCredentials }
            let renderer = try LocalRenderer(audioOutput: audioOutput, timeline: ingress.timeline,
                epoch: owner.epoch, timing: { floor in ingress.receiveLocalFloor(floor) })
            renderer.setAutomaticSyncEnabled(automaticSyncEnabled)
            guard ingress.install(host: host, renderer: renderer) else {
                host.stop(); renderer.stop(); throw CancellationError()
            }
            ingress.receiveLocalFloor(renderer.initialOutputFloor)
            renderer.start()
            playbackController = SystemPlaybackController()
            let monitor = NowPlayingMonitor { [weak self] media in
                Task { @MainActor [weak self] in
                    guard let self, self.lifecycle == token, self.ingress.isActive else { return }
                    self.ingress.setPlaying(media.isPlaying)
                    nowPlaying(media)
                }
            }
            self.monitor = monitor; monitor.start()
            let tap = SystemAudioTapCapture(sourcePlaybackIsActive: { ingress.sourcePlaying },
                unexpectedStopHandler: { [weak self] error in
                    // Revoke subscriptions immediately, before an actor hop.
                    ingress.revoke()
                    Task { @MainActor [weak self] in
                        guard let self, self.lifecycle == token else { return }
                        self.shouldPauseSourceOnStop = false
                        await self.stop()
                        stopped(error)
                    }
                })
            source = tap
            status("Preparing secure synchronized system audio")
            try await tap.start { samples, captureTimeNanos in ingress.accept(samples, captureTimeNanos: captureTimeNanos) }
            guard lifecycle == token, !Task.isCancelled, ingress.isActive else { throw CancellationError() }
            shouldPauseSourceOnStop = true
            status("Sharing encrypted system audio")
        } catch {
            await stop()
            throw error
        }
    }

    /// Invoked inline by SecureMediaAdmissionRelay on the admitted mesh executor.
    /// Credential identity/role and broadcaster authority are checked again by
    /// MediaHostSession; an authenticated peer is not assumed to be the owner.
    nonisolated func admit(channel: SecurePeerChannel, peer: AuthenticatedPeer) {
        guard let host = ingress.currentHost,
              peer.channelRole == .mediaControl || peer.channelRole == .video else { channel.cancel(); return }
        channel.withAuthenticatedCredentials { result in
            do {
                let credentials = try result.get()
                guard credentials.connectionID == peer.connectionID, credentials.remotePeerID == peer.nodeID,
                      self.ingress.currentHost === host else { throw SecureTransportError.invalidCredentials }
                if peer.channelRole == .video { try host.attachVideo(channel: channel, credentials: credentials) }
                else {
                    try host.attach(channel: channel, credentials: credentials)
                    self.ingress.noteMediaPeer(credentials)
                    self.ingress.annotationHost?.attach(credentials: credentials, mediaHost: host)
                }
            } catch { channel.cancel() }
        }
    }

    /// Synchronous authority/packet revocation. Hardware teardown is serialized
    /// on MainActor and the tap's own setup executor, never on the mesh queue.
    nonisolated func stopImmediately() {
        ingress.revoke()
        Task { @MainActor [weak self] in await self?.stop() }
    }

    func stop() async {
        if let cleanup { await cleanup.value; return }
        lifecycle = UUID()
        annotations?.endSource(); annotations?.stop(); annotations = nil
        ingress.revoke()
        if shouldPauseSourceOnStop { _ = playbackController?.perform(.pause) }
        shouldPauseSourceOnStop = false
        monitor?.stop(); monitor = nil
        playbackController = nil
        let source = self.source
        self.source = nil
        videoGeneration = UUID()
        videoPicker?.deactivate(); videoPicker = nil
        let capture = videoCapture, encoder = videoEncoder, decoder = videoDecoder
        videoCapture = nil; videoEncoder = nil; videoDecoder = nil
        let cleanup = Task<Void, Never> {
            if let source { try? await source.stop() }
            await capture?.stop()
            encoder?.stop(); decoder?.stop()
        }
        self.cleanup = cleanup
        await cleanup.value
    }

    func setLevel(volume: Double, muted: Bool) { ingress.renderer?.setLevel(volume: volume, muted: muted) }
    func setAutomaticSyncEnabled(_ enabled: Bool) {
        // Preserve pre-start changes while authenticated host setup is awaiting.
        automaticSyncEnabled = enabled
        ingress.renderer?.setAutomaticSyncEnabled(enabled)
    }
    func setMusicDucked(_ ducked: Bool) { ingress.renderer?.setMusicDucked(ducked) }
    func sampleTimingDiagnostics() async -> SessionTimingDiagnostics? {
        guard let renderer = ingress.renderer else { return nil }
        let token = lifecycle
        let local = await renderer.diagnostics()
        guard lifecycle == token, ingress.isActive else { return nil }
        return SessionTimingDiagnostics(receiver: local, host: ingress.diagnostics())
    }
    func performMediaCommand(_ command: RoomMediaCommand) -> Bool {
        guard ingress.isActive else { return false }
        return playbackController?.perform(command) ?? false
    }
    func requestResync() { ingress.currentHost?.refreshTimeline() }
    func samplePlaybackReport() async -> PlaybackSyncReport? {
        guard let renderer = ingress.renderer else { return nil }
        return await renderer.report()
    }

    func setVideoEnabled(_ enabled: Bool, videoHandler: @escaping (CGImage) -> Void = { _ in },
                         metadataHandler: @escaping (CapturedFrameMetadata) -> Void = { _ in },
                         stopped: @escaping (Error) -> Void = { _ in }) async throws {
        if !enabled {
            videoGeneration = UUID()
            annotations?.endSource()
            ingress.configureVideo(encoder: nil, decoder: nil)
            videoPicker?.deactivate(); videoPicker = nil
            let capture = videoCapture, encoder = videoEncoder, decoder = videoDecoder
            videoCapture = nil; videoEncoder = nil; videoDecoder = nil
            await capture?.stop(); encoder?.stop(); decoder?.stop()
            return
        }
        guard ingress.isActive, videoPicker == nil, videoCapture == nil else {
            throw ALOError("A secure broadcaster and an unused screen selection are required.")
        }
        let token = lifecycle, videoToken = UUID()
        videoGeneration = videoToken
        let picker = ScreenContentPicker()
        videoPicker = picker
        do {
            let filter = try await picker.selectDisplayOrWindow()
            try Task.checkCancellation()
            guard lifecycle == token, videoGeneration == videoToken, ingress.isActive else { throw CancellationError() }
            let ingress = self.ingress
            let annotationSource = annotations?.beginSource()
            let annotations = self.annotations
            let geometry = CapturedSurfaceMetadataJoin()
            let decoder = VideoDecoder { [weak self] image in
                // VideoPresentationQueue admits this handoff on main directly;
                // do not add a second unbounded asynchronous UI queue.
                MainActor.assumeIsolated {
                    guard let self, self.lifecycle == token, self.videoGeneration == videoToken,
                          self.ingress.isActive else { return }
                    videoHandler(image)
                }
            }
            decoder.updateClockOffsetNanos(0)
            decoder.setTargetLatencyNanos(ingress.timeline.playoutDelayNanos)
            let encoder = VideoEncoder(failureHandler: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.lifecycle == token,
                          self.videoGeneration == videoToken, self.ingress.isActive else { return }
                    try? await self.setVideoEnabled(false)
                    stopped(ALOError(message))
                }
            }) { frame in ingress.acceptVideo(frame, generation: videoToken) }
            let capture = ScreenVideoCapture()
            videoEncoder = encoder; videoDecoder = decoder; videoCapture = capture
            ingress.configureVideo(encoder: encoder, decoder: decoder, generation: videoToken)
            try await capture.start(filter: filter, metadata: { metadata in
                guard ingress.isCurrentVideo(videoToken) else { return }
                metadataHandler(metadata)
                if let joined = geometry.metadata(metadata), let annotationSource {
                    annotations?.captureMetadata(joined.metadata, frameSize: joined.size, generation: annotationSource)
                }
            }) { pixelBuffer, captureTime in
                guard ingress.isCurrentVideo(videoToken) else { return }
                if let joined = geometry.surface(size: CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                                               height: CVPixelBufferGetHeight(pixelBuffer)),
                                                 captureTimeNanos: captureTime), let annotationSource {
                    annotations?.captureMetadata(joined.metadata, frameSize: joined.size, generation: annotationSource)
                }
                encoder.encode(pixelBuffer, captureTimeNanos: captureTime)
            } stopped: { [weak self, weak capture] error in
                Task { @MainActor [weak self, weak capture] in
                    guard let self, let capture, self.videoCapture === capture,
                          self.lifecycle == token, self.videoGeneration == videoToken else { return }
                    try? await self.setVideoEnabled(false)
                    stopped(error)
                }
            }
            try Task.checkCancellation()
            guard lifecycle == token, videoGeneration == videoToken, videoCapture === capture,
                  ingress.isActive else { throw CancellationError() }
        } catch {
            if videoGeneration == videoToken { try? await setVideoEnabled(false) }
            else { picker.deactivate() }
            throw error
        }
    }

    /// All capture/ownership state is thread-safe. SystemAudioTapCapture already
    /// uses a serial delivery queue; the lock also serializes pause and teardown.
    private final class CaptureIngress: @unchecked Sendable {
        let timeline = CapturedMediaTimeline()
        private let lock = NSLock()
        private var owner: MediaHostSession.Broadcaster?
        private var host: MediaHostSession?
        private var local: LocalRenderer?
        private var packetizer = AudioPacketizer()
        private var playing: Bool?
        private var expectedNextCapture: UInt64?
        private var keyframe: ((UInt64?) -> Void)?
        private var preview: VideoDecoder?
        private var videoGeneration: UUID?
        private var annotations: SecureMacAnnotationHost?
        private var timingPolicy = SecureRoomTimingPolicy()
        private var localFloor = RoomTiming.defaultPlayoutDelayNanos
        private var mediaPeers: [UUID: UUID] = [:]
        private var roomTimingChangeCount: UInt64 = 0
        private var playbackGeneration = UUID()
        func noteMediaPeer(_ credentials: AuthenticatedChannelCredentials) {
            lock.withLock { mediaPeers[credentials.connectionID] = credentials.remotePeerID }
        }
        func detachMediaPeer(connectionID: UUID) {
            let annotations = lock.withLock { () -> SecureMacAnnotationHost? in
                if let peer = mediaPeers.removeValue(forKey: connectionID), !mediaPeers.values.contains(peer) {
                    timingPolicy.remove(peer: peer)
                }
                return self.annotations
            }
            annotations?.removePeer(connectionID: connectionID)
        }
        var annotationHost: SecureMacAnnotationHost? { lock.withLock { annotations } }
        func setAnnotations(_ annotations: SecureMacAnnotationHost) { lock.withLock { self.annotations = annotations } }
        var isActive: Bool { lock.withLock { owner != nil } }
        var currentBroadcaster: MediaHostSession.Broadcaster? { lock.withLock { owner } }
        var currentHost: MediaHostSession? { lock.withLock { host } }
        var renderer: LocalRenderer? { lock.withLock { local } }
        func diagnostics() -> HostTimingDiagnostics {
            lock.withLock {
                let now = MonotonicClock.nowNanos()
                let measured = timingPolicy.measurements(at: now)
                let peers = Set(mediaPeers.values)
                let listeners = peers.sorted { $0.uuidString < $1.uuidString }.map { peer in
                    let sample = measured.first { $0.peerID == peer }
                    let playback = sample?.report.playback
                    let elapsed = sample?.receivedElapsedNanos ?? 0
                    return HostListenerTimingDiagnostics(peerID: peer.uuidString,
                        isTimingEligible: sample?.isNetworkTimingEligible ?? false,
                        reportAgeMilliseconds: sample.map { Double($0.ageNanos) / 1_000_000 },
                        recommendedBufferMilliseconds: sample.map { Double($0.report.networkRecommendedDelayNanos) / 1_000_000 } ?? 0,
                        hardwareFloorMilliseconds: sample.map { Double($0.report.hardwareOutputFloorNanos) / 1_000_000 } ?? 0,
                        driftMilliseconds: playback?.driftNanos.map { Double($0) / 1_000_000 },
                        driftSampleAgeMilliseconds: playback?.driftSampleAgeNanos.map { Double($0 + elapsed) / 1_000_000 },
                        playbackReportAgeMilliseconds: playback == nil ? nil : Double(elapsed) / 1_000_000,
                        screenTiming: playback?.screenTiming)
                }
                return HostTimingDiagnostics(listenerCount: peers.count, reportingListenerCount: listeners.filter { $0.reportAgeMilliseconds != nil }.count,
                    groupBufferMilliseconds: Double(timeline.playoutDelayNanos) / 1_000_000,
                    maximumLatenessMilliseconds: measured.compactMap { $0.report.playback }.map { Double($0.latenessNanos) / 1_000_000 }.max() ?? 0,
                    totalResyncCount: measured.compactMap { $0.report.playback }.reduce(UInt64(0)) { sum, report in
                        let added = sum.addingReportingOverflow(report.resyncCount)
                        return added.overflow ? .max : added.partialValue
                    },
                    roomTimingChangeCount: roomTimingChangeCount, videoEnabled: videoGeneration != nil, listeners: listeners)
            }
        }
        var sourcePlaying: Bool? { lock.withLock { playing } }
        func begin(owner: MediaHostSession.Broadcaster) { lock.withLock { self.owner = owner } }
        func install(host: MediaHostSession, renderer: LocalRenderer) -> Bool {
            lock.withLock {
                guard owner != nil else { return false }
                self.host = host; local = renderer; return true
            }
        }
        func accept(_ samples: [Int16], captureTimeNanos: UInt64) {
            let refresh = lock.withLock { () -> MediaHostSession? in
                guard owner != nil, let host, playing != false, !samples.isEmpty,
                      samples.count <= 96_000, samples.count.isMultiple(of: 2), captureTimeNanos <= UInt64(Int64.max) else { return nil }
                let duration = UInt64(samples.count / 2) * 1_000_000_000 / 48_000
                let end = captureTimeNanos.addingReportingOverflow(duration)
                guard !end.overflow else { return nil }
                if let expected = expectedNextCapture,
                   captureTimeNanos < expected && expected - captureTimeNanos > 5_000_000
                    || captureTimeNanos > expected && captureTimeNanos - expected > 5_000_000 {
                    packetizer.discardPendingSamples()
                    // Drop only the partial PCM chunk. Complete packets retain
                    // their real capture timestamps and monotonic frame index;
                    // a tap gap must not re-prepare every healthy subscriber.
                }
                expectedNextCapture = end.partialValue
                // Packetization happens once, before local/remote fan-out. Both
                // consumers see identical frame indices and capture timestamps.
                let packets = packetizer.append(samples: samples, captureTimeNanos: captureTimeNanos)
                if !packets.isEmpty { timingPolicy.captureStarted(at: captureTimeNanos) }
                let needsRefresh = timeline.observe(packets)
                host.submitAudio(packets)
                local?.append(packets)
                return needsRefresh ? host : nil
            }
            refresh?.refreshTimeline()
        }
        func setPlaying(_ value: Bool?) {
            guard let value else { return }
            let host = lock.withLock { () -> MediaHostSession? in
                guard owner != nil, playing != value else { return nil }
                playbackGeneration = UUID()
                playing = value; expectedNextCapture = nil; packetizer.discardPendingSamples()
                timeline.setPlaying(value); local?.setPlaying(value)
                return self.host
            }
            host?.refreshTimeline()
        }
        func receiveTiming(peer: UUID, stream: MediaStreamIdentifier, report: MediaReceiverTimingReport, now: UInt64) {
            lock.withLock {
                guard owner?.epoch == stream.broadcasterEpoch else { return }
                timingPolicy.record(peer: peer, report: report, receivedAt: now)
            }
            updateTiming(now: now)
        }
        func receiveLocalFloor(_ floor: UInt64) {
            lock.withLock { localFloor = floor }
            updateTiming(now: MonotonicClock.nowNanos())
        }
        private func updateTiming(now: UInt64) {
            let work = lock.withLock { () -> (LocalRenderer, MediaHostSession, CapturedMediaTimeline.PlayoutCutover?, UUID)? in
                guard owner != nil, let host, let local else { return nil }
                let current = timeline.requestedPlayoutDelayNanos
                let desired = timingPolicy.desiredDelay(now: now, current: current,
                    localHardwareFloor: localFloor, playing: playing != false)
                guard desired != current else { return nil }
                let cutover = timeline.schedulePlayoutDelay(desired, now: now)
                // A pending proposal cannot be overwritten by another report.
                guard cutover != nil || (timeline.requestedPlayoutDelayNanos == timeline.playoutDelayNanos
                    && timeline.playoutDelayNanos != current) else { return nil }
                if cutover == nil { roomTimingChangeCount &+= 1 }
                return (local, host, cutover, playbackGeneration)
            }
            guard let (local, host, cutover, generation) = work else { return }
            guard let cutover else { host.refreshTimeline(); return }
            local.stage(cutover, authorizeCommit: { [weak self, weak host] commit in
                guard let self, let host else { return false }
                return try self.lock.withLock {
                    guard self.owner != nil, self.host === host,
                          self.playbackGeneration == generation else { return false }
                    // Preparation creates the native track outside this lock.
                    // Its bounded commit and publication form one transaction:
                    // pause/resume cannot revoke the reservation between them.
                    try commit()
                    guard self.timeline.announce(cutover) else { return false }
                    self.roomTimingChangeCount &+= 1
                    self.preview?.stagePlayoutAnchor(captureTimeNanos: cutover.captureTimeNanos,
                        delayNanos: cutover.playoutDelayNanos)
                    return true
                }
            }, completion: { [weak self, weak host] accepted in
                guard let self, let host else { return }
                if accepted { host.refreshTimeline() }
                else {
                    self.lock.withLock {
                        guard self.playbackGeneration == generation else { return }
                        self.timeline.cancelUnannounced(cutover)
                    }
                }
            })
        }
        func requestKeyframe(_ minimum: UInt64?) { lock.withLock { keyframe }?(minimum) }
        func configureVideo(encoder: VideoEncoder?, decoder: VideoDecoder?, generation: UUID? = nil) {
            let host = lock.withLock { () -> MediaHostSession? in
                keyframe = encoder.map { encoder in { _ in encoder.requestKeyframe() } }
                preview = decoder
                decoder?.setTargetLatencyNanos(timeline.playoutDelayNanos)
                if let owner, let anchor = timeline.anchor(for: .init(sessionID: owner.peerID,
                    broadcasterEpoch: owner.epoch, generation: 1), issuedAtHostNanos: MonotonicClock.nowNanos()) {
                    decoder?.stagePlayoutAnchor(captureTimeNanos: anchor.captureTimeNanos,
                        delayNanos: anchor.hostPlaybackTimeNanos - anchor.captureTimeNanos)
                }
                videoGeneration = generation
                return owner == nil ? nil : self.host
            }
            host?.setVideoEnabled(encoder != nil)
        }
        func isCurrentVideo(_ generation: UUID) -> Bool { lock.withLock { owner != nil && videoGeneration == generation } }
        func acceptVideo(_ frame: VideoFrame, generation: UUID) {
            let outputs = lock.withLock { () -> (MediaHostSession, VideoDecoder)? in
                guard owner != nil, videoGeneration == generation, let host, let preview else { return nil }
                return (host, preview)
            }
            outputs?.0.submitVideo(frame)
            outputs?.1.accept(frame)
        }
        func revoke() {
            let previous = lock.withLock { () -> (MediaHostSession?, LocalRenderer?, SecureMacAnnotationHost?) in
                owner = nil
                let previous = (host, local, annotations)
                host = nil; local = nil; keyframe = nil; preview = nil; videoGeneration = nil
                annotations = nil
                mediaPeers.removeAll()
                packetizer.discardPendingSamples(); expectedNextCapture = nil
                return previous
            }
            previous.0?.stop(); previous.1?.stop(); previous.2?.stop()
        }
    }

    final class LocalRenderer: @unchecked Sendable {
        private let queue: DispatchQueue
        private let nowNanos: () -> UInt64
        private let lock = NSLock()
        private let player: SecureMacPlaybackTimeline
        private let timeline: CapturedMediaTimeline
        private let stream: MediaStreamIdentifier
        private let timing: (UInt64) -> Void
        private var lastTimingReport: UInt64 = 0
        private var pending: [AudioPacket] = []
        private var stopped = false, playing = true
        private var playbackGeneration = UUID()
        private var pausePending = false
        private var timer: DispatchSourceTimer?
        /// Read only before start(), while the creating executor owns the player.
        var initialOutputFloor: UInt64 {
            RoomTiming.outputLatencyFloor(player.outputLatencyForTimingNanos,
                renderSchedulingHeadroomNanos: player.renderSchedulingHeadroomForTimingNanos)
        }
        init(audioOutput: RoomAudioOutputEngine, timeline: CapturedMediaTimeline, epoch: UInt64,
             timing: @escaping (UInt64) -> Void) throws {
            player = try SecureMacPlaybackTimeline(audioOutput: audioOutput)
            queue = DispatchQueue(label: "alo.secure-host.local-playback", qos: .userInteractive)
            nowNanos = MonotonicClock.nowNanos
            self.timeline = timeline
            self.timing = timing
            stream = .init(sessionID: UUID(), broadcasterEpoch: epoch, generation: 1)
        }
        /// Scheduling seam: the same runtime drain and stage paths can run with
        /// a fake native track and a controlled serial executor, without hardware.
        init(player: SecureMacPlaybackTimeline, timeline: CapturedMediaTimeline, epoch: UInt64,
             queue: DispatchQueue, nowNanos: @escaping () -> UInt64,
             timing: @escaping (UInt64) -> Void = { _ in }) {
            self.player = player; self.timeline = timeline; self.queue = queue
            self.nowNanos = nowNanos; self.timing = timing
            stream = .init(sessionID: UUID(), broadcasterEpoch: epoch, generation: 1)
        }
        func start() {
            queue.async {
                guard !self.lock.withLock({ self.stopped }) else { return }
                self.player.clockOffsetNanos = 0
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(5))
                timer.setEventHandler { [weak self] in self?.drain() }
                self.timer = timer; timer.resume()
            }
        }
        func append(_ packets: [AudioPacket]) {
            lock.withLock {
                guard !stopped, playing else { return }
                for packet in packets.suffix(128) {
                    if pending.count == 128 { pending.removeFirst() }
                    pending.append(packet)
                }
            }
        }
        func setPlaying(_ value: Bool) {
            lock.withLock {
                guard playing != value else { return }
                playbackGeneration = UUID()
                playing = value
                if !value { pending.removeAll(); pausePending = true }
            }
        }
        func setLevel(volume: Double, muted: Bool) {
            queue.async { self.player.setLevel(volume: volume, muted: muted) }
        }
        func setAutomaticSyncEnabled(_ enabled: Bool) {
            queue.async { self.player.setAutomaticSyncEnabled(enabled) }
        }
        func setMusicDucked(_ ducked: Bool) {
            queue.async { self.player.setDuckingGain(ducked ? 0.3 : 1) }
        }
        func stage(_ change: CapturedMediaTimeline.PlayoutCutover,
                   authorizeCommit: @escaping (_ commit: () throws -> Void) throws -> Bool,
                   completion: @escaping (Bool) -> Void) {
            let generation = lock.withLock { playbackGeneration }
            queue.async {
                guard self.lock.withLock({ !self.stopped && self.playing && !self.pausePending
                    && self.playbackGeneration == generation }) else { completion(false); return }
                let id = UUID()
                let anchor = MediaStreamAnchor(stream: self.stream, captureTimeNanos: change.captureTimeNanos,
                    frameIndex: change.frameIndex, hostPlaybackTimeNanos: change.captureTimeNanos + change.playoutDelayNanos,
                    issuedAtHostNanos: self.nowNanos())
                do {
                    try self.player.prepare(id: id, anchor: anchor, clockOffsetNanos: 0)
                    let accepted = try authorizeCommit { try self.player.commit(id: id) }
                    if !accepted { self.player.cancelPreparation(id: id) }
                    completion(accepted)
                } catch { self.player.cancelPreparation(id: id); completion(false) }
            }
        }
        func drain() {
            let batch = lock.withLock { () -> ([AudioPacket], Bool, Bool, Bool) in
                let batch = pending; pending.removeAll(keepingCapacity: true)
                let paused = pausePending; pausePending = false
                return (batch, playing, stopped, paused)
            }
            guard !batch.2 else { return }
            // A false→true update between drains must still invalidate the old
            // PCM and anchor before admitting the resumed capture reference.
            if batch.3 { player.setRoomPlayback(playing: false) }
            player.setRoomPlayback(playing: batch.1)
            let now = nowNanos()
            if batch.1, !batch.0.isEmpty, player.committedAnchor?.state != .running,
               let anchor = timeline.anchor(for: stream, issuedAtHostNanos: now) {
                let id = UUID()
                do {
                    try player.prepare(id: id, anchor: anchor, clockOffsetNanos: 0)
                    try player.commit(id: id)
                } catch { player.cancelPreparation(id: id) }
            }
            for packet in batch.0 { player.accept(packet) }
            player.maintainSync()
            if now >= lastTimingReport, now - lastTimingReport >= 1_000_000_000 {
                lastTimingReport = now
                timing(RoomTiming.outputLatencyFloor(player.outputLatencyForTimingNanos,
                    renderSchedulingHeadroomNanos: player.renderSchedulingHeadroomForTimingNanos))
            }
        }
        func stop() {
            lock.withLock { stopped = true; pending.removeAll() }
            queue.async { self.timer?.cancel(); self.timer = nil; self.player.stop() }
        }
        func report() async -> PlaybackSyncReport? {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: self.lock.withLock({ self.stopped }) ? nil : self.player.syncReport())
                }
            }
        }
        func diagnostics() async -> ReceiverTimingDiagnostics? {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !self.lock.withLock({ self.stopped }) else { continuation.resume(returning: nil); return }
                    let report = self.player.syncReport()
                    let format = self.player.outputHardwareFormatForDiagnostics
                    continuation.resume(returning: ReceiverTimingDiagnostics(
                        roundTripMilliseconds: 0, clockOffsetMilliseconds: 0, jitterMilliseconds: 0,
                        recommendedBufferMilliseconds: Double(self.player.targetLatencyNanos) / 1_000_000,
                        outputLatencyMilliseconds: Double(self.player.outputLatencyForTimingNanos) / 1_000_000,
                        renderHeadroomMilliseconds: Double(self.player.renderSchedulingHeadroomForTimingNanos) / 1_000_000,
                        outputSampleRate: format?.sampleRate, outputChannelCount: format?.channelCount,
                        latenessMilliseconds: Double(report.latenessNanos) / 1_000_000,
                        latePacketCount: report.latePacketCount, resyncCount: report.resyncCount,
                        currentDriftMilliseconds: report.driftNanos.map { Double($0) / 1_000_000 },
                        driftMeasurementAgeMilliseconds: report.driftSampleAgeNanos.map { Double($0) / 1_000_000 },
                        activePlayoutBufferMilliseconds: Double(self.player.activePlayoutDelayNanos) / 1_000_000,
                        automaticSyncState: self.player.automaticSyncState))
                }
            }
        }
        deinit { timer?.cancel() }
    }
}
