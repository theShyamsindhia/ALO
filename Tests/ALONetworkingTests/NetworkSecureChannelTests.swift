import Foundation
import Darwin
import Network
import Testing
import ALOIdentity
import ALORooms
@testable import ALONetworking

/// Actual loopback TLS and generation-4 claim exchange. This does not establish physical audio accuracy.
@Suite("Network-authorized live TLS channels", .serialized)
struct NetworkSecureChannelTests {
    @Test(arguments: BlockingPeerPinStore.Phase.allCases)
    fileprivate func blockedPinStoreDoesNotBlockSharedExecutorAndAdmissionResumes(phase: BlockingPeerPinStore.Phase) async throws {
        let fixture = try NetworkTLSFixture()
        let pins = BlockingPeerPinStore(phase: phase)
        let pair = try fixture.pair(serverPins: pins)
        defer { pins.release(); pair.cancel() }
        let admission = Task { try await pair.run() }
        try await networkTLSEventually { pins.didEnter }
        #expect(pair.sharedExecutorIsResponsive(), "Pin lookup/record must not park the shared media/control executor")
        pins.release()
        guard case .delivered = try await admission.value else { Issue.record("Admission failed after pin storage recovered"); return }
        #expect(await pair.snapshot().payloadsDelivered == 1)
    }

    @Test(arguments: BlockingPeerPinStore.Phase.allCases)
    fileprivate func cancelledPinStoreWorkCannotIssueLateAdmissionOrCredentials(phase: BlockingPeerPinStore.Phase) async throws {
        let fixture = try NetworkTLSFixture()
        let pins = BlockingPeerPinStore(phase: phase)
        let pair = try fixture.pair(serverPins: pins)
        defer { pins.release(); pair.cancel() }
        let admission = Task { try await pair.run() }
        try await networkTLSEventually { pins.didEnter }
        #expect(pair.sharedExecutorIsResponsive())
        pair.cancel()
        guard case .failed(.cancelled) = try await admission.value else { Issue.record("Pin work prevented cancellation"); return }
        pins.release()
        try await networkTLSEventually { pins.didFinish }
        let state = await pair.snapshot()
        #expect(state.clientPeer == nil && state.serverPeer == nil)
        #expect(state.clientCredentials == nil && state.serverCredentials == nil)
        #expect(state.payloadsDelivered == 0)
    }

    @Test func blockedChangedPolicyPersistenceDoesNotBlockSharedChannelExecutor() async throws {
        let fixture = try NetworkTLSFixture()
        let pair = try fixture.pair(role: .mediaControl)
        defer { pair.cancel() }
        guard case .delivered = try await pair.run() else { Issue.record("Initial TLS admission failed"); return }
        let descriptor = open(pair.clientRepository.directoryURL.appendingPathComponent(".repository.lock").path, O_RDWR)
        try #require(descriptor >= 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        #expect(flock(descriptor, LOCK_EX) == 0)
        let updated = try fixture.manifest.renamed(to: "Updated while client disk is blocked", signedBy: fixture.owner)
        try pair.serverAuthorization.policy.receive(updated)
        try await networkTLSEventually { pair.clientAuthorization.policy.pendingPolicyWorkCount == 1 }
        #expect(pair.sharedExecutorIsResponsive(), "A peer policy's flock must not stop media/control executor work")
        #expect(try pair.clientAuthorization.policy.snapshot().revision == fixture.manifest.revision)
        #expect(flock(descriptor, LOCK_UN) == 0)
        try await networkTLSEventually { (try? pair.clientAuthorization.policy.snapshot().revision) == updated.revision }
        #expect(await pair.sendAfterRevocation())
        try await networkTLSEventually { await pair.snapshot().payloadsDelivered >= 2 }
        let state = await pair.snapshot()
        #expect(state.clientFailure == nil && state.serverFailure == nil)
    }

    @Test func blockedFirstHelloRemainsCancellableAndCannotAdmitAfterShutdown() async throws {
        let fixture = try NetworkTLSFixture()
        let updated = try fixture.manifest.renamed(to: "Newer hello policy", signedBy: fixture.owner)
        let pair = try fixture.pair(clientManifest: updated)
        defer { pair.cancel() }
        let descriptor = open(pair.serverRepository.directoryURL.appendingPathComponent(".repository.lock").path, O_RDWR)
        try #require(descriptor >= 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        #expect(flock(descriptor, LOCK_EX) == 0)
        let admission = Task { try await pair.run() }
        try await networkTLSEventually { pair.serverAuthorization.policy.pendingPolicyWorkCount == 1 }
        #expect(pair.sharedExecutorIsResponsive(), "An unadmitted hello must not park the media/control executor")
        pair.cancel()
        guard case .failed(.cancelled) = try await admission.value else { Issue.record("Blocked admission ignored cancellation"); return }
        #expect(flock(descriptor, LOCK_UN) == 0)
        try await networkTLSEventually { pair.serverAuthorization.policy.pendingPolicyWorkCount == 0 }
        let state = await pair.snapshot()
        #expect(state.clientPeer == nil && state.serverPeer == nil)
        #expect(state.clientCredentials == nil && state.serverCredentials == nil)
        #expect(state.payloadsDelivered == 0)
    }

