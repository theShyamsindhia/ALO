import AVFoundation
import CoreAudio
import Foundation
import WERAICore
import WERAISharedAudioClient

@available(macOS 14.2, *)
struct TapCaptureLivenessWatchdog {
    private let timeoutNanos: UInt64
    private var latestFrame: UInt64 = 0
    private var lastProgressNanos: UInt64
    private var didReportFailure = false

    init(
        startedAtNanos: UInt64,
        timeoutNanos: UInt64 = 2_000_000_000
    ) {
        lastProgressNanos = startedAtNanos
        self.timeoutNanos = timeoutNanos
    }

    mutating func observe(latestFrame: UInt64, nowNanos: UInt64) -> Bool {
        guard !didReportFailure else { return false }
        if latestFrame != self.latestFrame {
            self.latestFrame = latestFrame
            lastProgressNanos = nowNanos
            return false
        }
        guard nowNanos >= lastProgressNanos,
              nowNanos - lastProgressNanos >= timeoutNanos
        else { return false }
        didReportFailure = true
        return true
    }
}

@available(macOS 14.2, *)
struct TapStreamConfiguration: Equatable {
    let sampleRate: Double
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32

    init(_ description: AudioStreamBasicDescription) {
        sampleRate = description.mSampleRate
        formatID = description.mFormatID
        formatFlags = description.mFormatFlags
        bytesPerPacket = description.mBytesPerPacket
        framesPerPacket = description.mFramesPerPacket
        bytesPerFrame = description.mBytesPerFrame
        channelsPerFrame = description.mChannelsPerFrame
        bitsPerChannel = description.mBitsPerChannel
    }
}

@available(macOS 14.2, *)
enum SystemAudioTapCaptureError: LocalizedError {
    case coreAudio(operation: String, status: OSStatus)

    var isPermissionFailure: Bool {
        switch self {
        case let .coreAudio(_, status):
            return status == kAudioDevicePermissionsError
        }
    }

    var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            return "Could not \(operation) (Core Audio error \(status))."
        }
    }
}

/// One authoritative system-audio path for synchronized broadcasting.
///
/// The process tap both suppresses the source application's immediate render
/// and supplies the PCM sent to HostServer. This invariant is essential: using
/// a muting tap while ScreenCaptureKit captures separately can starve the room.
@available(macOS 14.2, *)
final class SystemAudioTapCapture: AudioSource, @unchecked Sendable {
    private let setupQueue = DispatchQueue(label: "in.werai.audio.system-tap.setup", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "in.werai.audio.system-tap", qos: .userInteractive)
    private let deliveryQueue = DispatchQueue(label: "in.werai.audio.system-tap.delivery", qos: .userInteractive)
    private let deliveryQueueKey = DispatchSpecificKey<UInt8>()
    private let unexpectedStopHandler: @Sendable (Error) -> Void
    private let stateLock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapFormatConfiguration: TapStreamConfiguration?
    private var tapFormatListener: AudioObjectPropertyListenerBlock?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioHandler: AudioHandler?
    private var converter: TapPCMConverter?
    private var ring: ALOTapAudioRingHandle?
    private var deliveryTimer: DispatchSourceTimer?
    private var nextRingFrame: UInt64 = 0
    private var inputIsNonInterleaved = false
    private var hostTicksPerFrame = 0.0
    private var stopping = false
    private var unexpectedFailureReported = false
    private var livenessWatchdog = TapCaptureLivenessWatchdog(
        startedAtNanos: MonotonicClock.nowNanos()
    )

    init(unexpectedStopHandler: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.unexpectedStopHandler = unexpectedStopHandler
        deliveryQueue.setSpecific(key: deliveryQueueKey, value: 1)
    }

