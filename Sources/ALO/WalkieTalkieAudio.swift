import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ALOCore

struct VoiceInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let isSystemDefault: Bool
    let isBluetooth: Bool
    let isBuiltIn: Bool

    init(
        id: String,
        name: String,
        isSystemDefault: Bool,
        isBluetooth: Bool = false,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isSystemDefault = isSystemDefault
        self.isBluetooth = isBluetooth
        self.isBuiltIn = isBuiltIn
    }

    var menuName: String {
        isBluetooth ? "\(name) · reduces Bluetooth playback quality" : name
    }
}

enum VoiceInputCatalog {
    static func isUsableInputFormat(sampleRate: Double, channelCount: UInt32) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    static func availableDevices() -> [VoiceInputDevice] {
        let defaultID = defaultInputDeviceID()
        let devices: [VoiceInputDevice] = allDeviceIDs().compactMap { deviceID in
            guard isAlive(deviceID),
                  !isHidden(deviceID),
                  isSupportedInputTransport(deviceID),
                  hasInput(deviceID),
                  let uid = VirtualAudioDevice.uid(for: deviceID),
                  uid != VirtualAudioDevice.uid,
                  let name = name(for: deviceID)
            else { return nil }
            let transport = transportType(for: deviceID)
            return VoiceInputDevice(
                id: uid,
                name: name,
                isSystemDefault: deviceID == defaultID,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn
            )
        }
        return sorted(devices)
    }

    static func systemDefaultName() -> String? {
        defaultInputDeviceID().flatMap(name(for:))
    }

    static func automaticInputName() -> String? {
        let devices = availableDevices()
        if let uid = automaticInputUID(in: devices) {
            return devices.first(where: { $0.id == uid })?.name
        }
        return devices.first(where: \.isSystemDefault)?.name
    }

    /// Capturing a Bluetooth headset microphone switches its playback route to
    /// the low-bandwidth two-way profile. Automatic mode keeps wireless output
    /// in its full-quality profile by preferring a non-Bluetooth microphone.
    static func automaticInputUID(in devices: [VoiceInputDevice]) -> String? {
        guard devices.first(where: \.isSystemDefault)?.isBluetooth == true else { return nil }
        return devices.first(where: \.isBuiltIn)?.id
            ?? devices.first(where: { !$0.isBluetooth })?.id
    }

    static func sorted(_ devices: [VoiceInputDevice]) -> [VoiceInputDevice] {
        devices.sorted {
            if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id < $1.id
        }
    }

    static func apply(_ uid: String?, to inputNode: AVAudioInputNode) throws {
        let effectiveUID = uid ?? automaticInputUID(in: availableDevices())
        guard let effectiveUID else { return }
        guard var deviceID = VirtualAudioDevice.deviceID(uid: effectiveUID),
              isAlive(deviceID), hasInput(deviceID)
        else { throw ALOError("The selected microphone is no longer available.") }
        // Let AVAudioEngine follow the system input normally. Setting the same
        // device explicitly forces a HAL route onto VoiceProcessingIO and can
        // leave its capture path running without producing frames.
        guard deviceID != defaultInputDeviceID() else { return }
        guard let audioUnit = inputNode.audioUnit else {
            throw ALOError("ALO could not prepare the selected microphone.")
        }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw ALOError("ALO could not use the selected microphone (OSStatus \(status)).")
        }
    }

    static func usesSystemDefault(_ uid: String?) -> Bool {
        guard let uid else { return true }
        guard let deviceID = VirtualAudioDevice.deviceID(uid: uid) else { return false }
        return deviceID == defaultInputDeviceID()
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        var devices = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func hasInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size
        else { return false }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }
        return UnsafeMutableAudioBufferListPointer(bufferList).contains { $0.mNumberChannels > 0 }
    }

    private static func isSupportedInputTransport(_ deviceID: AudioDeviceID) -> Bool {
        guard let transport = transportType(for: deviceID) else { return true }
        return transport != kAudioDeviceTransportTypeAggregate
            && transport != kAudioDeviceTransportTypeVirtual
    }

    private static func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return nil
        }
        return transport
    }

    private static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
            && value != 0
    }

    private static func isHidden(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
            && value != 0
    }

    private static func name(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String : nil
    }
}

