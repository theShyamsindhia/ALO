#if os(macOS)
import Foundation
import Network
import Testing
import ALOIdentity
import ALORooms
@testable import ALONetworking

@Suite(.serialized)
struct MacDeviceMessageReceiverTests {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        var port: NWEndpoint.Port?
        var connections: [MacDeviceMessageReceiver.Connection] = []
        var events: [MacDeviceMessageReceiver.Connection: [String]] = [:]
        var grants: [UUID] = []
        var receipts: [Int: [CodexDeviceMessagingPolicy.Receipt]] = [:]
        var closed = Set<Int>()
        var ready = Set<Int>()
        var heldDispatch: (() -> Void)?
        var reviews: [(UUID, UUID, CodexDeviceMessagingPolicy.Receipt, MacDeviceMessageReceiver.ReviewReason)] = []
        func mutate(_ body: (State) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
        func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    }

    @Test func admissionCountsHeldPermitsAndTerminalLifecycleCannotReenable() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        let admission = ReceiverDispatchAdmission()
        try admission.setEnabled(true, service: f.service)
        let key = ReceiverDispatchAdmission.Key(grant: UUID(), message: UUID())
        let firstAdmission = admission.acquire(key)
        #expect(firstAdmission.outcome == .scheduled)
        let first = try #require(firstAdmission.permit)
        #expect(admission.acquire(key).outcome == .alreadyScheduled)
        var held = [first]
        for _ in 1..<32 { held.append(try #require(admission.acquire(.init(grant: UUID(), message: UUID())).permit)) }
        #expect(admission.countForTesting == 32)
        #expect(admission.acquire(.init(grant: UUID(), message: UUID())).outcome == .capacity)
        #expect(admission.acquire(key).outcome == .alreadyScheduled)
        first.release()
        #expect(admission.countForTesting == 31)
        let replacement = try #require(admission.acquire(key).permit)
        first.release() // Old release cannot consume the replacement token.
        #expect(admission.countForTesting == 32)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "alo.test.receiver.lifecycle", attributes: .concurrent)
        for _ in 0..<16 {
            group.enter(); queue.async { defer { group.leave() }; try? admission.setEnabled(true, service: f.service) }
            group.enter(); queue.async { defer { group.leave() }; admission.close(service: f.service) }
        }
        try #require(group.wait(timeout: .now() + 2) == .success)
        #expect(!admission.isOpen)
        #expect(throws: CodexDeviceMessagingError.disabled) { try admission.setEnabled(true, service: f.service) }
        #expect(throws: CodexDeviceMessagingError.disabled) { try f.service.challenge() }
        #expect(admission.acquire(.init(grant: UUID(), message: UUID())).outcome == .stopped)
        replacement.release(); held.removeAll()
        #expect(admission.countForTesting == 0)
    }

    /// Actual TLS + a local harmless executable exercise the public facade.
    /// No Codex installation, task queue, audio graph, or user process is used.
    @Test(arguments: [0, 1, 2])
    func actualTLSStoredDispatchPublishesFinalStatusAndReconnectDoesNotResend(mode: Int) async throws {
        let disconnect = mode == 1
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper")
        let marker = helper.appendingPathExtension("marker")
        let release = helper.appendingPathExtension("release")
        let body = "#!/bin/sh\nprintf started >> \"$0.marker\"\nprintf '%s\\0' \"$@\" > \"$0.args\"\ni=0\nwhile [ ! -f \"$0.release\" ] && [ \"$i\" -lt 350 ]; do /bin/sleep 0.01; i=$((i+1)); done\nexit 0\n"
        try Data(body.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        // Cleanup releases only this bounded helper; it never kills raw PIDs.
        defer { try? Data().write(to: release) }
        let owner = UserIdentity.ephemeral(), sender = UserIdentity.ephemeral()
        let receiverTLS = try InstallationIdentity.ephemeral(), senderTLS = try InstallationIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory.appendingPathComponent("network"))
        let manifest = try repository.create(name: "Live text fixture", owner: owner)
        let policy = try NetworkPolicyCenter(repository: repository, networkID: manifest.id)
        try policy.receive(manifest.addingMember(sender.publicIdentity, signedBy: owner))
        let receiverBinding = try DeviceIdentityBinding(user: owner, deviceName: "Receiver", generation: 1,
            installationPublicKeyHash: receiverTLS.publicIdentity.publicKeyHash)
        let senderBinding = try DeviceIdentityBinding(user: sender, deviceName: "Sender", generation: 1,
            installationPublicKeyHash: senderTLS.publicIdentity.publicKeyHash)
        let service = try CodexDeviceMessageService(policy: policy, localDevice: receiverBinding,
            actualLocalTLSHash: receiverTLS.publicIdentity.publicKeyHash,
            journal: CodexDeviceMessageJournal(directoryURL: directory.appendingPathComponent("journal")))
        let state = State()
        let facade = try MacDeviceMessageReceiver(identity: receiverTLS, service: service,
            pins: MemoryPeerPinStore(), executable: .init(locallyApprovedURL: helper),
            queue: DispatchQueue(label: "alo.test.facade", attributes: .concurrent)) { value in
                state.mutate {
                    switch value {
                    case .authenticated(let connection, _):
                        $0.connections.append(connection); $0.events[connection, default: []].append("authenticated")
                    case .received(let connection, _, _): $0.events[connection, default: []].append("received")
                    case .completion(let connection, _, _, _): $0.events[connection, default: []].append("completion")
                    case .dispatchFailed(let connection, _, _): $0.events[connection, default: []].append("failed")
                    case .reviewNeeded(let grant, let message, let receipt, let reason): $0.reviews.append((grant, message, receipt, reason))
                    case .closed(let connection): $0.events[connection, default: []].append("closed")
                    }
                }
            }
        if mode == 2 {
            facade.setDispatchDeliveryForTesting { callback in state.mutate { $0.heldDispatch = callback } }
        }
        try facade.setEnabled(true)
        facade.start { port in state.mutate { $0.port = port } }
        defer { facade.stop() }
        try await wait { state.read { $0.port != nil } }
        let port = try #require(state.read { $0.port })
        func client(_ index: Int) throws -> NetworkDeviceTextTransport {
            try NetworkDeviceTextTransport(endpoint: .hostPort(host: "127.0.0.1", port: port),
                identity: senderTLS, user: sender, binding: senderBinding, policy: policy,
                pins: MemoryPeerPinStore(), queue: DispatchQueue(label: "alo.test.facade.sender.\(index)")) { value in
                    state.mutate {
                        if case .grant(let grant) = value { $0.grants.append(grant) }
                        if case .receipt(_, _, let receipt) = value { $0.receipts[index, default: []].append(receipt) }
                        if case .closed = value { $0.closed.insert(index) }
                        if case .ready = value { $0.ready.insert(index) }
                    }
                }
        }
        let first = try client(0); first.start(); defer { first.stop() }
        try await wait { state.read { $0.connections.count == 1 } }
        let original = try #require(state.read { $0.connections.first })
        let task = UUID()
        facade.approve(connection: original, receiverChosenTask: task, lifetime: 60)
        try await wait { state.read { $0.grants.count == 1 } }
        let grant = try #require(state.read { $0.grants.first })
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: "Remote text is data, not local authority")
        first.send(message)
        if mode == 2 {
            try await wait { state.read { $0.receipts[0]?.first == .received && $0.heldDispatch != nil } }
            #expect(facade.dispatchStored(connection: original, grantID: grant, messageID: message.messageID) == .alreadyScheduled)
            first.stop()
            try await wait { state.read { $0.events[original]?.last == "closed" } }
            let releaseDispatch = try #require(state.read { $0.heldDispatch })
            state.mutate { $0.heldDispatch = nil }
            releaseDispatch()
            try await wait { state.read { !$0.reviews.isEmpty } }
            let review = try #require(state.read { $0.reviews.first })
            #expect(review.0 == grant && review.1 == message.messageID && review.2 == .received)
            #expect(review.3 == .disconnected)
            #expect(facade.localReceipt(grantID: grant, messageID: message.messageID) == .received)
            #expect(state.read { $0.events[original] == ["authenticated", "received", "closed"] })
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(service.nativeWorkerCountForTesting == 0)
            try facade.setEnabled(false)
            #expect(facade.localReceipt(grantID: grant, messageID: message.messageID) == .cancelled)
            facade.stop()
            #expect(facade.dispatchStored(connection: original, grantID: grant, messageID: message.messageID) == .stopped)
            return
        }
        try await wait { state.read { $0.receipts[0]?.first == .received } && FileManager.default.fileExists(atPath: marker.path) }
        var fresh: NetworkDeviceTextTransport?
        defer { fresh?.stop() }
        if disconnect {
            first.stop()
            try await wait { state.read { $0.events[original]?.last == "closed" } }
            fresh = try client(1); fresh?.start()
            try await wait { state.read { $0.connections.count == 2 && $0.ready.contains(1) } }
            // No new grant frame or text send: same still-authorized grant,
            // fresh TLS nonce/session, explicitly queried stored dispatch.
            fresh?.queryReceipt(grantID: grant, messageID: message.messageID)
            try await wait { state.read { $0.receipts[1]?.last == .dispatching } }
        }
        try Data().write(to: release)
        let observing = disconnect ? 1 : 0
        try await wait { state.read { $0.receipts[observing]?.last == .codexQueued } }
        #expect(try String(contentsOf: marker) == "started")
        let args = try Data(contentsOf: helper.appendingPathExtension("args")).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #expect(args.count == 5)
        #expect(args.prefix(4) == ["queue", "--thread", task.uuidString, "--message"])
        let attributed = try #require(args.last?.split(separator: "\n").last)
        let json = try #require(JSONSerialization.jsonObject(with: Data(attributed.utf8)) as? [String: String])
        #expect(json["senderRootID"] == sender.publicIdentity.userID)
        #expect(json["messageID"] == message.messageID.uuidString)
        #expect(json["peerText"] == message.text)
        #expect(!state.read { $0.receipts[observing, default: []].contains(.delivered) })
        if disconnect {
            #expect(state.read { $0.events[original] == ["authenticated", "received", "closed"] })
            #expect(fresh?.pendingReceiptsForTesting == 0)
        } else {
            try await wait { state.read { $0.events[original]?.last == "completion" } }
            #expect(first.pendingReceiptsForTesting == 0)
        }
        #expect(service.nativeWorkerCountForTesting == 0)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), "Bounded facade/native prerequisite must complete")
    }
}
#endif
