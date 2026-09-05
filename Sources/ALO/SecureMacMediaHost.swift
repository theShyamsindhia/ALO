import Foundation
import ALOCore
import ALONetworking
import ALOAppleMedia
import CoreGraphics
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
    private var shouldPauseSourceOnStop = false
    private var cleanup: Task<Void, Never>?
    private var videoPicker: ScreenContentPicker?
    private var videoCapture: ScreenVideoCapture?
    private var videoEncoder: VideoEncoder?
    private var videoDecoder: VideoDecoder?
    private var videoGeneration = UUID()

    init() {}
    deinit { ingress.revoke() }

    func start(mesh: MeshControlPlane, room: RoomConfiguration, broadcaster: MeshBroadcaster,
               audioOutput: RoomAudioOutputEngine, nowPlaying: @escaping (NowPlayingMedia) -> Void,
               status: @escaping (String) -> Void, stopped: @escaping @Sendable (Error) -> Void) async throws {
        guard !started, cleanup == nil, room.transportPolicy == .secureV2,
              UUID(uuidString: room.id) != nil, let peerID = UUID(uuidString: broadcaster.nodeID),
              broadcaster.epoch < .max else { throw SecureTransportError.invalidState }
        guard #available(macOS 14.2, *) else { throw ALOError("Synchronized broadcasting requires macOS 14.2 or newer.") }
        started = true
        let token = lifecycle
        let owner = MediaHostSession.Broadcaster(peerID: peerID, epoch: broadcaster.epoch)
        let ingress = self.ingress
        ingress.begin(owner: owner)
        do {
            let host: MediaHostSession = try await withCheckedThrowingContinuation { continuation in
                mesh.makeMediaHost(callbacks: .init(
                    currentBroadcaster: { ingress.currentBroadcaster },
                    currentAnchor: { _, stream, now in ingress.timeline.anchor(for: stream, issuedAtHostNanos: now) },
                    // Remote recovery never resets our local output or capture clock.
                    resync: { _, _, _ in },
                    requestKeyframe: { _, _, minimum in ingress.requestKeyframe(minimum) })) {
                        continuation.resume(with: $0)
                    }
            }
            guard lifecycle == token, !Task.isCancelled, ingress.isActive else { host.stop(); throw CancellationError() }
            guard host.localPeerID == peerID else { host.stop(); throw SecureTransportError.invalidCredentials }
            let renderer = try LocalRenderer(audioOutput: audioOutput, timeline: ingress.timeline)
            guard ingress.install(host: host, renderer: renderer) else {
                host.stop(); renderer.stop(); throw CancellationError()
            }
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
                else { try host.attach(channel: channel, credentials: credentials) }
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
            let encoder = VideoEncoder { frame in ingress.acceptVideo(frame, generation: videoToken) }
            let capture = ScreenVideoCapture()
            videoEncoder = encoder; videoDecoder = decoder; videoCapture = capture
            ingress.configureVideo(encoder: encoder, decoder: decoder, generation: videoToken)
            try await capture.start(filter: filter, metadata: { metadata in
                guard ingress.isCurrentVideo(videoToken) else { return }
                metadataHandler(metadata)
            }) { pixelBuffer, captureTime in
                guard ingress.isCurrentVideo(videoToken) else { return }
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
        var isActive: Bool { lock.withLock { owner != nil } }
        var currentBroadcaster: MediaHostSession.Broadcaster? { lock.withLock { owner } }
        var currentHost: MediaHostSession? { lock.withLock { host } }
        var renderer: LocalRenderer? { lock.withLock { local } }
        var sourcePlaying: Bool? { lock.withLock { playing } }
        func begin(owner: MediaHostSession.Broadcaster) { lock.withLock { self.owner = owner } }
        func install(host: MediaHostSession, renderer: LocalRenderer) -> Bool {
            lock.withLock {
                guard owner != nil else { return false }
                self.host = host; local = renderer; return true
            }
        }
        func accept(_ samples: [Int16], captureTimeNanos: UInt64) {
            lock.withLock {
                guard owner != nil, let host, playing != false, !samples.isEmpty,
                      samples.count <= 96_000, samples.count.isMultiple(of: 2), captureTimeNanos <= UInt64(Int64.max) else { return }
                let duration = UInt64(samples.count / 2) * 1_000_000_000 / 48_000
                let end = captureTimeNanos.addingReportingOverflow(duration)
                guard !end.overflow else { return }
                if let expected = expectedNextCapture,
                   captureTimeNanos < expected && expected - captureTimeNanos > 5_000_000
                    || captureTimeNanos > expected && captureTimeNanos - expected > 5_000_000 {
                    packetizer.discardPendingSamples()
                }
                expectedNextCapture = end.partialValue
                // Packetization happens once, before local/remote fan-out. Both
                // consumers see identical frame indices and capture timestamps.
                let packets = packetizer.append(samples: samples, captureTimeNanos: captureTimeNanos)
                timeline.observe(packets)
                host.submitAudio(packets)
                local?.append(packets)
            }
        }
        func setPlaying(_ value: Bool?) {
            guard let value else { return }
            let host = lock.withLock { () -> MediaHostSession? in
                guard owner != nil, playing != value else { return nil }
                playing = value; expectedNextCapture = nil; packetizer.discardPendingSamples()
                timeline.setPlaying(value); local?.setPlaying(value)
                return self.host
            }
            host?.refreshTimeline()
        }
        func requestKeyframe(_ minimum: UInt64?) { lock.withLock { keyframe }?(minimum) }
        func configureVideo(encoder: VideoEncoder?, decoder: VideoDecoder?, generation: UUID? = nil) {
            let host = lock.withLock { () -> MediaHostSession? in
                keyframe = encoder.map { encoder in { _ in encoder.requestKeyframe() } }
                preview = decoder
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
            let previous = lock.withLock { () -> (MediaHostSession?, LocalRenderer?) in
                owner = nil
                let previous = (host, local)
                host = nil; local = nil; keyframe = nil; preview = nil; videoGeneration = nil
                packetizer.discardPendingSamples(); expectedNextCapture = nil
                return previous
            }
            previous.0?.stop(); previous.1?.stop()
        }
    }

    private final class LocalRenderer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "alo.secure-host.local-playback", qos: .userInteractive)
        private let lock = NSLock()
        private let player: SynchronizedPlayer
        private let timeline: CapturedMediaTimeline
        private var pending: [AudioPacket] = []
        private var stopped = false, playing = true
        private var timer: DispatchSourceTimer?
        init(audioOutput: RoomAudioOutputEngine, timeline: CapturedMediaTimeline) throws {
            player = try SynchronizedPlayer(audioOutput: audioOutput)
            self.timeline = timeline
        }
        func start() {
            queue.async {
                guard !self.lock.withLock({ self.stopped }) else { return }
                self.player.clockOffsetNanos = 0
                self.player.setTargetLatencyNanos(self.timeline.playoutDelayNanos)
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
            lock.withLock { playing = value; if !value { pending.removeAll() } }
        }
        func setLevel(volume: Double, muted: Bool) {
            queue.async { self.player.setLevel(volume: volume, muted: muted) }
        }
        private func drain() {
            let batch = lock.withLock { () -> ([AudioPacket], Bool, Bool) in
                let batch = pending; pending.removeAll(keepingCapacity: true)
                return (batch, playing, stopped)
            }
            guard !batch.2 else { return }
            player.setRoomPlayback(playing: batch.1)
            player.setTargetLatencyNanos(timeline.playoutDelayNanos)
            for packet in batch.0 { player.accept(packet) }
            player.maintainSync()
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
        deinit { timer?.cancel() }
    }
}