/// Converts whichever hardware format the selected microphone actually
/// delivers into the stable full-band wire format. The source format is taken
/// from each tap buffer instead of a value read while Core Audio may still be
/// switching devices.
final class VoicePCMConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 8
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }
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
        else { return nil }
        return Data(
            bytes: samples,
            count: Int(converted.frameLength) * MemoryLayout<Int16>.size
        )
    }
}

final class WalkieTalkieMicrophone: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let packetFrames = 960

    private let queue = DispatchQueue(label: "in.werai.walkie-microphone", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var activeSessionID: String?
    private var configurationObserver: NSObjectProtocol?

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

    func start(
        sessionID: String,
        inputDeviceUID: String? = nil,
        handler: @escaping @Sendable (Data) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try self.startOnQueue(
                        sessionID: sessionID,
                        inputDeviceUID: inputDeviceUID,
                        handler: handler,
                        failureHandler: failureHandler
                    )
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop(sessionID: String? = nil) {
        queue.async { [weak self] in
            guard let self,
                  sessionID == nil || self.activeSessionID == sessionID
            else { return }
            self.stopOnQueue()
        }
    }

    private func startOnQueue(
        sessionID: String,
        inputDeviceUID: String?,
        handler: @escaping @Sendable (Data) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        stopOnQueue()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Use the hardware input unit directly. VoiceProcessingIO creates
        // transient aggregate devices and can report a running engine while
        // delivering no microphone frames on some Macs.
        try VoiceInputCatalog.apply(inputDeviceUID, to: input)
        let inputFormat = input.outputFormat(forBus: 0)
        guard VoiceInputCatalog.isUsableInputFormat(
            sampleRate: inputFormat.sampleRate,
            channelCount: inputFormat.channelCount
        ) else {
            throw ALOError("This Mac does not have an available microphone input.")
        }
        guard let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Self.sampleRate,
                  channels: 1,
                  interleaved: false
              )
        else { throw ALOError("This Mac does not have an available microphone input.") }

        let packetizer = VoicePacketizer(framesPerPacket: Self.packetFrames)
        let converter = VoicePCMConverter(outputFormat: outputFormat)
        // A nil tap format follows the input node's final hardware format. An
        // explicit format captured during a Bluetooth → built-in transition can
        // be stale and AVFAudio terminates the process on that mismatch.
        input.installTap(onBus: 0, bufferSize: 960, format: nil) { buffer, _ in
            guard let convertedData = converter.convert(buffer) else { return }
            for packet in packetizer.append(convertedData) {
                handler(packet)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        self.engine = engine
        activeSessionID = sessionID
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            self.queue.async {
                guard self.engine === engine, self.activeSessionID == sessionID else { return }
                do {
                    try self.startOnQueue(
                        sessionID: sessionID,
                        inputDeviceUID: inputDeviceUID,
                        handler: handler,
                        failureHandler: failureHandler
                    )
                } catch {
                    self.stopOnQueue()
                    failureHandler(error)
                }
            }
        }
    }

    private func stopOnQueue() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        activeSessionID = nil
    }

    deinit {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}

struct VoicePlaybackLeveler: Sendable {
    static let targetRMS: Float = 0.18
    static let noiseFloorRMS: Float = 0.01
    static let maximumGain: Float = 8
    static let peakCeiling: Float = 0.92
    static let gainAttack: Float = 0.10

    static func downwardRampFrameCount(
        sampleRate: Double,
        bufferFrameCount: Int
    ) -> Int {
        min(
            max(bufferFrameCount - 1, 0),
            max(1, Int((sampleRate / 1_000).rounded()))
        )
    }

    private(set) var gain: Float = 1

    mutating func process(_ buffer: AVAudioPCMBuffer, isConcealment: Bool = false) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        // Packet-loss concealment is synthetic silence, not a quiet microphone
        // callback. Preserve the current speech gain so one lost packet does
        // not make the following words fade back in over hundreds of ms.
        guard !isConcealment else { return }
        let count = Int(buffer.frameLength)
        var energy: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            energy += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(energy / Float(count))
        if rms < Self.noiseFloorRMS || peak == 0 {
            let previousGain = gain
            gain = 1
            guard peak > 0 else { return }
            for index in 0..<count {
                let progress = count > 1 ? Float(index) / Float(count - 1) : 1
                let rampedGain = previousGain + (gain - previousGain) * progress
                samples[index] = max(
                    -Self.peakCeiling,
                    min(Self.peakCeiling, samples[index] * rampedGain)
                )
            }
            return
        }

        let loudnessGain = max(1, Self.targetRMS / rms)
        let peakLimitedGain = Self.peakCeiling / peak
        let desiredGain = min(Self.maximumGain, loudnessGain, peakLimitedGain)
        let previousGain = gain
        // Reduce gain quickly before a loud transient. Raise it over a short
        // speech onset so room noise is not pumped between words.
        if desiredGain < gain {
            gain = desiredGain
        } else {
            gain += (desiredGain - gain) * Self.gainAttack
        }
        // Limit a downward transition to the first millisecond. This avoids a
        // buffer-boundary step while keeping the peak-limited portion short.
        let downwardRampFrames = Self.downwardRampFrameCount(
            sampleRate: buffer.format.sampleRate,
            bufferFrameCount: count
        )

        for index in 0..<count {
            let progress: Float
            if desiredGain < previousGain {
                progress = downwardRampFrames > 0
                    ? min(1, Float(index) / Float(downwardRampFrames))
                    : 1
            } else {
                progress = count > 1 ? Float(index) / Float(count - 1) : 1
            }
            let rampedGain = previousGain + (gain - previousGain) * progress
            samples[index] = max(
                -Self.peakCeiling,
                min(Self.peakCeiling, samples[index] * rampedGain)
            )
        }
    }
}

