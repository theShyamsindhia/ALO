import Foundation

/// Which audio boundary owns the effect. Exactly one boundary processes a frame.
enum DJLiveStage: Sendable, Equatable { case broadcast, listening }

struct DJLiveSnapshot: Sendable {
    let stage: DJLiveStage?
    let historyDuration: Double
    let delaySeconds: Double
    let looping: Bool
    let loopDuration: Double
    let hasLoopIn: Bool
    let waveform: [Float]
    let inputPeak: Float
    let outputPeak: Float
    let muted: Bool
    let hasCue: Bool
    let gain: Float
    let low: Float
    let mid: Float
    let high: Float
    let bufferedPCMBytes: Int
    let secondsSinceInput: Double?
    let recording: Bool
    let recordingDuration: Double
    let recordingReady: Bool
}

/// All PCM is stereo, interleaved, 48 kHz. The caller retains capture timestamps.
/// History, loop, and an armed recording each occupy at most 6,144,000 bytes;
/// overlay is 19,200 bytes. Recordings contain accepted dry broadcast input only.
final class DJLiveAudio: @unchecked Sendable {
    static let shared = DJLiveAudio()
    static let sampleRate = 48_000
    static let maximumFrames = sampleRate * 32
    static let overlayFrames = sampleRate / 10
    private static let summaryFrames = 256
    private let lock = NSLock()
    private var stage: DJLiveStage?
    private var history: [Int16] = []
    private var written: Int64 = 0
    private var lastCaptureTimeNanos: UInt64?
    private var lastInputUptime: UInt64?
    private var peaks: [Float] = []
    private var peakIDs: [Int64] = []
    private var inputPeak: Float = 0
    private var outputPeak: Float = 0
    private var delayFrames = 0
    private var loop: [Int16] = []
    private var loopOffset = 0
    private var loopIn: Int64?
    private var cue: Int64?
    private var overlay: [Int16] = []
    private var overlayRead = 0
    private var overlayCount = 0
    private var lastOverlayUptime: UInt64?
    private var muted = false
    private var gain: Float = 1
    private var low: Float = 0
    private var mid: Float = 0
    private var high: Float = 0
    private var filters = [DJLiveBiquad](repeating: .init(), count: 6)
    private var neutralEQ = true
    private var recordingStorage: [Int16] = []
    private var recordedSamples = 0
    private var recording = false

    func configure(stage next: DJLiveStage?) {
        lock.withLock {
            guard stage != next else { return }
            stage = next
            written = 0; delayFrames = 0; inputPeak = 0; outputPeak = 0
            lastCaptureTimeNanos = nil; lastInputUptime = nil
            loop = []; loopOffset = 0; loopIn = nil; cue = nil
            recordingStorage = []; recordedSamples = 0; recording = false
            overlayRead = 0; overlayCount = 0; lastOverlayUptime = nil
            muted = false; gain = 1; low = 0; mid = 0; high = 0
            filters = [DJLiveBiquad](repeating: .init(), count: 6); neutralEQ = true
            history = next == nil ? [] : [Int16](repeating: 0, count: Self.maximumFrames * 2)
            overlay = next == nil ? [] : [Int16](repeating: 0, count: Self.overlayFrames * 2)
            peaks = next == nil ? [] : [Float](repeating: 0, count: Self.maximumFrames / Self.summaryFrames)
            peakIDs = next == nil ? [] : [Int64](repeating: -1, count: Self.maximumFrames / Self.summaryFrames)
        }
    }

    func setMix(gain: Float, low: Float, mid: Float, high: Float) {
        lock.withLock {
            self.gain = Self.clamp(gain, 0...2, fallback: 1)
            let nextLow = Self.clamp(low, -24...12), nextMid = Self.clamp(mid, -24...12), nextHigh = Self.clamp(high, -24...12)
            guard self.low != nextLow || self.mid != nextMid || self.high != nextHigh else { return }
            self.low = nextLow; self.mid = nextMid; self.high = nextHigh
            neutralEQ = nextLow == 0 && nextMid == 0 && nextHigh == 0
            let coefficients = [DJLiveBiquad.shelf(frequency: 100, gain: nextLow, high: false),
                                DJLiveBiquad.peak(frequency: 1_000, gain: nextMid),
                                DJLiveBiquad.shelf(frequency: 10_000, gain: nextHigh, high: true)]
            for channel in 0..<2 {
                for band in 0..<3 { filters[channel * 3 + band].update(coefficients[band]) }
            }
        }
    }

