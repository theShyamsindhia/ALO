import Foundation
import Network
import CryptoKit
import ALOIdentity
import ALORooms

public enum SecureRoomAdmission: Sendable {
    case publicRoom
    case privateRoom(secret: Data)
    var kind: RoomAdmissionKind {
        switch self { case .publicRoom: return .publicRoom; case .privateRoom: return .privateRoom }
    }
}

public enum SecurePeerDirection: Sendable {
    case initiator(ReliableChannelRole)
    case responder(allowedChannelRoles: Set<ReliableChannelRole>)
    var proofRole: AdmissionProofRole {
        switch self { case .initiator: return .initiator; case .responder: return .responder }
    }
}

public struct SecurePeerConfiguration: Sendable {
    public let roomID: UUID
    public let incarnationID: UUID
    public let admission: SecureRoomAdmission
    public let offer: ProtocolOffer
    public let direction: SecurePeerDirection
    public let timing: ConnectionTimingPolicy
    public let networkAuthorization: NetworkChannelAuthorization?
    public init(roomID: UUID, incarnationID: UUID, admission: SecureRoomAdmission,
                offer: ProtocolOffer, direction: SecurePeerDirection, timing: ConnectionTimingPolicy = .init(),
                networkAuthorization: NetworkChannelAuthorization? = nil) throws {
        guard offer.wireVersions.contains(2) else { throw SecureTransportError.downgradeForbidden }
        if case .privateRoom(let secret) = admission, secret.count != 32 { throw SecureTransportError.invalidCredentials }
        if case .responder(let roles) = direction, roles.isEmpty { throw SecureTransportError.malformed }
        if offer.stateSyncVersions.contains(ProtocolOffer.currentRoomGeneration) {
            guard offer.stateSyncVersions == [ProtocolOffer.currentRoomGeneration],
                  let networkAuthorization, networkAuthorization.channelID == roomID else {
                throw SecureTransportError.invalidCredentials
            }
        } else if networkAuthorization != nil { throw SecureTransportError.unsupportedProtocol }
        self.roomID = roomID; self.incarnationID = incarnationID; self.admission = admission
        self.offer = offer; self.direction = direction; self.timing = timing
        self.networkAuthorization = networkAuthorization
    }
}

public struct AuthenticatedPeer: Sendable {
    public let nodeID: UUID
    public let publicKeyHash: Data
    public let incarnationID: UUID
    public let connectionID: UUID
    public let negotiated: NegotiatedProtocol
    public let channelRole: ReliableChannelRole
    public var userIdentity: PublicUserIdentity? = nil
}

public enum SecurePeerChannelError: LocalizedError, Equatable, Sendable {
    case connectionFailed, timedOut, protocolViolation, admissionFailed, queueFull, oversized, notAuthenticated, cancelled
    case incompatibleVersion
    public var errorDescription: String? {
        switch self {
        case .incompatibleVersion: return "This device uses an incompatible room system. Update all devices before joining."
        case .notAuthenticated: return "This device does not have an active secure room connection."
        case .admissionFailed: return "The device could not authenticate with this room."
        case .connectionFailed: return "The connection to the device failed."
        case .timedOut: return "The device did not respond in time."
        case .protocolViolation: return "The device sent an invalid room message."
        case .queueFull: return "The connection is busy. Try again shortly."
        case .oversized: return "The transfer message exceeds the connection limit."
        case .cancelled: return "The connection was cancelled."
        }
    }
}
public enum SecurePeerChannelState: Equatable, Sendable {
    case idle, connecting, authenticating, authenticated, failed(SecurePeerChannelError), cancelled
}

/// A reliable TLS connection plus its v2 admission transaction. Set handlers before start;
/// handlers run on the supplied serial queue. Public methods marshal onto that queue.
/// Mesh payloads preserve message boundaries; video payloads are bounded stream chunks.
/// No microphone or application command is triggered by this class.
public final class SecurePeerChannel: @unchecked Sendable {
    public static let maximumPayloadBytes = 262_144
    public static let maximumFrameBytes = 400 * 1_024
    public static let maximumQueuedBytes = 1_024 * 1_024
    public static let maximumQueuedFrames = 64
    public var onState: ((SecurePeerChannelState) -> Void)?
    public var onAuthenticated: ((AuthenticatedPeer) -> Void)?
    public var onPayload: ((Data) -> Void)?

