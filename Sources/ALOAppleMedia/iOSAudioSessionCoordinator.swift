#if os(iOS)
import AVFoundation
import Foundation
import ALOCore

/// One hardware engine mixes synchronized room media and independently scheduled
/// peer voices. Constructing this object never activates audio or asks for a mic.
@MainActor
public final class iOSAudioSessionCoordinator {
    private final class VoiceTrack {
        let player = AVAudioPlayerNode()
        var scheduler = PCMPlaybackScheduler(limits: .init(maximumBuffers: 32, schedulingHorizonNanos: 80_000_000))
        var lastReceivedNanos: UInt64 = 0
    }
    public private(set) var lifecycle = AudioLifecycle() {
        didSet { if lifecycle != oldValue { onLifecycleChanged?(lifecycle) } }
    }
    /// Lets the app immediately close Talk/Open Line consent and update its mic UI
    /// when a route, interruption, or suspension revokes transmission intent.
    public var onLifecycleChanged: (@MainActor (AudioLifecycle) -> Void)?
    public var levels = AudioMixLevels() { didSet { applyLevels() } }
    public var onNeedsResynchronization: (@MainActor (UInt64) -> Void)?
    public var onMicrophoneChunk: (@MainActor (VoicePCMChunk) -> Void)?
    public var onError: (@MainActor (Error) -> Void)?
    public let maximumVoicePeers: Int
    public var outputLatencyNanos: UInt64 {
        let seconds = max(0, engine.outputNode.presentationLatency, session.outputLatency)
        return seconds.isFinite ? UInt64(min(seconds, 10) * 1_000_000_000) : 0
    }
    private let session = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var mediaPlayers: [UUID: AVAudioPlayerNode] = [:]
    private var mediaMixer = AVAudioMixerNode()
    private var voiceMixer = AVAudioMixerNode()
    private var mediaTransition = MediaPlaybackTransition()
    private var voices: [UUID: VoiceTrack] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pumpTask: Task<Void, Never>?
    private var microphone: MicrophonePCMConverter?
    private var inputTapInstalled = false
    private var reconfiguring = false
    private var outputFormatSignature = ""

    public init(maximumVoicePeers: Int = 8) {
        self.maximumVoicePeers = min(16, max(1, maximumVoicePeers))
        buildGraph()
        observeSession()
    }

    public func startListening() throws {
        _ = lifecycle.startListening()
        invalidateOutput()
        do { try configureEngine(transmitting: false) }
        catch { lifecycle.stop(); stopHardware(); throw error }
        startPump()
        onNeedsResynchronization?(lifecycle.generation)
    }

    /// Call after authenticated clock sampling and a new future broadcaster anchor.
    /// The generation prevents a pre-route-change synchronization reply from restarting old audio.
    public func setMediaAnchor(_ anchor: AudioPlaybackAnchor, clockOffsetNanos: Int64,
                               generation: UInt64) throws {
        let id = UUID()
        try prepareMediaAnchor(id: id, anchor: anchor, clockOffsetNanos: clockOffsetNanos, generation: generation)
        try commitMediaAnchor(id: id, generation: generation)
    }

    public func prepareMediaAnchor(id: UUID, anchor: AudioPlaybackAnchor, clockOffsetNanos: Int64,
                                   generation: UInt64) throws {
        guard lifecycle.canRender, engine.isRunning, generation == lifecycle.generation else { throw AppleMediaError.invalidState }
        try mediaTransition.prepare(id: id, anchor: anchor, offsetNanos: clockOffsetNanos,
                                    outputLatencyNanos: outputLatencyNanos, nowNanos: MonotonicClock.nowNanos())
    }

