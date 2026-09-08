import Foundation
import CryptoKit
import Network
import ALOIdentity
import ALOCore

/// Separate text-only TLS protocol. It does not join an audio channel, advertise
/// a fake Main channel, or execute messages. Local application consent controls
/// listener creation and service enablement independently.
public final class NetworkDeviceTextTransport: @unchecked Sendable {
    public enum QueryResult {
        case receipt(CodexDeviceMessagingPolicy.Receipt)
        /// No record was found in the current own grant. Not proof of non-execution.
        case statusUnknown
        case grantExpired
        /// Only the query failed; previous message evidence is unchanged.
        case unavailable(CodexDeviceMessagingError)
    }
    public enum Event {
        /// Sender proof was accepted. This is not a task grant or dispatch permission.
        case ready
        /// Actual TLS/challenge-derived receiver identity; never a Bonjour claim.
        case remoteAuthenticated(NetworkDeviceAuthenticatedRemote)
        case authenticated(UUID, NetworkDeviceAuthorization.Context)
        case grant(UUID)
        case receipt(grantID: UUID, messageID: UUID, CodexDeviceMessagingPolicy.Receipt)
        case queryResult(grantID: UUID, messageID: UUID, QueryResult)
        /// Ends only this live observation, not other grants or the message.
        case subscriptionExpired(grantID: UUID, messageID: UUID)
        case messageAccepted(UUID, CodexDeviceMessageEnvelope)
        /// Local validation or a solicited receiver rate rejection. No automatic retry.
        case rejected(grantID: UUID, messageID: UUID, CodexDeviceMessagingError)
        case closed
    }
    private struct Wire: Codable {
        enum Kind: String, Codable { case challenge, claim, authenticated, grant, text, receiptQuery, queryResult, subscriptionExpired, receipt, rejected }
        enum QueryStatus: String, Codable { case statusUnknown, grantExpired, rateLimited }
        let kind: Kind
        var challenge: NetworkDeviceAuthorization.Challenge?
        var claim: NetworkDeviceAuthorization.Claim?
        var grantID: UUID?
        var message: CodexDeviceMessageEnvelope?
        var messageID: UUID?
        var receipt: CodexDeviceMessagingPolicy.Receipt?
        var rejection: String?
        var queryStatus: QueryStatus?
    }
    private enum Mode {
        case receiver(CodexDeviceMessageService)
        case sender(UserIdentity, DeviceIdentityBinding, NetworkPolicyCenter, Data)
    }
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let mode: Mode
    private let pins: PeerPinStore
    private let event: (Event) -> Void
    private let admitTLS: (PeerPublicIdentity) -> Bool
    private var parser = NetworkDeviceMessageFraming()
    private var expectedChallenge: NetworkDeviceAuthorization.Challenge?
    private var authenticatedRemote: NetworkDeviceAuthenticatedRemote?
    private var localSession: UUID?
    private var admitted = false
    private var closed = false
    private var sending = false
    private var outgoing: [Data] = []
    private var queuedBytes = 0
    private var outgoingFrameLimitForTesting: Int?
    private var responses = NetworkDeviceResponseLedger()
    private var subscriptions: [NetworkDeviceResponseLedger.Key: CodexDeviceMessagingPolicy.Receipt] = [:]
    private var timeout: Task<Void, Never>?
    private var deadlineGeneration = UUID()
    private var policyObserver: UUID?
    private let lifetime: TimeInterval = 300

