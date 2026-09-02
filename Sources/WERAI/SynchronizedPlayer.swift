import AVFoundation
import Foundation
import WERAICore

final class SynchronizedPlayer {
    static let targetLatencyNanos: UInt64 = 250_000_000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let format: AVAudioFormat
    private var pending = [UInt32: AudioPacket]()
    private var expectedSequence: UInt32?
    private var anchorFrameIndex: UInt64?
    private var anchorCaptureNanos: UInt64?
    private var hasStarted = false
    private var outputLatencyNanos: UInt64 = 0
    private let playbackStarted: (() -> Void)?

    var clockOffsetNanos: Int64?

    init(playbackStarted: (() -> Void)? = nil) throws {
        self.playbackStarted = playbackStarted
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(AudioPacket.sampleRate),
            channels: AVAudioChannelCount(AudioPacket.channelCount),
            interleaved: false
        ) else {
            throw WERAIError("Could not create the playback audio format.")
        }
        self.format = format

        engine.attach(player)
        engine.attach(varispeed)
        engine.connect(player, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        outputLatencyNanos = UInt64(max(0, engine.outputNode.presentationLatency) * 1_000_000_000)
    }

    func accept(_ packet: AudioPacket) {
        pending[packet.sequence] = packet
        if expectedSequence == nil {
            expectedSequence = packet.sequence
        }
        drain()
    }

    func maintainSync() {
        drain()
        guard hasStarted,
              let offset = clockOffsetNanos,
              let anchorFrameIndex,
              let anchorCaptureNanos,
              let renderTime = player.lastRenderTime,
              renderTime.isHostTimeValid,
              let playerTime = player.playerTime(forNodeTime: renderTime)
        else { return }

        let renderLocalNanos = MonotonicClock.ticksToNanos(renderTime.hostTime)
        let renderHostNanos = addSigned(renderLocalNanos, offset)
        let audibleHostNanos = renderHostNanos &+ outputLatencyNanos
        guard audibleHostNanos >= anchorCaptureNanos + Self.targetLatencyNanos else { return }

        let expectedFrames = Double(audibleHostNanos - anchorCaptureNanos - Self.targetLatencyNanos)
            * Double(AudioPacket.sampleRate) / 1_000_000_000
        let actualFrame = Double(anchorFrameIndex) + Double(playerTime.sampleTime)
        let errorFrames = Double(anchorFrameIndex) + expectedFrames - actualFrame
        let correction = max(-0.002, min(0.002, errorFrames / Double(AudioPacket.sampleRate) * 0.02))
        varispeed.rate = Float(1 + correction)
    }

    private func drain() {
        guard let offset = clockOffsetNanos else { return }

        while let sequence = expectedSequence {
            guard let packet = pending.removeValue(forKey: sequence) else {
                concealMissingPacketIfNeeded(sequence: sequence, offset: offset)
                return
            }

            let desiredAudibleNanos = addSigned(packet.captureTimeNanos, -offset)
                &+ Self.targetLatencyNanos
            let desiredRenderNanos = desiredAudibleNanos > outputLatencyNanos
                ? desiredAudibleNanos - outputLatencyNanos
                : desiredAudibleNanos
            let now = MonotonicClock.nowNanos()

            if !hasStarted, desiredRenderNanos <= now + 25_000_000 {
                expectedSequence = sequence &+ 1
                continue
            }

            guard let buffer = makeBuffer(packet.samples) else {
                expectedSequence = sequence &+ 1
                continue
            }
            player.scheduleBuffer(buffer)

            if !hasStarted {
                anchorFrameIndex = packet.frameIndex
                anchorCaptureNanos = packet.captureTimeNanos
                player.play(at: AVAudioTime(hostTime: MonotonicClock.nanosToTicks(desiredRenderNanos)))
                hasStarted = true
                print("Playback synchronized (\(Self.targetLatencyNanos / 1_000_000) ms network buffer).")
                playbackStarted?()
            }
            expectedSequence = sequence &+ 1
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        pending.removeAll()
        expectedSequence = nil
        hasStarted = false
    }

    func setLevel(volume: Double, muted: Bool) {
        player.volume = muted ? 0 : Float(min(max(volume, 0), 1))
    }

    private func concealMissingPacketIfNeeded(sequence: UInt32, offset: Int64) {
        guard hasStarted,
              let next = pending.values.min(by: { $0.sequence < $1.sequence }),
              next.sequence > sequence
        else { return }

        let nextRenderNanos = addSigned(next.captureTimeNanos, -offset)
            &+ Self.targetLatencyNanos
        guard nextRenderNanos <= MonotonicClock.nowNanos() + 50_000_000 else { return }

        let silence = [Int16](
            repeating: 0,
            count: Int(AudioPacket.framesPerPacket) * Int(AudioPacket.channelCount)
        )
        if let buffer = makeBuffer(silence) {
            player.scheduleBuffer(buffer)
        }
        expectedSequence = sequence &+ 1
        drain()
    }

    private func makeBuffer(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        let frames = samples.count / Int(AudioPacket.channelCount)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ), let channels = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(frames)
        let scale = 1 / Float(Int16.max)
        for frame in 0..<frames {
            channels[0][frame] = Float(samples[frame * 2]) * scale
            channels[1][frame] = Float(samples[frame * 2 + 1]) * scale
        }
        return buffer
    }

    private func addSigned(_ value: UInt64, _ delta: Int64) -> UInt64 {
        if delta >= 0 {
            return value &+ UInt64(delta)
        }
        return value > UInt64(-delta) ? value - UInt64(-delta) : 0
    }
}
