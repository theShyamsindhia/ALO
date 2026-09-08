import Foundation
import Network
import Testing
import ALOIdentity
import ALORooms
@testable import ALONetworking

@Suite(.serialized)
struct DeviceLiveStatusReviewTests {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var port: NWEndpoint.Port?
        var connection: UUID?
        var session: UUID?
        var grants: [UUID] = []
        var receipts = 0
        var closed = false
        var unknown = false
        var subscriptionExpired = false
        var queryReplies = 0
        var queryRateLimits = 0
        var textRejections = 0
        func mutate(_ body: (State) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
        func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    }

    @Test func explicitStatusQueryAfterIntermediateMustBeSent() throws {
        var ledger = NetworkDeviceResponseLedger()
        let key = NetworkDeviceResponseLedger.Key(grant: UUID(), message: UUID())
        _ = try ledger.reserve(key, digest: Data(repeating: 3, count: 32))
        _ = try ledger.resolve(key, receipt: .received)
        let sendsQuery = try ledger.reserveQuery(key)
        #expect(sendsQuery, "A settled observation must permit an explicit status-only refresh")
        #expect(ledger.pendingCount == 1)
    }

    @Test func liveTerminalWhileQueryPendingRetainsOnlyBoundedSolicitedResponse() throws {
        var ledger = NetworkDeviceResponseLedger()
        let key = NetworkDeviceResponseLedger.Key(grant: UUID(), message: UUID())
        _ = try ledger.reserve(key, digest: Data(repeating: 1, count: 32))
        _ = try ledger.resolve(key, receipt: .received)
        #expect(try ledger.reserveQuery(key))
        #expect(!(try ledger.reserveQuery(key)))
        #expect(try ledger.resolve(key, receipt: .codexQueued))
        #expect(ledger.pendingCount == 1)
        #expect(!(try ledger.resolveQuery(key, receipt: .codexQueued)))
        #expect(ledger.pendingCount == 0)
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.resolveQuery(key, receipt: .codexQueued) }
    }

    @Test func queryRateLimitNeverRejectsOriginalMessageAndScopedExpiryCanRaceQuery() throws {
        var ledger = NetworkDeviceResponseLedger()
        let key = NetworkDeviceResponseLedger.Key(grant: UUID(), message: UUID())
        _ = try ledger.reserve(key, digest: Data(repeating: 1, count: 32))
        _ = try ledger.resolve(key, receipt: .received)
        _ = try ledger.reserveQuery(key)
        try ledger.queryUnavailable(key, reason: .rateLimited)
        #expect(ledger.pendingCount == 1)
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.reject(key, reason: "rateLimited") }
        #expect(try ledger.reserveQuery(key))
        #expect(!(try ledger.resolveQuery(key, receipt: .received)))
        #expect(try ledger.reserveQuery(key))
        try ledger.endSubscription(key)
        #expect(ledger.pendingCount == 1)
        try ledger.queryUnavailable(key, reason: .grantExpired)
        #expect(ledger.pendingCount == 0)
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.endSubscription(key) }
        _ = try ledger.reserveQuery(key)
        try ledger.queryUnavailable(key, reason: .statusUnknown)
        #expect(ledger.pendingCount == 0)
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.queryUnavailable(key, reason: .statusUnknown) }
    }

    /// Baseline observed close and failed both ordinary-scope assertions. The
    /// corrected cases require explicit scoped status and healthy B continuation,
    /// not a timeout/no-close assumption. Security failures remain terminal.
    @Test(arguments: [0, 1, 2, 3, 4])
    func ordinaryStatusUnavailabilityMustNotCloseOtherAuthorizedWork(mode: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral(), sender = UserIdentity.ephemeral()
        let receiverTLS = try InstallationIdentity.ephemeral(), senderTLS = try InstallationIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory.appendingPathComponent("network"))
        let manifest = try repository.create(name: "Scoped status fixture", owner: owner)
        let policy = try NetworkPolicyCenter(repository: repository, networkID: manifest.id)
        try policy.receive(manifest.addingMember(sender.publicIdentity, signedBy: owner))
        let receiverBinding = try DeviceIdentityBinding(user: owner, deviceName: "Receiver", generation: 1,
            installationPublicKeyHash: receiverTLS.publicIdentity.publicKeyHash)
        let senderBinding = try DeviceIdentityBinding(user: sender, deviceName: "Sender", generation: 1,
            installationPublicKeyHash: senderTLS.publicIdentity.publicKeyHash)
        let clock = CodexDeviceMessageServiceTests.Clock(); clock.set(DeviceMessagingClock.nowNanos())
        let service = try CodexDeviceMessageService(policy: policy, localDevice: receiverBinding,
            actualLocalTLSHash: receiverTLS.publicIdentity.publicKeyHash,
            journal: CodexDeviceMessageJournal(directoryURL: directory.appendingPathComponent("journal")),
            nowNanos: { clock.read() })
        try service.setEnabled(true)
        let state = State(), queue = DispatchQueue(label: "alo.test.status-review")
        let listener = try NetworkDeviceTextListener(identity: receiverTLS, service: service,
            pins: MemoryPeerPinStore(), queue: queue) { id, event in
                if case .authenticated(let session, _) = event { state.mutate { $0.connection = id; $0.session = session } }
            }
        listener.start { port in state.mutate { $0.port = port } }; defer { listener.stop() }
        try await wait { state.read { $0.port != nil } }
        let port = try #require(state.read { $0.port })
        let client = try NetworkDeviceTextTransport(endpoint: .hostPort(host: "127.0.0.1", port: port),
            identity: senderTLS, user: sender, binding: senderBinding, policy: policy,
            pins: MemoryPeerPinStore(), queue: DispatchQueue(label: "alo.test.status-review.sender")) { event in
                state.mutate {
                    if case .grant(let grant) = event { $0.grants.append(grant) }
                    if case .receipt = event { $0.receipts += 1 }
                    if case .closed = event { $0.closed = true }
                    if case .queryResult(_, _, .statusUnknown) = event { $0.unknown = true }
                    if case .subscriptionExpired = event { $0.subscriptionExpired = true }
                    if case .queryResult(_, _, .receipt) = event { $0.queryReplies += 1 }
                    if case .queryResult(_, _, .unavailable(.rateLimited)) = event { $0.queryRateLimits += 1 }
                    if case .rejected = event { $0.textRejections += 1 }
                }
            }
        client.start(); defer { client.stop() }
        try await wait { state.read { $0.connection != nil } }
        let connection = try #require(state.read { $0.connection })
        listener.approve(connection: connection, localTaskID: UUID(), expiresAtNanos: clock.read() + 1_000_000_000)
        try await wait { state.read { $0.grants.count == 1 } }
        listener.approve(connection: connection, localTaskID: UUID(), expiresAtNanos: clock.read() + 600_000_000_000)
        try await wait { state.read { $0.grants.count == 2 } }
        let grants = state.read { $0.grants }
        let received = CodexDeviceMessageEnvelope(grantID: grants[0], text: "already accepted A")
        client.send(received)
        try await wait { state.read { $0.receipts == 1 } }
        let receivedB = CodexDeviceMessageEnvelope(grantID: grants[1], text: "still-authorized work B")
        client.send(receivedB)
        try await wait { state.read { $0.receipts == 2 } }
        let before = try service.checkpointForTesting()
        let writes = service.journalWritesForTesting
        let missingID = UUID()
        if mode == 4 {
            for index in 1...4 {
                client.queryReceipt(grantID: grants[1], messageID: receivedB.messageID)
                try await wait { state.read { $0.queryReplies == index } }
            }
            client.queryReceipt(grantID: grants[1], messageID: receivedB.messageID)
            try await wait { state.read { $0.queryRateLimits == 1 } }
            #expect(state.read { !$0.closed && $0.textRejections == 0 && $0.receipts == 2 })
            #expect(client.pendingReceiptsForTesting == 2)
            #expect(service.localReceipt(grantID: grants[1], messageID: receivedB.messageID) == .received)
            #expect(try service.checkpointForTesting() == before)
            #expect(service.journalWritesForTesting == writes)
            // Exercise explicit lookup of a later stored state not published
            // by the facade. This is a local ledger fixture, not native delivery.
            let session = try #require(state.read { $0.session })
            _ = try service.takeForDispatch(receivedB, connection: session)
            try service.complete(receivedB, result: .queued)
            clock.set(clock.read() + 6_000_000_000)
            client.queryReceipt(grantID: grants[1], messageID: receivedB.messageID)
            try await wait { state.read { $0.queryReplies == 5 && $0.receipts == 3 } }
            #expect(!state.read { $0.closed })
            #expect(client.pendingReceiptsForTesting == 1)
            return
        }
        switch mode {
        case 0: client.queryReceipt(grantID: grants[1], messageID: missingID)
        case 1:
            clock.set(clock.read() + 2_000_000_000)
            listener.publishCurrentReceipt(grantID: grants[0], messageID: received.messageID)
        case 2: client.queryReceipt(grantID: UUID(), messageID: UUID())
        default:
            clock.set(clock.read() + 301_000_000_000)
            listener.publishCurrentReceipt(grantID: grants[0], messageID: received.messageID)
        }
        try await wait { state.read { mode == 0 ? $0.unknown : (mode == 1 ? $0.subscriptionExpired : $0.closed) } }
        #expect(state.read { $0.closed } == (mode >= 2), "Own-grant status unavailability must remain scoped; foreign grant/session expiry stays terminal")
        #expect(try service.checkpointForTesting() == before)
        #expect(service.journalWritesForTesting == writes)
        #expect(service.localReceipt(grantID: grants[1], messageID: missingID) == nil)
        if mode < 2 {
            #expect(service.localReceipt(grantID: grants[0], messageID: received.messageID) == .received)
            client.send(.init(grantID: grants[1], text: "healthy B continuation after scoped status"))
            try await wait { state.read { $0.receipts == 3 } }
            #expect(!state.read { $0.closed })
            #expect(service.journalWritesForTesting == writes + 1)
        }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), "Actual TLS status prerequisite must complete")
    }
}
