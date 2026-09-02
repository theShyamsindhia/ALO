import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import WERAICore

final class SynchronizedPlayer {
    static let targetLatencyNanos = RoomTiming.defaultPlayoutDelayNanos
    static let hardResyncThresholdNanos: UInt64 = 100_000_000
    static let sustainedDriftThresholdNanos: UInt64 = 20_000_000
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let format: AVAudioFormat
    private let outputDeviceUID: String?
    private let explicitOutputDeviceID: AudioDeviceID?
    private var pending = [UInt32: AudioPacket]()
    private var expectedSequence: UInt32?
    private var anchorFrameIndex: UInt64?
    private var anchorCaptureNanos: UInt64?
    private var hasStarted = false
    private var outputLatencyNanos: UInt64 = 0
    private var activeOutputDeviceID: AudioDeviceID?
    private var targetLatencyNanos = RoomTiming.defaultPlayoutDelayNanos
    private var smoothedCorrection = 0.0
    private let playbackActivityChanged: ((Bool) -> Void)?
    private var latestLatenessNanos: UInt64 = 0
    private var latePacketCount: UInt64 = 0
    private var resyncCount: UInt64 = 0
    private var lastPacketReceivedNanos: UInt64?
    private var playbackWatchdog = PlaybackWatchdog()
    private var driftRecovery = PlaybackDriftRecovery()
    private var configurationObserver: NSObjectProtocol?
    private let configurationLock = NSLock()
    private var configurationChangePending = false
    private var isRecoveringConfiguration = false
    private var recoveryRetryNotBeforeNanos: UInt64 = 0
    private var participantVolume: Double = 1
    private var participantMuted = false
    private var playbackIsActive = false
    private(set) var configurationChangeCount: UInt64 = 0

    var clockOffsetNanos: Int64?