    func start(audioHandler: @escaping AudioHandler) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setupQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try self.startSynchronously(audioHandler: audioHandler)
                    continuation.resume(returning: ())
                } catch {
                    self.stopSynchronously()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws {
        await withCheckedContinuation { continuation in
            setupQueue.async { [weak self] in
                self?.stopSynchronously()
                continuation.resume()
            }
        }
    }

    deinit {
        stopSynchronously()
    }

    private func startSynchronously(audioHandler: @escaping AudioHandler) throws {
        guard tapID == kAudioObjectUnknown else { return }
        guard let ownProcessID = Self.audioObjectID(forPID: getpid()) else {
            throw WERAIError("ALO could not identify its own Core Audio process.")
        }

        stateLock.withLock {
            stopping = false
            unexpectedFailureReported = false
            self.audioHandler = audioHandler
        }
        livenessWatchdog = TapCaptureLivenessWatchdog(
            startedAtNanos: MonotonicClock.nowNanos()
        )

        let description = Self.tapDescription(excluding: ownProcessID)

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateProcessTap(description, &newTapID),
            operation: "create the synchronized system-audio tap"
        )
        tapID = newTapID

        let inputDescription = try Self.audioFormatProperty(
            objectID: tapID,
            selector: kAudioTapPropertyFormat
        )
        guard inputDescription.mFormatID == kAudioFormatLinearPCM,
              inputDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              inputDescription.mBitsPerChannel == 32,
              inputDescription.mChannelsPerFrame == UInt32(AudioPacket.channelCount),
              inputDescription.mSampleRate > 0,
              let ring = ALOTapAudioRingCreate()
        else {
            throw WERAIError("ALO received an unsupported system-audio tap format.")
        }
        self.ring = ring
        tapFormatConfiguration = TapStreamConfiguration(inputDescription)
        inputIsNonInterleaved = inputDescription.mFormatFlags
            & kAudioFormatFlagIsNonInterleaved != 0
        hostTicksPerFrame = AudioGetHostClockFrequency() / inputDescription.mSampleRate
        converter = try TapPCMConverter(inputSampleRate: inputDescription.mSampleRate)
        try installTapFormatListener()

        let tapUID = try Self.stringProperty(
            objectID: tapID,
            selector: kAudioTapPropertyUID
        )
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ALO Private Synchronized Audio",
            kAudioAggregateDeviceUIDKey: "in.werai.audio.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &newAggregateID
            ),
            operation: "create the synchronized system-audio device"
        )
        aggregateID = newAggregateID
        try Self.waitForInputStream(on: aggregateID)

        var newIOProcID: AudioDeviceIOProcID?
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(
                &newIOProcID,
                aggregateID,
                ioQueue
            ) { [weak self] _, inputData, inputTime, _, _ in
                self?.consumeRealtime(inputData: inputData, inputTime: inputTime)
            },
            operation: "read synchronized system audio"
        )
        ioProcID = newIOProcID
        try Self.check(
            AudioDeviceStart(aggregateID, ioProcID),
            operation: "start synchronized system audio"
        )
        startDeliveryTimer()
    }

    /// This runs in Core Audio's synchronous IO callback. Keep it bounded: no
    /// allocations, locks, conversion, Swift arrays, or calls into HostServer.
    private func consumeRealtime(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let ring else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let frameCount: UInt32
        if inputIsNonInterleaved {
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return }
            frameCount = buffers[0].mDataByteSize / UInt32(MemoryLayout<Float>.size)
            guard frameCount > 0 else { return }
            ALOTapAudioRingWritePlanarFloat(
                ring,
                left,
                right,
                frameCount,
                Self.hostTime(from: inputTime),
                hostTicksPerFrame
            )
        } else {
            guard let buffer = buffers.first,
                  let samples = buffer.mData?.assumingMemoryBound(to: Float.self)
            else { return }
            frameCount = buffer.mDataByteSize
                / UInt32(MemoryLayout<Float>.size * Int(AudioPacket.channelCount))
            guard frameCount > 0 else { return }
            ALOTapAudioRingWriteInterleavedFloat(
                ring,
                samples,
                frameCount,
                Self.hostTime(from: inputTime),
                hostTicksPerFrame
            )
        }
    }

    private static func hostTime(from inputTime: UnsafePointer<AudioTimeStamp>) -> UInt64 {
        let timestamp = inputTime.pointee
        if timestamp.mFlags.contains(.hostTimeValid), timestamp.mHostTime != 0 {
            return timestamp.mHostTime
        }
        return AudioGetCurrentHostTime()
    }

    private func startDeliveryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: deliveryQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drainRing() }
        deliveryTimer = timer
        timer.resume()
    }

    private func drainRing() {
        guard let ring, let converter else { return }
        let latest = ALOTapAudioRingLatestFrame(ring)
        let now = MonotonicClock.nowNanos()
        if livenessWatchdog.observe(latestFrame: latest, nowNanos: now) {
            reportUnexpectedStop(WERAIError(
                "System audio stopped arriving from Core Audio. Start broadcasting again."
            ))
            return
        }
        let capacity = ALOTapAudioRingCapacity()
        if latest > nextRingFrame &+ capacity {
            nextRingFrame = latest - capacity
        }
        guard latest > nextRingFrame else { return }

        let maximumFrames = UInt32(min(latest - nextRingFrame, 960))
        var input = [Float](
            repeating: 0,
            count: Int(maximumFrames) * Int(AudioPacket.channelCount)
        )
        var firstHostTime: UInt64 = 0
        let frameCount = input.withUnsafeMutableBufferPointer { samples in
            ALOTapAudioRingRead(
                ring,
                nextRingFrame,
                samples.baseAddress,
                maximumFrames,
                &firstHostTime
            )
        }
        guard frameCount > 0 else {
            let newest = ALOTapAudioRingLatestFrame(ring)
            nextRingFrame = newest > capacity ? newest - capacity : newest
            return
        }
        nextRingFrame &+= UInt64(frameCount)
        if frameCount < maximumFrames {
            input.removeLast(Int(maximumFrames - frameCount) * Int(AudioPacket.channelCount))
        }
        guard let samples = converter.convert(interleavedSamples: input), !samples.isEmpty else {
            return
        }
        let captureTimeNanos = firstHostTime == 0
            ? MonotonicClock.nowNanos()
            : MonotonicClock.ticksToNanos(firstHostTime)
        let handler = stateLock.withLock { stopping ? nil : audioHandler }
        handler?(samples, captureTimeNanos)
    }

    private func stopSynchronously() {
        stateLock.withLock {
            stopping = true
            audioHandler = nil
        }
        deliveryTimer?.setEventHandler {}
        deliveryTimer?.cancel()
        deliveryTimer = nil
        if tapID != kAudioObjectUnknown, let tapFormatListener {
            var address = Self.propertyAddress(selector: kAudioTapPropertyFormat)
            let removeStatus = AudioObjectRemovePropertyListenerBlock(
                tapID,
                &address,
                setupQueue,
                tapFormatListener
            )
            Self.logTeardownFailure(
                removeStatus,
                operation: "remove the synchronized audio format observer"
            )
            if removeStatus == noErr { self.tapFormatListener = nil }
        }
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            Self.logTeardownFailure(
                AudioDeviceStop(aggregateID, ioProcID),
                operation: "stop synchronized system audio"
            )
            let destroyStatus = Self.retryTeardown {
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            Self.logTeardownFailure(
                destroyStatus,
                operation: "destroy the synchronized audio callback"
            )
            if destroyStatus == noErr { self.ioProcID = nil }
        }
        if aggregateID != kAudioObjectUnknown, ioProcID == nil {
            let destroyStatus = Self.retryTeardown {
                AudioHardwareDestroyAggregateDevice(aggregateID)
            }
            Self.logTeardownFailure(
                destroyStatus,
                operation: "destroy the synchronized system-audio device"
            )
            if destroyStatus == noErr {
                aggregateID = AudioObjectID(kAudioObjectUnknown)
            }
        }
        if tapID != kAudioObjectUnknown, aggregateID == kAudioObjectUnknown {
            let destroyStatus = Self.retryTeardown {
                AudioHardwareDestroyProcessTap(tapID)
            }
            Self.logTeardownFailure(
                destroyStatus,
                operation: "destroy the synchronized system-audio tap"
            )
            if destroyStatus == noErr {
                tapID = AudioObjectID(kAudioObjectUnknown)
                tapFormatListener = nil
                tapFormatConfiguration = nil
            }
        }
        if DispatchQueue.getSpecific(key: deliveryQueueKey) == nil {
            deliveryQueue.sync {}
        }
        // If Core Audio still owns the IOProc block, it may still enter the
        // real-time callback. Retain its backing state rather than creating a
        // use-after-free; a later stop retries the detach.
        if ioProcID == nil {
            if let ring {
                ALOTapAudioRingDestroy(ring)
                self.ring = nil
            }
            converter = nil
            nextRingFrame = 0
        }
    }

    private func installTapFormatListener() throws {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleTapFormatChange()
        }
        var address = Self.propertyAddress(selector: kAudioTapPropertyFormat)
        try Self.check(
            AudioObjectAddPropertyListenerBlock(
                tapID,
                &address,
                setupQueue,
                listener
            ),
            operation: "observe the synchronized system-audio format"
        )
        tapFormatListener = listener
    }

    private func handleTapFormatChange() {
        guard tapID != kAudioObjectUnknown,
              let expected = tapFormatConfiguration
        else { return }
        do {
            let current = try Self.audioFormatProperty(
                objectID: tapID,
                selector: kAudioTapPropertyFormat
            )
            guard TapStreamConfiguration(current) != expected else { return }
            reportUnexpectedStop(WERAIError(
                "The system audio format changed. Start broadcasting again to resynchronize."
            ))
        } catch {
            reportUnexpectedStop(error)
        }
    }

    private func reportUnexpectedStop(_ error: Error) {
        let shouldReport = stateLock.withLock { () -> Bool in
            guard !stopping, !unexpectedFailureReported else { return false }
            unexpectedFailureReported = true
            return true
        }
        if shouldReport { unexpectedStopHandler(error) }
    }

    private static func audioObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = propertyAddress(selector: kAudioHardwarePropertyTranslatePIDToProcessObject)
        var processID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &processID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &size,
                &objectID
            )
        }
        return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
    }

    static func tapDescription(excluding ownProcessID: AudioObjectID) -> CATapDescription {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [ownProcessID]
        )
        description.name = "ALO synchronized system audio"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    private static func audioFormatProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(selector: selector)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            operation: "read the system-audio tap format"
        )
        return value
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> CFString {
        var address = propertyAddress(selector: selector)
        var size = UInt32(MemoryLayout<CFString>.stride)
        var value: CFString = "" as CFString
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(
                AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer),
                operation: "read the system-audio tap identifier"
            )
        }
        return value
    }

    private static func waitForInputStream(on deviceID: AudioObjectID) throws {
        var address = propertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeInput
        )
        for _ in 0..<50 {
            var size: UInt32 = 0
            if AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
               size >= UInt32(MemoryLayout<AudioObjectID>.stride) {
                return
            }
            usleep(20_000)
        }
        throw WERAIError("The synchronized system-audio device did not become ready.")
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw SystemAudioTapCaptureError.coreAudio(
                operation: operation,
                status: status
            )
        }
    }

    private static func logTeardownFailure(_ status: OSStatus, operation: String) {
        guard status != noErr else { return }
        fputs("ALO: Could not \(operation) (Core Audio error \(status)).\n", stderr)
    }

    private static func retryTeardown(
        attempts: Int = 3,
        _ operation: () -> OSStatus
    ) -> OSStatus {
        var status = operation()
        guard status != noErr else { return status }
        for _ in 1..<attempts {
            usleep(20_000)
            status = operation()
            if status == noErr { break }
        }
        return status
    }
}

