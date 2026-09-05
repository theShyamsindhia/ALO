import AppKit
import CoreAudio
import Foundation

/// The audio a broadcaster intends to share. Application selection is resolved
/// to fresh Core Audio process objects whenever the tap graph is built, so a
/// stale PID can never redirect capture to another process.
enum SystemAudioSource: Equatable, Sendable {
    case allSystemAudio
    case djStudio
    case application(bundleIdentifier: String, name: String)

    var title: String {
        switch self {
        case .allSystemAudio: return "All system audio"
        case .djStudio: return "DJ Studio"
        case .application(_, let name): return name
        }
    }

    var usesGlobalPlaybackControls: Bool {
        if case .allSystemAudio = self { return true }
        return false
    }

    var bundleIdentifier: String? {
        if case .application(let bundleIdentifier, _) = self { return bundleIdentifier }
        return nil
    }
}

struct SystemAudioApplication: Identifiable, Equatable, Sendable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

enum SystemAudioProcessCatalog {
    static func audibleApplications(excludingPID: pid_t = getpid()) -> [SystemAudioApplication] {
        let records = processRecords().filter {
            $0.pid != excludingPID && $0.isRunningOutput && !$0.bundleIdentifier.isEmpty
        }
        var applications = [String: SystemAudioApplication]()
        for record in records {
            let running = NSRunningApplication(processIdentifier: record.pid)
            let name = running?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = record.bundleIdentifier.split(separator: ".").last.map(String.init)
                ?? record.bundleIdentifier
            applications[record.bundleIdentifier] = SystemAudioApplication(
                bundleIdentifier: record.bundleIdentifier,
                name: name?.isEmpty == false ? name! : fallback
            )
        }
        return applications.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleIdentifier < $1.bundleIdentifier : order == .orderedAscending
        }
    }

    static func processObjectIDs(
        for source: SystemAudioSource,
        excludingPID: pid_t = getpid()
    ) throws -> [AudioObjectID] {
        guard case .application(let bundleIdentifier, let name) = source else { return [] }
        let matches = processRecords().filter {
            $0.pid != excludingPID && $0.bundleIdentifier == bundleIdentifier
        }.map(\.objectID)
        guard !matches.isEmpty else {
            throw ALOError("\(name) is no longer available for app audio. Start audio in that app, refresh the list, and try again.")
        }
        return matches
    }

    private struct ProcessRecord {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleIdentifier: String
        let isRunningOutput: Bool
    }

    private static func processRecords() -> [ProcessRecord] {
        processObjectIDs().compactMap { objectID in
            guard let pid: pid_t = scalarProperty(objectID, kAudioProcessPropertyPID),
                  let bundleIdentifier = stringProperty(objectID, kAudioProcessPropertyBundleID)
            else { return nil }
            let running: UInt32 = scalarProperty(objectID, kAudioProcessPropertyIsRunningOutput) ?? 0
            return ProcessRecord(objectID: objectID, pid: pid,
                                 bundleIdentifier: bundleIdentifier, isRunningOutput: running != 0)
        }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0, size % UInt32(MemoryLayout<AudioObjectID>.stride) == 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values.filter { $0 != kAudioObjectUnknown }
    }

    private static func scalarProperty<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> T? {
        var address = propertyAddress(selector)
        var value: T?
        var storage = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        var size = UInt32(storage.count)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &storage) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        storage.withUnsafeBytes { bytes in value = bytes.loadUnaligned(as: T.self) }
        return value
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = propertyAddress(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