    func setMuted(_ muted: Bool) { lock.withLock { self.muted = muted } }

    /// Allocate once on the control thread, never grow storage in the audio callback.
    func startRecording() throws {
        try lock.withLock {
            try requireActive()
            guard recordingStorage.isEmpty else {
                throw ALOError("Finish or cancel the current recording before recording another deck.")
            }
            recordingStorage = [Int16](repeating: 0, count: Self.maximumFrames * 2)
            recordedSamples = 0; recording = true
        }
    }

    /// Stops capture and consumes the take. A full take remains ready until consumed.
    func finishRecording() throws -> [Int16] {
        try lock.withLock {
            guard !recordingStorage.isEmpty else { throw ALOError("There is no recording to finish.") }
            recording = false
            guard recordedSamples > 0 else {
                recordingStorage = []; recordedSamples = 0
                throw ALOError("No broadcast audio was received. Let the music play, then record again.")
            }
            let take = recordedSamples == recordingStorage.count
                ? recordingStorage : Array(recordingStorage.prefix(recordedSamples))
            recordingStorage = []; recordedSamples = 0
            return take
        }
    }

    func cancelRecording() {
        lock.withLock { recording = false; recordingStorage = []; recordedSamples = 0 }
    }

    func process(_ samples: [Int16], stage requested: DJLiveStage, captureTimeNanos: UInt64? = nil) -> [Int16] {
        lock.withLock {
            guard stage == requested, !history.isEmpty, samples.count.isMultiple(of: 2), !samples.isEmpty else { return samples }
            if let captureTimeNanos {
                // Late predecessors and repeated deliveries must not rewind DSP state.
                if let previous = lastCaptureTimeNanos, captureTimeNanos <= previous {
                    // Preserve mute/gain even if a transport admits an old packet.
                    // Do not consume overlay or advance any time-dependent effect.
                    if muted { return [Int16](repeating: 0, count: samples.count) }
                    if gain == 1 { return samples }
                    return samples.map { Int16(min(32767, max(-32768, Float($0) * gain))) }
                }
                lastCaptureTimeNanos = captureTimeNanos
            }
            if recording {
                let count = min(samples.count, recordingStorage.count - recordedSamples)
                recordingStorage.withUnsafeMutableBufferPointer { destination in
                    samples.withUnsafeBufferPointer { source in
                        destination.baseAddress!.advanced(by: recordedSamples).update(from: source.baseAddress!, count: count)
                    }
                }
                recordedSamples += count
                if recordedSamples == recordingStorage.count { recording = false }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            lastInputUptime = now
            if let lastOverlayUptime, now - lastOverlayUptime > 100_000_000 {
                overlayRead = 0; overlayCount = 0; self.lastOverlayUptime = nil
            }
            var output = [Int16](repeating: 0, count: samples.count)
            var maximum: Float = 0
            var renderedMaximum: Float = 0
            for frame in 0..<(samples.count / 2) {
                let sourcePosition = written - Int64(delayFrames)
                let ring = Int(written % Int64(Self.maximumFrames)) * 2
                let summaryID = written / Int64(Self.summaryFrames)
                let summaryIndex = Int(summaryID % Int64(peaks.count))
                if peakIDs[summaryIndex] != summaryID { peakIDs[summaryIndex] = summaryID; peaks[summaryIndex] = 0 }
                for channel in 0..<2 {
                    let incoming = samples[frame * 2 + channel]
                    let incomingMagnitude = abs(Float(incoming)) / 32768
                    maximum = max(maximum, incomingMagnitude)
                    peaks[summaryIndex] = max(peaks[summaryIndex], incomingMagnitude)
                    let source: Int16
                    if !loop.isEmpty { source = loop[loopOffset + channel] }
                    else if delayFrames == 0 { source = incoming }
                    else if sourcePosition >= max(0, written - Int64(Self.maximumFrames)) {
                        source = history[Int(sourcePosition % Int64(Self.maximumFrames)) * 2 + channel]
                    } else { source = 0 }
                    // Read delayed audio before overwriting the oldest history frame.
                    history[ring + channel] = incoming
                    var value = Float(source) / 32768
                    if !neutralEQ {
                        for band in 0..<3 { value = filters[channel * 3 + band].process(value) }
                    }
                    value = muted ? 0 : value * gain
                    if overlayCount > 0 { value += Float(overlay[overlayRead + channel]) / 32768 }
                    let scaled = value.isFinite ? min(32767, max(-32768, value * 32768)) : 0
                    output[frame * 2 + channel] = Int16(scaled)
                    renderedMaximum = max(renderedMaximum, abs(scaled) / 32768)
                }
                written += 1
                if !loop.isEmpty { loopOffset = (loopOffset + 2) % loop.count }
                if overlayCount > 0 { overlayRead = (overlayRead + 2) % overlay.count; overlayCount -= 1 }
            }
            inputPeak = maximum; outputPeak = renderedMaximum
            return output
        }
    }

    /// FIFO drops oldest excess frames, so an interrupted producer cannot build latency.
    func offerOverlay(_ samples: [Int16]) {
        lock.withLock {
            guard stage != nil, !overlay.isEmpty, samples.count.isMultiple(of: 2) else { return }
            guard !samples.isEmpty else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if let lastOverlayUptime, now - lastOverlayUptime > 100_000_000 {
                overlayRead = 0; overlayCount = 0
            }
            lastOverlayUptime = now
            let incomingFrames = samples.count / 2
            let first = max(0, incomingFrames - Self.overlayFrames)
            for frame in first..<incomingFrames {
                if overlayCount == Self.overlayFrames {
                    overlayRead = (overlayRead + 2) % overlay.count; overlayCount -= 1
                }
                let destination = (overlayRead + overlayCount * 2) % overlay.count
                overlay[destination] = samples[frame * 2]; overlay[destination + 1] = samples[frame * 2 + 1]
                overlayCount += 1
            }
        }
    }

    func clearOverlay() { lock.withLock { overlayRead = 0; overlayCount = 0; lastOverlayUptime = nil } }

    func setDelay(seconds: Double) throws {
        try lock.withLock {
            try requireActive()
            guard seconds.isFinite, seconds >= 0, seconds <= Double(historyFrames) / Double(Self.sampleRate) else {
                throw ALOError("Choose a rewind position inside the available live history (up to 32 seconds).")
            }
            delayFrames = min(historyFrames, Int((seconds * Double(Self.sampleRate)).rounded()))
            loop = []; loopOffset = 0
        }
    }

    func toggleLoop(beats: Int, bpm: Double) throws {
        try lock.withLock {
            try requireActive()
            if !loop.isEmpty { loop = []; loopOffset = 0; return }
            guard [1, 2, 4, 8, 16].contains(beats), bpm.isFinite, bpm > 0 else {
                throw ALOError("Choose 1, 2, 4, 8, or 16 beats and enter a positive BPM.")
            }
            let seconds = Double(beats) * 60 / bpm
            guard seconds >= 0.02, seconds <= 32 else { throw ALOError("Live loops must be 0.02–32 seconds long.") }
            let frames = Int64((seconds * Double(Self.sampleRate)).rounded())
            try captureLoop(from: selectedCursor - frames, to: selectedCursor)
        }
    }

    func setLoopIn() {
        lock.withLock {
            guard stage != nil else { return }
            loop = []; loopOffset = 0; loopIn = selectedCursor
        }
    }

    func setLoopOut() throws {
        try lock.withLock {
            try requireActive()
            guard let loopIn else { throw ALOError("Set Loop In, let audio play, then set Loop Out.") }
            try captureLoop(from: loopIn, to: selectedCursor)
        }
    }

    func clearLoop() throws {
        try lock.withLock { try requireActive(); loop = []; loopOffset = 0; loopIn = nil }
    }
    func setCue() { lock.withLock { if stage != nil { cue = selectedCursor } } }
    func returnToCue() throws {
        try lock.withLock {
            try requireActive()
            guard let cue, cue >= oldestFrame, cue <= written else { throw ALOError("This cue is outside the available live history. Set a new cue.") }
            delayFrames = Int(written - cue); loop = []; loopOffset = 0
        }
    }

    func snapshot() -> DJLiveSnapshot {
        lock.withLock {
            var waveform = stage == nil || historyFrames == 0 ? [] : [Float](repeating: 0, count: 256)
            if !waveform.isEmpty {
                // Only peak summaries are visited; snapshots never scan or copy PCM.
                for index in peaks.indices {
                    let start = peakIDs[index] * Int64(Self.summaryFrames)
                    guard peakIDs[index] >= 0, start < written, start + Int64(Self.summaryFrames) > oldestFrame else { continue }
                    let first = max(oldestFrame, start)
                    let last = min(written - 1, start + Int64(Self.summaryFrames - 1))
                    let firstBin = min(255, Int((first - oldestFrame) * 256 / Int64(historyFrames)))
                    let lastBin = min(255, Int((last - oldestFrame) * 256 / Int64(historyFrames)))
                    for bin in firstBin...lastBin { waveform[bin] = max(waveform[bin], peaks[index]) }
                }
            }
            return DJLiveSnapshot(stage: stage, historyDuration: Double(historyFrames) / Double(Self.sampleRate),
                                  delaySeconds: Double(delayFrames) / Double(Self.sampleRate), looping: !loop.isEmpty,
                                  loopDuration: Double(loop.count / 2) / Double(Self.sampleRate), hasLoopIn: loopIn != nil,
                                  waveform: waveform, inputPeak: inputPeak, outputPeak: outputPeak, muted: muted,
                                  hasCue: cue.map { $0 >= oldestFrame && $0 <= written } ?? false,
                                  gain: gain, low: low, mid: mid, high: high,
                                  bufferedPCMBytes: (history.count + loop.count + overlay.count + recordingStorage.count) * MemoryLayout<Int16>.size,
                                  secondsSinceInput: lastInputUptime.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000_000 },
                                  recording: recording,
                                  recordingDuration: Double(recordedSamples / 2) / Double(Self.sampleRate),
                                  recordingReady: !recording && recordedSamples > 0)
        }
    }