/// Turns converter output (whose size follows the hardware callback) into stable
/// 20 ms wire packets. The input tap invokes this object serially.
final class VoicePacketizer: @unchecked Sendable {
    let framesPerPacket: Int
    private var pending = Data()

    init(framesPerPacket: Int = WalkieTalkieMicrophone.packetFrames) {
        self.framesPerPacket = framesPerPacket
    }

    var bytesPerPacket: Int { framesPerPacket * MemoryLayout<Int16>.size }
    var pendingByteCount: Int { pending.count }

    func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        pending.append(data)
        var packets = [Data]()
        while pending.count >= bytesPerPacket {
            packets.append(Data(pending.prefix(bytesPerPacket)))
            pending.removeFirst(bytesPerPacket)
        }
        return packets
    }
}

struct WalkieTalkiePlaybackTracker {
    private(set) var lastSequences = [String: UInt64]()

    mutating func begin(_ sessionID: String) { lastSequences[sessionID] = 0 }

    mutating func accepts(sessionID: String, sequence: UInt64) -> Bool {
        let last = lastSequences[sessionID] ?? 0
        guard sequence > last else { return false }
        lastSequences[sessionID] = sequence
        return true
    }

    mutating func end(_ sessionID: String) { lastSequences.removeValue(forKey: sessionID) }

    static func shouldDropIncomingBuffer(
        scheduledFrames: AVAudioFramePosition,
        incomingFrames: AVAudioFramePosition,
        maximumFrames: AVAudioFramePosition
    ) -> Bool {
        scheduledFrames + incomingFrames > maximumFrames
    }
}

struct VoicePlaybackSessionLifecycle {
    private(set) var isEnding = false
    var shouldDropAudio: Bool { isEnding }

    mutating func markEnding() { isEnding = true }

    mutating func beginRequiresReplacement() -> Bool {
        defer { isEnding = false }
        return isEnding
    }
}

struct VoiceLevelMeter {
    static func normalizedLevel(fromPCM16Mono data: Data) -> Double {
        guard !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<Int16>.size)
        else { return 0 }

        var sumOfSquares = 0.0
        let sampleCount = data.count / MemoryLayout<Int16>.size
        data.withUnsafeBytes { bytes in
            for index in 0..<sampleCount {
                let offset = index * MemoryLayout<Int16>.size
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let sample = Double(Int16(bitPattern: bits)) / 32_768
                sumOfSquares += sample * sample
            }
        }

        let rms = sqrt(sumOfSquares / Double(sampleCount))
        guard rms > 0.000_1 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 48) / 40))
    }
}

