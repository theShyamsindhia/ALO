import Foundation
import CoreGraphics
import ALOCore
import ALONetworking

/// Owns the secure receiver independently of the room's durable control link.
/// A failed media connection is redialed; it is never translated into a durable
/// broadcaster stop, and it cannot restart another participant's output graph.
final class SecureMacMediaReceiver: @unchecked Sendable {
    private let mesh: MeshControlPlane
    private let selection: MediaReceiverSession.Selection
    private let queue = DispatchQueue(label: "alo.secure-media.playback", qos: .userInteractive)
    private let player: SecureMacPlaybackTimeline
    private let status: (MediaReceiverSession.State) -> Void
    private let annotations: SecureMacAnnotationViewer?
    private let videoDecoder: VideoDecoder
    private var videoEnabled = false
    private var screenTiming = ReceiverScreenTiming()
    private let videoGate = VideoGate()
    private let attachmentGate = MediaAttachmentGate()
    private final class VideoGate: @unchecked Sendable {
        private let lock = NSLock()
        private var token: TransportToken?
        func set(_ token: TransportToken?) { lock.withLock { self.token = token } }
        func accepts(_ token: TransportToken) -> Bool { lock.withLock { self.token == token } }
    }
    private var supervisor = ConnectionSupervisor()
    private var receiver: MediaReceiverSession?
    private var token: TransportToken?
    private var timer: DispatchSourceTimer?
    private var stopped = true
    private var started = false
    private var lastTimingReportNanos: UInt64 = 0
    private var committed: MediaStreamAnchor?
    private var localRepairPending = false
    private var clock: MediaReceiverSession.ClockSnapshot?
    private let jitter = NetworkJitterEstimator()
    private let inbox = PacketInbox()

    /// The transport callback cannot enqueue an unbounded closure per 5ms packet.
    /// Each item retains its connection token, so a queued predecessor cannot
    /// repopulate playback after leave/rejoin or a failed connection replacement.
    final class PacketInbox: @unchecked Sendable {
        struct Item {
            let packet: AudioPacket
            let token: TransportToken
            let receivedAt = MonotonicClock.nowNanos()
        }
        private let lock = NSLock()
        private var pending: [Item] = []
        private var scheduled = false
        func append(_ item: Item) -> Bool {
            lock.withLock {
                if pending.count == 128 { pending.removeFirst() }
                pending.append(item)
                guard !scheduled else { return false }
                scheduled = true
                return true
            }
        }
        func take() -> [Item] {
            lock.withLock {
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                scheduled = false
                return batch
            }
        }
    }

    init(mesh: MeshControlPlane, selection: MediaReceiverSession.Selection,
         audioOutput: RoomAudioOutputEngine,
         status: @escaping (MediaReceiverSession.State) -> Void,
         playbackActivity: @escaping (Bool) -> Void = { _ in },
         annotations: SecureMacAnnotationViewer? = nil,
         videoHandler: @escaping (CGImage) -> Void = { _ in }) throws {
        self.mesh = mesh; self.selection = selection; self.status = status
        self.annotations = annotations
        videoDecoder = VideoDecoder(imageHandler: videoHandler)
        player = try SecureMacPlaybackTimeline(audioOutput: audioOutput, playbackActivity: playbackActivity)
    }

