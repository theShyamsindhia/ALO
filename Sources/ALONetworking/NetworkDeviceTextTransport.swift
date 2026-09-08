import Foundation
import Network
import ALOIdentity
import ALOCore

/// Separate text-only TLS protocol. It does not join an audio channel, advertise
/// a fake Main channel, or execute messages. Local application consent controls
/// listener creation and service enablement independently.
public final class NetworkDeviceTextTransport: @unchecked Sendable {
    public enum Event {
        case authenticated(UUID, NetworkDeviceAuthorization.Context)
        case grant(UUID)
        case receipt(grantID: UUID, messageID: UUID, CodexDeviceMessagingPolicy.Receipt)
        case messageAccepted(UUID, CodexDeviceMessageEnvelope)
        /// Local send validation failed; no receipt is pending and connection stays usable.
        case rejected(grantID: UUID, messageID: UUID, CodexDeviceMessagingError)
        case closed
    }
    private struct Wire: Codable {
        enum Kind: String, Codable { case challenge, claim, authenticated, grant, text, receipt }
        let kind: Kind
        var challenge: NetworkDeviceAuthorization.Challenge?
        var claim: NetworkDeviceAuthorization.Claim?
        var grantID: UUID?
        var message: CodexDeviceMessageEnvelope?
        var messageID: UUID?
        var receipt: CodexDeviceMessagingPolicy.Receipt?
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
    private var localSession: UUID?
    private var admitted = false
    private var closed = false
    private var sending = false
    private var outgoing: [Data] = []
    private var queuedBytes = 0
    private struct ReceiptKey: Hashable { let grant: UUID; let message: UUID }
    private var awaitingReceipts = Set<ReceiptKey>()
    private var timeout: DispatchWorkItem?
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
                queue: DispatchQueue, event: @escaping (Event) -> Void) throws {
        try binding.verify(expectedInstallationPublicKeyHash: identity.publicIdentity.publicKeyHash)
        let parameters = try SecureNetworkParameters.tcp(identity: identity, expectedPeerID: nil, pins: pins,
            firstContact: .explicitNetworkDeviceMessaging, verificationQueue: queue)
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
    /// Receiver-local approval only: callers obtain localTaskID from their local
    /// consent UI. No incoming wire message can invoke this method.
    public func approve(localTaskID: UUID, expiresAtNanos: UInt64) {
        queue.async {
            guard case .receiver(let service) = self.mode, let id = self.localSession, !self.closed else { return }
            do {
                let grant = try service.approve(connection: id, localTaskID: localTaskID,
                    expiresAt: expiresAtNanos)
                self.send(Wire(kind: .grant, grantID: grant))
            } catch { self.close() }
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
            let key = ReceiptKey(grant: envelope.grantID, message: envelope.messageID)
            guard (self.awaitingReceipts.contains(key) || self.awaitingReceipts.count < 32),
                  self.outgoing.count < 32, self.queuedBytes + frame.count <= 256 * 1024 else {
                self.event(.rejected(grantID: envelope.grantID, messageID: envelope.messageID, .capacity)); return
            }
            self.awaitingReceipts.insert(key)
            self.outgoing.append(frame); self.queuedBytes += frame.count; self.drain()
        }
    }
    static func textFrame(_ envelope: CodexDeviceMessageEnvelope) throws -> Data {
        guard !envelope.text.isEmpty, envelope.text.utf8.count <= CodexDeviceMessagingPolicy.maximumTextBytes else {
            throw CodexDeviceMessagingError.invalidEnvelope
        }
        return try NetworkDeviceMessageFraming.encode(JSONEncoder().encode(Wire(kind: .text, message: envelope)))
    }
    var pendingReceiptsForTesting: Int { queue.sync { awaitingReceipts.count } }
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
                    for payload in try self.parser.append(bytes) {
                        try self.handle(JSONDecoder().decode(Wire.self, from: payload))
                    }
                }
                if complete || error != nil { self.close() } else { self.receive() }
            } catch { self.close() }
        }
    }
    private func handle(_ wire: Wire) throws {
        let peer = try SecureNetworkParameters.peerIdentity(connection: connection)
        switch (mode, wire.kind) {
        case (.sender(let user, let binding, let policy, let localHash), .challenge):
            guard !admitted, expectedChallenge == nil, let challenge = wire.challenge else { throw CodexDeviceMessagingError.unauthorized }
            let claim = try NetworkDeviceAuthorization.Claim.signed(challenge: challenge, sender: binding,
                user: user, policy: policy, actualSenderTLSHash: localHash, actualReceiverTLSHash: peer.publicKeyHash)
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
            event(.authenticated(id, try service.peer(connection: id)))
        case (.sender, .authenticated):
            guard !admitted, expectedChallenge != nil else { throw CodexDeviceMessagingError.unauthorized }
            try pins.recordAfterAdmission(peer)
            admitted = true; armDeadline(lifetime)
        case (.sender, .grant):
            guard admitted, let grant = wire.grantID else { throw CodexDeviceMessagingError.unauthorized }
            event(.grant(grant))
        case (.receiver(let service), .text):
            guard admitted, let id = localSession, let message = wire.message else { throw CodexDeviceMessagingError.unauthorized }
            let receipt = try service.receive(message, connection: id)
            send(Wire(kind: .receipt, grantID: message.grantID, messageID: message.messageID, receipt: receipt))
            if receipt == .received { event(.messageAccepted(id, message)) }
        case (.sender, .receipt):
            guard admitted, let id = wire.messageID, let grant = wire.grantID, let receipt = wire.receipt,
                  awaitingReceipts.remove(ReceiptKey(grant: grant, message: id)) != nil else { throw CodexDeviceMessagingError.unauthorized }
            event(.receipt(grantID: grant, messageID: id, receipt))
        default: throw CodexDeviceMessagingError.invalidEnvelope
        }
    }
    private func send(_ wire: Wire) {
        do {
            let frame = try NetworkDeviceMessageFraming.encode(JSONEncoder().encode(wire))
            guard outgoing.count < 32, queuedBytes + frame.count <= 256 * 1024 else { throw CodexDeviceMessagingError.capacity }
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
        let task = DispatchWorkItem { [weak self] in self?.close() }
        timeout = task; queue.asyncAfter(deadline: .now() + seconds, execute: task)
    }
    private func close() {
        guard !closed else { return }; closed = true
        timeout?.cancel(); timeout = nil
        if case .receiver(let service) = mode, let localSession { service.disconnect(localSession) }
        if case .receiver(let service) = mode, let expectedChallenge { service.cancelChallenge(expectedChallenge) }
        if case .sender(_, _, let policy, _) = mode, let policyObserver { policy.removeObserver(policyObserver) }
        connection.stateUpdateHandler = nil; connection.cancel()
        outgoing.removeAll(); awaitingReceipts.removeAll(); queuedBytes = 0; event(.closed)
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
                queue: DispatchQueue, event: @escaping (UUID, NetworkDeviceTextTransport.Event) -> Void) throws {
        let parameters = try SecureNetworkParameters.tcp(identity: identity, expectedPeerID: nil, pins: pins,
            firstContact: .explicitNetworkDeviceMessaging, verificationQueue: queue)
        listener = try NWListener(using: parameters, on: port)
        self.service = service; self.pins = pins; self.queue = networkDeviceExecutor(target: queue); self.event = event
    }
    deinit {
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
        listener.cancel()
        for connection in connections.values { connection.stop() }
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
                guard let self, !self.stopped, self.connections.count - self.admitted.count < 8,
                      self.connections.count < 24 else { connection.cancel(); return }
                let id = UUID()
                let transport = NetworkDeviceTextTransport(accepted: connection, service: self.service,
                    pins: self.pins, queue: self.queue, admitTLS: { [weak self] peer in
                        guard let self, !self.stopped else { return false }
                        let known = (try? self.pins.pin(for: peer.nodeID)) == peer.publicKeyHash
                        guard known || self.unknownTLS.count < 4 else { return false }
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
        queue.async {
            guard !self.stopped else { return }
            self.connections[connection]?.approve(localTaskID: localTaskID, expiresAtNanos: expiresAtNanos)
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
