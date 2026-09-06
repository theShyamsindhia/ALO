import Foundation
import Network
import Testing
@testable import ALONetworking

@Suite("Actual secure peer channels", .serialized)
struct SecurePeerChannelTests {
    @Test func fileTransferUsesItsOwnAuthenticatedRole() async throws {
        let payload = try DirectFileWire.chunk(offset: 0, bytes: Data(repeating: 42, count: DirectFileWire.chunkBytes)).encoded()
        let pair = try SecureChannelPair(clientAdmission: .publicRoom, serverAdmission: .publicRoom,
            role: .fileTransfer, allowedRoles: [.fileTransfer], payload: payload)
        defer { pair.cancel() }
        let outcome = try await pair.run()
        guard case .delivered(let echo, let client, let server) = outcome else { Issue.record("File admission failed"); return }
        #expect(client.channelRole == .fileTransfer && server.channelRole == .fileTransfer)
        #expect(echo == payload)
    }
    @Test func privateAdmissionDeliversMaximumPayloadWithAuthenticatedIdentity() async throws {
        let payload = Data(repeating: 0xA5, count: SecurePeerChannel.maximumPayloadBytes)
        let pair = try SecureChannelPair(clientAdmission: .privateRoom(secret: NetworkFixture.secret),
                                         serverAdmission: .privateRoom(secret: NetworkFixture.secret), payload: payload)
        defer { pair.cancel() }
        let outcome = try await pair.run()
        guard case .delivered(let echo, let peer, let serverPeer) = outcome else { Issue.record("Expected authenticated delivery"); return }
        #expect(echo == payload)
        #expect(peer.nodeID == pair.serverIdentity.publicIdentity.nodeID)
        #expect(serverPeer.nodeID == pair.clientIdentity.publicIdentity.nodeID)
        #expect(peer.connectionID == serverPeer.connectionID)
        #expect(peer.negotiated.wireVersion == 2 && peer.negotiated.stateSyncVersion == 1)
    }

    @Test func publicAdmissionDispatchesTheAuthenticatedRequestedRole() async throws {
        let pair = try SecureChannelPair(clientAdmission: .publicRoom, serverAdmission: .publicRoom,
            role: .video, allowedRoles: [.roomControl, .mediaControl, .video], payload: Data([1,2,3]))
        defer { pair.cancel() }
        let outcome = try await pair.run()
        guard case .delivered(_, let clientPeer, let serverPeer) = outcome else { Issue.record("Expected public encrypted join"); return }
        #expect(clientPeer.channelRole == .video && serverPeer.channelRole == .video)
    }

    @Test func actualPublicTLSMediaCredentialsAgreeWithoutExposingRootKey() async throws {
        let pair = try SecureChannelPair(clientAdmission: .publicRoom, serverAdmission: .publicRoom,
            role: .mediaControl, allowedRoles: [.mediaControl], payload: Data([1]))
        defer { pair.cancel() }
        let outcome = try await pair.run()
        guard case .delivered = outcome else { Issue.record("Media control admission failed"); return }
        let subscriber = try #require(pair.clientCredentials), publisher = try #require(pair.serverCredentials)
        let registry = MediaSubscriptionRegistry()
        let ticket = try registry.reserveAdmittedSubscription(credentials: publisher, broadcasterEpoch: 7,
            generation: 9, channels: [.audio], now: 0)
        let flow = UUID()
        let challenge = try registry.receiveProbe(subscriber.makeReturnPathProbe(ticket: ticket),
            sessionID: ticket.sessionID, acceptedFlowID: flow, now: 1)
        try registry.receiveResponse(subscriber.answerReturnPathChallenge(challenge, ticket: ticket),
            sessionID: ticket.sessionID, acceptedFlowID: flow, now: 2)
        let packet = try registry.sealMedia(Data([42]), sessionID: ticket.sessionID, acceptedFlowID: flow, channel: .audio, now: 3)
        #expect(try subscriber.makeSubscriberDatagramOpener(ticket: ticket, channel: .audio).open(packet) == Data([42]))
        let udp = try DatagramLoopbackHarness(publisherCredentials: publisher, subscriberCredentials: subscriber)
        defer { udp.cancel() }
        let delivery = try await udp.receive(payload: Data(repeating: 3, count: 996))
        #expect(delivery.payload == Data(repeating: 3, count: 996))
    }

    @Test func wrongPrivateSecretNeverDeliversPayload() async throws {
        let pair = try SecureChannelPair(clientAdmission: .privateRoom(secret: Data(repeating: 7, count: 32)),
            serverAdmission: .privateRoom(secret: NetworkFixture.secret), payload: Data([1]))
        defer { pair.cancel() }
        let outcome = try await pair.run()
        guard case .failed(let error) = outcome else { Issue.record("Wrong room secret admitted"); return }
        #expect(error == .admissionFailed)
    }

    @Test func forbiddenRoleAndPublicPrivateMismatchFailClosed() async throws {
        let forbidden = try SecureChannelPair(clientAdmission: .publicRoom, serverAdmission: .publicRoom,
                                               role: .video, allowedRoles: [.roomControl], payload: Data([1]))
        defer { forbidden.cancel() }
        let roleOutcome = try await forbidden.run()
        guard case .failed = roleOutcome else { Issue.record("Forbidden channel role admitted"); return }
        let mismatch = try SecureChannelPair(clientAdmission: .publicRoom,
            serverAdmission: .privateRoom(secret: NetworkFixture.secret), payload: Data([1]))
        defer { mismatch.cancel() }
        let modeOutcome = try await mismatch.run()
        guard case .failed = modeOutcome else { Issue.record("Private room downgraded to public"); return }
    }