    private struct Hello: Codable {
        let roomID: UUID
        let peerID: UUID
        let keyHash: Data
        let incarnationID: UUID
        let connectionID: UUID
        let nonce: Data
        let wireVersions: [UInt16]
        let stateSyncVersions: [UInt16]
        let capabilities: UInt32
        let channelRole: ReliableChannelRole
        let admissionKind: RoomAdmissionKind
        let direction: UInt8
        let networkClaim: NetworkPeerClaim?
        func offer() throws -> ProtocolOffer {
            try ProtocolOffer(wireVersions: wireVersions, stateSyncVersions: stateSyncVersions,
                              capabilities: PeerCapabilities(rawValue: capabilities))
        }
    }
    private struct Frame: Codable {
        enum Kind: String, Codable { case hello, proof, accepted, payload, networkPolicy }
        let kind: Kind
        var hello: Hello? = nil
        var proof: Data? = nil
        var payload: Data? = nil
        var policy: NetworkManifest? = nil
    }
    private struct Send {
        let bytes: Data
        let requiresCurrentAuthorization: Bool
        let completion: ((Result<Void, Error>) -> Void)?
    }
    private let connection: NWConnection
    private let identity: InstallationIdentity
    private let configuration: SecurePeerConfiguration
    private let pins: PeerPinStore
    private let queue: DispatchQueue
    private let verificationQueue = DispatchQueue(label: "alo.secure-peer.verify", qos: .userInitiated)
    private let executorKey = DispatchSpecificKey<UInt8>()
    private var state: SecurePeerChannelState = .idle
    private var generation: UInt64 = 0
    private var deadline: DispatchWorkItem?
    private var receiveBuffer = Data()
    private var pending = [Send]()
    private var inFlight: Send?
    private var queuedBytes = 0
    private var localHello: Hello?
    private var remoteHello: Hello?
    private var tlsPeer: PeerPublicIdentity?
    private var admissionSession: TLSAdmissionSession?
    private var credentials: AuthenticatedChannelCredentials?
    private var remoteProofAccepted = false
    private var remoteAck = false
    private var localAckSent = false
    private var deferredPayloads = [Data]()
    private var deferredPayloadBytes = 0
    private var policyObserver: UUID?
    private var lastSentPolicyRevision: UInt64 = 0
    private var frameWorkInFlight = false
    private var policyValidationInFlight = false
    private var policyDeadline: DispatchWorkItem?
    private var policyWindowStarted: UInt64 = 0
    private var policyFramesInWindow = 0
    static let maximumPolicyFramesPerWindow = 8

    public init(connection: NWConnection, identity: InstallationIdentity, configuration: SecurePeerConfiguration,
                pins: PeerPinStore, queue: DispatchQueue) {
        self.connection = connection; self.identity = identity; self.configuration = configuration
        self.pins = pins; self.queue = queue
        queue.setSpecific(key: executorKey, value: 1)
    }

    deinit {
        if let policyObserver { configuration.networkAuthorization?.policy.removeObserver(policyObserver) }
        queue.setSpecific(key: executorKey, value: nil)
    }

