import Foundation
import Network
import Testing
import ALOIdentity
@testable import ALONetworking

struct DeviceMessagingStorageReviewTests {
    @Test func durableCheckpointOmitsPlaintextButLiveDispatchRetainsIt() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        try f.service.setEnabled(true)
        let connection = try f.connect()
        let context = try f.service.peer(connection: connection)
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        let grant = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 1_000)
        let secret = "PR5_PRIVATE_BODY_MUST_NOT_BE_ON_DISK"
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: secret)
        _ = try policy.receive(message, context: context, now: 0)
        let encoded = try JSONEncoder().encode(policy.checkpoint)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(secret))
        let directory = f.directory.appendingPathComponent("privacy-journal")
        let journal = try CodexDeviceMessageJournal(directoryURL: directory)
        try journal.save(policy.checkpoint)
        let raw = try Data(contentsOf: directory.appendingPathComponent("receipts.json"))
        #expect(!String(decoding: raw, as: UTF8.self).contains(secret))
        let dispatch = try policy.beginDispatch(message, context: context, now: 0)
        #expect(dispatch.peerText == secret)
    }

    @Test func oneGrantReceiptShareCannotConsumeAnotherGrantBudget() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        try f.service.setEnabled(true)
        var connection = try f.connect()
        var context = try f.service.peer(connection: connection)
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        let a = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 10_000_000_000_000)
        let b = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 10_000_000_000_000)
        for index in 0..<256 {
            let now = UInt64(index) * 6_000_000_000
            if index.isMultiple(of: 32) {
                f.clock.set(now); f.service.disconnect(connection); connection = try f.connect()
                context = try f.service.peer(connection: connection)
            }
            let message = CodexDeviceMessageEnvelope(grantID: a, text: "receipt \(index)")
            _ = try policy.receive(message, context: context, now: now)
            _ = try policy.beginDispatch(message, context: context, now: now)
            try policy.completeDispatch(grantID: a, messageID: message.messageID, result: .queued)
        }
        let now: UInt64 = 256 * 6_000_000_000
        f.clock.set(now); f.service.disconnect(connection); connection = try f.connect()
        context = try f.service.peer(connection: connection)
        #expect(throws: CodexDeviceMessagingError.capacity) {
            try policy.receive(.init(grantID: a, text: "over share"), context: context, now: now)
        }
        #expect(try policy.receive(.init(grantID: b, text: "other grant still works"), context: context, now: now) == .received)
    }

    @Test(arguments: [8_192, 16_384]) func queuedGrantSharePreservesOtherGrant(bytes: Int) throws {
        let f = try CodexDeviceMessageServiceTests.Fixture(); try f.service.setEnabled(true)
        let connection = try f.connect(), context = try f.service.peer(connection: connection)
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        let a = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 100_000_000_000)
        let b = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 100_000_000_000)
        let count = 65_536 / bytes
        for index in 0..<count {
            _ = try policy.receive(.init(grantID: a, text: String(repeating: "a", count: bytes)),
                context: context, now: UInt64(index) * 6_000_000_000)
        }
        let now = UInt64(count) * 6_000_000_000
        #expect(throws: CodexDeviceMessagingError.capacity) {
            try policy.receive(.init(grantID: a, text: "overflow"), context: context, now: now)
        }
        #expect(try policy.receive(.init(grantID: b, text: "other grant"), context: context, now: now) == .received)
    }

    @Test func orphanCleanupIsLockOwnedExactRegularFileOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal: CodexDeviceMessageJournal? = try .init(directoryURL: directory)
        let orphan = directory.appendingPathComponent("receipt-\(UUID().uuidString).tmp")
        let unrelated = directory.appendingPathComponent("receipt-not-a-uuid.tmp")
        let folder = directory.appendingPathComponent("receipt-\(UUID().uuidString).tmp")
        let link = directory.appendingPathComponent("receipt-\(UUID().uuidString).tmp")
        try Data("partial interrupted write".utf8).write(to: orphan)
        try Data("user file".utf8).write(to: unrelated)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        withExtendedLifetime(journal) {
            #expect(throws: (any Error).self) { try CodexDeviceMessageJournal(directoryURL: directory) }
            #expect(FileManager.default.fileExists(atPath: orphan.path))
        }
        journal = nil
        let reopened = try CodexDeviceMessageJournal(directoryURL: directory)
        withExtendedLifetime(reopened) {
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            #expect(FileManager.default.fileExists(atPath: unrelated.path))
            #expect(FileManager.default.fileExists(atPath: folder.path))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == unrelated.path)
        }
        _ = journal
    }

    @Test func listenerRejectsMismatchedLocalTLSBeforeStarting() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        #expect(throws: (any Error).self) {
            try NetworkDeviceTextListener(identity: InstallationIdentity.ephemeral(), service: f.service,
                pins: MemoryPeerPinStore(), queue: DispatchQueue(label: "mismatch")) { _, _ in }
        }
    }
}
