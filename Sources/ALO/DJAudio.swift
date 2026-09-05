import AVFoundation
import Combine
import CoreAudio
import ALOCore
import ALOSharedAudioClient

/// Equal-power fades keep independent decks balanced through the center.
enum DJMixMath {
    static func gains(crossfade: Double) -> (Float, Float) {
        let x = min(1, max(0, crossfade.isFinite ? crossfade : 0.5))
        return (Float(cos(x * .pi / 2)), Float(sin(x * .pi / 2)))
    }
    static func syncRate(sourceBPM: Double, targetBPM: Double, targetRate: Float) -> Float? {
        guard sourceBPM.isFinite, targetBPM.isFinite, sourceBPM > 0, targetBPM > 0 else { return nil }
        let rate = Float(targetBPM / sourceBPM) * targetRate
        return (0.75...1.25).contains(rate) ? rate : nil
    }
}

/// Reject oversized PCM before narrowing frame counts or allocating audio storage.
enum DJPCMStorage {
    static let maximumBufferBytes = 16 * 1024 * 1024
    static func fits(frames: Int64, channels: UInt32, bytesPerSample: Int = MemoryLayout<Float>.size,
                     limit: Int = maximumBufferBytes) -> Bool {
        guard frames > 0, frames <= Int64(UInt32.max), channels > 0,
              bytesPerSample > 0, limit > 0 else { return false }
        let stride = Int64(channels).multipliedReportingOverflow(by: Int64(bytesPerSample))
        guard !stride.overflow else { return false }
        let bytes = frames.multipliedReportingOverflow(by: stride.partialValue)
        return !bytes.overflow && bytes.partialValue <= Int64(limit)
    }
}

@MainActor
final class DJDeck: ObservableObject {
    @Published private(set) var title = "Load a song"
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var cue: Double = 0
    @Published var loops = false
    @Published private(set) var loopStart: Double?
    @Published private(set) var loopEnd: Double?
    @Published private(set) var loopEnabled = false
    @Published private(set) var loopBeats = 4
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var waveformLoading = false
    private var loopBuffer: AVAudioPCMBuffer?
    private var scheduledLoopStart: AVAudioFramePosition?
    private var scheduledLoopLength: AVAudioFramePosition = 0
    private var waveformTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    @Published var bpm: Double = 120
    @Published var gain: Float = 0.8
    @Published var rate: Float = 1 { didSet { pitch.rate = rate } }
    @Published var low: Float = 0 { didSet { eq.bands[0].gain = low } }
    @Published var mid: Float = 0 { didSet { eq.bands[1].gain = mid } }
    @Published var high: Float = 0 { didSet { eq.bands[2].gain = high } }
    let player = AVAudioPlayerNode()
    let pitch = AVAudioUnitTimePitch()
    let eq = AVAudioUnitEQ(numberOfBands: 3)
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var generation = UUID()
    private weak var engine: AVAudioEngine?
    private weak var mixer: AVAudioMixerNode?

    init(engine: AVAudioEngine, mixer: AVAudioMixerNode) {
        self.engine = engine; self.mixer = mixer
        [player, pitch, eq].forEach { engine.attach($0) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: eq, format: format)
        engine.connect(eq, to: mixer, format: format)
        for (index, frequency) in [100.0, 1_000.0, 10_000.0].enumerated() {
            eq.bands[index].filterType = index == 0 ? .lowShelf : index == 2 ? .highShelf : .parametric
            eq.bands[index].frequency = Float(frequency)
            eq.bands[index].bandwidth = 1
            eq.bands[index].bypass = false
        }
    }

