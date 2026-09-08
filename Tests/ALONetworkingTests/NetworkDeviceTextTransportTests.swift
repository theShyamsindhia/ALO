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
        var closed = false
        var rejected = false
        func mutate(_ body: (State) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
        func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    }
    @Test func actualTLSWithoutAudioChannelNeedsLocalTaskConsentAndRevokes() async throws {
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
        let service = try CodexDeviceMessageService(policy: policy, localDevice: receiverBinding,
            actualLocalTLSHash: receiverTLS.publicIdentity.publicKeyHash,
            journal: CodexDeviceMessageJournal(directoryURL: directory.appendingPathComponent("journal")))
        try service.setEnabled(true) // Explicit local fixture action, never wire input.
        let state = State(), queue = DispatchQueue(label: "alo.test.device-text")
        let task = UUID()
        var incoming: UUID?
        let listener = try NetworkDeviceTextListener(identity: receiverTLS, service: service,
            pins: MemoryPeerPinStore(), queue: queue) { id, event in
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
            pins: MemoryPeerPinStore(), queue: queue) { event in
                state.mutate {
                    if case .grant(let grant) = event { $0.grant = grant }
                    if case .receipt(_, _, let receipt) = event { $0.receipt = receipt }
                    if case .closed = event { $0.closed = true }
                    if case .rejected = event { $0.rejected = true }
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
        client.send(.init(grantID: grant, text: "Attributed remote text; not local authority"))
        try await wait { state.read { $0.receipt != nil } }
        #expect(state.read { $0.receipt == .received }) // Not Codex delivery.
        try service.revoke(grant: grant)
        try await wait { state.read { $0.closed } }
        client.stop()
        state.mutate { $0.rejected = false }
        client.send(.init(grantID: grant, text: "after stop"))
        try await wait { state.read { $0.rejected } }
        #expect(client.pendingReceiptsForTesting == 0)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), "Bounded actual TLS operation must complete")
    }
}