    /// The supplied connection must use SecureNetworkParameters.tcp. This class
    /// still requires a real ready TLS peer certificate before starting proofs.
    public init(accepted connection: NWConnection, service: CodexDeviceMessageService,
                pins: PeerPinStore, queue: DispatchQueue,
                admitTLS: @escaping (PeerPublicIdentity) -> Bool = { _ in true },
                event: @escaping (Event) -> Void) {
        self.connection = connection; self.queue = networkDeviceExecutor(target: queue); mode = .receiver(service)
        self.pins = pins; self.event = event
        self.admitTLS = admitTLS
    }
    public init(endpoint: NWEndpoint, identity: InstallationIdentity, user: UserIdentity,
                binding: DeviceIdentityBinding, policy: NetworkPolicyCenter, pins: PeerPinStore,
                queue: DispatchQueue,
                verificationQueue: DispatchQueue = DispatchQueue(label: "alo.device-text.verify", attributes: .concurrent),
                event: @escaping (Event) -> Void) throws {
        try binding.verify(expectedInstallationPublicKeyHash: identity.publicIdentity.publicKeyHash)
        let parameters = try SecureNetworkParameters.tcp(identity: identity, expectedPeerID: nil, pins: pins,
            firstContact: .explicitNetworkDeviceMessaging, verificationQueue: verificationQueue)
        connection = NWConnection(to: endpoint, using: parameters)
        self.queue = networkDeviceExecutor(target: queue); mode = .sender(user, binding, policy, identity.publicIdentity.publicKeyHash)
        self.pins = pins; self.event = event
        self.admitTLS = { _ in true }
    }
    deinit {
        timeout?.cancel()
        if case .receiver(let service) = mode {
            if let expectedChallenge { service.cancelChallenge(expectedChallenge) }
            if let localSession { service.disconnect(localSession) }
        }
        if case .sender(_, _, let policy, _) = mode, let policyObserver { policy.removeObserver(policyObserver) }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
    public func start() { queue.async { self.startOnQueue() } }
    public func stop() { queue.async { self.close() } }
    /// Explicit authenticated status lookup, including after reconnect. It does
    /// not resend text and never starts or retries native execution.
    /// Before an outstanding text send's first receipt, this is a no-op: the
    /// existing live receipt remains the response path, with no queryResult.
    /// Duplicate in-flight queries coalesce into the existing query response.
    public func queryReceipt(grantID: UUID, messageID: UUID) {
        queue.async {
            guard case .sender = self.mode, self.admitted, !self.closed else {
                self.event(.queryResult(grantID: grantID, messageID: messageID, .unavailable(.unauthorized))); return
            }
            do {
                guard try self.responses.reserveQuery(.init(grant: grantID, message: messageID)) else { return }
                self.send(Wire(kind: .receiptQuery, grantID: grantID, messageID: messageID))
            } catch {
                self.event(.queryResult(grantID: grantID, messageID: messageID, .unavailable(error as? CodexDeviceMessagingError ?? .capacity)))
            }
        }
    }
    /// IDs select only an existing authenticated observation. Receipt contents
    /// always come from the receiver service, never from the caller.
    func publishCurrentReceipt(grantID: UUID, messageID: UUID) {
        queue.async {
            let key = NetworkDeviceResponseLedger.Key(grant: grantID, message: messageID)
            guard !self.closed, self.admitted, self.subscriptions[key] != nil,
                  case .receiver(let service) = self.mode, let session = self.localSession else { return }
            do {
                let receipt = try service.currentReceipt(grantID: grantID, messageID: messageID, connection: session)
                guard self.subscriptions[key] != receipt else { return }
                self.publish(key, receipt: receipt)
            } catch CodexDeviceMessagingError.grantExpired {
                self.subscriptions.removeValue(forKey: key)
                self.send(Wire(kind: .subscriptionExpired, grantID: grantID, messageID: messageID))
            } catch { self.close() }
        }
    }
    private func publish(_ key: NetworkDeviceResponseLedger.Key, receipt: CodexDeviceMessagingPolicy.Receipt, queryResponse: Bool = false) {
        if receipt == .received || receipt == .dispatching { subscriptions[key] = receipt }
        else { subscriptions.removeValue(forKey: key) }
        send(Wire(kind: queryResponse ? .queryResult : .receipt, grantID: key.grant, messageID: key.message, receipt: receipt))
    }
    /// Receiver-local approval only: callers obtain localTaskID from their local
    /// consent UI. No incoming wire message can invoke this method.
    public func approve(localTaskID: UUID, expiresAtNanos: UInt64) {
        approve(localTaskID: localTaskID, expiresAtNanos: expiresAtNanos, result: nil)
    }
    func approve(localTaskID: UUID, expiresAtNanos: UInt64,
                 result: ((Result<UUID, CodexDeviceMessagingError>) -> Void)?) {
        queue.async {
            guard case .receiver(let service) = self.mode, let id = self.localSession, !self.closed else {
                result?(.failure(.unauthorized)); return
            }
            do {
                let grant = try service.approve(connection: id, localTaskID: localTaskID,
                    expiresAt: expiresAtNanos)
                // Receiver-local durable approval result is independent of wire
                // delivery. The owner can revoke this grant even if send closes.
                result?(.success(grant))
                self.send(Wire(kind: .grant, grantID: grant))
            } catch { result?(.failure(error as? CodexDeviceMessagingError ?? .unauthorized)); self.close() }
        }
    }
    public func send(_ envelope: CodexDeviceMessageEnvelope) {
        queue.async {
            guard case .sender = self.mode, self.admitted, !self.closed else {
                self.event(.rejected(grantID: envelope.grantID, messageID: envelope.messageID, .unauthorized)); return
            }
            let frame: Data
            do { frame = try Self.textFrame(envelope) }
            catch {
                self.event(.rejected(grantID: envelope.grantID, messageID: envelope.messageID, .invalidEnvelope))
                return
            }
            let key = NetworkDeviceResponseLedger.Key(grant: envelope.grantID, message: envelope.messageID)
            // Keep one 32-byte digest per pending request, not a second copy of
            // up to 32 frames beyond the existing output-byte budget.
            var next = self.responses
            do {
                guard try next.reserve(key, digest: Data(SHA256.hash(data: frame))) else { return }
            } catch {
                self.event(.rejected(grantID: envelope.grantID, messageID: envelope.messageID,
                                     error as? CodexDeviceMessagingError ?? .invalidEnvelope)); return
            }
            guard self.outgoing.count < 32, self.queuedBytes + frame.count <= 256 * 1024 else {
                self.event(.rejected(grantID: envelope.grantID, messageID: envelope.messageID, .capacity)); return
            }
            self.responses = next
            self.outgoing.append(frame); self.queuedBytes += frame.count; self.drain()
        }
    }
    static func textFrame(_ envelope: CodexDeviceMessageEnvelope) throws -> Data {
        guard !envelope.text.isEmpty, envelope.text.utf8.count <= CodexDeviceMessagingPolicy.maximumTextBytes else {
            throw CodexDeviceMessagingError.invalidEnvelope
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try NetworkDeviceMessageFraming.encode(encoder.encode(Wire(kind: .text, message: envelope)))
    }
    var pendingReceiptsForTesting: Int { queue.sync { responses.pendingCount } }
    func armDeadlineForTesting(_ seconds: TimeInterval) { queue.async { self.armDeadline(seconds) } }
    var deadlineGenerationForTesting: UUID { queue.sync { deadlineGeneration } }
    func fireDeadlineForTesting(_ generation: UUID) { queue.async { self.deadlineElapsed(generation) } }
    var closedForTesting: Bool { queue.sync { closed } }
    /// Observe the same handler before a peer can react to an emitted response.
    /// This does not change caps, authentication, framing, or output behavior.
    func receiveAndObserveForTesting(_ bytes: Data, observed: @escaping (Bool) -> Void) {
        queue.async {
            do { try self.handleReceivedBytes(bytes) } catch { self.close() }
            observed(self.closed)
        }
    }
    private func startOnQueue() {
        guard timeout == nil, !closed else { return }
        if case .sender(_, _, let policy, _) = mode {
            policyObserver = policy.observe { [weak self] in self?.stop() }
        }
        armDeadline(5)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                do {
                    let peer = try SecureNetworkParameters.peerIdentity(connection: self.connection)
                    guard self.admitTLS(peer) else { self.close(); return }
                    if case .receiver(let service) = self.mode {
                        let challenge = try service.challenge()
                        self.expectedChallenge = challenge
                        self.send(Wire(kind: .challenge, challenge: challenge))
                    }
                    self.receive()
                } catch { self.close() }
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: NetworkDeviceMessageFraming.maximumPayload + 4) { [weak self] bytes, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let bytes {
                    try self.handleReceivedBytes(bytes)
                }
                if complete || error != nil { self.close() } else { self.receive() }
            } catch { self.close() }
        }
    }
    private func handleReceivedBytes(_ bytes: Data) throws {
        for payload in try parser.append(bytes) {
            guard !closed else { return }
            try handle(JSONDecoder().decode(Wire.self, from: payload))
        }
    }
    /// Exercises the actual framing/handle path at an exhausted native-send
    /// admission boundary. Default production limit remains unchanged.
    func receiveAtCapacityForTesting(_ bytes: Data) {
        queue.async {
            self.outgoingFrameLimitForTesting = 0
            do { try self.handleReceivedBytes(bytes) } catch { self.close() }
        }
    }
    private func handle(_ wire: Wire) throws {
        guard !closed else { throw CodexDeviceMessagingError.unauthorized }
        let peer = try SecureNetworkParameters.peerIdentity(connection: connection)
        switch (mode, wire.kind) {
        case (.sender(let user, let binding, let policy, let localHash), .challenge):
            guard !admitted, expectedChallenge == nil, let challenge = wire.challenge else { throw CodexDeviceMessagingError.unauthorized }
            let claim = try NetworkDeviceAuthorization.Claim.signed(challenge: challenge, sender: binding,
                user: user, policy: policy, actualSenderTLSHash: localHash, actualReceiverTLSHash: peer.publicKeyHash)
            authenticatedRemote = try NetworkDeviceAuthenticatedRemote(challenge: challenge,
                actualTLSHash: peer.publicKeyHash, localUser: user.publicIdentity, policy: policy)
            expectedChallenge = challenge
            send(Wire(kind: .claim, claim: claim))
        case (.receiver(let service), .claim):
            guard !admitted, let claim = wire.claim, claim.challenge == expectedChallenge else { throw CodexDeviceMessagingError.unauthorized }
            let id = try service.authenticate(claim, actualPeerTLSHash: peer.publicKeyHash)
            localSession = id
            service.bindConnection(id, queue: queue) { [weak self] in self?.close() }
            try pins.recordAfterAdmission(peer)
            admitted = true; armDeadline(lifetime)
            send(Wire(kind: .authenticated))
            guard !closed else { return }
            event(.authenticated(id, try service.peer(connection: id)))
        case (.sender(let user, _, let policy, _), .authenticated):
            guard !admitted, expectedChallenge != nil, let remote = authenticatedRemote,
                  remote.fullSPKIHash == peer.publicKeyHash,
                  try remote.isCurrent(in: policy, localUser: user.publicIdentity) else { throw CodexDeviceMessagingError.unauthorized }
            try pins.recordAfterAdmission(peer)
            admitted = true; armDeadline(lifetime)
            event(.remoteAuthenticated(remote))
            event(.ready)
        case (.sender, .grant):
            guard admitted, let grant = wire.grantID else { throw CodexDeviceMessagingError.unauthorized }
            try responses.receivedGrant(grant)
            event(.grant(grant))
        case (.receiver(let service), .text):
            guard admitted, let id = localSession, let message = wire.message else { throw CodexDeviceMessagingError.unauthorized }
            let key = NetworkDeviceResponseLedger.Key(grant: message.grantID, message: message.messageID)
            guard subscriptions[key] != nil || subscriptions.count < 32 else {
                // The sender's identical bound prevents a legitimate 33rd
                // observation. Close once instead of serving unbudgeted replies.
                throw CodexDeviceMessagingError.capacity
            }
            let receipt: CodexDeviceMessagingPolicy.Receipt
            do { receipt = try service.receive(message, connection: id) }
            catch CodexDeviceMessagingError.rateLimited {
                send(Wire(kind: .rejected, grantID: message.grantID, messageID: message.messageID, rejection: "rateLimited"))
                return
            }
            catch CodexDeviceMessagingError.capacity {
                send(Wire(kind: .rejected, grantID: message.grantID, messageID: message.messageID, rejection: "capacity"))
                return
            }
            // Local notification follows durable admission even if the peer
            // cannot receive its receipt. It is not external dispatch authority.
            if receipt == .received { event(.messageAccepted(id, message)) }
            publish(key, receipt: receipt)
        case (.receiver(let service), .receiptQuery):
            guard admitted, let session = localSession, let grant = wire.grantID,
                  let message = wire.messageID else { throw CodexDeviceMessagingError.unauthorized }
            let key = NetworkDeviceResponseLedger.Key(grant: grant, message: message)
            guard subscriptions[key] != nil || subscriptions.count < 32 else {
                throw CodexDeviceMessagingError.capacity
            }
            do { publish(key, receipt: try service.queryReceipt(grantID: grant, messageID: message, connection: session), queryResponse: true) }
            catch CodexDeviceMessagingError.rateLimited {
                send(Wire(kind: .queryResult, grantID: grant, messageID: message, queryStatus: .rateLimited))
            }
            catch CodexDeviceMessagingError.statusUnknown {
                send(Wire(kind: .queryResult, grantID: grant, messageID: message, queryStatus: .statusUnknown))
            }
            catch CodexDeviceMessagingError.grantExpired {
                subscriptions.removeValue(forKey: key)
                send(Wire(kind: .queryResult, grantID: grant, messageID: message, queryStatus: .grantExpired))
            }
        case (.sender, .queryResult):
            guard admitted, let id = wire.messageID, let grant = wire.grantID,
                  (wire.receipt != nil) != (wire.queryStatus != nil) else { throw CodexDeviceMessagingError.unauthorized }
            let key = NetworkDeviceResponseLedger.Key(grant: grant, message: id)
            if let receipt = wire.receipt {
                if try responses.resolveQuery(key, receipt: receipt) {
                    event(.receipt(grantID: grant, messageID: id, receipt))
                }
                event(.queryResult(grantID: grant, messageID: id, .receipt(receipt)))
            } else if let status = wire.queryStatus {
                let reason: CodexDeviceMessagingError
                let result: QueryResult
                switch status {
                case .statusUnknown: reason = .statusUnknown; result = .statusUnknown
                case .grantExpired: reason = .grantExpired; result = .grantExpired
                case .rateLimited: reason = .rateLimited; result = .unavailable(.rateLimited)
                }
                try responses.queryUnavailable(key, reason: reason)
                event(.queryResult(grantID: grant, messageID: id, result))
            }
        case (.sender, .subscriptionExpired):
            guard admitted, let id = wire.messageID, let grant = wire.grantID else { throw CodexDeviceMessagingError.unauthorized }
            try responses.endSubscription(.init(grant: grant, message: id))
            event(.subscriptionExpired(grantID: grant, messageID: id))
        case (.sender, .receipt):
            guard admitted, let id = wire.messageID, let grant = wire.grantID, let receipt = wire.receipt else { throw CodexDeviceMessagingError.unauthorized }
            if try responses.resolve(.init(grant: grant, message: id), receipt: receipt) {
                event(.receipt(grantID: grant, messageID: id, receipt))
            }
        case (.sender, .rejected):
            guard admitted, let id = wire.messageID, let grant = wire.grantID else { throw CodexDeviceMessagingError.unauthorized }
            try responses.reject(.init(grant: grant, message: id), reason: wire.rejection)
            event(.rejected(grantID: grant, messageID: id, wire.rejection == "capacity" ? .capacity : .rateLimited))
        default: throw CodexDeviceMessagingError.invalidEnvelope
        }
    }
    private func send(_ wire: Wire) {
        guard !closed else { return }
        do {
            let frame = try NetworkDeviceMessageFraming.encode(JSONEncoder().encode(wire))
            guard outgoing.count < (outgoingFrameLimitForTesting ?? 32), queuedBytes + frame.count <= 256 * 1024 else { throw CodexDeviceMessagingError.capacity }
            outgoing.append(frame); queuedBytes += frame.count; drain()
        } catch { close() }
    }
    private func drain() {
        guard !sending, !closed, let frame = outgoing.first else { return }
        sending = true
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { self.close(); return }
            self.outgoing.removeFirst(); self.queuedBytes -= frame.count; self.sending = false; self.drain()
        })
    }
    private func armDeadline(_ seconds: TimeInterval) {
        timeout?.cancel()
        let generation = UUID(); deadlineGeneration = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        timeout = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                self?.deadlineElapsed(generation)
            }
        }
    }
    private func deadlineElapsed(_ generation: UUID) {
        guard deadlineGeneration == generation else { return }
        close()
    }
    private func close() {
        guard !closed else { return }; closed = true
        timeout?.cancel(); timeout = nil; deadlineGeneration = UUID()
        if case .receiver(let service) = mode, let localSession { service.disconnect(localSession) }
        if case .receiver(let service) = mode, let expectedChallenge { service.cancelChallenge(expectedChallenge) }
        if case .sender(_, _, let policy, _) = mode, let policyObserver { policy.removeObserver(policyObserver) }
        connection.stateUpdateHandler = nil; connection.cancel()
        outgoing.removeAll(); responses = .init(); subscriptions.removeAll(); queuedBytes = 0; event(.closed)
    }
}