    func load(_ url: URL) throws {
        let next = try AVAudioFile(forReading: url)
        guard next.length > 0, next.processingFormat.channelCount <= 2,
              next.length <= Int64(UInt32.max) else {
            throw ALOError("Choose a non-empty mono or stereo audio file shorter than 24 hours.")
        }
        stop()
        guard let engine, let mixer else { return }
        // Reconnect only this deck. AVAudioEngine converts at the mixer input.
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(pitch)
        engine.disconnectNodeOutput(eq)
        engine.connect(player, to: pitch, format: next.processingFormat)
        engine.connect(pitch, to: eq, format: next.processingFormat)
        engine.connect(eq, to: mixer, format: next.processingFormat)
        file = next
        title = url.deletingPathExtension().lastPathComponent
        duration = Double(next.length) / next.processingFormat.sampleRate
        cue = 0; position = 0; rate = 1; loops = false
        loopStart = nil; loopEnd = nil; loopBuffer = nil
        suspendWaveformAnalysis()
        waveform = []
        resumeWaveformAnalysis()
    }

    func suspendWaveformAnalysis() {
        waveformTask?.cancel(); waveformTask = nil
        loadGeneration = UUID(); waveformLoading = false
    }

    func resumeWaveformAnalysis() {
        guard let file, waveform.isEmpty, !waveformLoading else { return }
        loadGeneration = UUID()
        let token = loadGeneration, url = file.url
        waveformLoading = true
        waveformTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { (try? DJWaveform.peaks(url: url)) ?? [] }
            let peaks = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, self.loadGeneration == token else { return }
            self.waveform = peaks; self.waveformLoading = false
        }
    }

    deinit { waveformTask?.cancel() }

    func toggle() throws {
        guard file != nil else { return }
        if isPlaying { tick(); pause() }
        else { try play(from: position >= duration ? 0 : position) }
    }

    func seek(_ seconds: Double) throws {
        guard seconds.isFinite else { return }
        let target = min(duration, max(0, seconds))
        if loopEnabled, let start = loopStart, let end = loopEnd, target < start || target >= end {
            loopEnabled = false
        }
        if isPlaying { try play(from: target) } else { position = target }
    }

    func setCue() { tick(); cue = position }
    func returnToCue() throws { try seek(cue) }
    func stop() { pause(); position = 0; loopEnabled = false; loopBuffer = nil }
    private func pause() {
        generation = UUID(); player.stop(); isPlaying = false
        scheduledLoopStart = nil; scheduledLoopLength = 0
    }

    func setLoopBeats(_ beats: Int) throws {
        guard [1, 2, 4, 8, 16].contains(beats) else { throw ALOError("Choose 1, 2, 4, 8, or 16 beats.") }
        if loopEnabled, let start = loopStart {
            try activateLoop(start: start, end: start + beatDuration(beats))
        }
        loopBeats = beats
    }

    private func beatDuration(_ beats: Int) throws -> Double {
        guard bpm.isFinite, bpm > 0 else { throw ALOError("Enter a positive BPM before setting a beat loop.") }
        let seconds = Double(beats) * 60 / bpm
        guard seconds.isFinite, seconds <= 32 else { throw ALOError("Loops can be up to 32 seconds. Increase BPM or choose fewer beats.") }
        return seconds
    }

    func toggleBeatLoop() throws {
        tick()
        if loopEnabled { try exitLoop(); return }
        try activateLoop(start: position, end: position + beatDuration(loopBeats))
    }

    func setLoopIn() throws {
        tick()
        let start = position
        try exitLoop()
        loopStart = start; loopEnd = nil; loopBuffer = nil
    }

    func setLoopOut() throws {
        tick()
        guard let start = loopStart else { throw ALOError("Set Loop In first.") }
        try activateLoop(start: start, end: position)
    }

    func clearLoop() throws {
        try exitLoop()
        loopStart = nil; loopEnd = nil; loopBuffer = nil
    }

    private func exitLoop() throws {
        guard loopEnabled else { return }
        tick(); loopEnabled = false
        if isPlaying { try play(from: position) }
    }

    private func activateLoop(start: Double, end: Double) throws {
        guard let file else { throw ALOError("Load a song before setting a loop.") }
        guard start.isFinite, end.isFinite, start >= 0, end <= duration,
              end - start >= 0.02, end - start <= 32 else {
            throw ALOError("Place Loop Out after Loop In, within the song. Loops must be 0.02–32 seconds long.")
        }
        let sampleRate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(start * sampleRate)
        let last = min(file.length, AVAudioFramePosition(end * sampleRate))
        guard last > first, DJPCMStorage.fits(frames: last - first, channels: file.processingFormat.channelCount) else {
            throw ALOError("This loop needs more than 16 MiB of audio memory. Choose a shorter region for this high-resolution file.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(last - first)) else {
            throw ALOError("This loop could not be prepared.")
        }
        // A separate reader never moves the streaming deck's file cursor.
        let reader = try AVAudioFile(forReading: file.url)
        reader.framePosition = first
        try reader.read(into: buffer, frameCount: buffer.frameCapacity)
        guard buffer.frameLength == buffer.frameCapacity else { throw ALOError("Could not read the complete loop.") }
        tick()
        let wasPlaying = isPlaying
        loopBuffer = buffer
        loopStart = Double(first) / sampleRate
        loopEnd = Double(last) / sampleRate
        loopEnabled = true; loops = false
        position = min(max(position, loopStart!), loopEnd!)
        if position >= loopEnd! { position = loopStart! }
        if wasPlaying { try play(from: position) }
    }

    private func play(from seconds: Double) throws {
        guard let file, let engine else { return }
        pause()
        startFrame = min(file.length, max(0, Int64(seconds * file.processingFormat.sampleRate)))
        position = Double(startFrame) / file.processingFormat.sampleRate
        guard startFrame < file.length else { return }
        if !engine.isRunning { try engine.start() }
        if loopEnabled, let buffer = loopBuffer, let loopStart {
            let first = AVAudioFramePosition(loopStart * file.processingFormat.sampleRate)
            let last = first + AVAudioFramePosition(buffer.frameLength)
            if startFrame < first || startFrame >= last { startFrame = first }
            position = Double(startFrame) / file.processingFormat.sampleRate
            scheduledLoopStart = first; scheduledLoopLength = last - first
            let offset = AVAudioFrameCount(startFrame - first)
            if offset > 0 {
                // Stream the remaining region instead of allocating a second PCM copy.
                // Both schedules share the player queue, so the full loop follows
                // sample-contiguously without waiting for a main-thread callback.
                player.scheduleSegment(file, startingFrame: startFrame,
                                       frameCount: buffer.frameLength - offset, at: nil)
            }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play(); isPlaying = true
            return
        }
        let token = generation
        player.scheduleSegment(file, startingFrame: startFrame,
                               frameCount: AVAudioFrameCount(file.length - startFrame), at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.isPlaying = false; self.position = self.duration
                if self.loops {
                    do { try self.play(from: 0) }
                    catch { self.stop() }
                }
            }
        }
        player.play(); isPlaying = true
    }

    func tick() {
        guard isPlaying, let file, let render = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: render) else { return }
        let elapsedFrames = AVAudioFramePosition(Double(time.sampleTime) * file.processingFormat.sampleRate / time.sampleRate)
        if let first = scheduledLoopStart, scheduledLoopLength > 0 {
            position = Double(first + (startFrame - first + max(0, elapsedFrames)) % scheduledLoopLength) / file.processingFormat.sampleRate
        } else {
            position = min(duration, Double(startFrame + max(0, elapsedFrames)) / file.processingFormat.sampleRate)
        }
    }
}