struct VoiceLevelEnvelope {
    private(set) var level = 0.0

    mutating func update(target: Double) -> Double {
        let target = min(1, max(0, target))
        let response = target > level ? 0.5 : 0.16
        level += (target - level) * response
        return level
    }

    mutating func reset() { level = 0 }
}

struct VoiceJitterBuffer {
    enum Output: Equatable {
        case audio(Data)
        case silence(frames: Int)
    }

    let startupPacketCount: Int
    let maximumGapPackets: UInt64
    let maximumPendingPackets: Int
    let concealmentFrames: Int
    private(set) var expectedSequence: UInt64?
    private(set) var isStarted = false
    private(set) var pending = [UInt64: Data]()
    private(set) var lateDropCount = 0
    private(set) var concealedPacketCount = 0

    init(
        startupPacketCount: Int = 4,
        maximumGapPackets: UInt64 = 2,
        maximumPendingPackets: Int = 8,
        concealmentFrames: Int = WalkieTalkieMicrophone.packetFrames
    ) {
        self.startupPacketCount = max(1, startupPacketCount)
        self.maximumGapPackets = max(1, maximumGapPackets)
        self.maximumPendingPackets = max(self.startupPacketCount, maximumPendingPackets)
        self.concealmentFrames = max(1, concealmentFrames)
    }

    mutating func insert(sequence: UInt64, data: Data) -> [Output] {
        if isStarted, let expectedSequence, sequence < expectedSequence {
            lateDropCount += 1
            return []
        }
        guard pending[sequence] == nil else {
            lateDropCount += 1
            return []
        }
        pending[sequence] = data
        while pending.count > maximumPendingPackets, let oldest = pending.keys.min() {
            pending.removeValue(forKey: oldest)
            lateDropCount += 1
        }

        if !isStarted {
            expectedSequence = pending.keys.min()
            guard contiguousPacketCount() >= startupPacketCount else { return [] }
            isStarted = true
        }
        return drain(force: false)
    }

    mutating func finish() -> [Output] {
        guard !pending.isEmpty else { return [] }
        if expectedSequence == nil { expectedSequence = pending.keys.min() }
        isStarted = true
        return drain(force: true)
    }

    mutating func resetForRouteChange() {
        expectedSequence = nil
        isStarted = false
        pending.removeAll(keepingCapacity: true)
    }

    private func contiguousPacketCount() -> Int {
        guard var sequence = expectedSequence else { return 0 }
        var count = 0
        while pending[sequence] != nil {
            count += 1
            sequence &+= 1
        }
        return count
    }

    private mutating func drain(force: Bool) -> [Output] {
        var output = [Output]()
        while let expected = expectedSequence {
            if let data = pending.removeValue(forKey: expected) {
                output.append(.audio(data))
                expectedSequence = expected &+ 1
                continue
            }
            guard let next = pending.keys.min(), next > expected else { break }
            let gap = next - expected
            if gap <= maximumGapPackets, force || pending.count >= 2 {
                output.append(.silence(frames: concealmentFrames))
                concealedPacketCount += 1
                expectedSequence = expected &+ 1
                continue
            }
            if gap > maximumGapPackets {
                lateDropCount += Int(min(gap, UInt64(Int.max)))
                expectedSequence = next
                continue
            }
            break
        }
        return output
    }
}

final class WalkieTalkiePlayer: @unchecked Sendable {
    private final class Session {
        let id: String
        let senderID: String
        var senderName: String
        let sampleRate: Double
        let player: AVAudioPlayerNode
        var scheduledFrames: AVAudioFramePosition = 0
        var jitter: VoiceJitterBuffer
        var isActive = false
        var lifecycle = VoicePlaybackSessionLifecycle()
        var levelEnvelope = VoiceLevelEnvelope()
        var leveler = VoicePlaybackLeveler()
        var lastPublishedLevel = 0.0
        var lastLevelPublication: UInt64 = 0
        var timeoutWorkItem: DispatchWorkItem?
        var inactivityWorkItem: DispatchWorkItem?

        init(
            id: String,
            senderID: String,
            senderName: String,
            sampleRate: Double,
            player: AVAudioPlayerNode
        ) {
            self.id = id
            self.senderID = senderID
            self.senderName = senderName
            self.sampleRate = sampleRate
            self.player = player
            jitter = VoiceJitterBuffer(
                concealmentFrames: Int((sampleRate * 0.020).rounded())
            )
        }
    }

