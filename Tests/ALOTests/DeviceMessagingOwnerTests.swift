#if os(macOS)
import Foundation
import Network
import Testing
import ALOIdentity
import ALORooms
@testable import ALOAppModel
@testable import ALONetworking
@testable import ALO

/// Actual owner, socket, fixed local helper and TLS approval path. Holds are
/// outside lifecycle/security locks; no installed app, Keychain or Codex task.
@Suite(.serialized)
struct DeviceMessagingOwnerTests {
    enum Injected: Error { case revocationUnavailable }
    @Test func explicitCLIRunnerRejectsMalformedInputWithoutAppOrSocketBootstrap() {
        #expect(throws: DeviceMessagingCommand.Failure.invalidArguments) { try DeviceMessagingCommandRunner.run(["unknown"]) }
    }
    final class Captured: @unchecked Sendable {
        let lock = NSLock()
        var view = MacDeviceMessagingController.ViewState()
        var service: CodexDeviceMessageService?
        var port: NWEndpoint.Port?
        var grant: UUID?
        var heldApproval: (() -> Void)?
        var failRevoke = false
        var entered = false
        var explicitlyReleased: Bool?
        var discovery: [(UUID, Set<UUID>)] = []
        func read<T>(_ body: (Captured) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
        func update(_ body: (Captured) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
        func accept(_ snapshot: MacDeviceMessagingController.ViewState) {
            update { if snapshot.revision > $0.view.revision { $0.view = snapshot } }
        }
    }
    struct Fixture {
        let directory: URL
        let helper: URL
        let user = UserIdentity.ephemeral()
        let sender = UserIdentity.ephemeral()
        let identity: InstallationIdentity
        let senderIdentity: InstallationIdentity
        let policy: NetworkPolicyCenter
        let access: NetworkDeviceAccess
        let senderBinding: DeviceIdentityBinding
        let network: UUID
        init() throws {
            directory = URL(fileURLWithPath: "/private/tmp/alo-owner-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            helper = directory.appendingPathComponent("helper")
            try Data("#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$0.args.tmp\"\n/bin/mv \"$0.args.tmp\" \"$0.args\"\nexit 0\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            identity = try InstallationIdentity.ephemeral(); senderIdentity = try InstallationIdentity.ephemeral()
            let repository = NetworkRepository(directoryURL: directory.appendingPathComponent("network"))
            let manifest = try repository.create(name: "Owner lifecycle", owner: user)
            network = manifest.id
            policy = try NetworkPolicyCenter(repository: repository, networkID: network)
            try policy.receive(manifest.addingMember(sender.publicIdentity, signedBy: user))
            access = NetworkDeviceAccess(policy: policy, localDevice: try DeviceIdentityBinding(user: user,
                deviceName: "Receiver", generation: 1, installationPublicKeyHash: identity.publicIdentity.publicKeyHash))
            senderBinding = try DeviceIdentityBinding(user: sender, deviceName: "Sender", generation: 1,
                installationPublicKeyHash: senderIdentity.publicIdentity.publicKeyHash)
        }
        func clean() { try? FileManager.default.removeItem(at: directory) }
    }
    private func wait(_ label: String = "owner prerequisite", diagnostic: (() -> String)? = nil, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        if !predicate() { print("OWNER_PREREQUISITE \(label): \(diagnostic?() ?? "no additional snapshot")") }
        try #require(predicate(), Comment(rawValue: label))
    }
    private func approve(_ owner: DeviceMessagingOwner, _ captured: Captured, _ fixture: Fixture) async throws {
        let expected = try CodexLocalExecutableApproval(locallyApprovedURL: fixture.helper).canonicalURL.path
        owner.replaceIdentity(fixture.user.publicIdentity.userID)
        owner.approveExecutable(fixture.helper)
        try await wait("approved executable and completed prior stop", diagnostic: {
            captured.read { "approved=\($0.view.executable ?? "nil") expected=\(expected) stopping=\($0.view.stopping) enabled=\($0.view.enabled) error=\($0.view.error ?? "nil")" }
        }) { captured.read { $0.view.executable == expected && !$0.view.stopping } }
    }
    private func enable(_ owner: DeviceMessagingOwner, _ captured: Captured, _ fixture: Fixture) async throws {
        try await approve(owner, captured, fixture)
        owner.enableIngress()
        try await wait("owner ingress enabled", diagnostic: {
            captured.read { "stopping=\($0.view.stopping) enabled=\($0.view.enabled) error=\($0.view.error ?? "nil")" }
        }) { captured.read { $0.view.enabled } }
    }
    private func stop(_ owner: DeviceMessagingOwner, _ captured: Captured) async throws {
        owner.stop(); try await wait("completed owner teardown") { captured.read { !$0.view.enabled && !$0.view.stopping } }
    }
    @Test func explicitEnableRetriesAfterActualOccupiedSocketIsReleased() async throws {
        let f = try Fixture(); defer { f.clean() }
        let captured = Captured()
        let owner = DeviceMessagingOwner(testing: .init(directory: f.directory)) { captured.accept($0) }
        defer { owner.stopAndDrainForTesting() }
        try await approve(owner, captured, f)
        let occupied = try MacOwnerSocket.Server(directory: f.directory.appendingPathComponent("socket")) { _ in .init(status: .disabled) }
        defer { occupied.stop() }
        owner.enableIngress()
        try await wait("actual occupied endpoint construction rejected and cleanup completed") {
            captured.read { $0.view.error != nil && !$0.view.stopping }
        }
        try #require(captured.read { !$0.view.enabled })
        occupied.stop() // release actual owner lock/socket; never delete paths to force success
        owner.enableIngress() // same explicit true action used by the Settings toggle
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !captured.read({ $0.view.enabled }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(captured.read { $0.view.enabled }, "Explicit retry must construct ingress after the real obstruction is gone.")
    }
    @Test func heldActualReceiverConstructionCannotPublishOrEnableAfterDisable() async throws {
        let f = try Fixture(); defer { f.clean() }
        let captured = Captured(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let owner = DeviceMessagingOwner(testing: .init(directory: f.directory,
            beforeNetworkPublication: { _, service in
                captured.update { $0.service = service; $0.entered = true }
                let result = release.wait(timeout: .now() + 3)
                captured.update { $0.explicitlyReleased = result == .success }
            }, networkReady: { port in captured.update { $0.port = port } })) { view in captured.accept(view) }
        defer { release.signal(); owner.stopAndDrainForTesting() }
        try await enable(owner, captured, f)
        owner.addNetwork(f.network, user: f.user, identity: f.identity, pins: MemoryPeerPinStore(),
            access: f.access, token: owner.currentGeneration)
        try await wait("actual receiver construction entered", diagnostic: { captured.read { $0.view.error ?? "no UI error" } }) { captured.read { $0.entered } }
        owner.stop()
        try #require(captured.read { !$0.view.enabled && $0.view.stopping })
        release.signal()
        try await wait("stopped after releasing receiver construction") { captured.read { !$0.view.stopping } }
        #expect(captured.read { $0.explicitlyReleased == true })
        let service = try #require(captured.read { $0.service })
        #expect(throws: CodexDeviceMessagingError.disabled) { try service.challenge() }
        #expect(captured.read { $0.port == nil })
    }
    @Test func staleExecutableHashCannotRestoreApprovalAfterIdentityChanges() async throws {
        let f = try Fixture(); defer { f.clean() }
        let captured = Captured(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let owner = DeviceMessagingOwner(testing: .init(directory: f.directory, afterExecutableHash: {
            captured.update { $0.entered = true }
            let result = release.wait(timeout: .now() + 3)
            captured.update { $0.explicitlyReleased = result == .success }
        })) { view in captured.accept(view) }
        defer { release.signal(); owner.stopAndDrainForTesting() }
        owner.replaceIdentity(f.user.publicIdentity.userID); owner.approveExecutable(f.helper)
        try await wait("actual executable hash entered") { captured.read { $0.entered } }
        owner.replaceIdentity(f.sender.publicIdentity.userID)
        release.signal()
        try await stop(owner, captured)
        #expect(captured.read { $0.explicitlyReleased == true })
        #expect(captured.read { $0.view.executable == nil && !$0.view.enabled })
    }
    @Test func publishedPolicyRevisionReplacesCapturedDiscoveryNetworkSet() async throws {
        let f = try Fixture(); defer { f.clean() }
        let captured = Captured()
        let owner = DeviceMessagingOwner(testing: .init(directory: f.directory,
            beforeNetworkPublication: { _, service in captured.update { $0.service = service } },
            discoveryReplacement: { token, networks in captured.update { $0.discovery.append((token, networks)) } })) { view in
                captured.accept(view)
            }
        defer { owner.stopAndDrainForTesting() }
        try await enable(owner, captured, f)
        owner.addNetwork(f.network, user: f.user, identity: f.identity, pins: MemoryPeerPinStore(), access: f.access, token: owner.currentGeneration)
        try await wait("published initial network discovery", diagnostic: { captured.read { $0.view.error ?? "no UI error" } }) { captured.read { $0.discovery.last?.1 == Set([f.network]) } }
        let original = try #require(captured.read { $0.discovery.last?.0 })
        try f.policy.receive(f.policy.snapshot().removingMember(userID: f.sender.publicIdentity.userID, signedBy: f.user))
        try await wait("replaced discovery after policy revision") { captured.read { $0.discovery.last?.1.isEmpty == true } }
        #expect(captured.read { $0.discovery.last?.0 != original })
        let service = try #require(captured.read { $0.service })
        #expect(throws: CodexDeviceMessagingError.disabled) { try service.challenge() }
        #expect(captured.read { $0.view.candidates.isEmpty })
        try await stop(owner, captured)
    }
    @Test func heldRealApprovalAndRepeatedFailedRevocationCannotForgetAuthority() async throws {
        let f = try Fixture(); defer { f.clean() }
        let captured = Captured()
        let owner = DeviceMessagingOwner(testing: .init(directory: f.directory,
            beforeNetworkPublication: { _, service in captured.update { $0.service = service } },
            approvalDelivery: { callback in captured.update { $0.heldApproval = callback } },
            beforeRevoke: { if captured.read({ $0.failRevoke }) { throw Injected.revocationUnavailable } },
            networkReady: { port in captured.update { $0.port = port } })) { view in captured.accept(view) }
        defer { owner.stopAndDrainForTesting() }
        try await enable(owner, captured, f)
        let task = UUID()
        let registrationResponse = try MacOwnerSocket.request(.init(operation: .register, taskID: task, title: "Actual helper task"),
            directory: f.directory.appendingPathComponent("socket"))
        let registration = try #require(registrationResponse.registration)
        owner.testCapability(registration)
        let argsURL = f.helper.appendingPathExtension("args")
        try await wait("completed actual capability helper", diagnostic: { captured.read { $0.view.capabilityStatuses[registration] ?? $0.view.error ?? "no status" } }) {
            FileManager.default.fileExists(atPath: argsURL.path)
                && captured.read { $0.view.capabilityStatuses[registration]?.hasPrefix("Queued test") == true }
        }
        let args = try Data(contentsOf: argsURL).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        try #require(Array(args.prefix(4)) == ["queue", "--thread", task.uuidString, "--message"])
        let line = try #require(args.last?.split(separator: "\n").first { $0.hasPrefix("Confirmation code: ") })
        owner.confirm(registration, response: String(line.dropFirst("Confirmation code: ".count)))
        try await wait("confirmed local task") { captured.read { $0.view.registrations.contains { $0.id == registration && $0.state == .verified } } }
        owner.addNetwork(f.network, user: f.user, identity: f.identity, pins: MemoryPeerPinStore(),
            access: f.access, token: owner.currentGeneration)
        try await wait("actual receiver listening", diagnostic: { captured.read { $0.view.error ?? "no UI error" } }) { captured.read { $0.port != nil } }
        let client = try NetworkDeviceTextTransport(endpoint: .hostPort(host: "127.0.0.1", port: try #require(captured.read { $0.port })),
            identity: f.senderIdentity, user: f.sender, binding: f.senderBinding, policy: f.policy,
            pins: MemoryPeerPinStore(), queue: DispatchQueue(label: "alo.owner.test.sender")) { event in
                if case .grant(let grant) = event { captured.update { $0.grant = grant } }
            }
        client.start(); defer { client.stop() }
        try await wait { captured.read { !$0.view.incoming.isEmpty } }
        owner.approve(try #require(captured.read { $0.view.incoming.first?.id }), registration: registration)
        try await wait { captured.read { $0.heldApproval != nil && $0.grant != nil } }
        let service = try #require(captured.read { $0.service }), grant = try #require(captured.read { $0.grant })
        try #require(service.localGrants().contains { $0.id == grant && !$0.revoked })
        owner.forget(registration)
        try await wait { captured.read { $0.view.capabilityStatuses[registration]?.hasPrefix("Revoking") == true } }
        let denied = try MacOwnerSocket.request(.init(operation: .receipt, registration: registration, messageID: UUID()),
            directory: f.directory.appendingPathComponent("socket"))
        #expect(denied.status == .revoked)
        captured.update { $0.failRevoke = true }
        let deliverApproval = try #require(captured.read { $0.heldApproval })
        deliverApproval()
        try await wait { captured.read { $0.view.error?.contains("Late approval revocation failed") == true } }
        owner.forget(registration)
        try await wait { captured.read { $0.view.error?.contains("Grant revocation did not complete") == true } }
        #expect(captured.read { $0.view.registrations.contains { $0.id == registration } })
        #expect(service.localGrants().contains { $0.id == grant && !$0.revoked })
        captured.update { $0.failRevoke = false }; owner.forget(registration)
        try await wait { captured.read { !$0.view.registrations.contains { $0.id == registration } } }
        #expect(service.localGrants().contains { $0.id == grant && $0.revoked })
        try await stop(owner, captured)
    }
}
#endif