/// Scan sequentially using one small buffer so quiet gaps and late transients are
/// represented accurately without loading the song into memory or seeking per bin.
enum DJWaveform {
    static func peaks(url: URL, count: Int = 256) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, count > 0 else { return [] }
        let bins = min(256, count, Int(file.length))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var peaks = [Float](repeating: 0, count: bins)
        for index in 0..<bins {
            let last = file.length * Int64(index + 1) / Int64(bins)
            while file.framePosition < last {
                if Task.isCancelled { return [] }
                let frames = AVAudioFrameCount(min(4096, last - file.framePosition))
                try file.read(into: buffer, frameCount: frames)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                    throw ALOError("The waveform could not read this audio file.")
                }
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) {
                        let value = channels[channel][frame]
                        if value.isFinite { peaks[index] = max(peaks[index], min(1, abs(value))) }
                    }
                }
            }
        }
        return peaks
    }
}

/// A single subscription owns DJ broadcast output. Revocation precedes graph teardown.
final class DJAudioRelay: @unchecked Sendable {
    private let levelLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "in.werai.audio.dj-relay", qos: .userInteractive)
    private let ring: ALOTapAudioRingHandle?
    private var timer: DispatchSourceTimer?
    private var nextRingFrame: UInt64 = 0
    private var owner: UUID?
    private var handler: AudioSource.AudioHandler?
    private var peak: Float = 0
    private var liveOverlay = false

    init(automaticDrain: Bool = true) {
        ring = ALOTapAudioRingCreate()
        guard automaticDrain else { return }
        let timer = DispatchSource.makeTimerSource(queue: deliveryQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer
        timer.resume()
    }
    deinit {
        timer?.cancel()
        if let ring { ALOTapAudioRingDestroy(ring) }
    }
    func setLiveOverlay(_ enabled: Bool) {
        deliveryQueue.sync { liveOverlay = enabled }
    }
    func install(owner: UUID, handler: @escaping AudioSource.AudioHandler) throws {
        try deliveryQueue.sync {
            guard self.owner == nil else { throw ALOError("The DJ mix is already being shared.") }
            if let ring { nextRingFrame = ALOTapAudioRingLatestFrame(ring) }
            self.owner = owner; self.handler = handler
        }
    }
    @discardableResult func remove(owner: UUID) -> Bool {
        deliveryQueue.sync {
            guard self.owner == owner else { return false }
            self.owner = nil; handler = nil
            if let ring { nextRingFrame = ALOTapAudioRingLatestFrame(ring) }
            return true
        }
    }
    var level: Float { levelLock.withLock { peak } }

    /// Runs on AVAudioEngine's render callback. Keep this path allocation-free,
    /// lock-free, and isolated from packetization and network fan-out.
    func consume(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let ring, buffer.format.channelCount == 2,
              buffer.frameLength > 0, let channels = buffer.floatChannelData else { return }
        ALOTapAudioRingMarkCallback(ring)
        ALOTapAudioRingWritePlanarFloat(
            ring, channels[0], channels[1], UInt32(buffer.frameLength),
            time.isHostTimeValid ? time.hostTime : AudioGetCurrentHostTime(),
            AudioGetHostClockFrequency() / buffer.format.sampleRate
        )
    }

    private func drain() {
        guard let ring else { return }
        let latest = ALOTapAudioRingLatestFrame(ring)
        let capacity = ALOTapAudioRingCapacity()
        if latest > nextRingFrame &+ capacity { nextRingFrame = latest - capacity }
        guard latest > nextRingFrame else { return }
        let frameLimit = UInt32(min(latest - nextRingFrame, 960))
        var floats = [Float](repeating: 0, count: Int(frameLimit) * 2)
        var firstHostTime: UInt64 = 0
        let count = floats.withUnsafeMutableBufferPointer {
            ALOTapAudioRingRead(ring, nextRingFrame, $0.baseAddress, frameLimit, &firstHostTime)
        }
        guard count > 0 else {
            nextRingFrame = latest > capacity ? latest - capacity : latest
            return
        }
        nextRingFrame &+= UInt64(count)
        if count < frameLimit { floats.removeLast(Int(frameLimit - count) * 2) }
        var maximum: Float = 0
        var samples = [Int16](repeating: 0, count: floats.count)
        for index in floats.indices {
            let value = floats[index].isFinite ? floats[index] : 0
            maximum = max(maximum, abs(value))
            samples[index] = Int16(max(-1, min(1, value)) * Float(Int16.max))
        }
        levelLock.withLock { peak = maximum }
        if liveOverlay { DJLiveAudio.shared.offerOverlay(samples) }
        guard owner != nil else { return }
        let stamp = firstHostTime == 0
            ? MonotonicClock.nowNanos()
            : MonotonicClock.ticksToNanos(firstHostTime)
        handler?(samples, stamp)
    }

    func flushForTesting() { deliveryQueue.sync { drain() } }
}

