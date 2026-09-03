import AVFoundation
import Foundation
import WERAICore

final class WalkieTalkieMicrophone {
    static let sampleRate = 16_000.0
    private var engine: AVAudioEngine?

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            return false
        }
    }

    func start(handler: @escaping (Data) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Self.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw WERAIError("This Mac does not have an available microphone input.") }

        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { buffer, _ in
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 8
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, converted.frameLength > 0,
                  let samples = converted.int16ChannelData?[0]
            else { return }
            handler(Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
        }
        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    deinit { stop() }
}

final class WalkieTalkiePlayer {
    private let queue = DispatchQueue(label: "in.werai.walkie-playback", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    static let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: WalkieTalkieMicrophone.sampleRate,
        channels: 1
    )!
    private let format = playbackFormat
    private var sessionID: String?
    private var lastSequence: UInt64 = 0
    private var timeoutWorkItem: DispatchWorkItem?
    private var muted = false

    static func makePlaybackBuffer(fromPCM16Mono data: Data) -> AVAudioPCMBuffer? {
        guard !data.isEmpty,
              data.count <= 8_192,
              data.count.isMultiple(of: MemoryLayout<Int16>.size)
        else { return nil }

        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: frameCount
        ), let destination = buffer.floatChannelData?[0]
        else { return nil }

        buffer.frameLength = frameCount
        data.withUnsafeBytes { bytes in
            for index in 0..<Int(frameCount) {
                let offset = index * MemoryLayout<Int16>.size
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                destination[index] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        return buffer
    }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func accept(_ message: WalkieTalkieMessage) {
        queue.async { [weak self] in
            guard let self, !self.muted else { return }
            self.acceptOnQueue(message)
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.muted = muted
            if muted { self.stopOnQueue() }
        }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func acceptOnQueue(_ message: WalkieTalkieMessage) {
        switch message.kind {
        case .began:
            _ = beginSession(message.sessionID)
        case .audio:
            if sessionID != message.sessionID || !engine.isRunning {
                guard beginSession(message.sessionID) else { return }
            }
            guard message.sequence > lastSequence,
                  let data = message.pcm16Mono,
                  let buffer = Self.makePlaybackBuffer(fromPCM16Mono: data)
            else { return }
            lastSequence = message.sequence
            player.scheduleBuffer(buffer)
            if !player.isPlaying { player.play() }
            armTimeout(for: message.sessionID)
        case .ended:
            guard sessionID == message.sessionID else { return }
            stopOnQueue()
        }
    }

    @discardableResult
    private func beginSession(_ id: String) -> Bool {
        timeoutWorkItem?.cancel()
        player.stop()
        sessionID = id
        lastSequence = 0
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        guard engine.isRunning else {
            sessionID = nil
            return false
        }
        player.play()
        armTimeout(for: id)
        return true
    }

    private func armTimeout(for id: String) {
        timeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionID == id else { return }
            self.stopOnQueue()
        }
        timeoutWorkItem = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func stopOnQueue() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        player.stop()
        sessionID = nil
        lastSequence = 0
    }

    deinit {
        timeoutWorkItem?.cancel()
        player.stop()
        engine.stop()
    }
}