    public func start() {
        queue.async {
            guard self.state == .idle else { return }
            self.generation += 1
            self.policyObserver = self.configuration.networkAuthorization?.policy.observe { [weak self] in
                self?.queue.async { [weak self] in self?.networkPolicyChanged() }
            }
            let generation = self.generation
            self.transition(.connecting)
            self.setDeadline(self.configuration.timing.connectTimeout, generation: generation)
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == generation, !self.isTerminal else { return }
                switch state {
                case .ready: self.transportReady(generation: generation)
                case .failed: self.close(.connectionFailed)
                case .cancelled: self.close(.cancelled)
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    public func cancel() { queue.async { self.close(.cancelled) } }

    public func withAuthenticatedCredentials(_ completion: @escaping (Result<AuthenticatedChannelCredentials, Error>) -> Void) {
        let action = {
            guard self.state == .authenticated, let credentials = self.credentials else {
                completion(.failure(SecurePeerChannelError.notAuthenticated)); return
            }
            completion(.success(credentials))
        }
        // Authentication handlers can obtain credentials before handling coalesced payloads.
        if DispatchQueue.getSpecific(key: executorKey) == 1 { action() }
        else { queue.async(execute: action) }
    }

    /// Internal adapters share this executor without exposing it to application
    /// callers. Install their handlers inside the admission callback.
    var mediaExecutor: DispatchQueue { queue }
    /// Queue-confined backpressure measurement for transport diagnostics/tests.
    var pendingSendByteCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return queuedBytes
    }

    /// Derives only the UDP port from a media grant. The host must be the concrete
    /// remote address of this live admitted TLS path, preserving IPv6 scope.
    /// No service-name, user-supplied address, or unresolved endpoint fallback.
    public func withAuthenticatedDatagramEndpoint(port: NWEndpoint.Port,
        completion: @escaping (Result<NWEndpoint, Error>) -> Void) {
        let action = {
            guard self.state == .authenticated, let credentials = self.credentials,
                  credentials.isActive, credentials.channelRole == .mediaControl || credentials.channelRole == .voiceControl,
                  case .ready = self.connection.state, port.rawValue != 0,
                  let remote = self.connection.currentPath?.remoteEndpoint,
                  case .hostPort(let host, _) = remote else {
                completion(.failure(SecurePeerChannelError.notAuthenticated)); return
            }
            switch host {
            case .ipv4, .ipv6: completion(.success(.hostPort(host: host, port: port)))
            default: completion(.failure(SecureTransportError.wrongContext))
            }
        }
        if DispatchQueue.getSpecific(key: executorKey) == 1 { action() }
        else { queue.async(execute: action) }
    }

    public func send(payload: Data, completion: ((Result<Void, Error>) -> Void)? = nil) {
        let action = {
            guard self.state == .authenticated else { completion?(.failure(SecurePeerChannelError.notAuthenticated)); return }
            guard self.hasCurrentAuthorization else {
                completion?(.failure(SecurePeerChannelError.admissionFailed)); self.close(.admissionFailed); return
            }
            guard payload.count <= Self.maximumPayloadBytes else { completion?(.failure(SecurePeerChannelError.oversized)); return }
            self.enqueue(Frame(kind: .payload, payload: payload), completion: completion)
        }
        // Media clock adapters already run here. A second asynchronous hop
        // would add unrelated executor backlog AFTER the send timestamp.
        if DispatchQueue.getSpecific(key: executorKey) == 1 { action() }
        else { queue.async(execute: action) }
    }

    private var isTerminal: Bool {
        switch state { case .failed, .cancelled: return true; default: return false }
    }
    private func transition(_ next: SecurePeerChannelState) {
        guard state != next else { return }
        state = next; onState?(next)
    }
    private func setDeadline(_ interval: TimeInterval, generation: UInt64) {
        deadline?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, !self.isTerminal, self.state != .authenticated else { return }
            self.close(.timedOut)
        }
        deadline = task; queue.asyncAfter(deadline: .now() + interval, execute: task)
    }
    private func close(_ reason: SecurePeerChannelError) {
        guard !isTerminal else { return }
        generation += 1; deadline?.cancel(); deadline = nil
        policyDeadline?.cancel(); policyDeadline = nil
        frameWorkInFlight = false; policyValidationInFlight = false
        if let policyObserver { configuration.networkAuthorization?.policy.removeObserver(policyObserver) }
        policyObserver = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        let completions = pending.compactMap(\.completion) + [inFlight?.completion].compactMap { $0 }
        pending.removeAll(); inFlight = nil; queuedBytes = 0; receiveBuffer.removeAll()
        admissionSession = nil
        credentials?.invalidate(); credentials = nil
        deferredPayloads.removeAll(); deferredPayloadBytes = 0
        transition(reason == .cancelled ? .cancelled : .failed(reason))
        for completion in completions { completion(.failure(reason)) }
    }

    private func transportReady(generation: UInt64) {
        guard state == .connecting else { return }
        do {
            tlsPeer = try SecureNetworkParameters.peerIdentity(connection: connection)
            transition(.authenticating)
            setDeadline(configuration.timing.authenticationTimeout, generation: generation)
            if case .initiator(let role) = configuration.direction {
                let hello = try makeHello(connectionID: UUID(), role: role)
                localHello = hello; enqueue(Frame(kind: .hello, hello: hello))
            }
            receive(generation: generation)
        } catch { close(.admissionFailed) }
    }

    private func makeHello(connectionID: UUID, role: ReliableChannelRole) throws -> Hello {
        let claim = try configuration.networkAuthorization?.claim(installationKeyHash: identity.publicIdentity.publicKeyHash)
        lastSentPolicyRevision = claim?.manifest.revision ?? 0
        return Hello(roomID: configuration.roomID, peerID: identity.publicIdentity.nodeID,
            keyHash: identity.publicIdentity.publicKeyHash, incarnationID: configuration.incarnationID,
            connectionID: connectionID, nonce: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
            wireVersions: configuration.offer.wireVersions, stateSyncVersions: configuration.offer.stateSyncVersions,
            capabilities: configuration.offer.capabilities.rawValue, channelRole: role,
            admissionKind: configuration.admission.kind, direction: configuration.direction.proofRole.rawValue,
            networkClaim: claim)
    }

    private func receive(generation: UInt64) {
        guard !isTerminal, !frameWorkInFlight else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            guard let self, self.generation == generation, !self.isTerminal else { return }
            if let bytes, !bytes.isEmpty {
                self.receiveBuffer.append(bytes)
                guard self.receiveBuffer.count <= Self.maximumQueuedBytes else { self.close(.queueFull); return }
                do { try self.consumeFrames() }
                catch SecureTransportError.unsupportedProtocol { self.close(.incompatibleVersion); return }
                catch { self.close(.protocolViolation); return }
            }
            guard !self.isTerminal else { return }
            if error != nil || complete { self.close(.connectionFailed); return }
            self.receive(generation: generation)
        }
    }
    private func consumeFrames() throws {
        while receiveBuffer.count >= 4, !isTerminal, !frameWorkInFlight {
            var reader = WireReader(data: receiveBuffer)
            let length = Int(try reader.integer(UInt32.self))
            let maximum = state == .authenticated || (remoteProofAccepted && remoteAck) ? Self.maximumFrameBytes
                : (configuration.networkAuthorization == nil ? 8_192 : NetworkManifest.maximumEncodedBytes + 8_192)
            guard length > 0, length <= maximum else { throw SecureTransportError.oversized }
            guard receiveBuffer.count >= 4 + length else { return }
            let body = Data(receiveBuffer.dropFirst(4).prefix(length))
            receiveBuffer.removeFirst(4 + length)
            if configuration.networkAuthorization != nil {
                // Manifest decoding includes ECDSA verification. Do not put
                // peer-controlled cryptographic work on the shared media queue.
                frameWorkInFlight = true
                let token = generation
                let callbackQueue = queue
                verificationQueue.async { [weak self] in
                    let result = Result { try JSONDecoder().decode(Frame.self, from: body) }
                    callbackQueue.async { [weak self] in
                        guard let self, self.generation == token, !self.isTerminal else { return }
                        do {
                            try self.handle(result.get())
                            if !self.policyValidationInFlight { self.finishFrameWork(generation: token) }
                        } catch { self.failFrame(error) }
                    }
                }
            } else { try handle(JSONDecoder().decode(Frame.self, from: body)) }
        }
    }

