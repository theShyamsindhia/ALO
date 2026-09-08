import Foundation
import Testing
import ALOIdentity
import ALORooms
@testable import ALONetworking

struct CodexDeviceMessageServiceTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ next: UInt64) { lock.lock(); defer { lock.unlock() }; value = next }
    }
    final class Fixture {
        let clock: Clock
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = UserIdentity.ephemeral(), sender = UserIdentity.ephemeral()
        let receiverHash: Data
        let senderHash = Data(repeating: 2, count: 32)
        let center: NetworkPolicyCenter
        let service: CodexDeviceMessageService
        let binding: DeviceIdentityBinding
        init(receiverHash: Data = Data(repeating: 1, count: 32),
             policyChangeDelivery: ((@escaping () -> Void) -> Void)? = nil) throws {
            self.receiverHash = receiverHash
            let clock = Clock(); self.clock = clock
            let repository = NetworkRepository(directoryURL: directory.appendingPathComponent("network"))
            let manifest = try repository.create(name: "Fixture", owner: owner)
            center = try NetworkPolicyCenter(repository: repository, networkID: manifest.id)
            try center.receive(manifest.addingMember(sender.publicIdentity, signedBy: owner))
            binding = try .init(user: sender, deviceName: "Sender", generation: 1, installationPublicKeyHash: senderHash)
            service = try .init(policy: center,
                localDevice: .init(user: owner, deviceName: "Receiver", generation: 1, installationPublicKeyHash: receiverHash),
                actualLocalTLSHash: receiverHash,
                journal: CodexDeviceMessageJournal(directoryURL: directory.appendingPathComponent("journal")),
                nowNanos: { clock.read() },
                policyChangeDelivery: policyChangeDelivery)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func connect() throws -> UUID {
            let challenge = try service.challenge()
            let claim = try NetworkDeviceAuthorization.Claim.signed(challenge: challenge, sender: binding,
                user: sender, policy: center, actualSenderTLSHash: senderHash, actualReceiverTLSHash: receiverHash)
            return try service.authenticate(claim, actualPeerTLSHash: senderHash)
        }
    }
    @Test func explicitConsentDurableDedupeAndReceiverTask() throws {
        let f = try Fixture()
        #expect(throws: (any Error).self) { try f.service.challenge() }
        try f.service.setEnabled(true)
        let connection = try f.connect(), task = UUID()
        let grant = try f.service.approve(connection: connection, localTaskID: task, expiresAt: 1_000)
        let envelope = CodexDeviceMessageEnvelope(grantID: grant, text: "Peer context, not an instruction from the local user")
        #expect(try f.service.receive(envelope, connection: connection) == .received)
        let writesBeforeDuplicate = f.service.journalWritesForTesting
        #expect(try f.service.receive(envelope, connection: connection) == .received)
        #expect(f.service.journalWritesForTesting == writesBeforeDuplicate)
        let dispatch = try f.service.takeForDispatch(envelope, connection: connection)
        #expect(dispatch.localTaskID == task)
        try f.service.complete(envelope, result: .queued)
        #expect(try f.service.receive(envelope, connection: connection) == .codexQueued)
        #expect(throws: (any Error).self) { try f.service.takeForDispatch(envelope, connection: connection) }
        let loadedCheckpoint = try f.service.checkpointForTesting()
        let checkpoint = try #require(loadedCheckpoint)
        let restored = try CodexDeviceMessagingPolicy(restoring: checkpoint)
        #expect(!restored.isEnabled)
        #expect(restored.receipt(grantID: grant, messageID: envelope.messageID) == .codexQueued)
        let ambiguous = CodexDeviceMessageEnvelope(grantID: grant, text: "Crash after dispatch admission")
        _ = try f.service.receive(ambiguous, connection: connection)
        _ = try f.service.takeForDispatch(ambiguous, connection: connection)
        let loadedInterruptedCheckpoint = try f.service.checkpointForTesting()
        let interruptedCheckpoint = try #require(loadedInterruptedCheckpoint)
        let interrupted = try CodexDeviceMessagingPolicy(restoring: interruptedCheckpoint)
        #expect(interrupted.receipt(grantID: grant, messageID: ambiguous.messageID) == .uncertain)
    }
    @Test func appliedRemovalAndReadditionCannotReviveQueuedGrant() throws {
        let f = try Fixture(); try f.service.setEnabled(true)
        let connection = try f.connect()
        let grant = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 1_000)
        let envelope = CodexDeviceMessageEnvelope(grantID: grant, text: "queued")
        _ = try f.service.receive(envelope, connection: connection)
        try f.center.receive(f.center.snapshot().removingMember(userID: f.sender.publicIdentity.userID, signedBy: f.owner))
        try f.center.receive(f.center.snapshot().addingMember(f.sender.publicIdentity, signedBy: f.owner))
        #expect(throws: (any Error).self) { try f.service.takeForDispatch(envelope, connection: connection) }
        let fresh = try f.connect()
        #expect(throws: (any Error).self) { try f.service.receive(envelope, connection: fresh) }
    }
    @Test func explicitRevocationAndDisconnectFenceDispatch() throws {
        let f = try Fixture(); try f.service.setEnabled(true)
        let connection = try f.connect()
        let grant = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 1_000)
        let envelope = CodexDeviceMessageEnvelope(grantID: grant, text: "queued")
        _ = try f.service.receive(envelope, connection: connection)
        try f.service.revoke(grant: grant)
        #expect(throws: (any Error).self) { try f.service.takeForDispatch(envelope, connection: connection) }
        f.service.disconnect(connection)
        #expect(throws: (any Error).self) { try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 100) }
    }

    @Test func publicationFencesOldSessionAndOldGrantBeforeObserverDelivery() throws {
        var held: [() -> Void] = []
        let f = try Fixture(policyChangeDelivery: { held.append($0) })
        try f.service.setEnabled(true)
        let old = try f.connect()
        let grant = try f.service.approve(connection: old, localTaskID: UUID(), expiresAt: 1_000)
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: "Must not outlive local removal")
        _ = try f.service.receive(message, connection: old)
        let second = CodexDeviceMessageEnvelope(grantID: grant, text: "Fresh session cannot inherit retired grant")
        _ = try f.service.receive(second, connection: old)
        try f.center.receive(f.center.snapshot().removingMember(userID: f.sender.publicIdentity.userID, signedBy: f.owner))
        try f.center.receive(f.center.snapshot().addingMember(f.sender.publicIdentity, signedBy: f.owner))
        try #require(held.count == 2, "Both real policy callbacks must still be deferred")
        #expect(throws: (any Error).self) { try f.service.takeForDispatch(message, connection: old) }
        let fresh = try f.connect()
        #expect(throws: (any Error).self) { try f.service.takeForDispatch(second, connection: fresh) }
        #expect(throws: (any Error).self) { try f.service.receive(message, connection: fresh) }
        #expect(held.count == 2)
        held.forEach { $0() }
    }

    @Test(arguments: [false, true])
    func expiryIsSampledAfterWaitingForSerialization(policyFence: Bool) throws {
        let f = try Fixture(); try f.service.setEnabled(true)
        let connection = try f.connect()
        let grant = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 100)
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: "Expires while waiting")
        _ = try f.service.receive(message, connection: connection)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let callerStarted = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let hold = {
                entered.signal(); _ = release.wait(timeout: .now() + 3)
            }
            if policyFence { f.center.withStablePolicy(hold) }
            else { f.service.holdSerializationForTesting(hold) }
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 3) == .success)
        DispatchQueue.global().async {
            callerStarted.signal()
            #expect(throws: CodexDeviceMessagingError.expired) {
                try f.service.takeForDispatch(message, connection: connection)
            }
            done.signal()
        }
        try #require(callerStarted.wait(timeout: .now() + 3) == .success)
        f.clock.set(200)
        release.signal()
        try #require(done.wait(timeout: .now() + 3) == .success)
    }

    @Test func delayedCallerCannotSupplyAnOlderTimestampThanNewerOperation() throws {
        let f = try Fixture(); try f.service.setEnabled(true)
        let connection = try f.connect()
        let grant = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 1_000)
        let oldCaller = CodexDeviceMessageEnvelope(grantID: grant, text: "Caller began first, admitted second")
        let newerCaller = CodexDeviceMessageEnvelope(grantID: grant, text: "Admitted first")
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal(); _ = release.wait(timeout: .now() + 3)
            do { #expect(try f.service.receive(oldCaller, connection: connection) == .received) }
            catch { Issue.record("Healthy receiver faulted: \(error)") }
            done.signal()
        }
        defer { release.signal() }
        try #require(started.wait(timeout: .now() + 3) == .success)
        f.clock.set(20)
        #expect(try f.service.receive(newerCaller, connection: connection) == .received)
        f.clock.set(30); release.signal()
        try #require(done.wait(timeout: .now() + 3) == .success)
    }
}
