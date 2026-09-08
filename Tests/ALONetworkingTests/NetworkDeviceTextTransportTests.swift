import Foundation
import Network
import Testing
import ALOCore
import ALOIdentity
import ALORooms
@testable import ALONetworking

@Suite(.serialized)
struct NetworkDeviceTextTransportTests {
    @Test func executorSerializesEvenWithConcurrentCallerTarget() {
        let queue = networkDeviceExecutor(target: DispatchQueue(label: "alo.test.concurrent", attributes: .concurrent))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); release.wait() }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        queue.async { second.signal() }
        #expect(second.wait(timeout: .now() + 0.05) == .timedOut)
        release.signal()
        #expect(second.wait(timeout: .now() + 2) == .success)
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var port: NWEndpoint.Port?
        var authenticated = false
        var grant: UUID?
        var receipt: CodexDeviceMessagingPolicy.Receipt?
        var receiptCount = 0
        var rateRejections = 0
        var capacityRejections = 0
        var receiverEvents: [String] = []
        var conflicts = 0
        var holdEntered = false
        var closed = false
        var rejected = false
        func mutate(_ body: (State) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
        func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    }
    @Test(arguments: [false, true]) func actualTLSWithoutAudioChannelNeedsLocalTaskConsentAndRevokes(terminalBatch: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral(), sender = UserIdentity.ephemeral()
        let receiverTLS = try InstallationIdentity.ephemeral(), senderTLS = try InstallationIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory.appendingPathComponent("network"))
        let manifest = try repository.create(name: "Text-only fixture", owner: owner)
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
        try service.setEnabled(true) // Explicit local fixture action, never wire input.
        let state = State(), queue = DispatchQueue(label: "alo.test.device-text")
        let task = UUID()
        var incoming: UUID?
        let listener = try NetworkDeviceTextListener(identity: receiverTLS, service: service,
            pins: MemoryPeerPinStore(), queue: queue) { id, event in
                if case .closed = event { state.mutate { $0.receiverEvents.append("closed") } }
                if case .messageAccepted = event { state.mutate { $0.receiverEvents.append("accepted") } }
                if case .authenticated(_, let context) = event {
                    #expect(context.senderSPKIHash == senderTLS.publicIdentity.publicKeyHash)
                    incoming = id
                    state.mutate { $0.authenticated = true }
                }
            }
        listener.start { port in state.mutate { $0.port = port } }
        defer { listener.stop() }
        try await wait { state.read { $0.port != nil } }
        let port = try #require(state.read { $0.port })
        let client = try NetworkDeviceTextTransport(endpoint: .hostPort(host: "127.0.0.1", port: port),
            identity: senderTLS, user: sender, binding: senderBinding, policy: policy,
            pins: MemoryPeerPinStore(), queue: DispatchQueue(label: "alo.test.device-text.sender")) { event in
                state.mutate {
                    if case .grant(let grant) = event { $0.grant = grant }
                    if case .receipt(_, _, let receipt) = event { $0.receipt = receipt; $0.receiptCount += 1 }
                    if case .closed = event { $0.closed = true }
                    if case .rejected = event { $0.rejected = true }
                    if case .rejected(_, _, .rateLimited) = event { $0.rateRejections += 1 }
                    if case .rejected(_, _, .capacity) = event { $0.capacityRejections += 1 }
                    if case .rejected(_, _, .duplicateConflict) = event { $0.conflicts += 1 }
                }
            }
        client.start(); defer { client.stop() }
        try await wait { state.read { $0.authenticated } }
        #expect(state.read { $0.grant == nil && $0.receipt == nil })
        let connection = try #require(queue.sync { incoming })
        listener.approve(connection: connection, localTaskID: task, expiresAtNanos: DeviceMessagingClock.nowNanos() + 60_000_000_000)
        try await wait { state.read { $0.grant != nil } }
        let grant = try #require(state.read { $0.grant })
        client.send(.init(grantID: grant, text: String(repeating: "\u{0001}", count: 4_077)))
        try await wait { state.read { $0.rejected } }
        #expect(state.read { !$0.closed && $0.receipt == nil })
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            service.holdSerializationForTesting { state.mutate { $0.holdEntered = true }; _ = release.wait(timeout: .now() + 3) }
        }
        defer { release.signal() }
        try await wait(timeout: .seconds(2)) { state.read { $0.holdEntered } }
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: "Attributed remote text; not local authority")
        client.send(message)
        client.send(message) // Receiver is blocked: both local sends are in-flight.
        client.send(.init(grantID: grant, messageID: message.messageID, text: "conflicting payload"))
        #expect(client.pendingReceiptsForTesting == 1)
        #expect(state.read { $0.conflicts == 1 })
        release.signal()
        try await wait { state.read { $0.receipt != nil } }
        #expect(state.read { $0.receipt == .received }) // Not Codex delivery.
        for index in 0..<5 { client.send(.init(grantID: grant, text: "burst \(index)")) }
        try await wait { state.read { $0.receiptCount == 5 && $0.rateRejections == 1 } }
        #expect(state.read { !$0.closed })
        #expect(client.pendingReceiptsForTesting == 0)
        if terminalBatch {
            clock.set(clock.read() + 6_000_000_000)
            let one = try NetworkDeviceTextTransport.textFrame(.init(grantID: grant, text: "terminal first"))
            let two = try NetworkDeviceTextTransport.textFrame(.init(grantID: grant, text: "terminal second"))
            state.mutate { $0.receiverEvents = [] }
            listener.receiveAtCapacityForTesting(connection: connection, bytes: one + two)
            try await wait { state.read { $0.receiverEvents.contains("closed") } }
            queue.sync {} // Observe the full owner-queue batch, not just its first callback.
            #expect(state.read { $0.receiverEvents == ["accepted", "closed"] })
            return
        }
        for index in 0..<3 {
            clock.set(clock.read() + 6_000_000_000)
            client.send(.init(grantID: grant, text: "fill grant share \(index)"))
            try await wait { state.read { $0.receiptCount == 6 + index } }
        }
        clock.set(clock.read() + 6_000_000_000)
        client.send(.init(grantID: grant, text: "over grant share"))
        try await wait { state.read { $0.capacityRejections == 1 } }
        #expect(state.read { !$0.closed })
        #expect(client.pendingReceiptsForTesting == 0)
        try service.revoke(grant: grant)
        try await wait { state.read { $0.closed } }
        client.stop()
        state.mutate { $0.rejected = false }
        client.send(.init(grantID: grant, text: "after stop"))
        try await wait { state.read { $0.rejected } }
        #expect(client.pendingReceiptsForTesting == 0)
    }
    private func wait(timeout: Duration = .seconds(5), _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), "Bounded actual TLS operation must complete")
    }
}