    init(
        outputDeviceUID: String? = nil,
        outputDeviceID: AudioDeviceID? = nil,
        playbackActivityChanged: ((Bool) -> Void)? = nil
    ) throws {
        self.playbackActivityChanged = playbackActivityChanged
        self.outputDeviceUID = outputDeviceUID
        self.explicitOutputDeviceID = outputDeviceID
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
        try applyRequestedOutputDevice()
        engine.prepare()
        try engine.start()
        refreshOutputState()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.markAudioEngineConfigurationChanged()
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func accept(_ packet: AudioPacket) {
        let now = MonotonicClock.nowNanos()
        lastPacketReceivedNanos = now
        pending[packet.sequence] = packet
        if expectedSequence == nil {
            expectedSequence = packet.sequence
        }
        drain()
    }

    func maintainSync() {
        applyPendingAudioEngineConfigurationChange()
        drain()
        updatePlaybackActivity(nowNanos: MonotonicClock.nowNanos())
        guard hasStarted else {
            playbackWatchdog.reset()
            return
        }

        let now = MonotonicClock.nowNanos()
        let renderTime = player.lastRenderTime
        let playerTime = renderTime.flatMap { player.playerTime(forNodeTime: $0) }
        if playbackWatchdog.shouldResynchronize(
            sampleTime: playerTime?.sampleTime,
            nowNanos: now,
            lastPacketReceivedNanos: lastPacketReceivedNanos
        ) {
            latestLatenessNanos = max(latestLatenessNanos, Self.hardResyncThresholdNanos)
            hardResynchronize()
            return
        }

        guard let offset = clockOffsetNanos,
              let anchorFrameIndex,
              let anchorCaptureNanos,
              let renderTime,
              renderTime.isHostTimeValid,
              let playerTime
        else { return }

        let renderLocalNanos = MonotonicClock.ticksToNanos(renderTime.hostTime)
        let renderHostNanos = addSigned(renderLocalNanos, offset)
        let audibleHostNanos = renderHostNanos &+ outputLatencyNanos
        let timelineStart = anchorCaptureNanos &+ targetLatencyNanos
        let expectedNanos = audibleHostNanos > timelineStart
            ? audibleHostNanos - timelineStart
            : 0
        let expectedFrames = Double(expectedNanos)
            * Double(AudioPacket.sampleRate) / 1_000_000_000
        let actualFrame = Double(anchorFrameIndex) + Double(playerTime.sampleTime)
        let errorFrames = Double(anchorFrameIndex) + expectedFrames - actualFrame
        let absoluteErrorNanos = UInt64(
            abs(errorFrames) * 1_000_000_000 / Double(AudioPacket.sampleRate)
        )
        let hardResyncFrames = Double(AudioPacket.sampleRate)
            * Double(Self.hardResyncThresholdNanos) / 1_000_000_000
        if abs(errorFrames) > hardResyncFrames {
            latestLatenessNanos = absoluteErrorNanos
            hardResynchronize()
            return
        }
        if driftRecovery.shouldResynchronize(latenessNanos: absoluteErrorNanos) {
            latestLatenessNanos = absoluteErrorNanos
            hardResynchronize()
            return
        }
        let desiredCorrection = abs(errorFrames) < 24
            ? 0
            : max(-0.002, min(0.002, errorFrames / Double(AudioPacket.sampleRate) * 0.02))
        smoothedCorrection += (desiredCorrection - smoothedCorrection) * 0.12
        if abs(smoothedCorrection) < 0.000_005 {
            smoothedCorrection = 0
        }
        let rate = Float(1 + smoothedCorrection)
        if abs(varispeed.rate - rate) > 0.000_005 {
            varispeed.rate = rate
        }
    }

    private func drain() {
        guard let offset = clockOffsetNanos else { return }

        while let sequence = expectedSequence {
            guard let packet = pending.removeValue(forKey: sequence) else {
                if !hasStarted, let next = pending.values.min(by: { $0.sequence < $1.sequence }) {
                    expectedSequence = next.sequence
                    continue
                }
                concealMissingPacketIfNeeded(sequence: sequence, offset: offset)
                return
            }

            let desiredAudibleNanos = addSigned(packet.captureTimeNanos, -offset)
                &+ targetLatencyNanos
            let desiredRenderNanos = desiredAudibleNanos > outputLatencyNanos
                ? desiredAudibleNanos - outputLatencyNanos
                : desiredAudibleNanos
            let now = MonotonicClock.nowNanos()

            if hasStarted, now > desiredRenderNanos + Self.hardResyncThresholdNanos {
                latestLatenessNanos = now - desiredRenderNanos
                latePacketCount &+= 1
                hardResynchronize()
                expectedSequence = sequence &+ 1
                continue
            }

            if !hasStarted, desiredRenderNanos <= now + 25_000_000 {
                latestLatenessNanos = now > desiredRenderNanos ? now - desiredRenderNanos : 0
                latePacketCount &+= 1
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
                latestLatenessNanos = 0
                print("Playback synchronized (\(targetLatencyNanos / 1_000_000) ms room buffer).")
                updatePlaybackActivity(nowNanos: now)
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
        smoothedCorrection = 0
        varispeed.rate = 1
        latestLatenessNanos = 0
        lastPacketReceivedNanos = nil
        setPlaybackActive(false)
        playbackWatchdog.reset()
        driftRecovery.reset()
    }

    func setTargetLatencyNanos(_ nanos: UInt64) {
        targetLatencyNanos = RoomTiming.clampedPlayoutDelay(nanos)
    }

    func setLevel(volume: Double, muted: Bool) {
        participantVolume = min(max(volume, 0), 1)
        participantMuted = muted
        applyOutputGain()
    }

    private func applyOutputGain() {
        player.volume = participantMuted ? 0 : Float(participantVolume)
        updatePlaybackActivity(nowNanos: MonotonicClock.nowNanos())
    }

    private func updatePlaybackActivity(nowNanos: UInt64) {
        let streamIsRecent = lastPacketReceivedNanos.map {
            nowNanos >= $0 && nowNanos - $0 <= 500_000_000
        } ?? false
        setPlaybackActive(hasStarted && streamIsRecent)
    }

    private func setPlaybackActive(_ active: Bool) {
        guard playbackIsActive != active else { return }
        playbackIsActive = active
        playbackActivityChanged?(active)
    }

    func syncReport() -> PlaybackSyncReport {
        PlaybackSyncReport(
            measuredAtNanos: MonotonicClock.nowNanos(),
            latenessNanos: latestLatenessNanos,
            latePacketCount: latePacketCount,
            resyncCount: resyncCount
        )
    }

    func forceResync() {
        hardResynchronize()
    }

    func handleAudioEngineConfigurationChange() {
        configurationChangeCount &+= 1
        recoverAudioEngine()
    }

    private func markAudioEngineConfigurationChanged() {
        configurationLock.withLock {
            if !isRecoveringConfiguration { configurationChangePending = true }
        }
    }

    private func applyPendingAudioEngineConfigurationChange() {
        let pending = configurationLock.withLock {
            let pending = configurationChangePending
            configurationChangePending = false
            return pending
        }
        guard pending else { return }
        let now = MonotonicClock.nowNanos()
        guard now >= recoveryRetryNotBeforeNanos else {
            configurationLock.withLock { configurationChangePending = true }
            return
        }
        let currentDeviceID = currentOutputDeviceID()
        let currentLatencyNanos = measuredOutputLatencyNanos()
        let deviceChanged = activeOutputDeviceID != currentDeviceID
        let latencyChanged = Self.latencyChanged(
            from: outputLatencyNanos,
            to: currentLatencyNanos
        )
        // Core Audio also broadcasts configuration changes for unrelated private
        // taps. Ignore those only when this engine's device and latency are intact.
        if Self.shouldRecoverAfterConfigurationChange(
            engineIsRunning: engine.isRunning,
            deviceChanged: deviceChanged,
            latencyChanged: latencyChanged
        ) {
            handleAudioEngineConfigurationChange()
        }
    }

    static func shouldRecoverAfterConfigurationChange(
        engineIsRunning: Bool,
        deviceChanged: Bool,
        latencyChanged: Bool
    ) -> Bool {
        !engineIsRunning || deviceChanged || latencyChanged
    }

    static func latencyChanged(from old: UInt64, to new: UInt64) -> Bool {
        let difference = old > new ? old - new : new - old
        return difference > 1_000_000
    }

    private func recoverAudioEngine() {
        let shouldRecover = configurationLock.withLock {
            guard !isRecoveringConfiguration else { return false }
            isRecoveringConfiguration = true
            configurationChangePending = false
            return true
        }
        guard shouldRecover else { return }
        defer {
            configurationLock.withLock { isRecoveringConfiguration = false }
        }

        player.stop()
        engine.stop()
        hardResynchronize()
        do {
            try applyRequestedOutputDevice()
            engine.prepare()
            try engine.start()
            refreshOutputState()
            recoveryRetryNotBeforeNanos = 0
        } catch {
            fputs("Audio output recovery failed: \(error.localizedDescription)\n", stderr)
            recoveryRetryNotBeforeNanos = MonotonicClock.nowNanos() + 500_000_000
            configurationLock.withLock { configurationChangePending = true }
        }
    }

    private func measuredOutputLatencyNanos() -> UInt64 {
        UInt64(max(0, engine.outputNode.presentationLatency) * 1_000_000_000)
    }

    private func refreshOutputState() {
        outputLatencyNanos = measuredOutputLatencyNanos()
        activeOutputDeviceID = currentOutputDeviceID()
    }

    private func currentOutputDeviceID() -> AudioDeviceID? {
        guard let audioUnit = engine.outputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private func applyRequestedOutputDevice() throws {
        guard let deviceID = Self.selectedOutputDeviceID(
            explicitID: explicitOutputDeviceID,
            uid: outputDeviceUID,
            resolver: Self.audioDeviceID(forUID:)
        ) else { return }
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw WERAIError("Could not access the selected audio output.")
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw WERAIError("Could not select audio output device (OSStatus \(status)).")
        }
    }

    static func selectedOutputDeviceID(
        explicitID: AudioDeviceID?,
        uid: String?,
        resolver: (String) -> AudioDeviceID?
    ) -> AudioDeviceID? {
        explicitID ?? uid.flatMap(resolver)
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var uidValue: CFString = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        let status = withUnsafeMutablePointer(to: &uidValue) { uidPointer in
            withUnsafeMutablePointer(to: &deviceID) { devicePointer in
                var translated = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(devicePointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDeviceForUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &translated
                )
            }
        }
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private func hardResynchronize() {
        player.stop()
        smoothedCorrection = 0
        varispeed.rate = 1
        anchorFrameIndex = nil
        anchorCaptureNanos = nil
        hasStarted = false
        playbackWatchdog.reset()
        driftRecovery.reset()
        resyncCount &+= 1
        if let next = pending.values.min(by: { $0.sequence < $1.sequence }) {
            expectedSequence = next.sequence
        }
    }

    private func concealMissingPacketIfNeeded(sequence: UInt32, offset: Int64) {
        guard hasStarted,
              let next = pending.values.min(by: { $0.sequence < $1.sequence }),
              next.sequence > sequence
        else { return }

        let nextRenderNanos = addSigned(next.captureTimeNanos, -offset)
            &+ targetLatencyNanos
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

struct PlaybackDriftRecovery {
    static let requiredConsecutiveChecks = 3

    private var consecutiveLateChecks = 0

    mutating func shouldResynchronize(latenessNanos: UInt64) -> Bool {
        guard latenessNanos >= SynchronizedPlayer.sustainedDriftThresholdNanos else {
            reset()
            return false
        }
        consecutiveLateChecks += 1
        guard consecutiveLateChecks >= Self.requiredConsecutiveChecks else { return false }
        reset()
        return true
    }

    mutating func reset() {
        consecutiveLateChecks = 0
    }
}

struct PlaybackWatchdog {
    static let stallThresholdNanos: UInt64 = 250_000_000
    static let activePacketWindowNanos: UInt64 = 500_000_000

    private var lastSampleTime: Int64?
    private var lastProgressNanos: UInt64?

    mutating func shouldResynchronize(
        sampleTime: Int64?,
        nowNanos: UInt64,
        lastPacketReceivedNanos: UInt64?
    ) -> Bool {
        guard let lastPacketReceivedNanos,
              nowNanos >= lastPacketReceivedNanos,
              nowNanos - lastPacketReceivedNanos <= Self.activePacketWindowNanos
        else {
            reset()
            return false
        }

        if let sampleTime, lastSampleTime != sampleTime {
            lastSampleTime = sampleTime
            lastProgressNanos = nowNanos
            return false
        }
        if lastProgressNanos == nil {
            lastSampleTime = sampleTime
            lastProgressNanos = nowNanos
            return false
        }
        guard nowNanos - (lastProgressNanos ?? nowNanos) >= Self.stallThresholdNanos else {
            return false
        }
        lastProgressNanos = nowNanos
        return true
    }

    mutating func reset() {
        lastSampleTime = nil
        lastProgressNanos = nil
    }
}