    @Test func repeatedPolicyFramesAreRateLimitedBeforeUnboundedWorkAccumulates() async throws {
        let fixture = try NetworkTLSFixture()
        let pair = try fixture.pair()
        defer { pair.cancel() }
        guard case .delivered = try await pair.run() else { Issue.record("Initial TLS admission failed"); return }
        try await pair.sendPolicyFrames(fixture.manifest, count: SecurePeerChannel.maximumPolicyFramesPerWindow + 1)
        try await networkTLSEventually { await pair.snapshot().clientFailure != nil }
        #expect(await pair.snapshot().clientFailure == .protocolViolation)
        #expect(pair.clientAuthorization.policy.pendingPolicyWorkCount <= 1)
    }

    @Test(arguments: ReliableChannelRole.allCases)
    func membersExchangePayloadsAcrossEveryCurrentReliableRole(role: ReliableChannelRole) async throws {
        let fixture = try NetworkTLSFixture()
        let pair = try fixture.pair(role: role)
        defer { pair.cancel() }
        guard case .delivered(let bytes, let clientPeer, let serverPeer) = try await pair.run() else {
            Issue.record("A network member failed current-generation TLS admission"); return
        }
        #expect(bytes == pair.payload)
        #expect(clientPeer.userIdentity == fixture.owner.publicIdentity)
        #expect(serverPeer.userIdentity == fixture.member.publicIdentity)
        #expect(clientPeer.negotiated.stateSyncVersion == ProtocolOffer.currentRoomGeneration)
        #expect(serverPeer.negotiated.stateSyncVersion == ProtocolOffer.currentRoomGeneration)
        #expect(clientPeer.channelRole == role && serverPeer.channelRole == role)
        #expect(clientPeer.connectionID == serverPeer.connectionID)
    }

    @Test func sameUserRootAdmitsTwoDistinctTLSInstallations() async throws {
        let fixture = try NetworkTLSFixture()
        let recovered = try IdentityRecoveryDocument.restore(from: IdentityRecoveryDocument(identity: fixture.owner).serializedData())
        let pair = try fixture.pair(clientRoot: recovered)
        defer { pair.cancel() }
        guard case .delivered(_, let clientPeer, let serverPeer) = try await pair.run() else {
            Issue.record("Two devices of one user were not admitted"); return
        }
        #expect(clientPeer.userIdentity == serverPeer.userIdentity)
        #expect(clientPeer.userIdentity == fixture.owner.publicIdentity)
        #expect(clientPeer.nodeID != serverPeer.nodeID)
        #expect(clientPeer.publicKeyHash != serverPeer.publicKeyHash)
        #expect(clientPeer.publicKeyHash == pair.serverIdentity.publicIdentity.publicKeyHash)
        #expect(serverPeer.publicKeyHash == pair.clientIdentity.publicIdentity.publicKeyHash)
    }

    @Test func outsiderSelfSignedNetworkCannotJoinPublicChannel() async throws {
        let fixture = try NetworkTLSFixture()
        let outsider = UserIdentity.ephemeral()
        let forgedNetwork = try NetworkManifest.create(name: fixture.manifest.name, owner: outsider,
                                                       id: fixture.manifest.id, generation: fixture.manifest.generation)
        let pair = try fixture.pair(clientRoot: outsider, clientManifest: forgedNetwork)
        defer { pair.cancel() }
        guard case .failed(let failure) = try await pair.run() else {
            Issue.record("A self-signed outsider was admitted to another owner's public channel"); return
        }
        #expect(failure != .timedOut)
        let state = await pair.snapshot()
        #expect(state.clientPeer == nil && state.serverPeer == nil)
        #expect(state.payloadsDelivered == 0)
        #expect(state.clientCredentials == nil && state.serverCredentials == nil)
        #expect(try pair.serverAuthorization.policy.snapshot().owner == fixture.owner.publicIdentity)
    }

