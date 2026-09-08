import AppKit
import Combine
import Foundation
import Network
import ALOIdentity
import ALONetworking
import ALOAppModel

/// App-lifetime presentation owner. The socket and service worker never wait
/// synchronously for this actor. No channel/media phase owns these resources.
@MainActor
final class MacDeviceMessagingController: ObservableObject {
    struct Incoming: Identifiable {
        let id: UUID; let network: UUID; let root: String; let spki: String
    }
    struct Remote: Identifiable {
        let id: UUID; let network: UUID; let root: String; let spki: String; let grants: [UUID]
    }
    struct Destination: Identifiable {
        let id: UUID; let registration: UUID; let root: String; let spki: String
    }
    struct StoredGrant: Identifiable {
        let id: UUID; let network: UUID; let task: UUID; let revoked: Bool; let records: Int
    }
    struct ViewState {
        var revision: UInt64 = 0
        var enabled = false
        var stopping = false
        var executable: String?
        var registrations: [DeviceMessageRegistration.Entry] = []
        var incoming: [Incoming] = []
        var remotes: [Remote] = []
        var candidates: [NetworkDeviceMessagingDiscovery.Candidate] = []
        var destinations: [Destination] = []
        var storedGrants: [StoredGrant] = []
        var messageStatuses: [String] = []
        var capabilityStatuses: [UUID: String] = [:]
        var error: String?
    }
    @Published private(set) var view = ViewState()
    let account: NetworkAccountModel
    private var core: DeviceMessagingOwner!
    private var identityObserver: AnyCancellable?
    init(account: NetworkAccountModel) {
        self.account = account
        core = DeviceMessagingOwner { [weak self] snapshot in
            Task { @MainActor in
                guard let self, snapshot.revision > self.view.revision else { return }
                self.view = snapshot
            }
        }
        identityObserver = account.$identityReady.combineLatest(account.$identity)
            .map { ready, identity in ready ? identity?.publicIdentity.userID : nil }
            .removeDuplicates().sink { [weak self] root in self?.core.replaceIdentity(root) }
    }
    func approveExecutable(_ url: URL) { core.approveExecutable(url) }
    func setEnabled(_ value: Bool) { if value { core.enableIngress() } else { core.stop() } }
    func enableNetwork(_ networkID: UUID) {
        guard account.identityReady, let user = account.identity else { return }
        let token = core.currentGeneration
        Task {
            do {
                let installation = try await core.loadInstallation()
                let access = try await account.deviceAuthorization(networkID: networkID.uuidString,
                    installationHash: installation.identity.publicIdentity.publicKeyHash,
                    deviceName: Host.current().localizedName ?? "ALO device")
                guard account.identityReady, account.identity?.publicIdentity == user.publicIdentity else { return }
                core.addNetwork(networkID, user: user, identity: installation, access: access, token: token)
            } catch { core.reportUnavailable(token: token) }
        }
    }
    func test(_ registration: UUID) { core.testCapability(registration) }
    func confirm(_ registration: UUID, response: String) { core.confirm(registration, response: response) }
    func forget(_ registration: UUID) { core.forget(registration) }
    func retireGrant(_ grant: UUID, network: UUID) { core.retireGrant(grant, network: network) }
    func connect(_ candidate: NetworkDeviceMessagingDiscovery.Candidate) { core.connect(candidate) }
    func approve(_ incoming: UUID, registration: UUID) { core.approve(incoming, registration: registration) }
    func bind(_ remote: UUID, grant: UUID, registration: UUID) { core.bind(remote, grant: grant, registration: registration) }
    func stop() { core.stop() }
}

