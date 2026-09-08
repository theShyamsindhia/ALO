import Foundation
import Network
import Testing
import ALOIdentity
@testable import ALONetworking

struct DeviceMessagingReviewTests {
    @Test func continuousDeadlineTaskAndRenewalGeneration() async throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        let native = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let transport = NetworkDeviceTextTransport(accepted: native, service: f.service,
            pins: MemoryPeerPinStore(), queue: DispatchQueue(label: "deadline-test")) { _ in }
        transport.armDeadlineForTesting(20)
        let old = transport.deadlineGenerationForTesting
        transport.armDeadlineForTesting(20)
        #expect(transport.deadlineGenerationForTesting != old)
        transport.fireDeadlineForTesting(old)
        #expect(!transport.closedForTesting)
        transport.armDeadlineForTesting(0.01)
        let deadline = ContinuousClock.now + .seconds(1)
        while !transport.closedForTesting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(transport.closedForTesting)
    }
    @Test func queryClockRegressionPermanentlyDisablesService() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        try f.service.setEnabled(true)
        let connection = try f.connect()
        let grant = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 1_000)
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: "same")
        f.clock.set(20); _ = try f.service.receive(message, connection: connection)
        f.clock.set(10)
        #expect(throws: CodexDeviceMessagingError.clockRegressed) { try f.service.receive(message, connection: connection) }
        f.clock.set(30)
        #expect(throws: CodexDeviceMessagingError.disabled) { try f.service.receive(message, connection: connection) }
        #expect(throws: CodexDeviceMessagingError.disabled) { try f.service.setEnabled(true) }
        let writes = f.service.journalWritesForTesting
        #expect(throws: CodexDeviceMessagingError.disabled) { try f.service.revoke(grant: grant) }
        #expect(throws: CodexDeviceMessagingError.disabled) { try f.service.retireGrant(grant, acknowledgeReceiptLoss: true) }
        #expect(throws: CodexDeviceMessagingError.disabled) { try f.service.complete(message, result: .queued) }
        #expect(throws: CodexDeviceMessagingError.disabled) { try f.service.confirmDelivery(message) }
        #expect(f.service.journalWritesForTesting == writes)
        #expect(f.service.localGrants().count == 1) // Inspection/connection cleanup remain available.
        f.service.disconnect(connection)
    }
    @Test func stoppedListenerIgnoresDelayedAuthenticatedCallback() throws {
        let identity = try InstallationIdentity.ephemeral()
        let f = try CodexDeviceMessageServiceTests.Fixture(receiverHash: identity.publicIdentity.publicKeyHash)
        try f.service.setEnabled(true)
        let connection = try f.connect()
        let context = try f.service.peer(connection: connection)
        let state = NetworkDeviceTextTransportTests.State()
        let listener = try NetworkDeviceTextListener(identity: identity, service: f.service,
            pins: MemoryPeerPinStore(), queue: DispatchQueue(label: "stopped-listener-test")) { _, event in
                if case .authenticated = event { state.mutate { $0.authenticated = true } }
            }
        listener.enqueueTransportEventForTesting(connection, .authenticated(connection, context))
        #expect(listener.admittedCountForTesting == 1) // Same handler positive control.
        #expect(state.read { $0.authenticated })
        state.mutate { $0.authenticated = false }
        listener.stop()
        listener.enqueueTransportEventForTesting(connection, .authenticated(connection, context))
        #expect(listener.admittedCountForTesting == 0)
        #expect(!state.read { $0.authenticated })
    }
    @Test func duplicateQueriesAreBoundedWithoutJournalWrites() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        try f.service.setEnabled(true)
        let connection = try f.connect()
        let grant = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 1_000)
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: "same")
        _ = try f.service.receive(message, connection: connection)
        let writes = f.service.journalWritesForTesting
        for _ in 0..<4 { _ = try f.service.receive(message, connection: connection) }
        #expect(throws: CodexDeviceMessagingError.rateLimited) { try f.service.receive(message, connection: connection) }
        #expect(f.service.journalWritesForTesting == writes)
        f.service.disconnect(connection)
        let reconnected = try f.connect()
        #expect(throws: CodexDeviceMessagingError.rateLimited) { try f.service.receive(message, connection: reconnected) }
        #expect(f.service.journalWritesForTesting == writes)
    }
    @Test func cancelledChallengeChurnDoesNotConsumePendingCapacity() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        try f.service.setEnabled(true)
        for _ in 0..<100 {
            let challenge = try f.service.challenge()
            f.service.cancelChallenge(challenge)
        }
        _ = try f.connect()
    }
    @Test func restoredGrantIDsCanBeEnumeratedAndRetiredLocally() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        try f.service.setEnabled(true)
        let connection = try f.connect()
        for _ in 0..<32 { _ = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 1_000) }
        let saved = try f.service.checkpointForTesting()
        let checkpoint = try #require(saved)
        let journal = try CodexDeviceMessageJournal(directoryURL: f.directory.appendingPathComponent("restored"))
        try journal.save(checkpoint)
        let restored = try CodexDeviceMessageService(policy: f.center,
            localDevice: DeviceIdentityBinding(user: f.owner, deviceName: "Receiver", generation: 1, installationPublicKeyHash: f.receiverHash),
            actualLocalTLSHash: f.receiverHash, journal: journal, nowNanos: { 0 })
        let grants = restored.localGrants()
        #expect(grants.count == 32)
        for grant in grants {
            #expect(grant.revoked && grant.recordCount == 0)
            try restored.retireGrant(grant.id, acknowledgeReceiptLoss: false)
        }
        #expect(restored.localGrants().isEmpty)
        try restored.setEnabled(true)
        let challenge = try restored.challenge()
        let claim = try NetworkDeviceAuthorization.Claim.signed(challenge: challenge, sender: f.binding,
            user: f.sender, policy: f.center, actualSenderTLSHash: f.senderHash, actualReceiverTLSHash: f.receiverHash)
        let newConnection = try restored.authenticate(claim, actualPeerTLSHash: f.senderHash)
        _ = try restored.approve(connection: newConnection, localTaskID: UUID(), expiresAt: 100)
        #expect(restored.localGrants().count == 1)
    }
    @Test func injectedElapsedTimeExpiresAuthorization() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        try f.service.setEnabled(true)
        let connection = try f.connect()
        let grant = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 100)
        f.clock.set(101) // Models continuous elapsed time including a suspend interval.
        #expect(throws: CodexDeviceMessagingError.expired) {
            try f.service.receive(.init(grantID: grant, text: "after suspend"), connection: connection)
        }
        #expect(DeviceMessagingClock.nowNanos() > 0)
    }
    @Test func arbitraryGrantQueriesAllocateNoBudget() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        try f.service.setEnabled(true)
        let connection = try f.connect()
        for _ in 0..<100 {
            #expect(throws: CodexDeviceMessagingError.unauthorized) {
                try f.service.receive(.init(grantID: UUID(), text: "guess"), connection: connection)
            }
        }
        #expect(f.service.queryBudgetCountForTesting == 0)
    }
    @Test func exactWireEscapingBoundaryIsValidated() throws {
        let safe = CodexDeviceMessageEnvelope(grantID: UUID(), text: String(repeating: "\u{0001}", count: 4_000))
        #expect(try NetworkDeviceTextTransport.textFrame(safe).count <= 24 * 1024 + 4)
        let oversized = CodexDeviceMessageEnvelope(grantID: UUID(), text: String(repeating: "\u{0001}", count: 4_077))
        #expect(try JSONEncoder().encode(oversized).count <= 24 * 1024)
        #expect(throws: (any Error).self) { try NetworkDeviceTextTransport.textFrame(oversized) }
        _ = try NetworkDeviceTextTransport.textFrame(.init(grantID: UUID(), text: "😃\n\"\\"))
    }
    @Test func droppingTransportCancelsItsNativeConnectionWithoutStop() async throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        var transport: NetworkDeviceTextTransport? = NetworkDeviceTextTransport(accepted: connection,
            service: f.service, pins: MemoryPeerPinStore(), queue: DispatchQueue(label: "drop-test")) { _ in }
        weak var weakTransport = transport
        transport?.start()
        transport = nil
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if weakTransport == nil, case .cancelled = connection.state { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Dropping transport must release it and cancel native connection")
    }
    @Test func droppingListenerReleasesItsBoundPortWithoutStop() async throws {
        let identity = try InstallationIdentity.ephemeral()
        let f = try CodexDeviceMessageServiceTests.Fixture(receiverHash: identity.publicIdentity.publicKeyHash)
        let queue = DispatchQueue(label: "listener-drop-test")
        let state = NetworkDeviceTextTransportTests.State()
        var listener: NetworkDeviceTextListener? = try NetworkDeviceTextListener(identity: identity,
            service: f.service, pins: MemoryPeerPinStore(), queue: queue) { _, _ in }
        weak var weakListener = listener
        listener?.start { port in state.mutate { $0.port = port } }
        let deadline = ContinuousClock.now + .seconds(3)
        while state.read({ $0.port == nil }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let port = try #require(state.read { $0.port })
        let native = try #require(listener).nativeListenerForTesting
        print("LISTENER_DROP before=\(native.state) port=\(port)")
        listener = nil
        #expect(weakListener == nil)
        // cancel() requests asynchronous cancellation. CI observed replacement
        // EADDRINUSE while the original still reported ready, then cancelled.
        // Observe that native completion before the ONE rebind attempt, sharing
        // the original total deadline rather than retrying a failed listener.
        var cancellationCompleted = false
        while ContinuousClock.now < deadline {
            if case .cancelled = native.state { cancellationCompleted = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(cancellationCompleted, "Native cancellation must complete within original total deadline")
        print("LISTENER_DROP cancellationCompletedBeforeSingleRebind=\(native.state)")
        let replacement = try NWListener(using: .tcp, on: port)
        // Network.framework rejects start without an accept handler (EINVAL),
        // independently of port reuse. Reject any unexpected inbound connection.
        replacement.newConnectionHandler = { $0.cancel() }
        defer { replacement.cancel() }
        replacement.stateUpdateHandler = { value in
            print("LISTENER_REPLACEMENT state=\(value) original=\(native.state)")
            if case .ready = value { state.mutate { $0.authenticated = true } }
        }
        replacement.start(queue: queue)
        while !state.read({ $0.authenticated }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        print("LISTENER_DROP finalOriginal=\(native.state) replacement=\(replacement.state)")
        #expect(state.read { $0.authenticated })
    }
    @Test func droppingSenderRemovesPolicyObserverWithoutStop() async throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        let identity = try InstallationIdentity.ephemeral()
        let binding = try DeviceIdentityBinding(user: f.sender, deviceName: "Sender", generation: 1,
            installationPublicKeyHash: identity.publicIdentity.publicKeyHash)
        let listener = try NWListener(using: .tcp)
        let queue = DispatchQueue(label: "observer-drop-test")
        let state = NetworkDeviceTextTransportTests.State()
        // Retain a raw TCP peer that never finishes TLS, without certificate or app work.
        final class Connections: @unchecked Sendable {
            let lock = NSLock(); var values: [NWConnection] = []
            func add(_ connection: NWConnection) { lock.lock(); defer { lock.unlock() }; values.append(connection) }
            func cancel() { lock.lock(); defer { lock.unlock() }; values.forEach { $0.cancel() } }
        }
        let accepted = Connections()
        listener.newConnectionHandler = { connection in accepted.add(connection); connection.start(queue: queue) }
        listener.stateUpdateHandler = { value in
            if case .ready = value { state.mutate { $0.port = listener.port } }
        }
        listener.start(queue: queue)
        defer { listener.stateUpdateHandler = nil; listener.cancel(); accepted.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while state.read({ $0.port == nil }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let port = try #require(state.read { $0.port })
        let baseline = f.center.observerCountForTesting
        var sender: NetworkDeviceTextTransport? = try .init(endpoint: .hostPort(host: "127.0.0.1", port: port),
            identity: identity, user: f.sender, binding: binding, policy: f.center,
            pins: MemoryPeerPinStore(), queue: queue) { _ in }
        weak var weakSender = sender
        sender?.start()
        while f.center.observerCountForTesting == baseline, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(f.center.observerCountForTesting == baseline + 1)
        sender = nil
        while weakSender != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(weakSender == nil)
        #expect(f.center.observerCountForTesting == baseline)
    }
}