@available(macOS 14.2, *)
final class TapPCMConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(inputSampleRate: Double) throws {
        guard let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputSampleRate,
                channels: AVAudioChannelCount(AudioPacket.channelCount),
                interleaved: true
              ),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(AudioPacket.sampleRate),
                channels: AVAudioChannelCount(AudioPacket.channelCount),
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw WERAIError("ALO could not convert the system-audio tap to 48 kHz stereo.")
        }
        converter.primeMethod = .none
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(interleavedSamples: [Float]) -> [Int16]? {
        guard !interleavedSamples.isEmpty,
              interleavedSamples.count.isMultiple(of: Int(AudioPacket.channelCount))
        else { return nil }
        let frameCount = AVAudioFrameCount(
            interleavedSamples.count / Int(AudioPacket.channelCount)
        )
        guard let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: frameCount
        ) else { return nil }
        input.frameLength = frameCount
        let inputBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        guard inputBuffers.count == 1, let inputData = inputBuffers[0].mData else { return nil }
        interleavedSamples.withUnsafeBytes { source in
            if let sourceBase = source.baseAddress {
                memcpy(inputData, sourceBase, source.count)
            }
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard buffers.count == 1, let data = buffers[0].mData else { return nil }
        let sampleCount = Int(output.frameLength) * Int(AudioPacket.channelCount)
        return Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Int16.self),
            count: sampleCount
        ))
    }
}