@MainActor
final class DJStudio: ObservableObject {
    private static var instance: DJStudio?
    static var shared: DJStudio {
        if let instance { return instance }
        let studio = DJStudio()
        instance = studio
        return studio
    }
    static func stopIfCreated() { instance?.setLiveStage(nil); instance?.stopAll() }
    static func endLiveIfCreated() { instance?.setLiveStage(nil) }
    static var isSharingIfCreated: Bool { instance?.sharing ?? false }
    let engine = AVAudioEngine()
    let mixer = AVAudioMixerNode()
    let relay = DJAudioRelay()
    let a: DJDeck
    let b: DJDeck
    @Published var crossfade: Double = 0.5 { didSet { updateGains() } }
    @Published var master: Float = 0.75 { didSet { mixer.outputVolume = master; updateLiveMix() } }
    @Published private(set) var liveSnapshot = DJLiveAudio.shared.snapshot()
    @Published var liveLoopBeats = 4
    var liveEnabled: Bool { liveSnapshot.stage != nil }
    @Published var padGain: Float = 0.65
    @Published private(set) var level: Float = 0
    @Published private(set) var sharing = false
    @Published var error: String?
    @Published private(set) var activePads: Set<Int> = []
    static let defaultPadNames = ["Kick", "Snare", "Clap", "Closed hat", "Open hat", "Low tom", "High tom", "Rim", "Sub", "Bass", "Chord", "Pluck", "Bell", "Rise", "Noise", "Impact"]
    @Published private(set) var padNames = DJStudio.defaultPadNames
    private var pads: [AVAudioPlayerNode] = []
    private var buffers: [AVAudioPCMBuffer] = []
    private var padTokens = [UUID](repeating: UUID(), count: 16)
    private var timer: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var sharingFailure: (@Sendable (Error) -> Void)?
    private var gainSubscriptions: Set<AnyCancellable> = []

