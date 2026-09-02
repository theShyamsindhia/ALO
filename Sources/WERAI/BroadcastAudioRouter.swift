import CoreAudio
import Foundation

protocol AudioHardwareRouting: AnyObject {
    var defaultOutputUID: String? { get throws }
    var defaultSystemOutputUID: String? { get throws }
    func setDefaultOutput(uid: String) throws
    func setDefaultSystemOutput(uid: String) throws
    func availableOutputDevices() throws -> [AudioOutputRouteDevice]
}

struct AudioOutputRouteDevice: Equatable {
    let uid: String
    let isBuiltIn: Bool
}

struct BroadcastRouteJournal: Codable, Equatable {
    let virtualUID: String
    let previousOutputUID: String
    let previousSystemOutputUID: String
    let sessionID: String
    let createdAt: Date
}

final class BroadcastAudioRouter {
    private let hardware: AudioHardwareRouting
    private let journalURL: URL
    private(set) var journal: BroadcastRouteJournal?
    private(set) var isActive = false

    init(hardware: AudioHardwareRouting = CoreAudioHardwareRouting(), journalURL: URL? = nil) {
        self.hardware = hardware
        self.journalURL = journalURL ?? Self.defaultJournalURL
    }

    static var defaultJournalURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WERAI", isDirectory: true)
        return root.appendingPathComponent("broadcast-route.json")
    }

    func prepare(virtualUID: String = VirtualAudioDevice.uid) throws -> String {
        if journal == nil,
           FileManager.default.fileExists(atPath: journalURL.path) {
            _ = recoverStaleRoute()
        } else if journal != nil, !isActive {
            restore()
        }
        guard journal == nil else { throw WERAIError("An ALO audio route is already prepared.") }
        guard let output = try hardware.defaultOutputUID,
              let systemOutput = try hardware.defaultSystemOutputUID
        else { throw WERAIError("ALO could not identify the current physical audio output.") }
        guard output != virtualUID, systemOutput != virtualUID else {
            throw WERAIError("ALO Room is already the default output. Reopen ALO to restore the previous device first.")
        }
        let journal = BroadcastRouteJournal(
            virtualUID: virtualUID,
            previousOutputUID: output,
            previousSystemOutputUID: systemOutput,
            sessionID: UUID().uuidString,
            createdAt: Date()
        )
        try persist(journal)
        self.journal = journal
        return output
    }

    func activate() throws {
        guard let journal else { throw WERAIError("ALO audio routing was not prepared.") }
        do {
            try hardware.setDefaultOutput(uid: journal.virtualUID)
            try hardware.setDefaultSystemOutput(uid: journal.virtualUID)
            isActive = true
        } catch {
            restore()
            throw error
        }
    }

    func restore() {
        guard let journal else { return }
        if (try? hardware.defaultOutputUID) == journal.virtualUID {
            restoreOutput(preferredUID: journal.previousOutputUID, virtualUID: journal.virtualUID) {
                try hardware.setDefaultOutput(uid: $0)
            }
        }
        if (try? hardware.defaultSystemOutputUID) == journal.virtualUID {
            restoreOutput(preferredUID: journal.previousSystemOutputUID, virtualUID: journal.virtualUID) {
                try hardware.setDefaultSystemOutput(uid: $0)
            }
        }
        isActive = false
        let outputStillVirtual = (try? hardware.defaultOutputUID) == journal.virtualUID
        let systemStillVirtual = (try? hardware.defaultSystemOutputUID) == journal.virtualUID
        if !outputStillVirtual && !systemStillVirtual {
            self.journal = nil
            try? FileManager.default.removeItem(at: journalURL)
        }
    }

    private func restoreOutput(
        preferredUID: String,
        virtualUID: String,
        setter: (String) throws -> Void
    ) {
        if (try? setter(preferredUID)) != nil { return }
        guard let devices = try? hardware.availableOutputDevices() else { return }
        let candidates = devices.filter { $0.uid != virtualUID }
        let fallback = candidates.first(where: \.isBuiltIn) ?? candidates.first
        if let fallback { try? setter(fallback.uid) }
    }

    @discardableResult
    func recoverStaleRoute() -> Bool {
        guard let data = try? Data(contentsOf: journalURL),
              let stale = try? JSONDecoder().decode(BroadcastRouteJournal.self, from: data)
        else { return false }
        journal = stale
        restore()
        return journal == nil
    }

    private func persist(_ journal: BroadcastRouteJournal) throws {
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: journalURL, options: [.atomic])
    }
}

final class CoreAudioHardwareRouting: AudioHardwareRouting {
    var defaultOutputUID: String? { get throws { try uid(for: kAudioHardwarePropertyDefaultOutputDevice) } }
    var defaultSystemOutputUID: String? { get throws { try uid(for: kAudioHardwarePropertyDefaultSystemOutputDevice) } }

    func setDefaultOutput(uid: String) throws { try set(uid: uid, selector: kAudioHardwarePropertyDefaultOutputDevice) }
    func setDefaultSystemOutput(uid: String) throws { try set(uid: uid, selector: kAudioHardwarePropertyDefaultSystemOutputDevice) }

    func availableOutputDevices() throws -> [AudioOutputRouteDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr else { throw WERAIError("ALO could not enumerate audio outputs.") }
        var devices = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        )
        guard status == noErr else { throw WERAIError("ALO could not enumerate audio outputs.") }
        return devices.compactMap { device in
            guard Self.isOutputCapable(device), let uid = VirtualAudioDevice.uid(for: device) else { return nil }
            return AudioOutputRouteDevice(uid: uid, isBuiltIn: Self.isBuiltIn(device))
        }
    }

    private static func isOutputCapable(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isBuiltIn(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr &&
            transport == kAudioDeviceTransportTypeBuiltIn
    }

    private func uid(for selector: AudioObjectPropertySelector) throws -> String? {
        let device = try deviceID(for: selector)
        return VirtualAudioDevice.uid(for: device)
    }

    private func deviceID(for selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else {
            throw WERAIError("ALO could not read the current audio output (Core Audio error \(status)).")
        }
        return device
    }

    private func set(uid: String, selector: AudioObjectPropertySelector) throws {
        guard var device = VirtualAudioDevice.deviceID(uid: uid) else {
            throw WERAIError("Audio device \(uid) is no longer available.")
        }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device
        )
        guard status == noErr else {
            throw WERAIError("Could not switch the audio output (Core Audio error \(status)).")
        }
    }
}