    private let queue = DispatchQueue(label: "in.werai.walkie-playback", qos: .userInteractive)
    private let audioOutput: RoomAudioOutputEngine
    private var engine: AVAudioEngine { audioOutput.engine }
    var outputEngineIdentityForTesting: ObjectIdentifier { audioOutput.identity }
    static let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: WalkieTalkieMicrophone.sampleRate,
        channels: 1
    )!
    private let stateHandler: @Sendable (String, String, String, Bool, Double) -> Void
    private var sessions = [String: Session]()
    private var tracker = WalkieTalkiePlaybackTracker()
    private var configurationObserver: NSObjectProtocol?
    private var configurationRecoveryWorkItem: DispatchWorkItem?
    private var configurationRecoveryPending = false
    private var deferredRecoveryMessages = [WalkieTalkieMessage]()
    private var muted = false

    static func makePlaybackBuffer(
        fromPCM16Mono data: Data,
        sampleRate: Double = WalkieTalkieMicrophone.sampleRate
    ) -> AVAudioPCMBuffer? {
        guard !data.isEmpty,
              data.count <= 8_192,
              data.count.isMultiple(of: MemoryLayout<Int16>.size),
              (8_000...96_000).contains(sampleRate),
              let playbackFormat = AVAudioFormat(
                  standardFormatWithSampleRate: sampleRate,
                  channels: 1
              )
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

    init(
        audioOutput: RoomAudioOutputEngine = RoomAudioOutputEngine(),
        stateHandler: @escaping @Sendable (String, String, String, Bool, Double) -> Void = { _, _, _, _, _ in }
    ) {
        self.audioOutput = audioOutput
        self.stateHandler = stateHandler
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.scheduleConfigurationRecovery() }
        }
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
            if muted { self.stopAllOnQueue() }
        }
    }

    func stop() {
        queue.sync { stopAllOnQueue() }
    }

    private func acceptOnQueue(_ message: WalkieTalkieMessage) {
        if configurationRecoveryPending {
            // AVAudioPlayerNode clears scheduled buffers when its engine's route
            // changes. Hold the small wireless settle window instead of
            // restarting on an intermediate format or silently dropping speech.
            deferredRecoveryMessages.append(message)
            if deferredRecoveryMessages.count > 32 {
                if let audioIndex = deferredRecoveryMessages.firstIndex(where: { $0.kind == .audio }) {
                    deferredRecoveryMessages.remove(at: audioIndex)
                } else {
                    deferredRecoveryMessages.removeFirst()
                }
            }
            return
        }
        switch message.kind {
        case .began:
            _ = beginSession(message)
        case .audio:
            guard let data = message.pcm16Mono,
                  !data.isEmpty,
                  data.count <= 8_192,
                  data.count.isMultiple(of: MemoryLayout<Int16>.size)
            else { return }
            // Reliable delivery can still be reordered across relayed mesh
            // paths. Never let a straggler revive and replace a session whose
            // final buffers are deliberately draining; a new `.began` is the
            // only message allowed to start that session ID again.
            if sessions[message.sessionID]?.lifecycle.shouldDropAudio == true { return }
            let session = beginSession(message)
            guard let session else { return }
            session.senderName = message.senderName
            let output = session.jitter.insert(sequence: message.sequence, data: data)
            schedule(output, for: session)
            armTimeout(for: session)
        case .ended:
            finishSession(message.sessionID)
        }
    }

    @discardableResult
    private func beginSession(_ message: WalkieTalkieMessage) -> Session? {
        let sampleRate = Double(message.resolvedSampleRate)
        if let existing = sessions[message.sessionID] {
            if abs(existing.sampleRate - sampleRate) >= 1
                || existing.lifecycle.beginRequiresReplacement() {
                // A target can be removed and re-added quickly while the final
                // buffers from its `.ended` message are still rendering. Replace
                // the old object so its callbacks cannot mutate the revived
                // session, and give the new stream a fresh jitter timeline.
                stopSession(message.sessionID)
            } else {
                existing.senderName = message.senderName
                armTimeout(for: existing)
                return existing
            }
        }
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else { return nil }
        audioOutput.withGraph { engine in
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        audioOutput.retainClient()
        guard ensureEngineRunning() else {
            audioOutput.withGraph { engine in
                engine.disconnectNodeOutput(player)
                engine.detach(player)
            }
            audioOutput.releaseClient()
            return nil
        }
        let session = Session(
            id: message.sessionID,
            senderID: message.senderID,
            senderName: message.senderName,
            sampleRate: sampleRate,
            player: player
        )
        sessions[message.sessionID] = session
        tracker.begin(message.sessionID)
        armTimeout(for: session)
        return session
    }

    private func schedule(_ output: [VoiceJitterBuffer.Output], for session: Session) {
        for item in output {
            let data: Data
            let isConcealment: Bool
            switch item {
            case .audio(let audio):
                data = audio
                isConcealment = false
            case .silence(let frames):
                data = Data(count: frames * MemoryLayout<Int16>.size)
                isConcealment = true
            }
            schedule(data, for: session, isConcealment: isConcealment)
        }
    }

    private func schedule(
        _ data: Data,
        for session: Session,
        isConcealment: Bool = false
    ) {
        guard ensureEngineRunning() else {
            stopSession(session.id)
            return
        }
        guard let buffer = Self.makePlaybackBuffer(
            fromPCM16Mono: data,
            sampleRate: session.sampleRate
        ) else { return }
        session.leveler.process(buffer, isConcealment: isConcealment)
        let frames = buffer.frameLength
        let maximumBufferedFrames = AVAudioFramePosition(session.sampleRate * 0.20)

        if WalkieTalkiePlaybackTracker.shouldDropIncomingBuffer(
            scheduledFrames: session.scheduledFrames,
            incomingFrames: AVAudioFramePosition(frames),
            maximumFrames: maximumBufferedFrames
        ) {
            // Keep already-queued speech continuous. Dropping this newest frame
            // bounds latency without flushing the player's render queue.
            return
        }
        session.scheduledFrames += AVAudioFramePosition(frames)
        session.inactivityWorkItem?.cancel()
        session.inactivityWorkItem = nil
        let sessionID = session.id
        session.player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            self?.queue.async {
                guard let self,
                      let current = self.sessions[sessionID],
                      current === session
                else { return }
                current.scheduledFrames = max(0, current.scheduledFrames - AVAudioFramePosition(frames))
                if current.scheduledFrames == 0 {
                    if current.lifecycle.isEnding { self.stopSession(sessionID) }
                    else { self.armPlaybackInactivity(for: current) }
                }
            }
        }
        if !session.player.isPlaying, audioOutput.isRunning { session.player.play() }
        let level = session.levelEnvelope.update(target: VoiceLevelMeter.normalizedLevel(fromPCM16Mono: data))
        if session.isActive {
            publishLevelIfNeeded(for: session, level: level)
        } else {
            setSessionActive(session, true)
        }
    }

    private func ensureEngineRunning() -> Bool {
        do {
            try audioOutput.ensureRunning()
            return audioOutput.isRunning
        } catch {
            return false
        }
    }

    private func recoverAfterConfigurationChange() {
        let deferred = deferredRecoveryMessages
        deferredRecoveryMessages.removeAll(keepingCapacity: true)
        if sessions.isEmpty {
            // A configuration notification is not an output client. Starting
            // an empty AVAudioEngine can both hold a Bluetooth route forever
            // and raise an AVFAudio exception because it has no graph nodes.
            // Replay any speech that arrived during the settle window; its
            // session will attach a node, retain the output, and start it.
            configurationRecoveryPending = false
            for message in deferred { acceptOnQueue(message) }
            return
        }
        audioOutput.withGraph { engine in
            for session in sessions.values {
                guard let format = AVAudioFormat(
                    standardFormatWithSampleRate: session.sampleRate,
                    channels: 1
                ) else { continue }
                engine.disconnectNodeOutput(session.player)
                engine.connect(session.player, to: engine.mainMixerNode, format: format)
            }
        }
        guard ensureEngineRunning() else {
            configurationRecoveryPending = false
            deferredRecoveryMessages.removeAll()
            stopAllOnQueue()
            return
        }
        for session in sessions.values where !session.player.isPlaying {
            session.player.play()
        }
        configurationRecoveryPending = false
        for message in deferred { acceptOnQueue(message) }
    }

    private func scheduleConfigurationRecovery() {
        if !configurationRecoveryPending {
            configurationRecoveryPending = true
            for session in sessions.values {
                session.player.stop()
                session.scheduledFrames = 0
                session.jitter.resetForRouteChange()
                setSessionActive(session, false)
            }
        }
        configurationRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            configurationRecoveryWorkItem = nil
            recoverAfterConfigurationChange()
        }
        configurationRecoveryWorkItem = work
        // Wireless routes can publish several intermediate formats while they
        // settle. Coalesce that burst and reconnect once to the final format.
        queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func armTimeout(for session: Session) {
        session.timeoutWorkItem?.cancel()
        let sessionID = session.id
        let work = DispatchWorkItem { [weak self] in self?.stopSession(sessionID) }
        session.timeoutWorkItem = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Network delivery and render callbacks do not land at perfectly even
    /// intervals. A short hangover keeps the speaking indicator stable between
    /// otherwise-continuous 20 ms packets.
    private func armPlaybackInactivity(for session: Session) {
        session.inactivityWorkItem?.cancel()
        let sessionID = session.id
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session,
                  self.sessions[sessionID] === session,
                  session.scheduledFrames == 0,
                  !session.lifecycle.isEnding
            else { return }
            self.setSessionActive(session, false)
        }
        session.inactivityWorkItem = work
        queue.asyncAfter(deadline: .now() + .milliseconds(180), execute: work)
    }

    private func finishSession(_ id: String) {
        guard let session = sessions[id] else {
            tracker.end(id)
            return
        }
        session.lifecycle.markEnding()
        session.timeoutWorkItem?.cancel()
        session.inactivityWorkItem?.cancel()
        schedule(session.jitter.finish(), for: session)
        if session.scheduledFrames == 0 { stopSession(id) }
    }

    private func setSessionActive(_ session: Session, _ active: Bool) {
        guard session.isActive != active else { return }
        session.isActive = active
        if active {
            publishLevel(for: session, level: session.levelEnvelope.level)
        } else {
            session.levelEnvelope.reset()
            session.lastPublishedLevel = 0
            stateHandler(session.id, session.senderID, session.senderName, false, 0)
        }
    }

    private func publishLevelIfNeeded(for session: Session, level: Double) {
        let now = DispatchTime.now().uptimeNanoseconds
        let minimumInterval: UInt64 = 66_000_000
        guard now &- session.lastLevelPublication >= minimumInterval else { return }
        guard abs(level - session.lastPublishedLevel) >= 0.015 else { return }
        publishLevel(for: session, level: level, now: now)
    }

    private func publishLevel(for session: Session, level: Double, now: UInt64? = nil) {
        session.lastPublishedLevel = level
        session.lastLevelPublication = now ?? DispatchTime.now().uptimeNanoseconds
        stateHandler(session.id, session.senderID, session.senderName, true, level)
    }

    private func stopSession(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else {
            tracker.end(id)
            return
        }
        session.timeoutWorkItem?.cancel()
        session.player.stop()
        audioOutput.withGraph { engine in
            engine.disconnectNodeOutput(session.player)
            engine.detach(session.player)
        }
        audioOutput.releaseClient()
        tracker.end(id)
        setSessionActive(session, false)
    }

    private func stopAllOnQueue() {
        configurationRecoveryWorkItem?.cancel()
        configurationRecoveryWorkItem = nil
        configurationRecoveryPending = false
        deferredRecoveryMessages.removeAll()
        for id in Array(sessions.keys) { stopSession(id) }
    }

    deinit {
        configurationRecoveryWorkItem?.cancel()
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        let remainingSessions = Array(sessions.values)
        audioOutput.withGraph { engine in
            for session in remainingSessions {
                session.timeoutWorkItem?.cancel()
                session.inactivityWorkItem?.cancel()
                session.player.stop()
                engine.disconnectNodeOutput(session.player)
                engine.detach(session.player)
            }
        }
        for _ in remainingSessions {
            audioOutput.releaseClient()
        }
    }
}