    public func commitMediaAnchor(id: UUID, generation: UInt64) throws {
        guard lifecycle.canRender, engine.isRunning, generation == lifecycle.generation else { throw AppleMediaError.invalidState }
        try mediaTransition.commit(id: id, nowNanos: MonotonicClock.nowNanos())
        // At most the live and committed successor exist. A proposal creates no
        // hardware work, and committing never stops the live predecessor.
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: mediaMixer, format: Self.format(channels: 2))
        mediaPlayers[id] = player
        player.play()
        lifecycle.resynchronized(generation: generation)
    }

    public func pauseMedia(generation: UInt64) {
        guard generation == lifecycle.generation else { return }
        clearMediaOutput()
        lifecycle.requireResynchronization()
    }

    public func setMediaAnchor(_ anchor: AudioPlaybackAnchor, clock: ClockSynchronizer,
                               generation: UInt64) throws {
        let now = MonotonicClock.nowNanos()
        guard clock.isReady, let offset = clock.offsetNanos(at: now) else { throw AppleMediaError.clockNotReady }
        try setMediaAnchor(anchor, clockOffsetNanos: offset, generation: generation)
    }

    public func updateMediaClockOffset(_ offsetNanos: Int64) { mediaTransition.updateClockOffset(offsetNanos) }

    public func enqueueMedia(_ packet: AudioPacket, generation: UInt64) throws {
        guard lifecycle.canRender, generation == lifecycle.generation,
              !lifecycle.needsResynchronization else { throw AppleMediaError.invalidState }
        try mediaTransition.enqueue(packet, nowNanos: MonotonicClock.nowNanos())
        pump()
    }

    /// The transport must already have authenticated this peer and accepted its
    /// Talk/Open Line consent. Each peer owns a separate player timeline.
    public func enqueueVoice(peerID: UUID, chunk: VoicePCMChunk) throws {
        guard lifecycle.canRender, engine.isRunning else { throw AppleMediaError.invalidState }
        let now = MonotonicClock.nowNanos()
        let track: VoiceTrack
        if let existing = voices[peerID] { track = existing }
        else {
            guard voices.count < maximumVoicePeers else { throw AppleMediaError.capacity }
            track = VoiceTrack()
            engine.attach(track.player)
            engine.connect(track.player, to: voiceMixer, format: Self.format(channels: 1))
            voices[peerID] = track
        }
        if track.scheduler.anchor == nil {
            // Directed voice does not use the broadcaster clock. Its first arrival
            // anchors this independent peer timeline with 50 ms of jitter headroom.
            let audible = now + outputLatencyNanos + 50_000_000
            try track.scheduler.setAnchor(.init(captureTimeNanos: chunk.captureTimeNanos, hostPlaybackTimeNanos: audible),
                                          clockOffsetNanos: 0, outputLatencyNanos: outputLatencyNanos, nowNanos: now)
            track.player.play()
        }
        try track.scheduler.enqueueVoice(chunk, nowNanos: now)
        track.lastReceivedNanos = now
        pump()
    }

    /// Call when the authenticated voice session ends, before reusing this peer ID
    /// for a new microphone timeline. Idle peer tracks also retire automatically.
    public func endVoice(peerID: UUID) {
        guard let track = voices.removeValue(forKey: peerID) else { return }
        track.scheduler.invalidate()
        track.player.stop()
        engine.detach(track.player)
        applyLevels()
    }

    /// This is the only permission-requesting entry point. Its caller must be the
    /// local Talk/Open Line button after the existing consent state machine allows it.
    public func startMicrophoneFromUserAction() async throws {
        let token = try lifecycle.requestMicrophoneFromUserAction()
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in continuation.resume(returning: granted) }
        }
        guard token == lifecycle.microphoneRequestGeneration else { throw CancellationError() }
        guard lifecycle.completeMicrophonePermission(generation: token, granted: granted) else {
            throw AppleMediaError.microphoneDenied
        }
        invalidateOutput()
        do {
            try configureEngine(transmitting: true)
            onNeedsResynchronization?(lifecycle.generation)
        } catch {
            lifecycle.stopMicrophone()
            stopHardware()
            try? configureEngine(transmitting: false)
            onNeedsResynchronization?(lifecycle.generation)
            throw error
        }
    }

    public func stopMicrophone() throws {
        guard lifecycle.phase == .transmitting || lifecycle.phase == .requestingMicrophone else { return }
        lifecycle.stopMicrophone()
        invalidateOutput()
        try configureEngine(transmitting: false)
        onNeedsResynchronization?(lifecycle.generation)
    }

    /// Background execution ending must cancel microphone intent and all stale work.
    /// This does not invent silent playback or request a background keepalive task.
    public func suspend() {
        lifecycle.suspend()
        pumpTask?.cancel(); pumpTask = nil
        invalidateOutput()
        stopHardware()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    public func resumeListeningAfterResync() throws {
        guard lifecycle.wantsListening else { throw AppleMediaError.invalidState }
        try startListening() // Starts output only; a new clock/anchor is still required.
    }

    public func stop() {
        lifecycle.stop()
        pumpTask?.cancel(); pumpTask = nil
        invalidateOutput()
        stopHardware()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The owner calls close when leaving the room; route listeners must not outlive it.
    public func close() {
        stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func buildGraph() {
        engine.attach(mediaMixer); engine.attach(voiceMixer)
        engine.connect(mediaMixer, to: engine.mainMixerNode, format: Self.format(channels: 2))
        engine.connect(voiceMixer, to: engine.mainMixerNode, format: Self.format(channels: 2))
        applyLevels()
    }

    private func configureEngine(transmitting: Bool) throws {
        reconfiguring = true
        defer { reconfiguring = false }
        stopHardware()
        if transmitting {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        } else {
            try session.setCategory(.playback, mode: .default, options: [])
        }
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        if transmitting {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            guard input.isVoiceProcessingEnabled else { throw AppleMediaError.audioConfiguration }
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            let actualFormat = input.outputFormat(forBus: 0)
            let generation = lifecycle.generation
            let converter = try MicrophonePCMConverter(inputFormat: actualFormat) { [weak self] chunk in
                Task { @MainActor [weak self] in
                    guard let self, self.lifecycle.generation == generation, self.lifecycle.isMicrophoneActive else { return }
                    self.onMicrophoneChunk?(chunk)
                }
            }
            microphone = converter
            input.installTap(onBus: 0, bufferSize: 480, format: actualFormat) { buffer, time in converter.accept(buffer, time: time) }
            inputTapInstalled = true
        } else if engine.outputNode.isVoiceProcessingEnabled {
            // The paired IO nodes share voice-processing enablement.
            try engine.outputNode.setVoiceProcessingEnabled(false)
        }
        engine.prepare()
        try engine.start()
        for player in mediaPlayers.values { player.play() }
        for track in voices.values { track.player.play() }
        outputFormatSignature = formatSignature()
        applyLevels()
    }

    private func stopHardware() {
        if inputTapInstalled { engine.inputNode.removeTap(onBus: 0); inputTapInstalled = false }
        microphone?.cancel(); microphone = nil
        engine.stop()
    }

    private func invalidateOutput() {
        clearMediaOutput()
        for peer in Array(voices.keys) { endVoice(peerID: peer) }
    }

    private func clearMediaOutput() {
        mediaTransition.reset()
        for player in mediaPlayers.values { player.stop(); engine.detach(player) }
        mediaPlayers.removeAll()
    }

    private func startPump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                guard !Task.isCancelled, let self else { return }
                if self.lifecycle.canRender { self.pump() }
            }
        }
    }

    private func pump() {
        guard lifecycle.canRender, engine.isRunning else { return }
        let now = MonotonicClock.nowNanos()
        for delivery in mediaTransition.drain(nowNanos: now) {
            guard let player = mediaPlayers[delivery.trackID] else { continue }
            schedule(delivery.buffer, player: player) { [weak self] token in
                self?.mediaTransition.completed(trackID: delivery.trackID, token: token)
            }
        }
        for id in Array(mediaPlayers.keys) where !mediaTransition.trackIDs.contains(id) {
            if let player = mediaPlayers.removeValue(forKey: id) { player.stop(); engine.detach(player) }
        }
        for (peer, track) in voices {
            for scheduled in track.scheduler.drain(nowNanos: now) {
                schedule(scheduled, player: track.player) { [weak self, weak track] token in
                    guard let self, let track, self.voices[peer] === track else { return }
                    _ = track.scheduler.completed(token)
                }
            }
        }
        for (peer, track) in voices where now > track.lastReceivedNanos
            && now - track.lastReceivedNanos > 2_000_000_000 && track.scheduler.bufferedCount == 0 {
            endVoice(peerID: peer)
        }
        applyLevels()
    }

    private func schedule(_ scheduled: ScheduledPCMBuffer, player: AVAudioPlayerNode,
                          completed: @escaping @MainActor (AudioBufferToken) -> Void) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format(channels: scheduled.channels),
                                           frameCapacity: AVAudioFrameCount(scheduled.frameCount)),
              let samples = buffer.floatChannelData else { completed(scheduled.token); return }
        buffer.frameLength = AVAudioFrameCount(scheduled.frameCount)
        for frame in 0..<scheduled.frameCount {
            for channel in 0..<Int(scheduled.channels) {
                samples[channel][frame] = Float(scheduled.samples[frame * Int(scheduled.channels) + channel]) / 32768
            }
        }
        let time = AVAudioTime(hostTime: MonotonicClock.nanosToTicks(scheduled.renderTimeNanos))
        player.scheduleBuffer(buffer, at: time, options: [], completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in completed(scheduled.token) }
        }
    }

    private func applyLevels() {
        var effective = levels
        effective.incomingVoiceActive = voices.values.contains { $0.scheduler.bufferedCount > 0 }
        mediaMixer.outputVolume = effective.effectiveMediaVolume
        voiceMixer.outputVolume = effective.effectiveVoiceVolume
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in self?.interruption(type: type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let rawReason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in
                guard rawReason != AVAudioSession.RouteChangeReason.categoryChange.rawValue else { return }
                self?.routeChanged()
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let changed = note.object as? AVAudioEngine else { return }
            Task { @MainActor [weak self] in
                guard let self, changed === self.engine, !self.reconfiguring,
                      self.lifecycle.canRender,
                      !self.engine.isRunning || self.formatSignature() != self.outputFormatSignature else { return }
                self.routeChanged()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.mediaServicesReset() }
        })
    }

    private func interruption(type: UInt?, options: UInt) {
        guard let type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        if kind == .began {
            pumpTask?.cancel(); pumpTask = nil
            lifecycle.interrupt(); invalidateOutput(); stopHardware()
        } else if lifecycle.phase == .interrupted, lifecycle.wantsListening,
                  AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
            do { try resumeListeningAfterResync() } catch { onError?(error) }
        }
    }

    private func routeChanged() {
        guard !reconfiguring else { return }
        lifecycle.routeChanged()
        invalidateOutput()
        stopHardware()
        guard lifecycle.canRender else { return }
        do { try configureEngine(transmitting: false); onNeedsResynchronization?(lifecycle.generation) }
        catch { onError?(error) }
    }

    private func mediaServicesReset() {
        lifecycle.routeChanged()
        invalidateOutput(); stopHardware()
        engine = AVAudioEngine()
        mediaMixer = AVAudioMixerNode(); voiceMixer = AVAudioMixerNode()
        buildGraph()
        guard lifecycle.canRender else { return }
        do { try configureEngine(transmitting: false); onNeedsResynchronization?(lifecycle.generation) }
        catch { onError?(error) }
    }

    private func formatSignature() -> String {
        let format = engine.outputNode.outputFormat(forBus: 0)
        return "\(format.sampleRate)/\(format.channelCount)"
    }
    private static func format(channels: UInt32) -> AVAudioFormat {
        // These are fixed, validated application formats, not assumptions about hardware.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: false)!
    }

    deinit {
        pumpTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        microphone?.cancel()
        if inputTapInstalled { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
    }
}

