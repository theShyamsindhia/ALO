#if os(macOS)
import Foundation
import Darwin
import Testing
import ALOIdentity
@testable import ALONetworking

@Suite(.serialized)
struct DeviceMessageSpawnFenceTests {
    private typealias Adapter = MacCodexQueueAdapter

    private func withHelper(source: String = "printf started >> \"$0.marker\"\nprintf '%s\\0' \"$@\" > \"$0.args\"\nexit 0\n",
                            _ body: (Adapter.Runner, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("helper")
        try Data(("#!/bin/sh\n" + source).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = Adapter.Runner(executable: try .init(locallyApprovedURL: executable))
        try body(runner, executable.appendingPathExtension("marker"))
    }

    /// Baseline for the explicitly documented gap: reservation is not a spawn
    /// fence. A raw Prepared remains callable after service revocation. This
    /// desired invariant failed in the preserved baseline. This now retains the
    /// raw-path limitation as a positive control, not a purported production fix.
    @Test func reservationAloneCannotPreventLaterNativeStart() throws {
        try withHelper { runner, marker in
            let f = try CodexDeviceMessageServiceTests.Fixture()
            try f.service.setEnabled(true)
            let connection = try f.connect()
            let grant = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 1_000)
            let message = CodexDeviceMessageEnvelope(grantID: grant, text: "harmless test data")
            _ = try f.service.receive(message, connection: connection)
            let dispatch = try f.service.takeForDispatch(message, connection: connection)
            let native = try runner.prepare(.init(localTaskID: dispatch.localTaskID,
                messageID: dispatch.messageID, sender: dispatch.sender, text: dispatch.peerText))
            try f.service.revoke(grant: grant)
            let result = try native.start().waitForOutcome()
            try #require(result.outcome == .codexQueued, "The harmless native helper really started")
            #expect(FileManager.default.fileExists(atPath: marker.path), "Raw reservation remains deliberately insufficient; use the service fence")
        }
    }

    private func received(_ f: CodexDeviceMessageServiceTests.Fixture) throws -> (UUID, CodexDeviceMessageEnvelope) {
        try f.service.setEnabled(true)
        let connection = try f.connect()
        let grant = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 1_000)
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: "authenticated original body")
        _ = try f.service.receive(message, connection: connection)
        return (connection, message)
    }
    private func prepare(_ f: CodexDeviceMessageServiceTests.Fixture, _ connection: UUID,
                         _ message: CodexDeviceMessageEnvelope, _ runner: Adapter.Runner) throws -> CodexDeviceMessageService.NativePreparation {
        try f.service.prepareNativeDispatch(grantID: message.grantID, messageID: message.messageID,
            connection: connection, runner: runner)
    }
    private func receipt(_ f: CodexDeviceMessageServiceTests.Fixture, _ message: CodexDeviceMessageEnvelope) throws -> CodexDeviceMessagingPolicy.Receipt? {
        let checkpoint = try f.service.checkpointForTesting()
        let saved = try #require(checkpoint)
        return try CodexDeviceMessagingPolicy(restoring: saved).receipt(grantID: message.grantID, messageID: message.messageID)
    }

    @Test(arguments: [0, 1, 2, 3])
    func preparedStartRejectsRevocationDisableExpiryAndPublishedRemoval(change: Int) throws {
        try withHelper { runner, marker in
            var callbacks: [() -> Void] = []
            let f = try CodexDeviceMessageServiceTests.Fixture(policyChangeDelivery: { callbacks.append($0) })
            let (connection, message) = try received(f)
            let native = try prepare(f, connection, message, runner)
            switch change {
            case 0: try f.service.revoke(grant: message.grantID)
            case 1: try f.service.setEnabled(false)
            case 2: f.clock.set(1_000)
            default:
                try f.center.receive(f.center.snapshot().removingMember(userID: f.sender.publicIdentity.userID, signedBy: f.owner))
                try f.center.receive(f.center.snapshot().addingMember(f.sender.publicIdentity, signedBy: f.owner))
                try #require(callbacks.count == 2)
            }
            #expect(throws: (any Error).self) { try f.service.startPrepared(native) }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(f.service.nativeWorkerCountForTesting == 0)
        }
    }

    @Test func immutableBindingSingleStartAndTicketedCompletion() throws {
        try withHelper { runner, marker in
            let f = try CodexDeviceMessageServiceTests.Fixture()
            let (connection, message) = try received(f)
            let taskA = try #require(f.service.localGrants().first?.localTaskID)
            let taskB = UUID()
            let grantB = try f.service.approve(connection: connection, localTaskID: taskB, expiresAt: 1_000)
            let messageB = CodexDeviceMessageEnvelope(grantID: grantB, text: "separate authenticated message B")
            _ = try f.service.receive(messageB, connection: connection)
            let native = try prepare(f, connection, message, runner)
            let duplicate = try prepare(f, connection, message, runner)
            let nativeB = try prepare(f, connection, messageB, runner)
            let other = try CodexDeviceMessageServiceTests.Fixture()
            #expect(throws: CodexDeviceMessagingError.unauthorized) { try other.service.startPrepared(native) }
            let started = try f.service.startPrepared(native)
            #expect(throws: CodexDeviceMessagingError.invalidTransition) { try f.service.startPrepared(native) }
            #expect(throws: CodexDeviceMessagingError.invalidTransition) { try f.service.startPrepared(duplicate) }
            #expect(throws: CodexDeviceMessagingError.unauthorized) { try other.service.finishStarted(started) }
            let outcome = try f.service.finishStarted(started)
            if case .recorded(let result) = outcome { #expect(result.outcome == .codexQueued) }
            else { Issue.record("First valid completion was superseded") }
            if case .superseded = try f.service.finishStarted(started) {} else { Issue.record("Duplicate completion was accepted") }
            #expect(try String(contentsOf: marker) == "started")
            func checkArguments(task: UUID, message: CodexDeviceMessageEnvelope) throws {
                let data = try Data(contentsOf: marker.deletingPathExtension().appendingPathExtension("args"))
                let arguments = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                try #require(arguments.count == 5)
                #expect(Array(arguments.prefix(4)) == ["queue", "--thread", task.uuidString, "--message"])
                let json = try #require(arguments[4].split(separator: "\n").last)
                let attribution = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
                #expect(attribution == ["senderRootID": f.sender.publicIdentity.userID,
                    "messageID": message.messageID.uuidString, "peerText": message.text])
            }
            try checkArguments(task: taskA, message: message)
            let startedB = try f.service.startPrepared(nativeB)
            if case .recorded(let resultB) = try f.service.finishStarted(startedB) {
                #expect(resultB.outcome == .codexQueued)
            } else { Issue.record("Second bound message was not completed") }
            try checkArguments(task: taskB, message: messageB)
            #expect(try String(contentsOf: marker) == "startedstarted")
            #expect(try receipt(f, message) == .codexQueued)
            #expect(f.service.nativeWorkerCountForTesting == 0)
        }
    }

    @Test func permitsBoundPreparedWorkAndReleaseAbandonmentAndPreparationFailure() throws {
        try withHelper { runner, marker in
            let f = try CodexDeviceMessageServiceTests.Fixture()
            let (connection, message) = try received(f)
            var pending: [CodexDeviceMessageService.NativePreparation] = []
            for _ in 0..<32 { pending.append(try prepare(f, connection, message, runner)) }
            #expect(f.service.nativeWorkerCountForTesting == 32)
            #expect(throws: CodexDeviceMessagingError.capacity) { try prepare(f, connection, message, runner) }
            pending.removeLast().abandon()
            #expect(f.service.nativeWorkerCountForTesting == 31)
            pending.append(try prepare(f, connection, message, runner))
            pending.removeAll()
            #expect(f.service.nativeWorkerCountForTesting == 0)
            try FileManager.default.removeItem(at: marker.deletingPathExtension())
            #expect(throws: (any Error).self) { try prepare(f, connection, message, runner) }
            #expect(f.service.nativeWorkerCountForTesting == 0)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func knownSpawnFailureCancelsAndCannotBeRetried() throws {
        try withHelper { runner, marker in
            let f = try CodexDeviceMessageServiceTests.Fixture()
            let (connection, message) = try received(f)
            let native = try prepare(f, connection, message, runner)
            try FileManager.default.removeItem(at: marker.deletingPathExtension())
            #expect(throws: (any Error).self) { try f.service.startPrepared(native) }
            #expect(try receipt(f, message) == .cancelled)
            #expect(throws: CodexDeviceMessagingError.invalidTransition) { try f.service.startPrepared(native) }
            #expect(f.service.nativeWorkerCountForTesting == 0)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func durableIntentFailureNeverStarts() throws {
        try withHelper { runner, marker in
            let f = try CodexDeviceMessageServiceTests.Fixture()
            let (connection, message) = try received(f)
            let native = try prepare(f, connection, message, runner)
            let journal = f.directory.appendingPathComponent("journal/receipts.json")
            try #require(chflags(journal.path, UInt32(UF_IMMUTABLE)) == 0)
            defer { #expect(chflags(journal.path, 0) == 0) }
            #expect(throws: (any Error).self) { try f.service.startPrepared(native) }
            #expect(throws: CodexDeviceMessagingError.disabled) { try f.service.setEnabled(true) }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(f.service.nativeWorkerCountForTesting == 0)
        }
    }

    @Test(arguments: [false, true])
    func completedWorkCannotReviveRetiredOrPublishedOldAuthority(retire: Bool) throws {
        try withHelper { runner, marker in
            var callbacks: [() -> Void] = []
            let f = try CodexDeviceMessageServiceTests.Fixture(policyChangeDelivery: { callbacks.append($0) })
            let (connection, message) = try received(f)
            let native = try prepare(f, connection, message, runner)
            let started = try f.service.startPrepared(native)
            #expect(try receipt(f, message) == .uncertain, "A crash after durable intent never restores received/retriable")
            if retire {
                try f.service.revoke(grant: message.grantID)
                try f.service.retireGrant(message.grantID, acknowledgeReceiptLoss: true)
            } else {
                try f.center.receive(f.center.snapshot().removingMember(userID: f.sender.publicIdentity.userID, signedBy: f.owner))
                try f.center.receive(f.center.snapshot().addingMember(f.sender.publicIdentity, signedBy: f.owner))
                try #require(callbacks.count == 2)
            }
            if case .superseded = try f.service.finishStarted(started) {} else { Issue.record("Late completion revived old authority") }
            #expect(try receipt(f, message) == (retire ? nil : .uncertain))
            #expect(try String(contentsOf: marker) == "started")
        }
    }

    private final class SequencedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var sequence: [UInt64] = []
        private var last: UInt64 = 0
        func arm(_ values: [UInt64]) { lock.lock(); defer { lock.unlock() }; sequence = values }
        func read() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            if !sequence.isEmpty { last = sequence.removeFirst() }
            return last
        }
    }
    @Test(arguments: [false, true])
    func postSaveClockRecheckPreventsExpiredOrRegressedStart(regressed: Bool) throws {
        try withHelper { runner, marker in
            let f = try CodexDeviceMessageServiceTests.Fixture()
            let clock = SequencedClock()
            let service = try CodexDeviceMessageService(policy: f.center,
                localDevice: .init(user: f.owner, deviceName: "Receiver", generation: 1, installationPublicKeyHash: f.receiverHash),
                actualLocalTLSHash: f.receiverHash,
                journal: CodexDeviceMessageJournal(directoryURL: f.directory.appendingPathComponent("clock-journal")),
                nowNanos: { clock.read() })
            try service.setEnabled(true)
            let challenge = try service.challenge()
            let claim = try NetworkDeviceAuthorization.Claim.signed(challenge: challenge, sender: f.binding,
                user: f.sender, policy: f.center, actualSenderTLSHash: f.senderHash, actualReceiverTLSHash: f.receiverHash)
            let connection = try service.authenticate(claim, actualPeerTLSHash: f.senderHash)
            let grant = try service.approve(connection: connection, localTaskID: UUID(), expiresAt: 1_000)
            let message = CodexDeviceMessageEnvelope(grantID: grant, text: "post-save expiry")
            _ = try service.receive(message, connection: connection)
            let native = try service.prepareNativeDispatch(grantID: grant, messageID: message.messageID, connection: connection, runner: runner)
            let writes = service.journalWritesForTesting
            // First sample is stable-policy admission; second is after the real
            // intent save. Models elapsed persistence, not physical fsync timing.
            clock.arm(regressed ? [100, 50] : [0, 1_000])
            #expect(throws: regressed ? CodexDeviceMessagingError.clockRegressed : .expired) { try service.startPrepared(native) }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(service.journalWritesForTesting == writes + (regressed ? 1 : 2))
            let loaded = try service.checkpointForTesting()
            let saved = try #require(loaded)
            let restored = try CodexDeviceMessagingPolicy(restoring: saved)
            #expect(restored.receipt(grantID: grant, messageID: message.messageID) == (regressed ? .uncertain : .cancelled))
            if regressed {
                clock.arm([2_000])
                #expect(throws: CodexDeviceMessagingError.disabled) { try service.setEnabled(true) }
            }
            #expect(service.nativeWorkerCountForTesting == 0)
        }
    }

    @Test func revokeCompletesWhileActualChildWaitRunsOutsideFence() throws {
        let script = """
        printf started > "$0.marker"
        i=0
        while [ ! -f "$0.release" ] && [ "$i" -lt 200 ]; do
          /bin/sleep 0.01
          i=$((i+1))
        done
        exit 0
        """
        try withHelper(source: script) { runner, marker in
            let f = try CodexDeviceMessageServiceTests.Fixture()
            let (connection, message) = try received(f)
            let native = try prepare(f, connection, message, runner)
            let started = try f.service.startPrepared(native)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
            try #require(FileManager.default.fileExists(atPath: marker.path))
            let entered = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                do {
                    if case .superseded = try f.service.finishStarted(started, afterRunningCheckForTesting: { _ in entered.signal() }) {} else { Issue.record("Revoke was not preserved") }
                } catch { Issue.record("Unexpected finish error: \(error)") }
                done.signal()
            }
            try #require(entered.wait(timeout: .now() + 1) == .success)
            let began = ContinuousClock.now
            try f.service.revoke(grant: message.grantID)
            #expect(began.duration(to: .now) < .seconds(1), "Revoke must not wait for the bounded child lifetime")
            try Data().write(to: marker.deletingPathExtension().appendingPathExtension("release"))
            try #require(done.wait(timeout: .now() + 3) == .success)
            #expect(try receipt(f, message) == .uncertain)
            #expect(f.service.nativeWorkerCountForTesting == 0)
        }
    }
}
#endif
