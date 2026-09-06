import Foundation
import Security
import Network
import CryptoKit
import Testing
@testable import ALONetworking

@Suite("Installation TLS identity", .serialized)
struct TLSIdentityTests {
    @Test func secureRoomTCPAllowsSimultaneousListenAndDialEndpoints() throws {
        let identity = try InstallationIdentity.ephemeral()
        let parameters = try SecureNetworkParameters.tcp(
            identity: identity,
            expectedPeerID: nil,
            pins: MemoryPeerPinStore(),
            firstContact: .explicitRoomJoin,
            verificationQueue: DispatchQueue(label: "alo.tests.secure-endpoint-reuse")
        )
        #expect(parameters.allowLocalEndpointReuse)
    }

    @Test func ephemeralCertificateParsesAndSignatureVerifiesWithoutKeychain() throws {
        let identity = try InstallationIdentity.ephemeral()
        let publicKey = try #require(SecCertificateCopyKey(identity.certificate))
        #expect(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256,
            identity.signedCertificateBody as CFData, identity.certificateSignature as CFData, nil))
        let fromCertificate = try PeerPublicIdentity.from(certificate: identity.certificate)
        #expect(fromCertificate == identity.publicIdentity)
        var copied: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity.identity, &copied) == errSecSuccess)
        #expect(copied != nil)
        let different = try InstallationIdentity.ephemeral()
        #expect(different.publicIdentity.nodeID != identity.publicIdentity.nodeID)
        #expect(different.publicIdentity.publicKeyHash != identity.publicIdentity.publicKeyHash)
    }

    @Test func explicitFirstContactIsProvisionalAndKnownIdentityMustMatch() throws {
        let identity = try InstallationIdentity.ephemeral()
        let pins = MemoryPeerPinStore()
        #expect(throws: IdentityError.unknownPeer) {
            try PeerTrustVerifier.evaluate(certificate: identity.certificate, expectedNodeID: identity.publicIdentity.nodeID,
                                           pins: pins, firstContact: .rejectUnknown)
        }
        let peer = try PeerTrustVerifier.evaluate(certificate: identity.certificate, expectedNodeID: identity.publicIdentity.nodeID,
                                                  pins: pins, firstContact: .explicitRoomJoin)
        #expect(pins.pin(for: peer.nodeID) == nil)
        try pins.recordAfterAdmission(peer)
        #expect(try PeerTrustVerifier.evaluate(certificate: identity.certificate, expectedNodeID: peer.nodeID,
                                               pins: pins, firstContact: .rejectUnknown) == peer)
        #expect(throws: IdentityError.peerIdentityMismatch) {
            try PeerTrustVerifier.evaluate(certificate: identity.certificate, expectedNodeID: UUID(),
                                           pins: pins, firstContact: .explicitRoomJoin)
        }
        var changedHash = peer.publicKeyHash
        changedHash[changedHash.startIndex + 31] ^= 1
        let changedKeyForSameNode = try PeerPublicIdentity(publicKeyHash: changedHash)
        #expect(changedKeyForSameNode.nodeID == peer.nodeID)
        #expect(throws: IdentityError.changedPeerKey) { try pins.recordAfterAdmission(changedKeyForSameNode) }
    }

    @Test func productionAndDevelopmentNamespacesAreSeparate() throws {
        let production = try IdentityKeychainNamespace(applicationID: "com.example.alo", environment: .production)
        let development = try IdentityKeychainNamespace(applicationID: "com.example.alo", environment: .development)
        #expect(production.service != development.service)
        #expect(throws: IdentityError.invalidNamespace) {
            try IdentityKeychainNamespace(applicationID: "*", environment: .development)
        }
    }

    @Test func actualMutualTLSExporterAndPrivateAdmissionAgree() async throws {
        let clientIdentity = try InstallationIdentity.ephemeral()
        let serverIdentity = try InstallationIdentity.ephemeral()
        let clientPins = MemoryPeerPinStore(), serverPins = MemoryPeerPinStore()
        let harness = try TLSLoopback(client: clientIdentity, server: serverIdentity, clientPins: clientPins, serverPins: serverPins)
        defer { harness.cancel() }
        let (client, server) = try await harness.connect()
        let offer = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop)
        let transcript = try AdmissionTranscript(roomID: NetworkFixture.room,
            initiatorID: clientIdentity.publicIdentity.nodeID, responderID: serverIdentity.publicIdentity.nodeID,
            connectionID: UUID(), initiatorKeyHash: clientIdentity.publicIdentity.publicKeyHash,
            responderKeyHash: serverIdentity.publicIdentity.publicKeyHash,
            initiatorNonce: Data(repeating: 1, count: 32), responderNonce: Data(repeating: 2, count: 32),
            initiatorOffer: offer, responderOffer: offer, policy: .secureV2)
        let clientExporter = try SecureNetworkParameters.exporter(connection: client, transcript: transcript)
        let serverExporter = try SecureNetworkParameters.exporter(connection: server, transcript: transcript)
        #expect(clientExporter.count == 32)
        #expect(clientExporter == serverExporter)
        let clientSession = try TLSAdmissionSession(connection: client, identity: clientIdentity,
            transcript: transcript, localRole: .initiator, pins: clientPins)
        let serverSession = try TLSAdmissionSession(connection: server, identity: serverIdentity,
            transcript: transcript, localRole: .responder, pins: serverPins)
        #expect(throws: SecureTransportError.invalidCredentials) {
            try clientSession.privateChannelSecret(roomSecret: NetworkFixture.secret)
        }
        let wrong = try clientSession.makePrivateProof(roomSecret: Data(repeating: 9, count: 32))
        #expect(throws: SecureTransportError.invalidCredentials) {
            try serverSession.admitPrivatePeer(proof: wrong, roomSecret: NetworkFixture.secret)
        }
        #expect(serverPins.pin(for: clientIdentity.publicIdentity.nodeID) == nil)
        try serverSession.admitPrivatePeer(proof: clientSession.makePrivateProof(roomSecret: NetworkFixture.secret),
                                           roomSecret: NetworkFixture.secret)
        try clientSession.admitPrivatePeer(proof: serverSession.makePrivateProof(roomSecret: NetworkFixture.secret),
                                           roomSecret: NetworkFixture.secret)
        let clientKey = try clientSession.privateChannelSecret(roomSecret: NetworkFixture.secret).withUnsafeBytes { Data($0) }
        let serverKey = try serverSession.privateChannelSecret(roomSecret: NetworkFixture.secret).withUnsafeBytes { Data($0) }
        #expect(clientKey == serverKey)
        #expect(clientPins.pin(for: serverIdentity.publicIdentity.nodeID) == serverIdentity.publicIdentity.publicKeyHash)
    }

    @Test func plaintextAndNotReadyConnectionsCannotSupplyExporter() throws {
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        #expect(throws: SecureTransportError.missingTLSExporter) {
            try SecureNetworkParameters.exporter(connection: connection, transcript: NetworkFixture.transcript())
        }
    }
}