/// Mutable transport/resource maps are confined to worker. The separate short
/// state lock covers only pure admission/snapshots, never keychain/hash/fsync or
/// callback invocation. Lifecycle work is not queued behind a held hash worker.
final class DeviceMessagingOwner: @unchecked Sendable {
    typealias UI = MacDeviceMessagingController
    private let worker = DispatchQueue(label: "alo.device-owner.services", qos: .utility)
    private let lifecycle = DispatchQueue(label: "alo.device-owner.lifecycle", qos: .userInitiated)
    private let lifecycleFence = NSLock() // publication/enable vs actual teardown; never socket state work
    private let stateLock = NSLock()
    private var state = DeviceMessagingControllerState()
    private var generation = UUID()
    private var root: String?
    private var enabled = false
    private var approval: CodexLocalExecutableApproval?
    private var approvalChoice = UUID()
    private var forgetting: Set<UUID> = [] // stateLock; blocks new local effects during actual revoke
    private var snapshot = UI.ViewState()
    private let publish: (UI.ViewState) -> Void
    struct Testing {
        var directory: URL
        var beforeNetworkPublication: ((MacDeviceMessageReceiver, CodexDeviceMessageService) -> Void)?
        var approvalDelivery: ((@escaping () -> Void) -> Void)?
        var beforeRevoke: (() throws -> Void)?
        var afterExecutableHash: (() -> Void)?
        var networkReady: ((NWEndpoint.Port) -> Void)?
        var discoveryReplacement: ((UUID, Set<UUID>) -> Void)?
    }
    private let testing: Testing?
    private var server: MacOwnerSocket.Server?
    private var probe: MacDeviceCapabilityProbe?
    private var discovery: NetworkDeviceMessagingDiscovery?
    private var networks: [UUID: Context] = [:]
    private var incoming: [UUID: (UUID, MacDeviceMessageReceiver.Connection)] = [:]
    private var outbound: [UUID: Peer] = [:]
    private struct Route {
        var peer: UUID
        let grant: UUID; let registration: UUID; let remote: NetworkDeviceAuthenticatedRemote
    }
    private var routes: [UUID: Route] = [:]
    private struct Observed {
        let ticket: DeviceMessagingControllerState.Ticket
        let observation: DeviceMessagingControllerState.Observation
        let registration: UUID
        let querying: Bool
    }
    private var observations: [String: Observed] = [:] // no message text retained after enqueue
    private var challenges: [UUID: DeviceMessageRegistration.Challenge] = [:]
    private var grants: [UUID: (UUID, UUID)] = [:] // grant -> network, local registration
    private struct PendingApproval { let registration: UUID; let task: UUID; let token: UUID }
    private var approvals: [UUID: PendingApproval] = [:]
    private var messageKeys: [(UUID, UUID)] = []
    private var liveReceivers: [MacDeviceMessageReceiver] = [] // lifecycleFence: teardown references only
    private var liveTransports: [NetworkDeviceTextTransport] = []
    private var liveProbe: MacDeviceCapabilityProbe? // lifecycleFence, not deferred worker cleanup
    private var liveServer: MacOwnerSocket.Server?
    private var liveDiscovery: NetworkDeviceMessagingDiscovery?
    private var discoveryGeneration = UUID()
    private struct Context {
        let identity: InstallationIdentity; let pins: PeerPinStore; let user: UserIdentity; let access: NetworkDeviceAccess
        let receiver: MacDeviceMessageReceiver; let service: CodexDeviceMessageService
        let observer: UUID
    }
    private struct Peer {
        let network: UUID; let transport: NetworkDeviceTextTransport
        var descriptor: NetworkDeviceAuthenticatedRemote?
        var grants: [UUID] = []
    }
    init(testing: Testing? = nil, publish: @escaping (UI.ViewState) -> Void) { self.testing = testing; self.publish = publish }
    var currentGeneration: UUID { stateLock.withLock { generation } }
    private func current(_ token: UUID) -> Bool { stateLock.withLock { enabled && generation == token } }
    private func emit() {
        let value = stateLock.withLock { () -> UI.ViewState in
            snapshot.revision += 1
            snapshot.registrations = state.registrations
            snapshot.messageStatuses = messageKeys.prefix(32).compactMap { registration, message in
                state.snapshot(registration: registration, messageID: message).map { "\(message.uuidString): \($0.status.rawValue)" }
            }
            return snapshot
        }
        publish(value)
    }
    func replaceIdentity(_ identity: String?) {
        let changed = stateLock.withLock { () -> Bool in
            guard root != identity else { return false }
            root = identity; approvalChoice = UUID(); approval = nil; snapshot.executable = nil
            return true
        }
        if changed { stop() }
    }
    func approveExecutable(_ url: URL) {
        stop()
        let ticket = stateLock.withLock { () -> (UUID, UUID, String?) in
            approvalChoice = UUID(); return (generation, approvalChoice, root)
        }
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let value = try CodexLocalExecutableApproval(locallyApprovedURL: url)
                self.testing?.afterExecutableHash?()
                self.stateLock.withLock {
                    guard self.generation == ticket.0, self.approvalChoice == ticket.1, self.root == ticket.2 else { return }
                    self.approval = value; self.snapshot.executable = value.canonicalURL.path
                }
            } catch { self.stateLock.withLock {
                guard self.generation == ticket.0, self.approvalChoice == ticket.1, self.root == ticket.2 else { return }
                self.snapshot.error = "Executable approval failed."
            } }
            self.emit()
        }
    }
    func enableIngress() {
        let token: UUID? = stateLock.withLock {
            guard !enabled, !snapshot.stopping, root != nil, approval != nil else { return nil }
            generation = UUID(); enabled = true; snapshot.error = nil
            return generation
        }
        guard let token else { return }
        worker.async { [weak self] in
            guard let self, self.current(token) else { return }
            do {
                let directory = try self.testing?.directory.appendingPathComponent("socket") ?? DeviceMessagingCommandRunner.endpointDirectory
                let server = try MacOwnerSocket.Server(directory: directory) { [weak self] request in
                    self?.handle(request) ?? .init(status: .disabled)
                }
                let preparedProbe = try self.stateLock.withLock({ self.approval }).map { try MacDeviceCapabilityProbe(executable: $0, callbackQueue: self.worker) }
                self.lifecycleFence.lock()
                let ready = self.stateLock.withLock { () -> Bool in
                    guard self.enabled, self.generation == token else { return false }
                    let construction = self.state.beginEnable()
                    _ = self.state.finishConstruction(construction, succeeded: true)
                    self.snapshot.enabled = true; self.snapshot.stopping = false
                    return true
                }
                guard ready else { self.lifecycleFence.unlock(); server.stop(); preparedProbe?.stop(); return }
                self.server = server; self.liveServer = server
                self.probe = preparedProbe; self.liveProbe = preparedProbe
                self.lifecycleFence.unlock()
            } catch { self.reportUnavailable(token: token) }
            self.emit()
        }
    }
    func loadInstallation() async throws -> MacSecureRoomIdentity {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { continuation.resume(with: Result { try MacSecureRoomIdentity() }) }
        }
    }
    func reportUnavailable(token: UUID) {
        guard current(token) else { return }
        stateLock.withLock { snapshot.error = "Device messaging operation unavailable; no automatic retry." }; emit()
    }
    func addNetwork(_ id: UUID, user: UserIdentity, identity: MacSecureRoomIdentity, access: NetworkDeviceAccess, token: UUID) {
        addNetwork(id, user: user, identity: identity.identity, pins: identity.pins, access: access, token: token)
    }
    /// Both app and ephemeral test fixtures execute this actual construction path.
    func addNetwork(_ id: UUID, user: UserIdentity, identity: InstallationIdentity, pins: PeerPinStore, access: NetworkDeviceAccess, token: UUID) {
        worker.async { [weak self] in
            guard let self, self.current(token), self.networks[id] == nil,
                  self.networks.count < 8, let executable = self.stateLock.withLock({ self.approval }) else { return }
            do {
                let journalRoot = self.testing?.directory.appendingPathComponent("journal") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let base = journalRoot
                    .appendingPathComponent(Bundle.main.bundleIdentifier ?? "in.werai.audio")
                    .appendingPathComponent("DeviceMessaging").appendingPathComponent(user.publicIdentity.userID)
                    .appendingPathComponent(id.uuidString)
                let journal = try CodexDeviceMessageJournal(directoryURL: base)
                let service = try CodexDeviceMessageService(policy: access.policy, localDevice: access.localDevice,
                    actualLocalTLSHash: identity.publicIdentity.publicKeyHash, journal: journal)
                let receiver = try MacDeviceMessageReceiver(identity: identity, service: service, pins: pins,
                    executable: executable, queue: self.worker) { [weak self] event in
                    guard let self else { return }
                    let deliver: () -> Void = { [weak self] in self?.worker.async { [weak self] in self?.received(event, network: id, token: token) } }
                    if case .approvalResult = event, let hold = self.testing?.approvalDelivery { hold(deliver) }
                    else { deliver() }
                }
                let revision = try access.policy.snapshot().revision
                self.testing?.beforeNetworkPublication?(receiver, service)
                self.lifecycleFence.lock()
                guard self.current(token) else { self.lifecycleFence.unlock(); receiver.stop(); return }
                do { try receiver.setEnabled(true) }
                catch { self.lifecycleFence.unlock(); receiver.stop(); throw error }
                guard self.current(token) else { self.lifecycleFence.unlock(); receiver.stop(); return }
                let observer = access.policy.observe { [weak self] in
                    self?.worker.async { [weak self] in self?.policyChanged(id, token: token, revision: revision) }
                }
                self.networks[id] = Context(identity: identity, pins: pins, user: user, access: access, receiver: receiver, service: service, observer: observer)
                self.liveReceivers.append(receiver)
                receiver.advertise(networkID: id)
                receiver.start { [weak self] port in
                    self?.testing?.networkReady?(port)
                    self?.worker.async { [weak self] in self?.refreshDiscovery(token) }
                }
                self.lifecycleFence.unlock()
                self.policyChanged(id, token: token, revision: revision)
                self.refreshStoredGrants()
            } catch { self.reportUnavailable(token: token) }
        }
    }
    private func policyChanged(_ id: UUID, token: UUID, revision: UInt64) {
        guard current(token), let context = networks[id],
              (try? context.access.policy.snapshot().revision) != revision else { return }
        // A published membership revision retires this discovery/connection
        // instance. Re-enable explicitly through a fresh authorization accessor.
        context.receiver.stop(); context.access.policy.removeObserver(context.observer)
        networks.removeValue(forKey: id)
        lifecycleFence.withLock { liveReceivers.removeAll { $0 === context.receiver } }
        for peer in outbound.values where peer.network == id { peer.transport.stop() }
        let retired = incoming.filter { $0.value.0 == id }.map(\.key)
        for connection in retired { incoming.removeValue(forKey: connection) }
        stateLock.withLock {
            snapshot.incoming.removeAll { retired.contains($0.id) }
            snapshot.error = "Network authority changed. Re-enable this network explicitly; no text is resent."
        }
        refreshDiscovery(token)
        refreshStoredGrants()
    }
    private func refreshStoredGrants() {
        let values = networks.flatMap { network, context in context.receiver.localGrants().map {
            UI.StoredGrant(id: $0.id, network: network, task: $0.localTaskID, revoked: $0.revoked, records: $0.recordCount)
        } }
        stateLock.withLock { snapshot.storedGrants = values }; emit()
    }
    /// Only the explicit Settings confirmation invokes receipt-loss retirement.
    func retireGrant(_ grant: UUID, network: UUID) {
        worker.async { [weak self] in
            guard let self, let receiver = self.networks[network]?.receiver else { return }
            do { try receiver.retire(grant: grant, acknowledgeReceiptLoss: true) }
            catch { self.stateLock.withLock { self.snapshot.error = "Grant retirement failed. Its recorded evidence has not been acknowledged as removed." } }
            self.refreshStoredGrants()
        }
    }
    private func refreshDiscovery(_ token: UUID) {
        guard current(token) else { return }
        discovery?.stop()
        stateLock.withLock { snapshot.candidates = [] }
        let discoveryToken = UUID(); discoveryGeneration = discoveryToken
        let discovery = NetworkDeviceMessagingDiscovery(queue: worker) { [weak self] event in
            guard let self, self.current(token), self.discoveryGeneration == discoveryToken else { return }
            switch event {
            case .candidates(let candidates): self.stateLock.withLock { self.snapshot.candidates = candidates }
            case .unavailable: self.stateLock.withLock { self.snapshot.error = "Nearby discovery unavailable. Retry explicitly." }
            }
            self.emit()
        }
        lifecycleFence.lock()
        guard current(token) else { lifecycleFence.unlock(); discovery.stop(); return }
        self.discovery = discovery; liveDiscovery = discovery; discovery.start(networks: Set(networks.keys))
        lifecycleFence.unlock()
        testing?.discoveryReplacement?(discoveryToken, Set(networks.keys))
    }
    private func handle(_ request: LocalDeviceMessageProtocol.Request) -> LocalDeviceMessageProtocol.Response {
        do {
            let result: (LocalDeviceMessageProtocol.Response, DeviceMessagingControllerState.Effect?) = try stateLock.withLock {
                guard enabled, snapshot.enabled else { return (.init(status: .disabled), nil) }
                switch request.operation {
                case .register:
                    guard let task = request.taskID, let title = request.title else { return (.init(status: .rejected), nil) }
                    let id = try state.register(taskID: task, title: title)
                    return (.init(status: .pendingApproval, registration: id), nil)
                case .status:
                    let entry = state.registrations.first { $0.id == request.registration }
                    let status: LocalDeviceMessageProtocol.Response.Status
                    switch entry?.state {
                    case .pendingApproval?: status = .pendingApproval
                    case .capabilityPending?: status = .capabilityPending
                    case .verified?: status = .ready
                    case .revoked?: status = .revoked
                    case nil: status = .unavailable
                    }
                    return (.init(status: status, registration: request.registration), nil)
                case .send, .receipt:
                    guard let registration = request.registration, !forgetting.contains(registration) else { return (.init(status: .revoked), nil) }
                    let effect = try state.admit(request)
                    if let registration = request.registration, let message = request.messageID,
                       !messageKeys.contains(where: { $0 == (registration, message) }), messageKeys.count < 32 {
                        messageKeys.append((registration, message))
                    }
                    let status = request.registration.flatMap { registration in request.messageID.flatMap { state.snapshot(registration: registration, messageID: $0)?.status } } ?? .unavailable
                    return (.init(status: status, registration: request.registration, messageID: request.messageID), effect)
                }
            }
            if let effect = result.1 { worker.async { [weak self] in self?.perform(effect) } }
            worker.async { [weak self] in self?.emit() }
            return result.0
        } catch {
            return .init(status: .unavailable, registration: request.registration, messageID: request.messageID)
        }
    }
    private func key(_ peer: UUID, _ grant: UUID, _ message: UUID) -> String { "\(peer)/\(grant)/\(message)" }
    private func perform(_ effect: DeviceMessagingControllerState.Effect) {
        guard stateLock.withLock({ state.isCurrent(effect.ticket) && !forgetting.contains(effect.request.registration ?? UUID()) }),
              let route = routes[effect.destination], let peer = outbound[route.peer],
              let descriptor = peer.descriptor, let context = networks[peer.network],
              (try? context.access.policy.snapshot().revision) == descriptor.policyRevision,
              let message = effect.request.messageID else {
            stateLock.withLock { _ = state.finish(effect.ticket, result: .unavailable) }; emit(); return
        }
        guard let registration = effect.request.registration else { return }
        observations[key(route.peer, route.grant, message)] = Observed(ticket: effect.ticket,
            observation: effect.observation, registration: registration, querying: effect.request.operation == .receipt)
        if effect.request.operation == .send, let text = effect.request.text {
            peer.transport.send(.init(grantID: route.grant, messageID: message, text: text))
        } else { peer.transport.queryReceipt(grantID: route.grant, messageID: message) }
    }
    func testCapability(_ registration: UUID) {
        worker.async { [weak self] in
            guard let self, let probe = self.probe, let approval = self.stateLock.withLock({ self.approval }) else { return }
            do {
                let challenge = try self.stateLock.withLock { try self.state.beginCapabilityTest(registration: registration, approvedDigest: approval.digest, now: DeviceMessagingClock.nowNanos()) }
                self.challenges[registration] = challenge
                let token = self.currentGeneration
                let admission = probe.submit(taskID: challenge.taskID, challengeID: challenge.id, response: challenge.nonce,
                    expiresAt: challenge.expiresAt) { [weak self] outcome in
                    guard let self, self.current(token) else { return }
                    self.stateLock.withLock { self.snapshot.capabilityStatuses[registration] = outcome == .queued ? "Queued test; enter code from the actual task." : "Test unavailable or uncertain; not verified." }
                    self.emit()
                }
                self.stateLock.withLock { self.snapshot.capabilityStatuses[registration] = admission == .pending ? "Test pending; not verified." : "Test not admitted; not verified." }
            } catch { self.stateLock.withLock { self.snapshot.error = "Capability test unavailable." } }
            self.emit()
        }
    }
    func confirm(_ registration: UUID, response: String) {
        worker.async { [weak self] in
            guard let self, let challenge = self.challenges[registration], let response = UUID(uuidString: response),
                  let approval = self.stateLock.withLock({ self.approval }) else { return }
            do {
                try self.stateLock.withLock { try self.state.confirmCapability(challenge, response: response, approvedDigest: approval.digest, now: DeviceMessagingClock.nowNanos()) }
                self.challenges.removeValue(forKey: registration)
                self.stateLock.withLock { self.snapshot.capabilityStatuses[registration] = "Locally confirmed from the selected task." }
            } catch { self.stateLock.withLock { self.snapshot.error = "Confirmation did not match the current task test." } }
            self.emit()
        }
    }
    func connect(_ candidate: NetworkDeviceMessagingDiscovery.Candidate) {
        worker.async { [weak self] in
            guard let self, self.stateLock.withLock({ self.enabled }), self.outbound.count < 8,
                  let context = self.networks[candidate.networkHint] else { return }
            let id = UUID(), token = self.currentGeneration
            do {
                let transport = try NetworkDeviceTextTransport(endpoint: candidate.endpoint, identity: context.identity,
                    user: context.user, binding: context.access.localDevice, policy: context.access.policy,
                    pins: context.pins, queue: self.worker) { [weak self] event in
                    self?.worker.async { [weak self] in self?.sent(event, peer: id, token: token) }
                }
                self.lifecycleFence.lock()
                guard self.current(token) else { self.lifecycleFence.unlock(); transport.stop(); return }
                self.outbound[id] = Peer(network: candidate.networkHint, transport: transport)
                self.liveTransports.append(transport)
                transport.start()
                self.lifecycleFence.unlock()
            } catch { self.reportUnavailable(token: token) }
        }
    }
    func bind(_ peerID: UUID, grant: UUID, registration: UUID) {
        worker.async { [weak self] in
            guard let self, let peer = self.outbound[peerID], let descriptor = peer.descriptor,
                  peer.grants.contains(grant), let context = self.networks[peer.network],
                  (try? context.access.policy.snapshot().revision) == descriptor.policyRevision,
                  let approval = self.stateLock.withLock({ self.forgetting.contains(registration) ? nil : self.approval }) else { return }
            do {
                let id = try self.stateLock.withLock { try self.state.bindAuthenticatedDestination(registration: registration, approvedDigest: approval.digest) }
                self.routes[id] = Route(peer: peerID, grant: grant, registration: registration, remote: descriptor)
                self.stateLock.withLock {
                    self.snapshot.destinations.append(.init(id: id, registration: registration, root: descriptor.root.userID,
                        spki: descriptor.fullSPKIHash.map { String(format: "%02x", $0) }.joined()))
                }
            } catch { self.stateLock.withLock { self.snapshot.error = "Confirm the local task capability before choosing a destination." } }
            self.emit()
        }
    }
    func approve(_ incomingID: UUID, registration: UUID) {
        worker.async { [weak self] in
            guard let self, let (network, connection) = self.incoming[incomingID], let context = self.networks[network],
                  let task = self.stateLock.withLock({ self.forgetting.contains(registration) ? nil : self.state.registrations.first { $0.id == registration && $0.state == .verified }?.taskID }),
                  self.approvals.count < 32 else { return }
            let request = UUID(); self.approvals[request] = PendingApproval(registration: registration, task: task, token: self.currentGeneration)
            context.receiver.approve(connection: connection, receiverChosenTask: task, lifetime: 3600, requestID: request)
        }
    }
    func forget(_ registration: UUID) {
        stateLock.withLock { forgetting.insert(registration); snapshot.capabilityStatuses[registration] = "Revoking grants; removal has not completed." }
        emit()
        worker.async { [weak self] in
            guard let self else { return }
            do {
                for (grant, value) in self.grants where value.1 == registration {
                    try self.testing?.beforeRevoke?()
                    try self.networks[value.0]?.receiver.revoke(grant: grant)
                }
                self.grants = self.grants.filter { $0.value.1 != registration }
                self.routes = self.routes.filter { $0.value.registration != registration }
                self.stateLock.withLock { self.snapshot.destinations.removeAll { $0.registration == registration } }
                self.observations = self.observations.filter { $0.value.registration != registration }
                self.challenges.removeValue(forKey: registration)
                self.finishForgetIfSettled(registration)
            } catch { self.stateLock.withLock { self.snapshot.error = "Grant revocation did not complete; registration was not forgotten." } }
            self.refreshStoredGrants()
            self.emit()
        }
    }
    private func finishForgetIfSettled(_ registration: UUID) {
        guard !approvals.values.contains(where: { $0.registration == registration }),
              !grants.values.contains(where: { $0.1 == registration }) else { return }
        stateLock.withLock {
            guard forgetting.contains(registration) else { return }
            state.forgetAfterLocalGrantRevocation(registration)
            messageKeys.removeAll { $0.0 == registration }
            snapshot.capabilityStatuses.removeValue(forKey: registration); forgetting.remove(registration)
        }
    }
    private func received(_ event: MacDeviceMessageReceiver.Event, network: UUID, token: UUID) {
        guard current(token), let context = networks[network] else { return }
        switch event {
        case .authenticated(let connection, let peer):
            guard incoming.count < 32 else { return }
            let id = UUID(); incoming[id] = (network, connection)
            stateLock.withLock { snapshot.incoming.append(.init(id: id, network: network, root: peer.sender.userID, spki: peer.senderSPKIHash.map { String(format: "%02x", $0) }.joined())) }
        case .approvalResult(let request, let result):
            let pending = approvals.removeValue(forKey: request)
            switch result {
            case .success(let grant):
                let valid = pending.map { pending in stateLock.withLock {
                    generation == pending.token && !forgetting.contains(pending.registration)
                        && state.registrations.contains { $0.id == pending.registration && $0.taskID == pending.task && $0.state == .verified }
                } } ?? false
                if valid, let pending { grants[grant] = (network, pending.registration) }
                else {
                    if let pending { grants[grant] = (network, pending.registration) }
                    do { try testing?.beforeRevoke?(); try context.receiver.revoke(grant: grant) }
                    catch { stateLock.withLock { snapshot.error = "Late approval revocation failed; removal is not complete." }; emit(); return }
                    grants.removeValue(forKey: grant)
                }
            case .failure: stateLock.withLock { snapshot.error = "Local task grant was not approved." }
            }
            if let pending { finishForgetIfSettled(pending.registration) }
            refreshStoredGrants()
        case .received(_, let grant, let message), .completion(_, let grant, let message, _), .dispatchFailed(_, let grant, let message):
            let receipt = context.receiver.localReceipt(grantID: grant, messageID: message)
            stateLock.withLock { snapshot.error = receipt.map { "Incoming message \(message.uuidString): \($0.rawValue)" } ?? "Incoming status unavailable; do not assume it was unqueued." }
        case .reviewNeeded(let grant, let message, _, _):
            let receipt = context.receiver.localReceipt(grantID: grant, messageID: message)
            stateLock.withLock { snapshot.error = receipt.map { "Local review needed for \(message.uuidString): \($0.rawValue)" } ?? "Local review needed; status unavailable." }
        case .closed(let connection):
            let ids = incoming.filter { $0.value.0 == network && $0.value.1 == connection }.map(\.key)
            for id in ids { incoming.removeValue(forKey: id) }
            stateLock.withLock { snapshot.incoming.removeAll { ids.contains($0.id) } }
        }
        emit()
    }
    private func sent(_ event: NetworkDeviceTextTransport.Event, peer id: UUID, token: UUID) {
        guard current(token), var peer = outbound[id] else { return }
        switch event {
        case .remoteAuthenticated(let descriptor):
            guard descriptor.networkID == peer.network else { peer.transport.stop(); return }
            // Only an explicit new connection reaching actual TLS proof can
            // rebind known logical routes. No text/query is sent by this step.
            for (destination, route) in routes where route.remote.networkID == descriptor.networkID
                && route.remote.generation == descriptor.generation && route.remote.policyRevision == descriptor.policyRevision
                && route.remote.root == descriptor.root && route.remote.fullSPKIHash == descriptor.fullSPKIHash {
                routes[destination]?.peer = id
                if !peer.grants.contains(route.grant), peer.grants.count < 32 { peer.grants.append(route.grant) }
            }
            peer.descriptor = descriptor; outbound[id] = peer
        case .grant(let grant):
            if peer.grants.count < 32, !peer.grants.contains(grant) { peer.grants.append(grant); outbound[id] = peer }
        case .receipt(let grant, let message, let receipt):
            if let effect = observations[key(id, grant, message)] {
                stateLock.withLock {
                    if !effect.querying && state.isCurrent(effect.ticket) { _ = state.finish(effect.ticket, result: .receipt(receipt)) }
                    else { _ = state.observe(effect.observation, receipt: receipt) }
                }
            }
        case .queryResult(let grant, let message, let result):
            if let effect = observations[key(id, grant, message)], effect.querying {
                stateLock.withLock {
                    switch result {
                    case .receipt(let receipt): _ = state.finish(effect.ticket, result: .receipt(receipt))
                    case .statusUnknown: _ = state.finish(effect.ticket, result: .statusUnknown)
                    case .grantExpired, .unavailable: _ = state.finish(effect.ticket, result: .unavailable)
                    }
                }
            }
        case .rejected(let grant, let message, _):
            if let effect = observations[key(id, grant, message)] { stateLock.withLock { _ = state.finish(effect.ticket, result: .unavailable) } }
        case .closed:
            outbound.removeValue(forKey: id)
            lifecycleFence.withLock { liveTransports.removeAll { $0 === peer.transport } }
            for (entry, effect) in observations where entry.hasPrefix(id.uuidString + "/") {
                stateLock.withLock { _ = state.finish(effect.ticket, result: .unavailable) }
            }
        default: break
        }
        stateLock.withLock {
            snapshot.remotes = outbound.compactMap { id, peer in
                peer.descriptor.map { .init(id: id, network: peer.network, root: $0.root.userID,
                    spki: $0.fullSPKIHash.map { String(format: "%02x", $0) }.joined(), grants: peer.grants) }
            }
        }
        emit()
    }
    func stop() {
        let closing: UUID? = stateLock.withLock {
            guard !snapshot.stopping else { return nil }
            generation = UUID(); enabled = false; state.invalidate()
            snapshot.enabled = false; snapshot.stopping = true
            return generation
        }
        guard let closing else { return }; emit()
        lifecycle.async { [weak self] in
            guard let self else { return }
            let resources = self.lifecycleFence.withLock { () -> ([MacDeviceMessageReceiver], [NetworkDeviceTextTransport], MacDeviceCapabilityProbe?, MacOwnerSocket.Server?, NetworkDeviceMessagingDiscovery?) in
                let resources = (self.liveReceivers, self.liveTransports, self.liveProbe, self.liveServer, self.liveDiscovery)
                self.liveReceivers.removeAll(); self.liveTransports.removeAll(); self.liveProbe = nil; self.liveServer = nil; self.liveDiscovery = nil
                return resources
            }
            // Actual service authority is disabled before teardown is reported complete.
            resources.4?.stop()
            resources.2?.stop() // native capability fence before any confirmed teardown
            for receiver in resources.0 { receiver.stop() }
            for transport in resources.1 { transport.stop() }
            resources.3?.stop()
            self.worker.async { [weak self] in
                guard let self, self.currentGeneration == closing else { return }
                self.discovery?.stop(); self.discovery = nil
                self.server?.stop(); self.server = nil; self.probe?.stop(); self.probe = nil
                for context in self.networks.values { context.access.policy.removeObserver(context.observer) }
                self.networks.removeAll(); self.incoming.removeAll(); self.outbound.removeAll()
                self.routes.removeAll(); self.observations.removeAll(); self.challenges.removeAll(); self.grants.removeAll(); self.approvals.removeAll()
                self.stateLock.withLock {
                    self.messageKeys.removeAll(); self.snapshot.stopping = false
                    self.forgetting.removeAll()
                    self.snapshot.incoming = []; self.snapshot.remotes = []; self.snapshot.candidates = []
                    self.snapshot.destinations = []
                    self.snapshot.storedGrants = []
                    self.snapshot.capabilityStatuses = [:]
                }
                self.emit()
            }
        }
    }
}