    private var now: TimeInterval { Double(MonotonicClock.nowNanos()) / 1_000_000_000 }

    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.stopped = false
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                self.player.maintainSync()
                self.reportTiming()
                self.perform(self.supervisor.advance(lifecycle: self.supervisor.lifecycle, now: self.now,
                                                     jitterUnit: Double.random(in: 0...1)))
            }
            self.timer = timer; timer.resume()
            self.perform(self.supervisor.start(now: self.now))
        }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.attachmentGate.set(nil)
            self.perform(self.supervisor.stop())
            self.timer?.cancel(); self.timer = nil
            self.receiver?.stop(); self.receiver = nil
            self.annotations?.stop()
            self.videoGate.set(nil); self.videoDecoder.stop()
            self.token = nil; self.committed = nil
            _ = self.inbox.take()
            self.player.stop()
        }
    }

    func setLevel(volume: Double, muted: Bool) {
        queue.async { self.player.setLevel(volume: volume, muted: muted) }
    }
    func setMusicDucked(_ ducked: Bool) {
        queue.async { self.player.setDuckingGain(ducked ? 0.3 : 1) }
    }

    func resynchronize() { queue.async { self.receiver?.resynchronize() } }

    func setVideoEnabled(_ enabled: Bool) {
        queue.async {
            guard !self.stopped, self.videoEnabled != enabled else { return }
            self.videoEnabled = enabled
            self.screenTiming.update(enabled: enabled, at: MonotonicClock.nowNanos())
            self.configureVideo()
        }
    }

    private func configureVideo() {
        guard let receiver, let token else { return }
        videoGate.set(videoEnabled ? token : nil)
        if !videoEnabled { receiver.stopVideo(); videoDecoder.forceResync(); return }
        let mesh = self.mesh, peerID = selection.broadcasterPeerID
        let gate = videoGate, decoder = videoDecoder
        receiver.startVideo(openChannel: { completion in
            mesh.openMediaChannel(to: peerID, role: .video) { result in completion(result.map { $0.0 }) }
        }, callbacks: .init(frame: { frame, _, _ in
            guard gate.accepts(token) else { return }
            // VideoDecoder owns bounded decode + presentation admission itself.
            decoder.accept(frame)
        }, state: { state in
            if state == .recovering, gate.accepts(token) { decoder.forceResync() }
        }))
    }

    func diagnosticsSnapshot() -> ReceiverTimingDiagnostics {
        queue.sync {
            let report = player.syncReport()
            let format = player.outputHardwareFormatForDiagnostics
            let now = MonotonicClock.nowNanos()
            let fresh = clock.flatMap { now >= $0.sampledAtLocalNanos && now - $0.sampledAtLocalNanos <= 5_000_000_000 ? $0 : nil }
            return ReceiverTimingDiagnostics(
                roundTripMilliseconds: fresh.map { Double($0.roundTripNanos) / 1_000_000 },
                clockOffsetMilliseconds: fresh.map { Double($0.offsetNanos) / 1_000_000 },
                jitterMilliseconds: Double(jitter.jitterNanos) / 1_000_000,
                recommendedBufferMilliseconds: Double(jitter.recommendedPlayoutDelayNanos(
                    roundTripNanos: fresh?.roundTripNanos,
                    outputLatencyNanos: player.outputLatencyForTimingNanos,
                    renderSchedulingHeadroomNanos: player.renderSchedulingHeadroomForTimingNanos)) / 1_000_000,
                outputLatencyMilliseconds: Double(player.outputLatencyForTimingNanos) / 1_000_000,
                renderHeadroomMilliseconds: Double(player.renderSchedulingHeadroomForTimingNanos) / 1_000_000,
                outputSampleRate: format?.sampleRate, outputChannelCount: format?.channelCount,
                latenessMilliseconds: Double(report.latenessNanos) / 1_000_000,
                latePacketCount: report.latePacketCount, resyncCount: report.resyncCount,
                currentDriftMilliseconds: report.driftNanos.map { Double($0) / 1_000_000 },
                driftMeasurementAgeMilliseconds: report.driftSampleAgeNanos.map { Double($0) / 1_000_000 },
                video: screenTiming.presentationSnapshot(videoDecoder.presentationTimingSnapshot),
                videoEnabled: screenTiming.videoEnabled)
        }
    }

    private func perform(_ actions: [ConnectionAction]) {
        for action in actions {
            switch action {
            case .discover(let lifecycle):
                // The mesh resolves the current admitted peer endpoint on every
                // open. Never retain the previous NWConnection or remote address.
                perform(supervisor.resolved(lifecycle: lifecycle, now: now))
            case .connect(let token): connect(token)
            case .cancel(let cancelled):
                if token == cancelled {
                    attachmentGate.set(nil)
                    receiver?.stop(); receiver = nil; token = nil
                    annotations?.disconnect()
                    videoGate.set(nil); videoDecoder.resetTiming()
                    videoDecoder.resetTiming()
                    committed = nil; localRepairPending = false; clock = nil; jitter.reset()
                    _ = inbox.take()
                    // Only a terminal control failure reaches this action.
                    // UDP ticket renewal does not: it keeps the live renderer.
                    player.setRoomPlayback(playing: false)
                    player.clockOffsetNanos = nil
                }
            case .retryScheduled: status(.recovering)
            case .becameActive: status(.active)
            case .candidateReady, .cutoverPrepared: break
            }
        }
    }

    private func connect(_ attempt: TransportToken) {
        guard !stopped else { return }
        token = attempt
        attachmentGate.set(attempt)
        mesh.openMediaChannel(to: selection.broadcasterPeerID, role: .mediaControl) { [weak self] result in
            guard let self, self.attachmentGate.accepts(attempt) else {
                if case .success(let (channel, _)) = result { channel.cancel() }
                return
            }
            switch result {
            case .failure:
                self.queue.async { self.failed(attempt) }
            case .success(let (channel, _)):
                // This attachment stays inline on the mesh executor. Deferring
                // it to MainActor would lose coalesced early channel payloads.
                MediaReceiverSession.attach(channel: channel, expected: self.selection,
                    callbacks: self.callbacks(for: attempt)) { result in
                    if case .success(let receiver) = result, self.attachmentGate.accepts(attempt) {
                        self.annotations?.attach(channel: channel, receiver: receiver)
                    }
                    self.queue.async {
                        guard !self.stopped, self.token == attempt else {
                            if case .success(let stale) = result { stale.stop() }
                            return
                        }
                        switch result {
                        case .success(let receiver):
                            self.receiver = receiver
                            self.reportTiming(force: true)
                            self.configureVideo()
                            self.perform(self.supervisor.ready(attempt, now: self.now))
                            self.perform(self.supervisor.authenticated(attempt, now: self.now))
                        case .failure: self.failed(attempt)
                        }
                    }
                }
            }
        }
    }

    private func failed(_ attempt: TransportToken) {
        guard !stopped, token == attempt else { return }
        attachmentGate.set(nil)
        perform(supervisor.fail(attempt, now: now, jitterUnit: Double.random(in: 0...1)))
    }

    private func callbacks(for attempt: TransportToken) -> MediaReceiverSession.Callbacks {
        .init(prepareAnchor: { [weak self] preparation in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped, self.token == attempt else { return }
                // Preparation must not reset, stop, or mute the predecessor.
                self.reportTiming(force: true)
                do {
                    try self.player.prepare(id: preparation.id, anchor: preparation.anchor,
                        clockOffsetNanos: preparation.clock.offsetNanos)
                    self.receiver?.completePreparation(id: preparation.id, ready: true)
                } catch {
                    self.player.cancelPreparation(id: preparation.id)
                    let repair = (error as? SecureMacPlaybackTimeline.PreparationError) == .missedCutover
                        && self.player.repairMissedCutover(preparation.anchor)
                    if repair {
                        self.localRepairPending = true
                        self.committed = nil
                        _ = self.inbox.take()
                        self.status(.recovering)
                    }
                    self.receiver?.completePreparation(id: preparation.id, ready: false)
                    if repair { self.receiver?.resynchronize() }
                }
            }
        }, anchorCommitted: { [weak self] preparation in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped, self.token == attempt else { return }
                let anchor = preparation.anchor
                do { try self.player.commit(id: preparation.id) }
                catch { self.receiver?.resynchronize(); return }
                self.clock = preparation.clock
                self.videoDecoder.updateClockOffsetNanos(preparation.clock.offsetNanos)
                self.videoDecoder.stagePlayoutAnchor(captureTimeNanos: anchor.captureTimeNanos,
                    delayNanos: anchor.hostPlaybackTimeNanos - anchor.captureTimeNanos)
                self.committed = anchor
                self.localRepairPending = false
                self.perform(self.supervisor.synchronized(attempt, madeProgress: true, now: self.now))
            }
        }, audio: { [weak self] packet, _, _ in
            guard let self else { return }
            if self.inbox.append(.init(packet: packet, token: attempt)) {
                self.queue.async { [weak self] in self?.drainPackets() }
            }
        }, state: { [weak self] state in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped, self.token == attempt else { return }
                if state == .failed { self.failed(attempt) }
                else { self.status(self.localRepairPending && state == .active ? .recovering : state) }
            }
        }, clock: { [weak self] clock in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped, self.token == attempt else { return }
                self.player.clockOffsetNanos = clock.offsetNanos
                self.clock = clock
                self.videoDecoder.updateClockOffsetNanos(clock.offsetNanos)
            }
        }, paused: { [weak self] _, _ in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped, self.token == attempt else { return }
                self.localRepairPending = false
                self.player.setRoomPlayback(playing: false)
            }
        }, annotation: { [weak self] in self?.annotations?.receiveAnnotation($0) ?? false },
           metadata: { [weak self] in self?.annotations?.receiveMetadata($0) ?? false })
    }

    private func drainPackets() {
        let batch = inbox.take()
        guard !stopped else { return }
        for item in batch where item.token == token {
            guard committed != nil else { continue }
            if let clock {
                jitter.observe(captureTimeNanos: item.packet.captureTimeNanos,
                    receivedAt: item.receivedAt, clockOffsetNanos: clock.offsetNanos)
            }
            player.accept(item.packet)
        }
    }

    private func reportTiming(force: Bool = false) {
        guard let receiver else { return }
        let now = MonotonicClock.nowNanos()
        guard force || now >= lastTimingReportNanos && now - lastTimingReportNanos >= 1_000_000_000 else { return }
        let floor = RoomTiming.outputLatencyFloor(player.outputLatencyForTimingNanos,
            renderSchedulingHeadroomNanos: player.renderSchedulingHeadroomForTimingNanos)
        let freshClock = clock.flatMap { now >= $0.sampledAtLocalNanos && now - $0.sampledAtLocalNanos <= MediaReceiverTimingReport.maximumAgeNanos ? $0 : nil }
        let network = jitter.recommendedPlayoutDelayNanos(roundTripNanos: freshClock?.roundTripNanos,
            outputLatencyNanos: player.outputLatencyForTimingNanos,
            renderSchedulingHeadroomNanos: player.renderSchedulingHeadroomForTimingNanos)
        let rendered = player.syncReport()
        let playback = PlaybackSyncReport(measuredAtNanos: 0, latenessNanos: rendered.latenessNanos,
            latePacketCount: rendered.latePacketCount, resyncCount: rendered.resyncCount,
            driftNanos: rendered.driftNanos, driftSampleAgeNanos: rendered.driftSampleAgeNanos,
            screenTiming: screenTiming.presentationSnapshot(videoDecoder.presentationTimingSnapshot).relativeTimingReport)
        guard let report = try? MediaReceiverTimingReport(hardwareOutputFloorNanos: floor,
            networkRecommendedDelayNanos: max(floor, network), roundTripNanos: freshClock?.roundTripNanos,
            playback: playback) else { return }
        receiver.updateTiming(report)
        lastTimingReportNanos = now
    }
}
