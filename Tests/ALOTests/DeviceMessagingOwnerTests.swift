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
        #expect(DeviceMessagingCommand.Failure.invalidInput.localizedDescription.contains("UTF-8"))
        #expect(DeviceMessagingCommand.Failure.inputTooLarge.localizedDescription.contains("16 KiB"))
        for status: LocalDeviceMessageProtocol.Response.Status in [.disabled, .revoked, .rejected, .unavailable, .definitelyNotQueued] {
            #expect(throws: (any Error).self) { try DeviceMessagingCommandRunner.requireAcceptedResponse(.init(status: status)) }
        }
        for status: LocalDeviceMessageProtocol.Response.Status in [.pendingApproval, .capabilityPending, .ready, .authenticatedReceipt, .codexQueued, .deliveredConfirmed, .uncertain, .pending, .statusUnknown] {
            #expect(throws: Never.self) { try DeviceMessagingCommandRunner.requireAcceptedResponse(.init(status: status)) }
        }
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
        var messageHistory: [String] = []
        var queryResults: [(UUID, UUID)] = []
        func read<T>(_ body: (Captured) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
        func update(_ body: (Captured) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
        func accept(_ snapshot: MacDeviceMessagingController.ViewState) {
            update {
                if snapshot.revision > $0.view.revision {
                    $0.view = snapshot; $0.messageHistory.append(contentsOf: snapshot.messageStatuses)
                }
            }
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
    @Test(arguments: [false, true])
    func heldRealApprovalAndRepeatedFailedRevocationCannotForgetAuthority(retireNetwork: Bool) async throws {
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
        if retireNetwork {
            try f.policy.receive(f.policy.snapshot().removingMember(userID: f.sender.publicIdentity.userID, signedBy: f.user))
            try await wait("actual retired receiver authority") {
                service.localGrants().contains { $0.id == grant && $0.revoked }
            }
            owner.forget(registration)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while captured.read({ $0.view.registrations.contains { $0.id == registration } }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(captured.read { !$0.view.registrations.contains { $0.id == registration } },
                "Retired authority must settle pending approvals even if the callback never arrives")
            return
        }
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
    @Test(arguments: [false, true]) func twoActualOwnersSendAttributedTextAndReconnectForStatusWithoutResend(failedRevocation: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let senderDirectory = f.directory.appendingPathComponent("sender")
        try FileManager.default.createDirectory(at: senderDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let senderHelper = senderDirectory.appendingPathComponent("helper")
        let script = "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$0.args.tmp\"\n/bin/mv \"$0.args.tmp\" \"$0.args\"\nprintf 'run\\n' >> \"$0.runs\"\nexit 0\n"
        for helper in [f.helper, senderHelper] {
            try Data(script.utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        }
        let received = Captured(), sent = Captured()
        let receiver = DeviceMessagingOwner(testing: .init(directory: f.directory,
            beforeNetworkPublication: { _, service in received.update { $0.service = service } },
            beforeRevoke: { if received.read({ $0.failRevoke }) { throw Injected.revocationUnavailable } },
            networkReady: { port in received.update { $0.port = port } })) { received.accept($0) }
        let sender = DeviceMessagingOwner(testing: .init(directory: senderDirectory,
            networkReady: { port in sent.update { $0.port = port } },
            queryResultObserved: { grant, message in sent.update { $0.queryResults.append((grant, message)) } })) { sent.accept($0) }
        defer { sender.stopAndDrainForTesting(); receiver.stopAndDrainForTesting() }
        try await enable(receiver, received, f)
        sender.replaceIdentity(f.sender.publicIdentity.userID); sender.approveExecutable(senderHelper)
        let expected = try CodexLocalExecutableApproval(locallyApprovedURL: senderHelper).canonicalURL.path
        try await wait("second actual owner executable approved") { sent.read { $0.view.executable == expected && !$0.view.stopping } }
        sender.enableIngress()
        try await wait("second actual owner ingress enabled") { sent.read { $0.view.enabled } }
        func registerAndConfirm(_ owner: DeviceMessagingOwner, captured: Captured, directory: URL, helper: URL, task: UUID) async throws -> UUID {
            let response = try MacOwnerSocket.request(.init(operation: .register, taskID: task, title: "Explicit local task"), directory: directory.appendingPathComponent("socket"))
            let registration = try #require(response.registration)
            owner.testCapability(registration)
            try await wait("actual capability helper completed") { captured.read { $0.view.capabilityStatuses[registration]?.hasPrefix("Queued test") == true } }
            let args = try Data(contentsOf: helper.appendingPathExtension("args")).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            try #require(Array(args.prefix(4)) == ["queue", "--thread", task.uuidString, "--message"])
            let nonceLine = try #require(args.last?.split(separator: "\n").first { $0.hasPrefix("Confirmation code: ") })
            owner.confirm(registration, response: String(nonceLine.dropFirst("Confirmation code: ".count)))
            try await wait("actual local confirmation accepted") { captured.read { $0.view.registrations.contains { $0.id == registration && $0.state == .verified } } }
            return registration
        }
        let receiverTask = UUID(), senderTask = UUID()
        let receiverRegistration = try await registerAndConfirm(receiver, captured: received, directory: f.directory, helper: f.helper, task: receiverTask)
        let senderRegistration = try await registerAndConfirm(sender, captured: sent, directory: senderDirectory, helper: senderHelper, task: senderTask)
        let repeated = try MacOwnerSocket.request(.init(operation: .register, taskID: senderTask, title: "Explicit local task"),
            directory: senderDirectory.appendingPathComponent("socket"))
        #expect(repeated.registration == senderRegistration && repeated.status == .ready)
        receiver.addNetwork(f.network, user: f.user, identity: f.identity, pins: MemoryPeerPinStore(), access: f.access, token: receiver.currentGeneration)
        sender.addNetwork(f.network, user: f.sender, identity: f.senderIdentity, pins: MemoryPeerPinStore(),
            access: NetworkDeviceAccess(policy: f.policy, localDevice: f.senderBinding), token: sender.currentGeneration)
        try await wait("both actual network contexts ready") { received.read { $0.port != nil } && sent.read { $0.port != nil } }
        let candidate = NetworkDeviceMessagingDiscovery.Candidate(id: UUID(), networkHint: f.network,
            endpoint: .hostPort(host: "127.0.0.1", port: try #require(received.read { $0.port })))
        sender.connect(candidate)
        try await wait("actual two-owner TLS context") { received.read { !$0.view.incoming.isEmpty } && sent.read { !$0.view.remotes.isEmpty } }
        let remote = try #require(sent.read { $0.view.remotes.first })
        #expect(remote.root == f.user.publicIdentity.userID)
        #expect(remote.spki == f.identity.publicIdentity.publicKeyHash.map { String(format: "%02x", $0) }.joined())
        receiver.approve(try #require(received.read { $0.view.incoming.first?.id }), registration: receiverRegistration)
        try await wait("actual receiver-issued grant reached sender owner") { sent.read { $0.view.remotes.first?.grants.isEmpty == false } }
        let grant = try #require(sent.read { $0.view.remotes.first?.grants.first })
        sender.bind(remote.id, grant: grant, registration: senderRegistration)
        try await wait("opaque destination bound locally") { sent.read { !$0.view.destinations.isEmpty } }
        let destination = try #require(sent.read { $0.view.destinations.first?.id })
        if failedRevocation {
            received.update { $0.failRevoke = true }
            receiver.forget(receiverRegistration)
            try await wait("explicit revocation failed before ordinary message arrives") {
                received.read { $0.view.error?.contains("Grant revocation did not complete") == true }
            }
            #expect(try MacOwnerSocket.request(.init(operation: .status, registration: receiverRegistration),
                directory: f.directory.appendingPathComponent("socket")).status == .revoked)
            #expect(try MacOwnerSocket.request(.init(operation: .register, taskID: receiverTask, title: "Same receiver task"),
                directory: f.directory.appendingPathComponent("socket")).status == .revoked)
            receiver.approve(UUID(), registration: receiverRegistration)
            try await wait("ordinary invalid action is separately reported") { received.read { $0.view.notice?.contains("Approval unavailable") == true } }
            #expect(received.read { $0.view.error?.contains("Grant revocation did not complete") == true })
        }
        let message = UUID(), body = "Peer data: exact two-owner text; never a task selector."
        let request = try LocalDeviceMessageProtocol.Request(operation: .send, registration: senderRegistration,
            destination: destination, messageID: message, text: body)
        let accepted = try MacOwnerSocket.request(request, directory: senderDirectory.appendingPathComponent("socket"))
        #expect(accepted.status == .pending)
        let receivedStatus = "\(message.uuidString): \(LocalDeviceMessageProtocol.Response.Status.authenticatedReceipt.rawValue)"
        let queuedStatus = "\(message.uuidString): \(LocalDeviceMessageProtocol.Response.Status.codexQueued.rawValue)"
        try await wait("live queued receipt reached actual sender owner without query") { sent.read { $0.messageHistory.contains(queuedStatus) } }
        #expect(sent.read { $0.messageHistory.contains(receivedStatus) })
        if failedRevocation {
            #expect(received.read { $0.view.error?.contains("Grant revocation did not complete") == true },
                "Ordinary incoming receipts must not hide a failed authority revocation.")
        }
        try await wait("incoming receipt is presented separately") { received.read { $0.view.notice?.contains(message.uuidString) == true } }
        #expect(sender.pendingCountForTesting == 0)
        #expect(sent.read { $0.queryResults.isEmpty })
        let args = try Data(contentsOf: f.helper.appendingPathExtension("args")).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #expect(Array(args.prefix(4)) == ["queue", "--thread", receiverTask.uuidString, "--message"])
        let jsonLine = try #require(args.last?.split(separator: "\n").last)
        let attributed = try #require(JSONSerialization.jsonObject(with: Data(jsonLine.utf8)) as? [String: String])
        #expect(attributed["senderRootID"] == f.sender.publicIdentity.userID)
        #expect(attributed["messageID"] == message.uuidString)
        #expect(attributed["peerText"] == body)
        #expect(try String(contentsOf: f.helper.appendingPathExtension("runs")) == "run\nrun\n")
        #expect(try String(contentsOf: senderHelper.appendingPathExtension("runs")) == "run\n")
        #expect(try MacOwnerSocket.request(request, directory: senderDirectory.appendingPathComponent("socket")).status == .codexQueued)
        let conflict = try LocalDeviceMessageProtocol.Request(operation: .send, registration: senderRegistration,
            destination: destination, messageID: message, text: "Different body for the same ID")
        #expect(try MacOwnerSocket.request(conflict, directory: senderDirectory.appendingPathComponent("socket")).status == .rejected)
        sender.closePeerForTesting(remote.id)
        try await wait("actual old sender transport closed") { sent.read { $0.view.remotes.isEmpty } }
        #expect(sender.observationCountForTesting == 0, "Closed peers must release their live observation slots.")
        sender.connect(candidate)
        try await wait("explicit fresh connection rebound same approved identity") { sent.read { $0.view.remotes.first?.id != nil && $0.view.remotes.first?.id != remote.id } }
        #expect(sent.read { $0.view.destinations.first?.id == destination })
        let query = try MacOwnerSocket.request(.init(operation: .receipt, registration: senderRegistration, messageID: message),
            directory: senderDirectory.appendingPathComponent("socket"))
        #expect(query.status == .codexQueued)
        try await wait("fresh authenticated status query settled") {
            sender.pendingCountForTesting == 0 && sent.read { $0.queryResults.contains { $0.0 == grant && $0.1 == message } }
        }
        #expect(try String(contentsOf: f.helper.appendingPathExtension("runs")) == "run\nrun\n")
        #expect(try String(contentsOf: senderHelper.appendingPathExtension("runs")) == "run\n")
        #expect(!sent.read { $0.messageHistory.contains("\(message.uuidString): \(LocalDeviceMessageProtocol.Response.Status.deliveredConfirmed.rawValue)") })
        let receiverService = try #require(received.read { $0.service })
        #expect(receiverService.localReceipt(grantID: grant, messageID: message) == .codexQueued)
        // Fill the actual local presentation table through the socket. Clearing
        // one status must not delete the receiver's durable duplicate evidence.
        for _ in 0..<31 {
            let next = UUID()
            let accepted = try MacOwnerSocket.request(.init(operation: .send, registration: senderRegistration,
                destination: destination, messageID: next, text: "Bounded status capacity test"),
                directory: senderDirectory.appendingPathComponent("socket"))
            #expect(accepted.status == .pending)
            // The real receiver intentionally rate-limits this rapid sequence.
            // Both queued and rejected attempts retain local presentation slots;
            // this checks that bound, not permission to bypass receiver limits.
            try await wait("settled local status for capacity control") {
                sent.read { $0.view.messages.contains { $0.message == next && ($0.status == "codexQueued" || $0.status == "unavailable") } }
            }
        }
        let overflow = try LocalDeviceMessageProtocol.Request(operation: .send, registration: senderRegistration,
            destination: destination, messageID: UUID(), text: "New local presentation slot")
        #expect(try MacOwnerSocket.request(overflow, directory: senderDirectory.appendingPathComponent("socket")).status == .unavailable)
        sender.retireMessage(registration: senderRegistration, message: message)
        try await wait("explicit Settings action removed local status") {
            sent.read { !$0.view.messages.contains { $0.message == message } }
        }
        #expect(receiverService.localReceipt(grantID: grant, messageID: message) == .codexQueued)
        #expect(try MacOwnerSocket.request(overflow, directory: senderDirectory.appendingPathComponent("socket")).status == .pending,
            "Local capacity was reclaimed. This is not evidence of receiver capacity or delivery.")
        if failedRevocation {
            sender.testCapability(senderRegistration)
            try await wait("fresh capability test invalidated the previous local capability") {
                sent.read { $0.view.registrations.contains { $0.id == senderRegistration && $0.state == .capabilityPending } }
            }
        } else {
            try f.policy.receive(f.policy.snapshot().removingMember(userID: f.sender.publicIdentity.userID, signedBy: f.user))
            try await wait("actual policy revision retired old destinations") {
                sent.read { $0.view.destinations.isEmpty && $0.view.error?.contains("Network authority changed") == true }
            }
        }
        #expect(sender.routeCountForTesting == 0, "Network retirement and reverification must retire the owner's routes.")
        #expect(sent.read { $0.view.destinations.isEmpty }, "Settings must not offer unusable old destination commands.")
    }
}
#endif