/// Uses ephemeral identities and loopback only; no user/default Keychain writes or signing.
private final class TLSLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "alo.tests.tls-loopback")
    private let listener: NWListener
    private let clientParameters: NWParameters
    private var client: NWConnection?
    private var server: NWConnection?
    private var clientReady = false, serverReady = false
    private var continuation: CheckedContinuation<(NWConnection, NWConnection), Error>?

    init(client: InstallationIdentity, server: InstallationIdentity,
         clientPins: PeerPinStore, serverPins: PeerPinStore) throws {
        clientParameters = try SecureNetworkParameters.tcp(identity: client, expectedPeerID: server.publicIdentity.nodeID,
            pins: clientPins, firstContact: .explicitRoomJoin, verificationQueue: queue)
        let serverParameters = try SecureNetworkParameters.tcp(identity: server, expectedPeerID: client.publicIdentity.nodeID,
            pins: serverPins, firstContact: .explicitRoomJoin, verificationQueue: queue)
        listener = try NWListener(using: serverParameters, on: .any)
    }
    func connect() async throws -> (NWConnection, NWConnection) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.server == nil else { connection.cancel(); return }
                    self.server = connection
                    connection.stateUpdateHandler = { [weak self] state in self?.state(state, isClient: false) }
                    connection.start(queue: self.queue)
                }
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port, self.client == nil else { return }
                        let client = NWConnection(host: "127.0.0.1", port: port, using: self.clientParameters)
                        self.client = client
                        client.stateUpdateHandler = { [weak self] state in self?.state(state, isClient: true) }
                        client.start(queue: self.queue)
                    case .failed(let error): self.fail(error)
                    default: break
                    }
                }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, self.continuation != nil else { return }
                    self.fail(SecureTransportError.expired)
                }
            }
        }
    }
    private func state(_ state: NWConnection.State, isClient: Bool) {
        switch state {
        case .ready:
            if isClient { clientReady = true } else { serverReady = true }
            if clientReady, serverReady, let client, let server, let continuation {
                self.continuation = nil; continuation.resume(returning: (client, server))
            }
        case .failed(let error): fail(error)
        default: break
        }
    }
    private func fail(_ error: Error) {
        guard let continuation else { return }
        self.continuation = nil; continuation.resume(throwing: error)
        listener.cancel(); client?.cancel(); server?.cancel()
    }
    func cancel() {
        queue.async {
            self.listener.cancel(); self.client?.cancel(); self.server?.cancel()
        }
    }
}
