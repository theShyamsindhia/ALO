import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import WERAICore

struct VoiceInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let isSystemDefault: Bool
}

enum VoiceInputCatalog {
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
            return VoiceInputDevice(id: uid, name: name, isSystemDefault: deviceID == defaultID)
        }
        return sorted(devices)
    }

    static func systemDefaultName() -> String? {
        defaultInputDeviceID().flatMap(name(for:))
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
        guard let uid else { return }
        guard var deviceID = VirtualAudioDevice.deviceID(uid: uid),
              isAlive(deviceID), hasInput(deviceID)
        else { throw WERAIError("The selected microphone is no longer available.") }
        // Let AVAudioEngine follow the system input normally. Setting the same
        // device explicitly forces a HAL route onto VoiceProcessingIO and can
        // leave its capture path running without producing frames.
        guard deviceID != defaultInputDeviceID() else { return }
        guard let audioUnit = inputNode.audioUnit else {
            throw WERAIError("ALO could not prepare the selected microphone.")
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
            throw WERAIError("ALO could not use the selected microphone (OSStatus \(status)).")
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
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return true
        }
        return transport != kAudioDeviceTransportTypeAggregate
            && transport != kAudioDeviceTransportTypeVirtual
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

final class WalkieTalkieMicrophone: @unchecked Sendable {
    static let sampleRate = 16_000.0

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

    static func shouldResetBuffer(
        scheduledFrames: AVAudioFramePosition,
        incomingFrames: AVAudioFramePosition,
        maximumFrames: AVAudioFramePosition
    ) -> Bool {
        scheduledFrames + incomingFrames > maximumFrames
    }
}

final class WalkieTalkiePlayer: @unchecked Sendable {
    private final class Session {
        let id: String
        let senderID: String
        var senderName: String
        let player: AVAudioPlayerNode
        var scheduledFrames: AVAudioFramePosition = 0
        var bufferGeneration: UInt64 = 0
        var timeoutWorkItem: DispatchWorkItem?

        init(id: String, senderID: String, senderName: String, player: AVAudioPlayerNode) {
            self.id = id
            self.senderID = senderID
            self.senderName = senderName
            self.player = player
        }
    }

    private let queue = DispatchQueue(label: "in.werai.walkie-playback", qos: .userInteractive)
    private let engine = AVAudioEngine()
    static let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: WalkieTalkieMicrophone.sampleRate,
        channels: 1
    )!
    private let format = playbackFormat
    private let stateHandler: @Sendable (String, String, Bool) -> Void
    private var sessions = [String: Session]()
    private var tracker = WalkieTalkiePlaybackTracker()
    private var configurationObserver: NSObjectProtocol?
    private var muted = false
    private let maximumBufferedFrames = AVAudioFramePosition(WalkieTalkieMicrophone.sampleRate * 0.18)

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

    init(stateHandler: @escaping @Sendable (String, String, Bool) -> Void = { _, _, _ in }) {
        self.stateHandler = stateHandler
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.recoverAfterConfigurationChange() }
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
        switch message.kind {
        case .began:
            _ = beginSession(message)
        case .audio:
            guard let data = message.pcm16Mono,
                  !data.isEmpty,
                  data.count <= 8_192,
                  data.count.isMultiple(of: MemoryLayout<Int16>.size)
            else { return }
            let session = sessions[message.sessionID] ?? beginSession(message)
            guard let session,
                  tracker.accepts(sessionID: message.sessionID, sequence: message.sequence)
            else { return }
            session.senderName = message.senderName
            schedule(data, for: session)
            armTimeout(for: session)
        case .ended:
            stopSession(message.sessionID)
        }
    }

    @discardableResult
    private func beginSession(_ message: WalkieTalkieMessage) -> Session? {
        if let existing = sessions[message.sessionID] {
            existing.senderName = message.senderName
            armTimeout(for: existing)
            return existing
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard ensureEngineRunning() else {
            engine.disconnectNodeOutput(player)
            engine.detach(player)
            return nil
        }
        let session = Session(
            id: message.sessionID,
            senderID: message.senderID,
            senderName: message.senderName,
            player: player
        )
        sessions[message.sessionID] = session
        tracker.begin(message.sessionID)
        player.play()
        stateHandler(session.senderID, session.senderName, true)
        armTimeout(for: session)
        return session
    }

    private func schedule(_ data: Data, for session: Session) {
        guard ensureEngineRunning() else {
            stopSession(session.id)
            return
        }
        guard let buffer = Self.makePlaybackBuffer(fromPCM16Mono: data) else { return }
        let frames = buffer.frameLength

        if WalkieTalkiePlaybackTracker.shouldResetBuffer(
            scheduledFrames: session.scheduledFrames,
            incomingFrames: AVAudioFramePosition(frames),
            maximumFrames: maximumBufferedFrames
        ) {
            session.player.stop()
            session.scheduledFrames = 0
            session.bufferGeneration &+= 1
        }
        session.scheduledFrames += AVAudioFramePosition(frames)
        let sessionID = session.id
        let bufferGeneration = session.bufferGeneration
        session.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async {
                guard let self,
                      let current = self.sessions[sessionID],
                      current === session,
                      current.bufferGeneration == bufferGeneration
                else { return }
                current.scheduledFrames = max(0, current.scheduledFrames - AVAudioFramePosition(frames))
            }
        }
        if !session.player.isPlaying, engine.isRunning { session.player.play() }
    }

    private func ensureEngineRunning() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        do {
            try engine.start()
            return engine.isRunning
        } catch {
            return false
        }
    }

    private func recoverAfterConfigurationChange() {
        engine.stop()
        for session in sessions.values {
            session.player.stop()
            session.scheduledFrames = 0
            session.bufferGeneration &+= 1
        }
        guard ensureEngineRunning() else {
            stopAllOnQueue()
            return
        }
        for session in sessions.values where !session.player.isPlaying {
            session.player.play()
        }
    }

    private func armTimeout(for session: Session) {
        session.timeoutWorkItem?.cancel()
        let sessionID = session.id
        let work = DispatchWorkItem { [weak self] in self?.stopSession(sessionID) }
        session.timeoutWorkItem = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func stopSession(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else {
            tracker.end(id)
            return
        }
        session.timeoutWorkItem?.cancel()
        session.player.stop()
        engine.disconnectNodeOutput(session.player)
        engine.detach(session.player)
        tracker.end(id)
        stateHandler(session.senderID, session.senderName, false)
        if sessions.isEmpty { engine.pause() }
    }

    private func stopAllOnQueue() {
        for id in Array(sessions.keys) { stopSession(id) }
        engine.stop()
    }

    deinit {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for session in sessions.values {
            session.timeoutWorkItem?.cancel()
            session.player.stop()
        }
        engine.stop()
    }
}
