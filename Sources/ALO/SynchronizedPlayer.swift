import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ALOCore

struct MediaOutputGain {
    static func effectiveGain(
        participantVolume: Double,
        muted: Bool,
        duckingGain: Double = 1
    ) -> Double {
        muted ? 0 : min(max(participantVolume, 0), 1) * min(max(duckingGain, 0), 1)
    }
}

struct AudioOutputHardwareFormat: Equatable {
    let sampleRate: Double
    let channelCount: UInt32

    static func changed(from old: Self?, to new: Self?) -> Bool {
        switch (old, new) {
        case (.none, .none): return false
        case (.some, .none), (.none, .some): return true
        case (.some(let old), .some(let new)):
            return abs(old.sampleRate - new.sampleRate) >= 1
                || old.channelCount != new.channelCount
        }
    }
}

struct AudioOutputRenderBudget {
    static let safetyMarginNanos: UInt64 = 10_000_000
    static let maximumHeadroomNanos: UInt64 = 200_000_000

    static func schedulingHeadroomNanos(
        bufferFrames: UInt32?,
        safetyOffsetFrames: UInt32?,
        sampleRate: Double
    ) -> UInt64 {
        guard sampleRate > 0 else { return RoomTiming.renderSchedulingHeadroomNanos }
        let hardwareFrames = UInt64(bufferFrames ?? 0) &+ UInt64(safetyOffsetFrames ?? 0)
        let hardwareLeadNanos = UInt64(
            Double(hardwareFrames) * 1_000_000_000 / sampleRate
        )
        return min(
            maximumHeadroomNanos,
            max(
                RoomTiming.renderSchedulingHeadroomNanos,
                hardwareLeadNanos &+ safetyMarginNanos
            )
        )
    }
}

struct AudioConfigurationRecoveryGate {
    private(set) var changePending = false
    private(set) var isRecovering = false

    mutating func markChanged() { changePending = true }

    mutating func takePendingChange() -> Bool {
        defer { changePending = false }
        return changePending
    }

    mutating func beginRecovery() -> Bool {
        guard !isRecovering else { return false }
        isRecovering = true
        return true
    }

    mutating func endRecovery() { isRecovering = false }
}

final class SynchronizedPlayer {
    static let targetLatencyNanos = RoomTiming.defaultPlayoutDelayNanos
    static let hardResyncThresholdNanos: UInt64 = 100_000_000
    private let audioOutput: RoomAudioOutputEngine
    private var engine: AVAudioEngine { audioOutput.engine }
    var outputEngineIdentityForTesting: ObjectIdentifier { audioOutput.identity }
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
    private var renderSchedulingHeadroomNanos = RoomTiming.renderSchedulingHeadroomNanos
    private var lastOutputStateRefreshNanos: UInt64 = 0
    private var activeOutputDeviceID: AudioDeviceID?
    private var activeOutputHardwareFormat: AudioOutputHardwareFormat?
    private var targetLatencyNanos = RoomTiming.defaultPlayoutDelayNanos
    private var smoothedCorrection = 0.0
    private let playbackActivityChanged: ((Bool) -> Void)?
    private var latestLatenessNanos: UInt64 = 0
    private var latestDriftMeasurement: (magnitude: UInt64, time: UInt64)?
    private var latePacketCount: UInt64 = 0
    private var resyncCount: UInt64 = 0
    private var lastPacketReceivedNanos: UInt64?
    private var playbackWatchdog = PlaybackWatchdog()
    private var driftRecovery = PlaybackDriftRecovery()
    private var configurationObserver: NSObjectProtocol?
    private let configurationLock = NSLock()
    private var configurationGate = AudioConfigurationRecoveryGate()
    private var recoveryRetryNotBeforeNanos: UInt64 = 0
    private var duckingGain: Double = 1
    private var participantVolume: Double = 1
    private var participantMuted = false
    private var playbackIsActive = false
    private var roomPlaybackIsPlaying = true
    private var resyncCutoverCaptureNanos: UInt64?
    private(set) var configurationChangeCount: UInt64 = 0
    private var nodesAreAttached = false
    private var outputLeaseHeld = false
    private var observedOutputStartGeneration: UInt64 = 0

    var expectedSequenceForTesting: UInt32? { expectedSequence }
    var outputLatencyForTimingNanos: UInt64 { outputLatencyNanos }
    var renderSchedulingHeadroomForTimingNanos: UInt64 { renderSchedulingHeadroomNanos }
    var outputHardwareFormatForDiagnostics: AudioOutputHardwareFormat? {
        activeOutputHardwareFormat
    }

