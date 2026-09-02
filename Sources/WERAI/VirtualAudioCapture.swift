import Foundation
import WERAICore
import WERAISharedAudioClient

/// Reads the HAL driver's output directly from its shared SPSC ring. It never opens
/// a recording/input API and therefore does not request microphone access.
final class VirtualAudioCapture: AudioSource {
    private let queue = DispatchQueue(label: "in.werai.audio.shared-reader", qos: .userInteractive)
    private var handle: WERAISharedAudioHandle?
    private var timer: DispatchSourceTimer?
    private var handler: AudioHandler?
    private var generation: UInt64 = 0
    private var nextFrame: UInt64 = 0
    private let capacity: UInt64 = 32_768
    private let maximumChunkFrames: UInt64 = 960

    func start(audioHandler: @escaping AudioHandler) async throws {
        guard handle == nil else { return }
        guard let opened = WERAISharedAudioClientOpen() else {
            throw ALOAudioSetupError.bridgeUnavailable
        }
        handle = opened
        handler = audioHandler
        generation = WERAISharedAudioClientGeneration(opened)
        nextFrame = WERAISharedAudioClientLatestFrame(opened)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer
        timer.resume()
    }

    func stop() async throws {
        queue.sync {
            timer?.cancel()
            timer = nil
            if let handle { WERAISharedAudioClientClose(handle) }
            handle = nil
            handler = nil
        }
    }

    private func drain() {
        guard let handle else { return }
        let currentGeneration = WERAISharedAudioClientGeneration(handle)
        let latest = WERAISharedAudioClientLatestFrame(handle)
        if currentGeneration != generation {
            generation = currentGeneration
            nextFrame = latest
            return
        }
        if latest > nextFrame &+ capacity { nextFrame = latest - capacity }
        let end = min(latest, nextFrame &+ maximumChunkFrames)
        guard end > nextFrame else { return }

        var samples = [Int16]()
        samples.reserveCapacity(Int(end - nextFrame) * 2)
        var firstHostTime: UInt64?
        while nextFrame < end {
            var stereo = [Float](repeating: 0, count: 2)
            var hostTime: UInt64 = 0
            guard WERAISharedAudioClientRead(handle, nextFrame, &stereo, &hostTime) != 0 else {
                // The producer can lap a suspended reader between our `latest`
                // snapshot and this slot read. Skip the lost position so one
                // overwritten frame cannot stall capture forever.
                let newest = WERAISharedAudioClientLatestFrame(handle)
                nextFrame = max(nextFrame &+ 1, newest > capacity ? newest - capacity : 0)
                break
            }
            if firstHostTime == nil { firstHostTime = hostTime }
            samples.append(Self.quantize(stereo[0]))
            samples.append(Self.quantize(stereo[1]))
            nextFrame &+= 1
        }
        guard !samples.isEmpty, let firstHostTime else { return }
        handler?(samples, MonotonicClock.ticksToNanos(firstHostTime))
    }

    private static func quantize(_ value: Float) -> Int16 {
        Int16(clamping: Int(min(max(value, -1), 1) * Float(Int16.max)))
    }
}