    @Test func privateChannelAdmitsOnlyAnExplicitCurrentMemberGrant() async throws {
        let fixture = try NetworkTLSFixture()
        let allowed = try fixture.pair(channelID: fixture.privateChannel.id)
        defer { allowed.cancel() }
        guard case .delivered = try await allowed.run() else {
            Issue.record("An explicitly granted private-channel member was denied"); return
        }

        let closed = try ALORooms.NetworkChannel(id: fixture.privateChannel.id, name: fixture.privateChannel.name,
                                        visibility: .privateMembers)
        let removedGrant = try fixture.manifest.updatingChannel(closed, signedBy: fixture.owner)
        let denied = try fixture.pair(serverManifest: removedGrant, channelID: fixture.privateChannel.id)
        defer { denied.cancel() }
        guard case .failed(let failure) = try await denied.run() else {
            Issue.record("A stale private-channel grant admitted a denied member"); return
        }
        #expect(failure != .timedOut)
        #expect(await denied.snapshot().payloadsDelivered == 0)
        #expect(try denied.serverAuthorization.policy.snapshot().revision == removedGrant.revision)
    }

    @Test func ownerRevocationClosesLiveTLSAndInvalidatesPreviouslyIssuedCredentials() async throws {
        let fixture = try NetworkTLSFixture()
        let pair = try fixture.pair(role: .mediaControl)
        defer { pair.cancel() }
        guard case .delivered = try await pair.run() else { Issue.record("Initial member admission failed"); return }
        let admitted = await pair.snapshot()
        let clientCredentials = try #require(admitted.clientCredentials)
        let serverCredentials = try #require(admitted.serverCredentials)
        #expect(clientCredentials.isActive && serverCredentials.isActive)
        let revoked = try fixture.manifest.removingMember(userID: fixture.member.publicIdentity.userID, signedBy: fixture.owner)
        try pair.serverAuthorization.policy.receive(revoked)

        try await networkTLSEventually {
            let state = await pair.snapshot()
            return state.serverFailure != nil && !serverCredentials.isActive && !clientCredentials.isActive
        }
        #expect(try pair.serverAuthorization.policy.snapshot().revision == revoked.revision)
        #expect(await pair.sendAfterRevocation() == false)

        // A new TLS connection with the old signed member policy cannot restore authorization.
        let replay = try fixture.pair(serverManifest: revoked, role: .mediaControl)
        defer { replay.cancel() }
        guard case .failed(let failure) = try await replay.run() else { Issue.record("Stale membership revived after revocation"); return }
        #expect(failure != .timedOut)
        #expect(await replay.snapshot().payloadsDelivered == 0)
    }

    @Test func signedPolicyUpdateTravelsOverTLSAndPersistsAtOtherMember() async throws {
        let fixture = try NetworkTLSFixture()
        let pair = try fixture.pair()
        defer { pair.cancel() }
        guard case .delivered = try await pair.run() else { Issue.record("Initial member admission failed"); return }
        let updated = try fixture.manifest.renamed(to: "Policy propagated over TLS", signedBy: fixture.owner)
        try pair.serverAuthorization.policy.receive(updated)
        try await networkTLSEventually {
            (try? pair.clientAuthorization.policy.snapshot().revision) == updated.revision
        }
        let reopened = NetworkRepository(directoryURL: pair.clientRepository.directoryURL)
        #expect(try reopened.trustedManifest(id: updated.id).name == updated.name)
        let state = await pair.snapshot()
        #expect(state.clientFailure == nil && state.serverFailure == nil)
        #expect(state.clientCredentials?.isActive == true && state.serverCredentials?.isActive == true)
    }
}

private final class NetworkTLSFixture {
    let owner = UserIdentity.ephemeral()
    let member = UserIdentity.ephemeral()
    let manifest: NetworkManifest
    let privateChannel: ALORooms.NetworkChannel
    let directory: URL