/// Explicitly started listener, with a separate connection cap before admission.
/// Endpoint discovery/approval UI belongs to the subsequent application adapter.
public final class NetworkDeviceTextListener: @unchecked Sendable {
    private let listener: NWListener
    private let service: CodexDeviceMessageService
    private let pins: PeerPinStore
    private let queue: DispatchQueue
    private let event: (UUID, NetworkDeviceTextTransport.Event) -> Void
    private var connections: [UUID: NetworkDeviceTextTransport] = [:]
    private var admitted = Set<UUID>()
    private var unknownTLS = Set<UUID>()
    private var started = false
    private var stopped = false
    public init(identity: InstallationIdentity, service: CodexDeviceMessageService,
                pins: PeerPinStore, port: NWEndpoint.Port = .any,
                queue: DispatchQueue,
                verificationQueue: DispatchQueue = DispatchQueue(label: "alo.device-listener.verify", attributes: .concurrent),
                event: @escaping (UUID, NetworkDeviceTextTransport.Event) -> Void) throws {
        guard identity.publicIdentity.publicKeyHash == service.localTLSHashForBinding else {
            throw CodexDeviceMessagingError.unauthorized
        }
        let parameters = try SecureNetworkParameters.tcp(identity: identity, expectedPeerID: nil, pins: pins,
            firstContact: .explicitNetworkDeviceMessaging, verificationQueue: verificationQueue)
        listener = try NWListener(using: parameters, on: port)
        self.service = service; self.pins = pins; self.queue = networkDeviceExecutor(target: queue); self.event = event
    }
    deinit {
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
        listener.cancel()
        for connection in connections.values { connection.stop() }
    }
    /// Untrusted discovery metadata only. Authentication still binds the actual
    /// TLS certificate and signed network challenge, never this TXT record.
    func advertise(networkID: UUID) {
        queue.async {
            guard !self.started, !self.stopped else { return }
            self.listener.service = NWListener.Service(name: nil, type: "_alo-codex._tcp",
                txtRecord: NWTXTRecord(["v": "1", "id": networkID.uuidString]))
        }
    }
    public func start(ready: @escaping (NWEndpoint.Port) -> Void) {
        queue.async {
            guard !self.started, !self.stopped else { return }
            self.started = true
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                if case .ready = state, let port = self.listener.port { ready(port) }
                if case .failed = state { self.stop() }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                // Separate preauthorization capacity cannot evict admitted peers.
                // Before TLS identity exists, eight slots remain susceptible to
                // connection occupation; deadlines bound duration, not availability.
                guard let self, !self.stopped,
                      NetworkDeviceAdmissionLimits.acceptsConnection(total: self.connections.count, admitted: self.admitted.count)
                else { connection.cancel(); return }
                let id = UUID()
                let transport = NetworkDeviceTextTransport(accepted: connection, service: self.service,
                    pins: self.pins, queue: self.queue, admitTLS: { [weak self] peer in
                        guard let self, !self.stopped else { return false }
                        let known = (try? self.pins.pin(for: peer.nodeID)) == peer.publicKeyHash
                        guard NetworkDeviceAdmissionLimits.acceptsTLS(known: known, unknownCount: self.unknownTLS.count) else { return false }
                        if !known { self.unknownTLS.insert(id) }
                        return true
                    }) { [weak self] event in
                        self?.handleTransportEvent(id, event)
                    }
                self.connections[id] = transport; transport.start()
            }
            self.listener.start(queue: self.queue)
        }
    }
    public func approve(connection: UUID, localTaskID: UUID, expiresAtNanos: UInt64) {
        approve(connection: connection, localTaskID: localTaskID, expiresAtNanos: expiresAtNanos, result: nil)
    }
    func approve(connection: UUID, localTaskID: UUID, expiresAtNanos: UInt64,
                 result: ((Result<UUID, CodexDeviceMessagingError>) -> Void)?) {
        queue.async {
            guard !self.stopped, let transport = self.connections[connection] else {
                result?(.failure(.unauthorized)); return
            }
            transport.approve(localTaskID: localTaskID, expiresAtNanos: expiresAtNanos, result: result)
        }
    }
    /// A completion may belong to an old transport; each current subscription
    /// independently revalidates its own authenticated service session.
    func publishCurrentReceipt(grantID: UUID, messageID: UUID) {
        queue.async {
            guard !self.stopped else { return }
            for connection in self.connections.values {
                connection.publishCurrentReceipt(grantID: grantID, messageID: messageID)
            }
        }
    }
    private func handleTransportEvent(_ id: UUID, _ value: NetworkDeviceTextTransport.Event) {
        guard !stopped else { return }
        if case .authenticated = value { admitted.insert(id); unknownTLS.remove(id) }
        if case .closed = value { connections.removeValue(forKey: id); admitted.remove(id); unknownTLS.remove(id) }
        event(id, value)
    }
    /// Injects a delayed callback into the same serialized production handler.
    func enqueueTransportEventForTesting(_ id: UUID, _ value: NetworkDeviceTextTransport.Event) {
        queue.async { self.handleTransportEvent(id, value) }
    }
    var admittedCountForTesting: Int { queue.sync { admitted.count } }
    var nativeListenerForTesting: NWListener { listener }
    func receiveAtCapacityForTesting(connection: UUID, bytes: Data) {
        queue.async { self.connections[connection]?.receiveAtCapacityForTesting(bytes) }
    }
    func receiveAndObserveForTesting(connection: UUID, bytes: Data, observed: @escaping (Bool) -> Void) {
        queue.async { self.connections[connection]?.receiveAndObserveForTesting(bytes, observed: observed) }
    }
    public func stop() {
        queue.async {
            guard !self.stopped else { return }; self.stopped = true
            self.listener.cancel()
            for connection in self.connections.values { connection.stop() }
            self.connections.removeAll()
            self.admitted.removeAll(); self.unknownTLS.removeAll()
        }
    }
}