    init() {
        engine.attach(mixer)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        a = DJDeck(engine: engine, mixer: mixer); b = DJDeck(engine: engine, mixer: mixer)
        for index in 0..<16 {
            let player = AVAudioPlayerNode()
            engine.attach(player); engine.connect(player, to: mixer, format: format)
            pads.append(player); buffers.append(Self.makePad(index, format: format))
        }
        let relay = relay
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in relay.consume(buffer, time: time) }
        mixer.outputVolume = master
        a.$gain.combineLatest(b.$gain).sink { [weak self] left, right in
            guard let self else { return }
            let (x, y) = DJMixMath.gains(crossfade: self.crossfade)
            self.a.player.volume = left * x; self.b.player.volume = right * y
            if self.liveEnabled { DJLiveAudio.shared.setMix(gain: left * x * self.master, low: self.a.low, mid: self.a.mid, high: self.a.high) }
        }.store(in: &gainSubscriptions)
        a.$low.combineLatest(a.$mid, a.$high).sink { [weak self] low, mid, high in
            guard let self, self.liveEnabled else { return }
            DJLiveAudio.shared.setMix(gain: self.a.gain * DJMixMath.gains(crossfade: self.crossfade).0 * self.master, low: low, mid: mid, high: high)
        }.store(in: &gainSubscriptions)
        updateGains()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.audioConfigurationChanged() }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        timer?.invalidate()
    }

    private func audioConfigurationChanged() {
        let hadPlayback = a.isPlaying || b.isPlaying || !activePads.isEmpty
        stopAll()
        if sharing {
            do { if !engine.isRunning { try engine.start() } }
            catch {
                self.error = "The audio output changed and the DJ mix could not restart: \(error.localizedDescription)"
                sharingFailure?(error)
                return
            }
        }
        if hadPlayback { error = "The audio output changed. Playback stopped; press Play or trigger a pad to continue on the new output." }
    }

    func startUpdates() {
        a.resumeWaveformAnalysis(); b.resumeWaveformAnalysis()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.a.tick(); self.b.tick()
                self.refreshLive()
                let nextLevel = self.liveEnabled
                    ? ((self.liveSnapshot.secondsSinceInput ?? 2) < 1 ? self.liveSnapshot.outputPeak : 0)
                    : (self.engine.isRunning ? self.relay.level : 0)
                if self.level != nextLevel { self.level = nextLevel }
            }
        }
    }
    func stopUpdates() {
        a.suspendWaveformAnalysis(); b.suspendWaveformAnalysis()
        timer?.invalidate(); timer = nil
        if !sharing { engine.stop() }
    }
    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }
    func updateGains() {
        let (left, right) = DJMixMath.gains(crossfade: crossfade)
        a.player.volume = a.gain * left; b.player.volume = b.gain * right
        updateLiveMix()
    }
    func updateLiveMix() {
        guard liveEnabled else { return }
        DJLiveAudio.shared.setMix(gain: a.gain * DJMixMath.gains(crossfade: crossfade).0 * master, low: a.low, mid: a.mid, high: a.high)
    }
    func refreshLive() {
        let snapshot = DJLiveAudio.shared.snapshot()
        if liveEnabled || snapshot.stage != nil { liveSnapshot = snapshot }
    }
    func setLiveStage(_ stage: DJLiveStage?) {
        guard stage != liveSnapshot.stage else { return }
        if stage != nil && sharing { error = "Stop sharing the file mix before selecting a live input."; return }
        relay.setLiveOverlay(false)
        stopAll()
        if stage != nil {
            // Opening the live setup starts at unity with neutral EQ, so the
            // existing broadcast sounds unchanged until the user moves a control.
            crossfade = 0; master = 1; a.gain = 1
            a.low = 0; a.mid = 0; a.high = 0
        }
        DJLiveAudio.shared.configure(stage: stage)
        liveSnapshot = DJLiveAudio.shared.snapshot()
        engine.mainMixerNode.outputVolume = stage != nil || sharing ? 0 : 1
        relay.setLiveOverlay(stage != nil)
        updateLiveMix()
    }
    func toggleLivePlayback() {
        DJLiveAudio.shared.setMuted(!liveSnapshot.muted); refreshLive()
    }
    func toggleLiveLoop() throws {
        try DJLiveAudio.shared.toggleLoop(beats: liveLoopBeats, bpm: a.bpm); refreshLive()
    }
    func sync(_ deck: DJDeck, to other: DJDeck) {
        guard let rate = DJMixMath.syncRate(sourceBPM: deck.bpm, targetBPM: other.bpm, targetRate: other.rate) else {
            error = "Enter both song BPMs. Tempo matching must stay within ±25%."; return
        }
        deck.rate = rate
    }
    func trigger(_ index: Int) {
        guard pads.indices.contains(index) else { return }
        perform {
            if !engine.isRunning { try engine.start() }
            let player = pads[index], token = UUID()
            padTokens[index] = token; player.stop(); player.volume = padGain
            activePads.insert(index)
            player.scheduleBuffer(buffers[index], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.padTokens[index] == token else { return }
                    self.activePads.remove(index)
                }
            }
            player.play()
        }
    }
    func restorePad(_ index: Int) {
        guard pads.indices.contains(index) else { return }
        pads[index].stop(); padTokens[index] = UUID(); activePads.remove(index)
        buffers[index] = Self.makePad(index, format: buffers[index].format)
        padNames[index] = Self.defaultPadNames[index]
    }
    func loadPad(_ index: Int, url: URL) throws {
        guard pads.indices.contains(index) else { return }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, Double(file.length) / file.processingFormat.sampleRate <= 10,
              file.processingFormat.channelCount <= 2 else {
            throw ALOError("Choose a mono or stereo sample up to 10 seconds long.")
        }
        guard DJPCMStorage.fits(frames: file.length, channels: file.processingFormat.channelCount) else {
            throw ALOError("This high-resolution sample needs more than 16 MiB to decode. Choose a shorter sample or export it at 48 kHz.")
        }
        let format = buffers[index].format
        let outputFrames = Int64(ceil(Double(file.length) * 48_000 / file.processingFormat.sampleRate)) + 512
        guard outputFrames <= 480_512, DJPCMStorage.fits(frames: outputFrames, channels: 2) else {
            throw ALOError("Choose a sample no longer than 10 seconds.")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outputFrames)) else {
            throw ALOError("This sample format could not be converted.")
        }
        try file.read(into: input)
        let inputProvider = DJConversionInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            inputProvider.next(state)
        }
        if let conversionError { throw conversionError }
        guard status != .error, output.frameLength > 0 else { throw ALOError("This sample contains no playable audio.") }
        pads[index].stop(); padTokens[index] = UUID(); activePads.remove(index)
        buffers[index] = output; padNames[index] = url.deletingPathExtension().lastPathComponent
    }
    func stopAll() {
        if liveEnabled {
            DJLiveAudio.shared.setMuted(true)
            try? DJLiveAudio.shared.clearLoop()
            DJLiveAudio.shared.clearOverlay()
            refreshLive()
        }
        a.stop(); b.stop()
        for index in pads.indices { padTokens[index] = UUID(); pads[index].stop() }
        activePads.removeAll(); level = 0
        if !sharing { engine.pause() }
    }
    func beginSharing(owner: UUID, handler: @escaping AudioSource.AudioHandler, failure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        setLiveStage(nil)
        try relay.install(owner: owner, handler: handler)
        sharingFailure = failure
        // The room renderer supplies the synchronized local copy; avoid doubling it.
        engine.mainMixerNode.outputVolume = 0
        do { if !engine.isRunning { try engine.start() }; sharing = true }
        catch { relay.remove(owner: owner); sharingFailure = nil; engine.mainMixerNode.outputVolume = 1; throw error }
    }
    func endSharing(owner: UUID) {
        guard relay.remove(owner: owner) else { return }
        sharingFailure = nil
        sharing = false; stopAll(); engine.mainMixerNode.outputVolume = 1
        if timer == nil { engine.stop() }
    }

    static func makePad(_ index: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let duration = index == 13 ? 1.2 : index == 4 ? 0.5 : 0.32
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48_000))!
        buffer.frameLength = buffer.frameCapacity
        var seed = UInt32(index + 1)
        for frame in 0..<Int(buffer.frameLength) {
            let t = Double(frame) / 48_000, fade = pow(max(0, 1 - t / duration), 3)
            seed = 1664525 &* seed &+ 1013904223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            let frequency = [55.0, 180, 800, 7000, 6000, 120, 210, 950, 45, 110, 220, 440, 880, 400, 1000, 65][index]
            let phase = 2 * Double.pi * (frequency * t + (index == 0 || index == 15 ? 12 * (1 - exp(-t * 40)) : 0))
            var wave = sin(phase)
            if [1, 2, 3, 4, 14, 15].contains(index) { wave = noise * 0.7 + wave * 0.3 }
            if index == 10 { wave = (wave + sin(phase * 1.25) + sin(phase * 1.5)) / 3 }
            if index == 13 { wave = sin(2 * .pi * (200 * t + 700 * t * t)) * min(1, t * 4) }
            let value = Float(wave * fade * min(1, t * 1000) * 0.6)
            for channel in 0..<2 { buffer.floatChannelData![channel][frame] = value }
        }
        return buffer
    }
}

final class DJMixAudioSource: AudioSource {
    private let owner = UUID()
    private let unexpectedStopHandler: @Sendable (Error) -> Void
    init(unexpectedStopHandler: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.unexpectedStopHandler = unexpectedStopHandler
    }
    func start(audioHandler: @escaping AudioHandler) async throws {
        try await MainActor.run { try DJStudio.shared.beginSharing(owner: owner, handler: audioHandler, failure: unexpectedStopHandler) }
    }
    func stop() async throws {
        await MainActor.run { DJStudio.shared.endSharing(owner: owner) }
    }
}

/// AVAudioConverter pulls this buffer synchronously; the lock also makes ownership explicit.
private final class DJConversionInput: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
    }
}