    init() throws {
        privateChannel = try ALORooms.NetworkChannel(name: "Private", visibility: .privateMembers,
                                            allowedUserIDs: [member.publicIdentity.userID])
        manifest = try NetworkManifest.create(name: "TLS Test Network", owner: owner)
            .addingMember(member.publicIdentity, signedBy: owner).addingChannel(privateChannel, signedBy: owner)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-network-tls-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func pair(clientRoot: UserIdentity? = nil, clientManifest: NetworkManifest? = nil,
              serverManifest: NetworkManifest? = nil, channelID: UUID? = nil,
              role: ReliableChannelRole = .roomControl, serverPins: PeerPinStore? = nil) throws -> NetworkTLSLoopbackPair {
        try NetworkTLSLoopbackPair(clientRoot: clientRoot ?? member, serverRoot: owner,
            clientManifest: clientManifest ?? manifest, serverManifest: serverManifest ?? manifest,
            channelID: channelID ?? manifest.mainChannel.id, role: role,
            directory: directory.appendingPathComponent(UUID().uuidString), serverPins: serverPins)
    }
}

private final class NetworkTLSLoopbackPair: @unchecked Sendable {
    enum Outcome { case delivered(Data, AuthenticatedPeer, AuthenticatedPeer), failed(SecurePeerChannelError) }
    struct Snapshot {
        var clientPeer: AuthenticatedPeer?
        var serverPeer: AuthenticatedPeer?
        var clientCredentials: AuthenticatedChannelCredentials?
        var serverCredentials: AuthenticatedChannelCredentials?
        var clientFailure: SecurePeerChannelError?
        var serverFailure: SecurePeerChannelError?
        var payloadsDelivered = 0
    }
    let clientIdentity: InstallationIdentity
    let serverIdentity: InstallationIdentity
    let clientAuthorization: NetworkChannelAuthorization
    let serverAuthorization: NetworkChannelAuthorization
    let clientRepository: NetworkRepository
    let serverRepository: NetworkRepository
    let payload = Data("Network member payload".utf8)
    private let queue = DispatchQueue(label: "alo.tests.network-tls")
    private let listener: NWListener
    private let clientParameters: NWParameters
    private let clientConfiguration: SecurePeerConfiguration
    private let serverConfiguration: SecurePeerConfiguration
    private let clientPins = MemoryPeerPinStore()
    private let serverPins: PeerPinStore
    private var client: SecurePeerChannel?
    private var server: SecurePeerChannel?
    private var serverConnection: NWConnection?
    private var state = Snapshot()
    private var continuation: CheckedContinuation<Outcome, Error>?

    init(clientRoot: UserIdentity, serverRoot: UserIdentity, clientManifest: NetworkManifest,
         serverManifest: NetworkManifest, channelID: UUID, role: ReliableChannelRole, directory: URL,
         serverPins: PeerPinStore? = nil) throws {
        self.serverPins = serverPins ?? MemoryPeerPinStore()
        clientIdentity = try .ephemeral()
        serverIdentity = try .ephemeral()
        clientRepository = NetworkRepository(directoryURL: directory.appendingPathComponent("client"))
        serverRepository = NetworkRepository(directoryURL: directory.appendingPathComponent("server"))
        try clientRepository.accept(clientManifest, for: clientRoot.publicIdentity)
        try serverRepository.accept(serverManifest, for: serverRoot.publicIdentity)
        clientAuthorization = try NetworkChannelAuthorization(
            policy: NetworkPolicyCenter(repository: clientRepository, networkID: clientManifest.id), channelID: channelID,
            localDevice: DeviceIdentityBinding(user: clientRoot, deviceName: "TLS client", generation: 1,
                                               installationPublicKeyHash: clientIdentity.publicIdentity.publicKeyHash))
        serverAuthorization = try NetworkChannelAuthorization(
            policy: NetworkPolicyCenter(repository: serverRepository, networkID: serverManifest.id), channelID: channelID,
            localDevice: DeviceIdentityBinding(user: serverRoot, deviceName: "TLS server", generation: 1,
                                               installationPublicKeyHash: serverIdentity.publicIdentity.publicKeyHash))
        // Current channels authorize private/public visibility through signed network policy.
        let offer = try ProtocolOffer.current(capabilities: .desktop)
        clientConfiguration = try SecurePeerConfiguration(roomID: channelID, incarnationID: UUID(), admission: .publicRoom,
            offer: offer, direction: .initiator(role), networkAuthorization: clientAuthorization)
        serverConfiguration = try SecurePeerConfiguration(roomID: channelID, incarnationID: UUID(), admission: .publicRoom,
            offer: offer, direction: .responder(allowedChannelRoles: [role]), networkAuthorization: serverAuthorization)
        clientParameters = try SecureNetworkParameters.tcp(identity: clientIdentity, expectedPeerID: serverIdentity.publicIdentity.nodeID,
            pins: clientPins, firstContact: .explicitRoomJoin, verificationQueue: queue)
        let serverParameters = try SecureNetworkParameters.tcp(identity: serverIdentity, expectedPeerID: clientIdentity.publicIdentity.nodeID,
            pins: self.serverPins, firstContact: .explicitRoomJoin, verificationQueue: queue)
        listener = try NWListener(using: serverParameters, on: .any)
    }

