import Foundation
import Testing
@testable import ALO

struct BroadcastAudioRouterTests {
    @Test("Route activation and restoration preserve both physical defaults")
    func activateAndRestore() throws {
        let hardware = FakeAudioHardware(output: "physical", system: "alerts")
        let journal = temporaryJournal()
        let router = BroadcastAudioRouter(hardware: hardware, journalURL: journal)

        #expect(try router.prepare() == "physical")
        #expect(FileManager.default.fileExists(atPath: journal.path))
        try router.activate()
        #expect(hardware.output == VirtualAudioDevice.uid)
        #expect(hardware.system == VirtualAudioDevice.uid)

        router.restore()
        #expect(hardware.output == "physical")
        #expect(hardware.system == "alerts")
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("Restore does not overwrite a user's later output choice")
    func compareAndSwapRestore() throws {
        let hardware = FakeAudioHardware(output: "physical", system: "alerts")
        let router = BroadcastAudioRouter(hardware: hardware, journalURL: temporaryJournal())
        _ = try router.prepare()
        try router.activate()
        hardware.output = "headphones"
        router.restore()

        #expect(hardware.output == "headphones")
        #expect(hardware.system == "alerts")
    }

    @Test("A partial routing failure rolls back and clears its recovery journal")
    func partialFailureRollsBack() throws {
        let hardware = FakeAudioHardware(output: "physical", system: "alerts")
        let journal = temporaryJournal()
        let router = BroadcastAudioRouter(hardware: hardware, journalURL: journal)
        _ = try router.prepare()
        hardware.failSystemSet = true

        #expect(throws: (any Error).self) { try router.activate() }
        #expect(hardware.output == "physical")
        #expect(hardware.system == "alerts")
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("A stale crash journal restores only defaults still routed to ALO")
    func crashRecovery() throws {
        let hardware = FakeAudioHardware(output: "physical", system: "alerts")
        let journalURL = temporaryJournal()
        let first = BroadcastAudioRouter(hardware: hardware, journalURL: journalURL)
        _ = try first.prepare()
        try first.activate()
        hardware.system = "user-system-choice"

        let relaunched = BroadcastAudioRouter(hardware: hardware, journalURL: journalURL)
        #expect(relaunched.recoverStaleRoute())
        #expect(hardware.output == "physical")
        #expect(hardware.system == "user-system-choice")
    }

    @Test("A failed restoration retains the crash journal for a later retry")
    func failedRestoreRetainsJournal() throws {
        let hardware = FakeAudioHardware(output: "physical", system: "alerts")
        let journalURL = temporaryJournal()
        let router = BroadcastAudioRouter(hardware: hardware, journalURL: journalURL)
        _ = try router.prepare()
        try router.activate()
        hardware.failOutputRestore = true

        router.restore()
        #expect(hardware.output == VirtualAudioDevice.uid)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))

        hardware.failOutputRestore = false
        router.restore()
        #expect(hardware.output == "physical")
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("An unplugged journaled output restores to a built-in fallback")
    func unpluggedOutputUsesBuiltInFallback() throws {
        let hardware = FakeAudioHardware(output: "usb", system: "usb")
        hardware.devices = [
            AudioOutputRouteDevice(uid: "usb", isBuiltIn: false),
            AudioOutputRouteDevice(uid: "display", isBuiltIn: false),
            AudioOutputRouteDevice(uid: "speakers", isBuiltIn: true),
            AudioOutputRouteDevice(uid: VirtualAudioDevice.uid, isBuiltIn: false),
        ]
        let journalURL = temporaryJournal()
        let router = BroadcastAudioRouter(hardware: hardware, journalURL: journalURL)
        _ = try router.prepare()
        try router.activate()
        hardware.devices.removeAll { $0.uid == "usb" }

        router.restore()
        #expect(hardware.output == "speakers")
        #expect(hardware.system == "speakers")
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("Prepare retries stale recovery after the saved output was unplugged")
    func prepareRetriesStaleRecovery() throws {
        let hardware = FakeAudioHardware(output: "usb", system: "usb")
        hardware.devices = [
            AudioOutputRouteDevice(uid: "usb", isBuiltIn: false),
            AudioOutputRouteDevice(uid: "speakers", isBuiltIn: true),
            AudioOutputRouteDevice(uid: VirtualAudioDevice.uid, isBuiltIn: false),
        ]
        let journalURL = temporaryJournal()
        let crashed = BroadcastAudioRouter(hardware: hardware, journalURL: journalURL)
        _ = try crashed.prepare()
        try crashed.activate()
        hardware.devices.removeAll { $0.uid == "usb" }

        let relaunched = BroadcastAudioRouter(hardware: hardware, journalURL: journalURL)
        #expect(try relaunched.prepare() == "speakers")
        #expect(hardware.output == "speakers")
        relaunched.restore()
    }

    private func temporaryJournal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-route-\(UUID().uuidString).json")
    }
}

private final class FakeAudioHardware: AudioHardwareRouting {
    var output: String?
    var system: String?
    var failSystemSet = false
    var failOutputRestore = false
    var devices = [
        AudioOutputRouteDevice(uid: "physical", isBuiltIn: true),
        AudioOutputRouteDevice(uid: "alerts", isBuiltIn: true),
        AudioOutputRouteDevice(uid: VirtualAudioDevice.uid, isBuiltIn: false),
    ]

    init(output: String?, system: String?) {
        self.output = output
        self.system = system
    }

    var defaultOutputUID: String? { get throws { output } }
    var defaultSystemOutputUID: String? { get throws { system } }
    func setDefaultOutput(uid: String) throws {
        if failOutputRestore, uid != VirtualAudioDevice.uid { throw FakeRouteError.failed }
        guard devices.contains(where: { $0.uid == uid }) else { throw FakeRouteError.failed }
        output = uid
    }
    func setDefaultSystemOutput(uid: String) throws {
        if failSystemSet { throw FakeRouteError.failed }
        guard devices.contains(where: { $0.uid == uid }) else { throw FakeRouteError.failed }
        system = uid
    }
    func availableOutputDevices() throws -> [AudioOutputRouteDevice] { devices }
}

private enum FakeRouteError: Error { case failed }