/// Copies a bounded number of tap buffers; resampling and packetization happen
/// off the render thread. A canceled converter never delivers another chunk.
private final class MicrophonePCMConverter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "in.werai.ios.microphone-conversion", qos: .userInteractive)
    private let lock = NSLock()
    private var canceled = false
    private var queued = 0
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let handler: @Sendable (VoicePCMChunk) -> Void
    private var pending: [Int16] = []
    private var pendingTime: UInt64?
    private var nextFrame: UInt64 = 0
    private var lastInputEnd: UInt64?

    init(inputFormat: AVAudioFormat, handler: @escaping @Sendable (VoicePCMChunk) -> Void) throws {
        guard inputFormat.sampleRate.isFinite, (8_000...192_000).contains(inputFormat.sampleRate),
              inputFormat.channelCount > 0, inputFormat.channelCount <= 8,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { throw AppleMediaError.unavailableInput }
        outputFormat = output; self.converter = converter; self.handler = handler
    }

    func cancel() { lock.lock(); canceled = true; lock.unlock() }

    func accept(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock()
        guard !canceled, queued < 4, buffer.frameLength > 0, buffer.frameLength <= 4096 else { lock.unlock(); return }
        queued += 1
        lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { releaseSlot(); return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { releaseSlot(); return }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else { releaseSlot(); return }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        let capture = time.isHostTimeValid ? MonotonicClock.ticksToNanos(time.hostTime) : MonotonicClock.nowNanos()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.releaseSlot() }
            self.lock.lock(); let alive = !self.canceled; self.lock.unlock()
            guard alive else { return }
            self.convert(copy, capturedAt: capture)
        }
    }

    private func convert(_ input: AVAudioPCMBuffer, capturedAt capture: UInt64) {
        if let end = lastInputEnd, capture > end, capture - end > 20_000_000 {
            pending.removeAll(keepingCapacity: true); pendingTime = nil; converter.reset()
        }
        lastInputEnd = capture + UInt64(Double(input.frameLength) / input.format.sampleRate * 1_000_000_000)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48_000 / input.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return input
        }
        guard error == nil, status != .error, let samples = output.floatChannelData?.pointee else { return }
        if pending.isEmpty { pendingTime = capture }
        for index in 0..<Int(output.frameLength) {
            let value = samples[index].isFinite ? min(32767, max(-32768, samples[index] * 32768)) : 0
            pending.append(Int16(value))
        }
        while pending.count >= VoicePCMChunk.framesPerChunk {
            guard let start = pendingTime,
                  let chunk = try? VoicePCMChunk(frameIndex: nextFrame, captureTimeNanos: start,
                                                samples: Array(pending.prefix(VoicePCMChunk.framesPerChunk))) else { return }
            pending.removeFirst(VoicePCMChunk.framesPerChunk)
            pendingTime = pending.isEmpty ? nil : start + 10_000_000
            guard nextFrame <= UInt64.max - UInt64(VoicePCMChunk.framesPerChunk) else { cancel(); return }
            nextFrame += UInt64(VoicePCMChunk.framesPerChunk)
            lock.lock(); let alive = !canceled; lock.unlock()
            guard alive else { return }
            handler(chunk)
        }
    }

    private func releaseSlot() { lock.lock(); queued -= 1; lock.unlock() }
}
#endif