    @Test func cancellationIsTerminalAndCannotRestartTheChannel() async throws {
        let identity = try InstallationIdentity.ephemeral()
        let queue = DispatchQueue(label: "alo.tests.secure-cancel")
        let offer = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .mobile)
        let config = try SecurePeerConfiguration(roomID: NetworkFixture.room, incarnationID: UUID(),
            admission: .publicRoom, offer: offer, direction: .initiator(.roomControl))
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let channel = SecurePeerChannel(connection: connection, identity: identity, configuration: config,
                                        pins: MemoryPeerPinStore(), queue: queue)
        let states: [SecurePeerChannelState] = await withCheckedContinuation { continuation in
            var states = [SecurePeerChannelState]()
            channel.onState = { states.append($0) }
            channel.cancel(); channel.start(); channel.cancel()
            queue.async { continuation.resume(returning: states) }
        }
        #expect(states == [.cancelled])
    }
}

private final class SecureChannelPair: @unchecked Sendable {
    enum Outcome { case delivered(Data, AuthenticatedPeer, AuthenticatedPeer), failed(SecurePeerChannelError) }
    let clientIdentity: InstallationIdentity
    let serverIdentity: InstallationIdentity
    private let queue = DispatchQueue(label: "alo.tests.secure-channel")
    private let listener: NWListener
    private let clientParameters: NWParameters
    private let clientConfig: SecurePeerConfiguration
    private let serverConfig: SecurePeerConfiguration
    private let clientPins = MemoryPeerPinStore(), serverPins = MemoryPeerPinStore()
    private let payload: Data
    private var client: SecurePeerChannel?
    private var server: SecurePeerChannel?
    private var clientPeer: AuthenticatedPeer?, serverPeer: AuthenticatedPeer?
    private(set) var clientCredentials: AuthenticatedChannelCredentials?, serverCredentials: AuthenticatedChannelCredentials?
    private var continuation: CheckedContinuation<Outcome, Error>?

    init(clientAdmission: SecureRoomAdmission, serverAdmission: SecureRoomAdmission,
         role: ReliableChannelRole = .roomControl, allowedRoles: Set<ReliableChannelRole> = [.roomControl], payload: Data) throws {
        clientIdentity = try .ephemeral(); serverIdentity = try .ephemeral(); self.payload = payload
        let offer = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop)
        clientConfig = try .init(roomID: NetworkFixture.room, incarnationID: UUID(), admission: clientAdmission,
                                offer: offer, direction: .initiator(role))
        serverConfig = try .init(roomID: NetworkFixture.room, incarnationID: UUID(), admission: serverAdmission,
                                offer: offer, direction: .responder(allowedChannelRoles: allowedRoles))
        clientParameters = try SecureNetworkParameters.tcp(identity: clientIdentity, expectedPeerID: serverIdentity.publicIdentity.nodeID,
            pins: clientPins, firstContact: .explicitRoomJoin, verificationQueue: queue)
        let serverParameters = try SecureNetworkParameters.tcp(identity: serverIdentity, expectedPeerID: clientIdentity.publicIdentity.nodeID,
            pins: serverPins, firstContact: .explicitRoomJoin, verificationQueue: queue)
        listener = try NWListener(using: serverParameters, on: .any)
    }
    func run() async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.server == nil else { connection.cancel(); return }
                    let channel = SecurePeerChannel(connection: connection, identity: self.serverIdentity,
                        configuration: self.serverConfig, pins: self.serverPins, queue: self.queue)
                    self.server = channel
                    channel.onState = { [weak self] state in self?.state(state) }
                    channel.onAuthenticated = { [weak self] peer in
                        guard let self else { return }
                        self.serverPeer = peer
                        self.server?.withAuthenticatedCredentials { result in self.serverCredentials = try? result.get() }
                    }
                    channel.onPayload = { [weak self] payload in
                        guard let self, self.serverPeer != nil else { return }
                        self.server?.send(payload: payload)
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
                            configuration: self.clientConfig, pins: self.clientPins, queue: self.queue)
                        self.client = channel
                        channel.onState = { [weak self] state in self?.state(state) }
                        channel.onAuthenticated = { [weak self] peer in
                            guard let self else { return }
                            self.clientPeer = peer
                            self.client?.withAuthenticatedCredentials { result in self.clientCredentials = try? result.get() }
                            self.client?.send(payload: self.payload)
                        }
                        channel.onPayload = { [weak self] data in
                            guard let self, let clientPeer = self.clientPeer, let serverPeer = self.serverPeer else { return }
                            self.finish(.delivered(data, clientPeer, serverPeer))
                        }
                        channel.start()
                    case .failed: self.finish(.failed(.connectionFailed))
                    default: break
                    }
                }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, let continuation = self.continuation else { return }
                    self.continuation = nil; continuation.resume(throwing: SecurePeerChannelError.timedOut)
                }
            }
        }
    }
    private func state(_ state: SecurePeerChannelState) {
        if case .failed(let error) = state { finish(.failed(error)) }
    }
    private func finish(_ result: Outcome) {
        guard let continuation else { return }
        self.continuation = nil; continuation.resume(returning: result)
    }
    func cancel() {
        queue.async { self.listener.cancel(); self.client?.cancel(); self.server?.cancel() }
    }
}