    private func failFrame(_ error: Error) {
        if (error as? SecureTransportError) == .unsupportedProtocol { close(.incompatibleVersion) }
        else { close(.protocolViolation) }
    }

    private func finishFrameWork(generation: UInt64) {
        guard self.generation == generation, !isTerminal else { return }
        frameWorkInFlight = false
        do { try consumeFrames() }
        catch { failFrame(error); return }
        receive(generation: generation)
    }

    private func verifyPolicy(_ manifest: NetworkManifest, authorization: NetworkChannelAuthorization,
                              preflight: @escaping () throws -> Void = {},
                              completion: @escaping (SecurePeerChannel) throws -> Void) {
        policyValidationInFlight = true
        let token = generation
        let callbackQueue = queue
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.policyValidationInFlight, !self.isTerminal else { return }
            self.close(.timedOut)
        }
        policyDeadline = timeout
        queue.asyncAfter(deadline: .now() + configuration.timing.authenticationTimeout, execute: timeout)
        verificationQueue.async { [weak self] in
            let finish: (Result<Void, Error>) -> Void = { [weak self] result in
                callbackQueue.async { [weak self] in
                    guard let self, self.generation == token, !self.isTerminal else { return }
                    self.policyDeadline?.cancel(); self.policyDeadline = nil
                    self.policyValidationInFlight = false
                    do { try result.get(); try completion(self); self.finishFrameWork(generation: token) }
                    catch { self.close(.admissionFailed) }
                }
            }
            do { try preflight(); authorization.policy.receiveAsynchronously(manifest, completion: finish) }
            catch { finish(.failure(error)) }
        }
    }

    private func handle(_ frame: Frame) throws {
        switch frame.kind {
        case .networkPolicy:
            guard state == .authenticated, frame.hello == nil, frame.proof == nil, frame.payload == nil,
                  let policy = frame.policy, let authorization = configuration.networkAuthorization else {
                throw SecureTransportError.invalidState
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if policyWindowStarted == 0 || now &- policyWindowStarted >= 10_000_000_000 {
                policyWindowStarted = now; policyFramesInWindow = 0
            }
            guard policyFramesInWindow < Self.maximumPolicyFramesPerWindow else { throw SecureTransportError.capacity }
            policyFramesInWindow += 1
            verifyPolicy(policy, authorization: authorization) { $0.networkPolicyChanged() }
        case .hello:
            guard state == .authenticating, remoteHello == nil, let hello = frame.hello,
                  frame.proof == nil, frame.payload == nil, frame.policy == nil, let peer = tlsPeer,
                  hello.roomID == configuration.roomID, hello.peerID == peer.nodeID, hello.keyHash == peer.publicKeyHash,
                  hello.nonce.count == 32, hello.admissionKind == configuration.admission.kind,
                  hello.direction != configuration.direction.proofRole.rawValue,
                  (hello.direction == 1 || hello.direction == 2) else { throw SecureTransportError.wrongContext }
            _ = try hello.offer()
            _ = try NegotiatedProtocol.negotiate(initiator: configuration.offer, responder: hello.offer(), policy: .secureV2)
            switch configuration.direction {
            case .initiator(let role):
                guard hello.channelRole == role, hello.connectionID == localHello?.connectionID else { throw SecureTransportError.wrongContext }
            case .responder(let roles):
                guard roles.contains(hello.channelRole) else { throw SecureTransportError.wrongContext }
            }
            if let authorization = configuration.networkAuthorization {
                guard let claim = hello.networkClaim, claim.channelID == configuration.roomID else {
                    throw SecureTransportError.invalidCredentials
                }
                verifyPolicy(claim.manifest, authorization: authorization, preflight: {
                    try claim.device.verify(expectedInstallationPublicKeyHash: peer.publicKeyHash)
                }) { channel in
                    try authorization.validateCurrentAccess(claim.device.userIdentity)
                    try channel.finishHello(hello)
                }
            } else {
                guard hello.networkClaim == nil else { throw SecureTransportError.unsupportedProtocol }
                try finishHello(hello)
            }
        case .proof:
            guard state == .authenticating, !remoteProofAccepted, frame.hello == nil, frame.payload == nil, frame.policy == nil,
                  let proof = frame.proof, proof.count == 32, let admissionSession else { throw SecureTransportError.invalidState }
            if configuration.networkAuthorization != nil {
                verifyAdmissionProof(proof, session: admissionSession)
                return
            }
            do {
                switch configuration.admission {
                case .privateRoom(let secret): try admissionSession.admitPrivatePeer(proof: proof, roomSecret: secret)
                case .publicRoom: try admissionSession.admitPublicPeer(proof: proof)
                }
            } catch { close(.admissionFailed); return }
            acknowledgeProof()
        case .accepted:
            guard state == .authenticating, remoteProofAccepted, !remoteAck,
                  frame.hello == nil, frame.proof == nil, frame.payload == nil, frame.policy == nil else { throw SecureTransportError.invalidState }
            remoteAck = true; finishAdmissionIfReady()
        case .payload:
            guard frame.hello == nil, frame.proof == nil, frame.policy == nil,
                  let payload = frame.payload, payload.count <= Self.maximumPayloadBytes else { throw SecureTransportError.invalidState }
            if state == .authenticated {
                guard hasCurrentAuthorization else { close(.admissionFailed); return }
                onPayload?(payload)
            }
            else {
                // A peer can receive our ACK before Network delivers its local send completion.
                // Bound that scheduling overlap and release it only after our admission callback.
                guard state == .authenticating, remoteProofAccepted, remoteAck,
                      deferredPayloads.count < Self.maximumQueuedFrames,
                      deferredPayloadBytes + payload.count <= Self.maximumQueuedBytes else { throw SecureTransportError.invalidState }
                deferredPayloads.append(payload); deferredPayloadBytes += payload.count
            }
        }
    }

    /// The frame remains in flight and the session is removed from channel
    /// state while its mutable admission/pin operation runs on one worker.
    /// Cancellation may finish a valid pin write, but can never publish an ACK
    /// or credentials for the closed channel.
    private func verifyAdmissionProof(_ proof: Data, session: TLSAdmissionSession) {
        admissionSession = nil
        policyValidationInFlight = true
        let token = generation
        let admission = configuration.admission
        let queued = SecureVerificationWorkPool.submit(completionQueue: queue, work: {
            Result {
                switch admission {
                case .privateRoom(let secret): try session.admitPrivatePeer(proof: proof, roomSecret: secret)
                case .publicRoom: try session.admitPublicPeer(proof: proof)
                }
            }
        }, completion: { [weak self] result in
            guard let self, self.generation == token, self.state == .authenticating, !self.isTerminal else { return }
            self.policyValidationInFlight = false
            do {
                try result.get()
                guard self.hasCurrentAuthorization else { throw SecureTransportError.invalidCredentials }
                self.admissionSession = session
                self.acknowledgeProof()
                self.finishFrameWork(generation: token)
            } catch { self.close(.admissionFailed) }
        })
        if !queued { close(.queueFull) }
    }

    private func acknowledgeProof() {
        remoteProofAccepted = true
        let token = generation
        enqueue(Frame(kind: .accepted)) { [weak self] result in
            guard let self, self.generation == token, !self.isTerminal else { return }
            if case .success = result { self.localAckSent = true; self.finishAdmissionIfReady() }
        }
    }

    private func finishHello(_ hello: Hello) throws {
        guard state == .authenticating, remoteHello == nil else { throw SecureTransportError.invalidState }
        if case .responder = configuration.direction {
            let response = try makeHello(connectionID: hello.connectionID, role: hello.channelRole)
            localHello = response; enqueue(Frame(kind: .hello, hello: response))
        }
        remoteHello = hello
        try beginAdmission()
    }

    private func beginAdmission() throws {
        guard let localHello, let remoteHello else { throw SecureTransportError.invalidState }
        let initiator = configuration.direction.proofRole == .initiator ? localHello : remoteHello
        let responder = configuration.direction.proofRole == .responder ? localHello : remoteHello
        let transcript = try AdmissionTranscript(roomID: configuration.roomID, initiatorID: initiator.peerID,
            responderID: responder.peerID, connectionID: initiator.connectionID,
            initiatorKeyHash: initiator.keyHash, responderKeyHash: responder.keyHash,
            initiatorNonce: initiator.nonce, responderNonce: responder.nonce,
            initiatorOffer: initiator.offer(), responderOffer: responder.offer(), policy: .secureV2,
            channelRole: initiator.channelRole, admissionKind: configuration.admission.kind,
            initiatorIncarnationID: initiator.incarnationID, responderIncarnationID: responder.incarnationID,
            initiatorNetworkClaim: initiator.networkClaim?.transcriptDigest(),
            responderNetworkClaim: responder.networkClaim?.transcriptDigest())
        let session = try TLSAdmissionSession(connection: connection, identity: identity, transcript: transcript,
            localRole: configuration.direction.proofRole, pins: pins)
        admissionSession = session
        let proof: Data
        switch configuration.admission {
        case .privateRoom(let secret): proof = try session.makePrivateProof(roomSecret: secret)
        case .publicRoom: proof = try session.makePublicProof()
        }
        enqueue(Frame(kind: .proof, proof: proof))
    }

    private func finishAdmissionIfReady() {
        guard state == .authenticating, remoteProofAccepted, remoteAck, localAckSent,
              let remoteHello, let admissionSession else { return }
        do {
            if let authorization = configuration.networkAuthorization, let claim = remoteHello.networkClaim {
                try authorization.validateCurrentAccess(claim.device.userIdentity)
            }
            let root: SymmetricKey
            switch configuration.admission {
            case .privateRoom(let secret): root = try admissionSession.privateChannelSecret(roomSecret: secret)
            case .publicRoom: root = try admissionSession.publicChannelSecret()
            }
            let authorization = configuration.networkAuthorization
            let remoteUser = remoteHello.networkClaim?.device.userIdentity
            credentials = AuthenticatedChannelCredentials(transcript: admissionSession.transcript,
                localRole: configuration.direction.proofRole, rootSecret: root, stillAuthorized: {
                    guard let authorization else { return true }
                    guard let remoteUser else { return false }
                    return (try? authorization.validateCurrentAccess(remoteUser)) != nil
                })
        } catch { close(.admissionFailed); return }
        deadline?.cancel(); deadline = nil
        transition(.authenticated)
        onAuthenticated?(AuthenticatedPeer(nodeID: remoteHello.peerID, publicKeyHash: remoteHello.keyHash,
            incarnationID: remoteHello.incarnationID, connectionID: remoteHello.connectionID,
            negotiated: admissionSession.transcript.negotiated, channelRole: remoteHello.channelRole,
            userIdentity: remoteHello.networkClaim?.device.userIdentity))
        networkPolicyChanged()
        let payloads = deferredPayloads; deferredPayloads.removeAll(); deferredPayloadBytes = 0
        for payload in payloads {
            guard state == .authenticated, hasCurrentAuthorization else { close(.admissionFailed); return }
            onPayload?(payload)
        }
    }

    private var hasCurrentAuthorization: Bool {
        guard let authorization = configuration.networkAuthorization else { return true }
        guard let remote = remoteHello?.networkClaim?.device.userIdentity else { return false }
        return (try? authorization.validateCurrentAccess(remote)) != nil
    }

    private func networkPolicyChanged() {
        guard !isTerminal, let authorization = configuration.networkAuthorization else { return }
        do {
            let policy = try authorization.policy.snapshot()
            try policy.authorize(authorization.localDevice.userIdentity, channelID: configuration.roomID)
            if let remote = remoteHello?.networkClaim?.device.userIdentity {
                try authorization.validateCurrentAccess(remote)
            }
            if state == .authenticated, policy.revision > lastSentPolicyRevision {
                lastSentPolicyRevision = policy.revision
                enqueue(Frame(kind: .networkPolicy, policy: policy))
            }
        } catch { close(.admissionFailed) }
    }

    private func enqueue(_ frame: Frame, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard !isTerminal else { completion?(.failure(SecurePeerChannelError.cancelled)); return }
        do {
            let body = try JSONEncoder().encode(frame)
            guard body.count <= Self.maximumFrameBytes else { completion?(.failure(SecurePeerChannelError.oversized)); return }
            var wire = WireBytes(); wire.append(UInt32(body.count)); wire.append(body)
            guard queuedBytes + wire.data.count <= Self.maximumQueuedBytes,
                  pending.count + (inFlight == nil ? 0 : 1) < Self.maximumQueuedFrames else {
                completion?(.failure(SecurePeerChannelError.queueFull)); close(.queueFull); return
            }
            queuedBytes += wire.data.count
            pending.append(Send(bytes: wire.data, requiresCurrentAuthorization: frame.kind == .payload,
                                completion: completion))
            drain()
        } catch { completion?(.failure(error)); close(.protocolViolation) }
    }
    private func drain() {
        guard !isTerminal, inFlight == nil, !pending.isEmpty else { return }
        // Membership can change while a payload waits behind another write.
        // Recheck before handing its bytes to Network.framework, not only when
        // the application enqueues it. Bytes already handed to TLS cannot be recalled.
        if pending[0].requiresCurrentAuthorization && !hasCurrentAuthorization {
            close(.admissionFailed)
            return
        }
        let send = pending.removeFirst(); inFlight = send
        let generation = self.generation
        connection.send(content: send.bytes, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == generation, !self.isTerminal else { return }
            self.inFlight = nil; self.queuedBytes -= send.bytes.count
            if error != nil { send.completion?(.failure(SecurePeerChannelError.connectionFailed)); self.close(.connectionFailed); return }
            send.completion?(.success(())); self.drain()
        })
    }
}