    var clockOffsetNanos: Int64?

    init(
        audioOutput: RoomAudioOutputEngine = RoomAudioOutputEngine(),
        outputDeviceUID: String? = nil,
        outputDeviceID: AudioDeviceID? = nil,
        playbackActivityChanged: ((Bool) -> Void)? = nil
    ) throws {
        self.audioOutput = audioOutput
        self.playbackActivityChanged = playbackActivityChanged
        self.outputDeviceUID = outputDeviceUID
        self.explicitOutputDeviceID = outputDeviceID
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(AudioPacket.sampleRate),
            channels: AVAudioChannelCount(AudioPacket.channelCount),
            interleaved: false
        ) else {
            throw ALOError("Could not create the playback audio format.")
        }
        self.format = format

        do {
            try audioOutput.withGraph { engine in
                engine.attach(player)
                engine.attach(varispeed)
                engine.connect(player, to: varispeed, format: format)
                engine.connect(varispeed, to: engine.mainMixerNode, format: format)
                nodesAreAttached = true
                try applyRequestedOutputDevice()
            }
            audioOutput.retainClient()
            outputLeaseHeld = true
            try audioOutput.ensureRunning()
        } catch {
            detachOutputNodes()
            throw error
        }
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
        detachOutputNodes()
    }

    func accept(_ packet: AudioPacket) {
        guard nodesAreAttached else { return }
        guard roomPlaybackIsPlaying else { return }
        guard Self.shouldAdmitPacket(
            sequence: packet.sequence,
            expectedSequence: expectedSequence,
            isAlreadyPending: pending[packet.sequence] != nil
        ) else { return }
        if let cutover = resyncCutoverCaptureNanos {
            guard packet.captureTimeNanos >= cutover else { return }
            resyncCutoverCaptureNanos = nil
        }
        let now = MonotonicClock.nowNanos()
        lastPacketReceivedNanos = now
        pending[packet.sequence] = packet
        if expectedSequence == nil {
            expectedSequence = packet.sequence
        }
        drain()
    }

    func maintainSync() {
        // An unavailable render clock is unknown, not a fresh zero-error sample.
        latestDriftMeasurement = nil
        guard nodesAreAttached else { return }
        let now = MonotonicClock.nowNanos()
        guard roomPlaybackIsPlaying else {
            setPlaybackActive(false)
            return
        }
        applyPendingAudioEngineConfigurationChange()
        refreshOutputTimingIfNeeded(nowNanos: now)
        drain()
        updatePlaybackActivity(nowNanos: now)
        guard hasStarted else {
            playbackWatchdog.reset()
            return
        }

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
        guard let renderHostNanos = RoomTiming.hostTimeNanos(clientTimeNanos: renderLocalNanos,
                                                           clockOffsetNanos: offset) else { return }
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
        latestDriftMeasurement = (absoluteErrorNanos, now)
        if driftRecovery.shouldResynchronize(latenessNanos: absoluteErrorNanos) {
            latestLatenessNanos = absoluteErrorNanos
            hardResynchronize()
            return
        }
        let desiredCorrection = abs(errorFrames) < 24
            ? 0
            : max(-0.01, min(0.01, errorFrames / Double(AudioPacket.sampleRate) * 0.25))
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

            guard let localCaptureNanos = RoomTiming.clientTimeNanos(hostTimeNanos: packet.captureTimeNanos,
                                                                    clockOffsetNanos: offset) else {
                expectedSequence = sequence &+ 1
                continue
            }
            let audibleTime = localCaptureNanos.addingReportingOverflow(targetLatencyNanos)
            guard !audibleTime.overflow else {
                expectedSequence = sequence &+ 1
                continue
            }
            let desiredAudibleNanos = audibleTime.partialValue
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

            if !hasStarted, desiredRenderNanos <= now + renderSchedulingHeadroomNanos {
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
        pending.removeAll()
        expectedSequence = nil
        hasStarted = false
        smoothedCorrection = 0
        varispeed.rate = 1
        latestLatenessNanos = 0
        lastPacketReceivedNanos = nil
        resyncCutoverCaptureNanos = nil
        clockOffsetNanos = nil
        setPlaybackActive(false)
        playbackWatchdog.reset()
        driftRecovery.reset()
        latestDriftMeasurement = nil
        applyOutputGain()
        detachOutputNodes()
    }

    func setTargetLatencyNanos(_ nanos: UInt64) {
        targetLatencyNanos = RoomTiming.clampedPlayoutDelay(nanos)
    }

    func setDuckingGain(_ gain: Double) {
        duckingGain = min(1, max(0, gain))
        applyOutputGain()
    }

    func setLevel(volume: Double, muted: Bool) {
        participantVolume = min(max(volume, 0), 1)
        participantMuted = muted
        applyOutputGain()
    }

    func setRoomPlayback(playing: Bool) {
        guard roomPlaybackIsPlaying != playing else { return }
        roomPlaybackIsPlaying = playing
        guard !playing else { return }

        player.stop()
        pending.removeAll()
        expectedSequence = nil
        anchorFrameIndex = nil
        anchorCaptureNanos = nil
        hasStarted = false
        smoothedCorrection = 0
        varispeed.rate = 1
        latestLatenessNanos = 0
        resyncCutoverCaptureNanos = nil
        playbackWatchdog.reset()
        driftRecovery.reset()
        latestDriftMeasurement = nil
        setPlaybackActive(false)
    }

    private func applyOutputGain() {
        player.volume = Float(MediaOutputGain.effectiveGain(
            participantVolume: participantVolume,
            muted: participantMuted,
            duckingGain: duckingGain
        ))
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
        let now = MonotonicClock.nowNanos()
        return PlaybackSyncReport(
            measuredAtNanos: now,
            latenessNanos: latestLatenessNanos,
            latePacketCount: latePacketCount,
            resyncCount: resyncCount,
            driftNanos: latestDriftMeasurement?.magnitude,
            driftSampleAgeNanos: latestDriftMeasurement.flatMap { now >= $0.time ? now - $0.time : nil }
        )
    }

    func forceResync(atOrAfterCaptureNanos cutoverCaptureNanos: UInt64? = nil) {
        guard let cutoverCaptureNanos else {
            hardResynchronize()
            return
        }

        // Unlike automatic drift correction, a user-requested room sync must
        // not reuse any receiver-local backlog. Clear both already-scheduled
        // and pending audio, then ignore the live stream until the broadcaster's
        // shared future cutover timestamp arrives.
        player.stop()
        pending.removeAll()
        expectedSequence = nil
        anchorFrameIndex = nil
        anchorCaptureNanos = nil
        hasStarted = false
        smoothedCorrection = 0
        varispeed.rate = 1
        latestLatenessNanos = 0
        lastPacketReceivedNanos = nil
        playbackWatchdog.reset()
        driftRecovery.reset()
        latestDriftMeasurement = nil
        resyncCutoverCaptureNanos = cutoverCaptureNanos
        resyncCount &+= 1
        setPlaybackActive(false)
    }

    /// Starts a new transport epoch without tearing down the shared hardware
    /// graph. Host processes restart their packet sequence at zero, so keeping
    /// sequence, timeline, or watchdog state across a control reconnect would
    /// make every packet from the new stream look stale.
    func resetStream() {
        player.stop()
        pending.removeAll()
        expectedSequence = nil
        anchorFrameIndex = nil
        anchorCaptureNanos = nil
        hasStarted = false
        smoothedCorrection = 0
        varispeed.rate = 1
        latestLatenessNanos = 0
        lastPacketReceivedNanos = nil
        resyncCutoverCaptureNanos = nil
        playbackWatchdog.reset()
        driftRecovery.reset()
        latestDriftMeasurement = nil
        setPlaybackActive(false)
    }

    func handleAudioEngineConfigurationChange() {
        configurationChangeCount &+= 1
        recoverAudioEngine()
    }

    private func markAudioEngineConfigurationChanged() {
        configurationLock.withLock {
            // Bluetooth routes can transition through several formats. Retain a
            // notification that arrives during recovery so the next maintenance
            // pass reconciles the final hardware state too.
            configurationGate.markChanged()
        }
    }

    private func applyPendingAudioEngineConfigurationChange() {
        let pending = configurationLock.withLock {
            configurationGate.takePendingChange()
        }
        guard pending else { return }
        let now = MonotonicClock.nowNanos()
        guard now >= recoveryRetryNotBeforeNanos else {
            configurationLock.withLock { configurationGate.markChanged() }
            return
        }
        let currentDeviceID = currentOutputDeviceID()
        let currentLatencyNanos = measuredOutputLatencyNanos()
        let currentHardwareFormat = currentOutputHardwareFormat()
        let deviceChanged = activeOutputDeviceID != currentDeviceID
        let latencyChanged = Self.latencyChanged(
            from: outputLatencyNanos,
            to: currentLatencyNanos
        )
        let outputFormatChanged = AudioOutputHardwareFormat.changed(
            from: activeOutputHardwareFormat,
            to: currentHardwareFormat
        )
        let engineRestarted = observedOutputStartGeneration != 0
            && observedOutputStartGeneration != audioOutput.startGeneration
        // Core Audio also broadcasts configuration changes for unrelated private
        // taps. Rebuild only when this engine stopped or its route/format changed;
        // latency-only updates are folded into the live timeline below.
        if Self.shouldRecoverAfterConfigurationChange(
            engineIsRunning: audioOutput.isRunning,
            deviceChanged: deviceChanged,
            latencyChanged: latencyChanged,
            outputFormatChanged: outputFormatChanged,
            engineRestarted: engineRestarted
        ) {
            handleAudioEngineConfigurationChange()
        } else {
            if Self.shouldAcceptOutputLatencyMeasurement(
                engineIsRunning: audioOutput.isRunning,
                previousLatencyNanos: outputLatencyNanos,
                measuredLatencyNanos: currentLatencyNanos
            ) {
                outputLatencyNanos = currentLatencyNanos
            }
            renderSchedulingHeadroomNanos = measuredRenderSchedulingHeadroomNanos(
                deviceID: currentDeviceID,
                hardwareFormat: currentHardwareFormat
            )
            activeOutputDeviceID = currentDeviceID
            activeOutputHardwareFormat = currentHardwareFormat
        }
    }

    static func shouldRecoverAfterConfigurationChange(
        engineIsRunning: Bool,
        deviceChanged: Bool,
        latencyChanged _: Bool,
        outputFormatChanged: Bool = false,
        engineRestarted: Bool = false
    ) -> Bool {
        !engineIsRunning || deviceChanged || outputFormatChanged || engineRestarted
    }

    static func latencyChanged(from old: UInt64, to new: UInt64) -> Bool {
        let difference = old > new ? old - new : new - old
        return difference > 1_000_000
    }

    static func shouldAcceptOutputLatencyMeasurement(
        engineIsRunning: Bool,
        previousLatencyNanos: UInt64,
        measuredLatencyNanos: UInt64
    ) -> Bool {
        engineIsRunning && (measuredLatencyNanos > 0 || previousLatencyNanos == 0)
    }

    private func recoverAudioEngine() {
        let shouldRecover = configurationLock.withLock {
            configurationGate.beginRecovery()
        }
        guard shouldRecover else { return }
        defer {
            configurationLock.withLock { configurationGate.endRecovery() }
        }

        guard nodesAreAttached else { return }
        player.stop()
        hardResynchronize()
        do {
            try audioOutput.withGraph { engine in
                engine.disconnectNodeOutput(player)
                engine.disconnectNodeOutput(varispeed)
                engine.connect(player, to: varispeed, format: format)
                engine.connect(varispeed, to: engine.mainMixerNode, format: format)
                try applyRequestedOutputDevice()
            }
            try audioOutput.ensureRunning()
            refreshOutputState()
            applyOutputGain()
            recoveryRetryNotBeforeNanos = 0
        } catch {
            fputs("Audio output recovery failed: \(error.localizedDescription)\n", stderr)
            recoveryRetryNotBeforeNanos = MonotonicClock.nowNanos() + 500_000_000
            configurationLock.withLock { configurationGate.markChanged() }
        }
    }

    private func measuredOutputLatencyNanos() -> UInt64 {
        UInt64(max(0, engine.outputNode.presentationLatency) * 1_000_000_000)
    }

    private func refreshOutputState() {
        observedOutputStartGeneration = audioOutput.startGeneration
        outputLatencyNanos = measuredOutputLatencyNanos()
        activeOutputDeviceID = currentOutputDeviceID()
        activeOutputHardwareFormat = currentOutputHardwareFormat()
        renderSchedulingHeadroomNanos = measuredRenderSchedulingHeadroomNanos(
            deviceID: activeOutputDeviceID,
            hardwareFormat: activeOutputHardwareFormat
        )
        lastOutputStateRefreshNanos = MonotonicClock.nowNanos()
    }

    private func refreshOutputTimingIfNeeded(nowNanos: UInt64) {
        guard nowNanos >= lastOutputStateRefreshNanos,
              nowNanos - lastOutputStateRefreshNanos >= 2_000_000_000,
              audioOutput.isRunning
        else { return }
        lastOutputStateRefreshNanos = nowNanos
        let measuredLatencyNanos = measuredOutputLatencyNanos()
        guard Self.shouldAcceptOutputLatencyMeasurement(
            engineIsRunning: audioOutput.isRunning,
            previousLatencyNanos: outputLatencyNanos,
            measuredLatencyNanos: measuredLatencyNanos
        ) else { return }
        outputLatencyNanos = measuredLatencyNanos
        renderSchedulingHeadroomNanos = measuredRenderSchedulingHeadroomNanos(
            deviceID: currentOutputDeviceID(),
            hardwareFormat: currentOutputHardwareFormat()
        )
    }

    private func measuredRenderSchedulingHeadroomNanos(
        deviceID: AudioDeviceID?,
        hardwareFormat: AudioOutputHardwareFormat?
    ) -> UInt64 {
        guard let deviceID else { return RoomTiming.renderSchedulingHeadroomNanos }
        return AudioOutputRenderBudget.schedulingHeadroomNanos(
            bufferFrames: Self.audioDeviceUInt32Property(
                deviceID: deviceID,
                selector: kAudioDevicePropertyBufferFrameSize
            ),
            safetyOffsetFrames: Self.audioDeviceUInt32Property(
                deviceID: deviceID,
                selector: kAudioDevicePropertySafetyOffset
            ),
            sampleRate: Self.audioDeviceNominalSampleRate(deviceID)
                ?? hardwareFormat?.sampleRate
                ?? Double(AudioPacket.sampleRate)
        )
    }

    private static func audioDeviceNominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr && value > 0 ? value : nil
    }

    private static func audioDeviceUInt32Property(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
    }

    private func currentOutputHardwareFormat() -> AudioOutputHardwareFormat? {
        guard let audioUnit = engine.outputNode.audioUnit else { return nil }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            0,
            &description,
            &size
        )
        guard status == noErr,
              description.mSampleRate > 0,
              description.mChannelsPerFrame > 0
        else { return nil }
        return AudioOutputHardwareFormat(
            sampleRate: description.mSampleRate,
            channelCount: description.mChannelsPerFrame
        )
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
            throw ALOError("Could not access the selected audio output.")
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
            throw ALOError("Could not select audio output device (OSStatus \(status)).")
        }
    }

    private func detachOutputNodes() {
        audioOutput.withGraph { engine in
            guard nodesAreAttached else { return }
            player.stop()
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(varispeed)
            engine.detach(player)
            engine.detach(varispeed)
            nodesAreAttached = false
        }
        if outputLeaseHeld {
            outputLeaseHeld = false
            audioOutput.releaseClient()
        }
    }

    static func selectedOutputDeviceID(
        explicitID: AudioDeviceID?,
        uid: String?,
        resolver: (String) -> AudioDeviceID?
    ) -> AudioDeviceID? {
        explicitID ?? uid.flatMap(resolver)
    }

    /// UDP can deliver a final packet from a stale transport after a device has
    /// rejoined. Once a sequence has been consumed it must never be allowed
    /// back into `pending`, or the next hard resync can jump to that old packet.
    static func shouldAdmitPacket(
        sequence: UInt32,
        expectedSequence: UInt32?,
        isAlreadyPending: Bool
    ) -> Bool {
        guard !isAlreadyPending else { return false }
        guard let expectedSequence else { return true }
        guard sequence != expectedSequence else { return true }
        return Int32(bitPattern: sequence &- expectedSequence) > 0
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
        latestDriftMeasurement = nil
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

        guard let localCaptureNanos = RoomTiming.clientTimeNanos(hostTimeNanos: next.captureTimeNanos,
                                                                clockOffsetNanos: offset) else { return }
        let audibleTime = localCaptureNanos.addingReportingOverflow(targetLatencyNanos)
        guard !audibleTime.overflow else { return }
        let nextAudibleNanos = audibleTime.partialValue
        let nextRenderNanos = nextAudibleNanos > outputLatencyNanos
            ? nextAudibleNanos - outputLatencyNanos
            : nextAudibleNanos
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

}

struct PlaybackDriftRecovery {
    static let minimumSampleCount = 9
    static let maximumSampleCount = 21

    private var samples = [UInt64]()

    mutating func shouldResynchronize(latenessNanos: UInt64) -> Bool {
        samples.append(latenessNanos)
        if samples.count > Self.maximumSampleCount {
            samples.removeFirst(samples.count - Self.maximumSampleCount)
        }
        guard samples.count >= Self.minimumSampleCount else { return false }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        guard median >= SynchronizedPlayer.hardResyncThresholdNanos else { return false }
        reset()
        return true
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
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