    private var historyFrames: Int { Int(min(written, Int64(Self.maximumFrames))) }
    private var oldestFrame: Int64 { max(0, written - Int64(Self.maximumFrames)) }
    private var selectedCursor: Int64 { written - Int64(delayFrames) }
    private func requireActive() throws {
        guard stage != nil else { throw ALOError("Start or join a broadcast before using the live deck.") }
    }
    private func captureLoop(from start: Int64, to end: Int64) throws {
        guard start >= oldestFrame, end <= written, end > start,
              end - start >= 960, end - start <= Int64(Self.maximumFrames) else {
            throw ALOError("Not enough live history for this loop. Let more audio play, shorten the loop, or move closer to Live.")
        }
        // No process call can observe this replacement while the control lock is held.
        // Release an existing region before allocating, keeping PCM residency bounded.
        loop = []; loopOffset = 0
        var region = [Int16](repeating: 0, count: Int(end - start) * 2)
        for frame in 0..<Int(end - start) {
            let source = Int((start + Int64(frame)) % Int64(Self.maximumFrames)) * 2
            region[frame * 2] = history[source]; region[frame * 2 + 1] = history[source + 1]
        }
        loop = region; loopOffset = 0
    }
    private static func clamp(_ value: Float, _ range: ClosedRange<Float>, fallback: Float = 0) -> Float {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// RBJ filters, two state values per channel/band. Coefficients update without PCM allocation.
private struct DJLiveBiquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0
    mutating func update(_ next: DJLiveBiquad) {
        b0 = next.b0; b1 = next.b1; b2 = next.b2; a1 = next.a1; a2 = next.a2
    }
    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        if !output.isFinite || !z1.isFinite || !z2.isFinite { z1 = 0; z2 = 0; return 0 }
        return output
    }
    private static func normalized(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Self {
        var result = Self()
        result.b0 = Float(b0 / a0); result.b1 = Float(b1 / a0); result.b2 = Float(b2 / a0)
        result.a1 = Float(a1 / a0); result.a2 = Float(a2 / a0)
        return result
    }
    static func peak(frequency: Double, gain: Float) -> Self {
        let a = pow(10, Double(gain) / 40), w = 2 * Double.pi * frequency / 48_000
        let c = cos(w), alpha = sin(w) / 2
        return normalized(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
    }
    static func shelf(frequency: Double, gain: Float, high: Bool) -> Self {
        let a = pow(10, Double(gain) / 40), w = 2 * Double.pi * frequency / 48_000
        let c = cos(w), beta = sqrt(2 * a) * sin(w)
        if high {
            return normalized(a * ((a + 1) + (a - 1) * c + beta), -2 * a * ((a - 1) + (a + 1) * c),
                              a * ((a + 1) + (a - 1) * c - beta), (a + 1) - (a - 1) * c + beta,
                              2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - beta)
        }
        return normalized(a * ((a + 1) - (a - 1) * c + beta), 2 * a * ((a - 1) - (a + 1) * c),
                          a * ((a + 1) - (a - 1) * c - beta), (a + 1) + (a - 1) * c + beta,
                          -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - beta)
    }
}
