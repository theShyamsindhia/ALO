import CoreAudio
import Foundation

/// Privately consumes a Core Audio process tap whose only job is to suppress
/// the original source render. ScreenCaptureKit remains the room's audio source.
@available(macOS 14.2, *)
final class SourceMuteTap: @unchecked Sendable {
    private let ioQueue = DispatchQueue(label: "in.werai.audio.mute-tap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    func start() throws {
        guard tapID == kAudioObjectUnknown else { return }
        guard let ownProcessID = Self.audioObjectID(forPID: getpid()) else {
            throw WERAIError("ALO could not identify its own Core Audio process.")
        }

        // Excluding this process is important: ALO's synchronized Receiver must
        // remain audible while all other system audio is privately suppressed.
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [ownProcessID]
        )
        tapDescription.name = "ALO synchronized source"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(tapDescription, &newTapID),
            operation: "create the system-audio mute tap"
        )
        tapID = newTapID

        do {
            let tapUID = try Self.stringProperty(
                objectID: tapID,
                selector: kAudioTapPropertyUID
            )
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "ALO Private Audio Device",
                kAudioAggregateDeviceUIDKey: "in.werai.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: tapUID]
                ]
            ]
            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            try check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &newAggregateID
                ),
                operation: "create the private tap device"
            )
            aggregateID = newAggregateID

            try Self.waitForInputStream(on: aggregateID)

            var newIOProcID: AudioDeviceIOProcID?
            try check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &newIOProcID,
                    aggregateID,
                    ioQueue
                ) { _, _, _, _, _ in
                    // Reading activates `.mutedWhenTapped`; samples are already
                    // captured separately by ScreenCaptureKit.
                },
                operation: "start reading the mute tap"
            )
            ioProcID = newIOProcID
            try check(
                AudioDeviceStart(aggregateID, ioProcID),
                operation: "activate synchronized source playback"
            )
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        stop()
    }

    private static func audioObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = propertyAddress(selector: kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &objectIDs
        ) == noErr else { return nil }

        for objectID in objectIDs {
            var processAddress = propertyAddress(selector: kAudioProcessPropertyPID)
            var processID: pid_t = 0
            var processSize = UInt32(MemoryLayout<pid_t>.stride)
            guard AudioObjectGetPropertyData(
                objectID,
                &processAddress,
                0,
                nil,
                &processSize,
                &processID
            ) == noErr else { continue }
            if processID == pid { return objectID }
        }
        return nil
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
                AudioObjectGetPropertyData(
                    objectID,
                    &address,
                    0,
                    nil,
                    &size,
                    pointer
                ),
                operation: "read the audio tap identifier"
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
        throw WERAIError("The private Core Audio tap did not expose an input stream.")
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

    private func check(_ status: OSStatus, operation: String) throws {
        try Self.check(status, operation: operation)
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw WERAIError("Could not \(operation) (Core Audio error \(status)).")
        }
    }
}