    func run() async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.server == nil else { connection.cancel(); return }
                    self.serverConnection = connection
                    let channel = SecurePeerChannel(connection: connection, identity: self.serverIdentity,
                        configuration: self.serverConfiguration, pins: self.serverPins, queue: self.queue)
                    self.server = channel
                    channel.onState = { [weak self] state in self?.observe(state, client: false) }
                    channel.onAuthenticated = { [weak self] peer in
                        guard let self else { return }
                        self.state.serverPeer = peer
                        self.server?.withAuthenticatedCredentials { self.state.serverCredentials = try? $0.get() }
                    }
                    channel.onPayload = { [weak self] bytes in
                        guard let self, self.state.serverPeer != nil else { return }
                        self.state.payloadsDelivered += 1
                        self.server?.send(payload: bytes)
                    }
                    channel.start()
                }
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port, self.client == nil else { return }
                        let connection = NWConnection(host: "127.0.0.1", port: port, using: self.clientParameters)
                        let channel = SecurePeerChannel(connection: connection, identity: self.clientIdentity,
                            configuration: self.clientConfiguration, pins: self.clientPins, queue: self.queue)
                        self.client = channel
                        channel.onState = { [weak self] state in self?.observe(state, client: true) }
                        channel.onAuthenticated = { [weak self] peer in
                            guard let self else { return }
                            self.state.clientPeer = peer
                            self.client?.withAuthenticatedCredentials { self.state.clientCredentials = try? $0.get() }
                            self.client?.send(payload: self.payload)
                        }
                        channel.onPayload = { [weak self] bytes in
                            guard let self, let clientPeer = self.state.clientPeer, let serverPeer = self.state.serverPeer else { return }
                            self.finish(.delivered(bytes, clientPeer, serverPeer))
                        }
                        channel.start()
                    case .failed: self.finish(.failed(.connectionFailed))
                    default: break
                    }
                }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                    self?.finish(.failed(.timedOut))
                }
            }
        }
    }

    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.state) } }
    }

    func sharedExecutorIsResponsive() -> Bool {
        let finished = DispatchSemaphore(value: 0)
        queue.async { finished.signal() }
        return finished.wait(timeout: .now() + 0.5) == .success
    }

    func sendPolicyFrames(_ policy: NetworkManifest, count: Int) async throws {
        struct PolicyFrame: Encodable { let kind = "networkPolicy"; let policy: NetworkManifest }
        let body = try JSONEncoder().encode(PolicyFrame(policy: policy))
        var frame = WireBytes(); frame.append(UInt32(body.count)); frame.append(body)
        let bytes = (0..<count).reduce(into: Data()) { bytes, _ in bytes.append(frame.data) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let connection = self.serverConnection else {
                    continuation.resume(throwing: SecurePeerChannelError.notAuthenticated); return
                }
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        }
    }

    func sendAfterRevocation() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let client = self.client else { continuation.resume(returning: false); return }
                client.send(payload: self.payload) { result in
                    if case .success = result { continuation.resume(returning: true) }
                    else { continuation.resume(returning: false) }
                }
            }
        }
    }

    private func observe(_ update: SecurePeerChannelState, client: Bool) {
        if case .failed(let error) = update {
            if client { state.clientFailure = error } else { state.serverFailure = error }
            finish(.failed(error))
        }
    }

    private func finish(_ result: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }

    func cancel() {
        queue.async {
            self.listener.cancel(); self.client?.cancel(); self.server?.cancel()
            self.finish(.failed(.cancelled))
        }
    }
}

/// No Keychain operations: gates one memory-backed pin-store call to reproduce
/// slow storage deterministically while the real loopback TLS channel runs.
private final class BlockingPeerPinStore: PeerPinStore, @unchecked Sendable {
    enum Phase: CaseIterable, Sendable { case lookup, record }
    private let phase: Phase
    private let memory = MemoryPeerPinStore()
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    private var finished = false
    init(phase: Phase) { self.phase = phase }
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var didFinish: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func release() { gate.signal() }
    private func pause(_ operation: Phase) throws {
        lock.lock()
        let shouldPause = operation == phase && !entered
        if shouldPause { entered = true }
        lock.unlock()
        guard shouldPause else { return }
        let result = gate.wait(timeout: .now() + 5)
        lock.lock(); finished = true; lock.unlock()
        guard result == .success else { throw SecurePeerChannelError.timedOut }
    }
    func pin(for nodeID: UUID) throws -> Data? { try pause(.lookup); return memory.pin(for: nodeID) }
    func recordAfterAdmission(_ peer: PeerPublicIdentity) throws { try pause(.record); try memory.recordAfterAdmission(peer) }
}

private func networkTLSEventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(await condition(), "Live TLS channel did not reach the expected authorization state within eight seconds")
}
