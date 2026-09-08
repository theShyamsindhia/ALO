import Foundation
import Network
import ALOIdentity
import ALORooms

/// Discovery is a reachability hint, never a membership credential.
public struct NearbyNetwork: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let ownerID: String
    public init(id: UUID, name: String, ownerID: String) {
        self.id = id; self.name = name; self.ownerID = ownerID
    }
}

public struct NearbyNetworkJoinRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let networkID: UUID
    public let displayName: String
    public let identity: PublicUserIdentity
}

public enum NearbyNetworkError: LocalizedError {
    case unavailable, invalidMessage, connectionClosed, rejected, timedOut, busy
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "This network is no longer nearby. Refresh and try again."
        case .invalidMessage: return "The nearby network identity could not be verified."
        case .connectionClosed: return "The nearby connection closed before the request finished. It may have expired. Try again while the owner is available."
        case .rejected: return "The owner declined the join request."
        case .timedOut: return "The join request expired. Try again while the owner is available."
        case .busy: return "Too many join requests are active. Try again shortly."
        }
    }
}

public struct NearbyNetworkApprovalDeliveryError: LocalizedError {
    public let underlyingDescription: String
    public init(underlyingDescription: String) { self.underlyingDescription = underlyingDescription }
    public var errorDescription: String? {
        "Membership was approved, but the invitation could not be delivered. Ask the person to retry Join. \(underlyingDescription)"
    }
}

/// Challenge proof prevents a captured request from being replayed to a different
/// owner challenge or network. The device claim must also match the live TLS key.
public struct NearbyNetworkJoinProof: Codable, Sendable {
    public let device: DeviceIdentityBinding
    public let signature: Data
    public init(user: UserIdentity, device: DeviceIdentityBinding, networkID: UUID, nonce: UUID) throws {
        guard user.publicIdentity == device.userIdentity else { throw NearbyNetworkError.invalidMessage }
        self.device = device
        signature = try user.sign(Self.payload(networkID, nonce, device), domain: "alo.network.join-request.v1")
    }
    public func verify(networkID: UUID, nonce: UUID, installationHash: Data) throws {
        try device.verify(expectedInstallationPublicKeyHash: installationHash)
        guard device.userIdentity.verify(signature: signature, payload: Self.payload(networkID, nonce, device),
            domain: "alo.network.join-request.v1") else { throw NearbyNetworkError.invalidMessage }
    }
    private static func payload(_ networkID: UUID, _ nonce: UUID, _ device: DeviceIdentityBinding) -> Data {
        Data("\(networkID.uuidString)\n\(nonce.uuidString)\n\(device.userIdentity.userID)\n\(device.installationPublicKeyHash.base64EncodedString())".utf8)
    }
}

/// A separate, bounded bootstrap protocol. Mutual TLS authenticates installation
/// keys; root-signed device bindings authenticate accounts. Only an explicit owner
/// action produces a normal signed invitation. No channel payloads use this service.
public final class NearbyNetworkService: @unchecked Sendable {
    public static let serviceType = "_alo-network._tcp"
    private let queue = DispatchQueue(label: "alo.network.bootstrap")
    private let installation: InstallationIdentity
    private let user: UserIdentity
    private let binding: DeviceIdentityBinding
    private let pins = MemoryPeerPinStore()
    private let changed: @Sendable ([NearbyNetwork]) -> Void
    private let requestsChanged: @Sendable ([NearbyNetworkJoinRequest]) -> Void
    private let failed: @Sendable (String) -> Void
    private let notice: @Sendable (String?) -> Void
    private var lastNotice: String?
    private var browser: NWBrowser?
    private var listeners = [UUID: NWListener]()
    private var endpoints = [UUID: (NearbyNetwork, NWEndpoint)]()
    private var sessions = [UUID: Session]()
    private var pending = [UUID: NearbyNetworkJoinRequest]()

    struct Message: Codable {
        var version = 1
        let kind: String
        let networkID: UUID
        var binding: DeviceIdentityBinding?
        var invitation: NetworkInvitation?
        var nonce: UUID?
        var proof: NearbyNetworkJoinProof?
    }
    private final class Session {
        let connection: NWConnection
        let networkID: UUID
        var completion: ((Result<NetworkInvitation, Error>) -> Void)?
        var deliveryCompletion: ((Result<Void, Error>) -> Void)?
        var remoteHost: String?
        var remoteKeyHash: Data?
        var timeout: DispatchWorkItem?
        init(_ connection: NWConnection, networkID: UUID) { self.connection = connection; self.networkID = networkID }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    deinit {
        browser?.cancel(); listeners.values.forEach { $0.cancel() }
        sessions.values.forEach { $0.timeout?.cancel(); $0.connection.cancel() }
    }

    public init(user: UserIdentity, displayName: String,
                changed: @escaping @Sendable ([NearbyNetwork]) -> Void,
                requestsChanged: @escaping @Sendable ([NearbyNetworkJoinRequest]) -> Void,
                failed: @escaping @Sendable (String) -> Void,
                notice: @escaping @Sendable (String?) -> Void = { _ in }) throws {
        installation = try .ephemeral()
        self.user = user
        binding = try DeviceIdentityBinding(user: user, deviceName: displayName, generation: 1,
            installationPublicKeyHash: installation.publicIdentity.publicKeyHash)
        self.changed = changed; self.requestsChanged = requestsChanged; self.failed = failed
        self.notice = notice
    }

    public func start(ownedNetworks: [NetworkManifest]) {
        queue.async { [self] in
            updateListeners(ownedNetworks)
            guard browser == nil else { return }
            let parameters = NWParameters(); parameters.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                guard let self, let browser, self.browser === browser else { return }
                var found = [UUID: (NearbyNetwork, NWEndpoint)]()
                for result in results.prefix(256) {
                    guard case .bonjour(let record) = result.metadata, record["v"] == "1",
                          let rawID = record["id"], let id = UUID(uuidString: rawID),
                          let name = record["name"], !RoomDiscovery.text(name).isEmpty,
                          let owner = record["owner"], owner.utf8.count <= 128 else { continue }
                    found[id] = (NearbyNetwork(id: id, name: RoomDiscovery.text(name), ownerID: owner), result.endpoint)
                }
                self.endpoints = found
                self.changed(found.values.map { $0.0 }.sorted { $0.name < $1.name })
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, let browser, self.browser === browser else { return }
                if case .failed(let error) = state {
                    self.failed(Self.discoveryErrorMessage(error)); browser.cancel(); self.browser = nil
                }
                if case .waiting(let error) = state { self.failed(Self.discoveryErrorMessage(error)) }
            }
            browser.start(queue: queue)
        }
    }

    private func parameters() throws -> NWParameters {
        try SecureNetworkParameters.tcp(identity: installation, expectedPeerID: nil, pins: pins,
            firstContact: .explicitRoomJoin, verificationQueue: queue)
    }

    private func updateListeners(_ manifests: [NetworkManifest]) {
        let allOwned = manifests.filter { $0.owner == binding.userIdentity }.sorted { $0.id.uuidString < $1.id.uuidString }
        let owned = allOwned.prefix(16)
        let nextNotice = allOwned.count > 16
            ? "Only 16 owned networks can be advertised nearby at once. Other networks remain available through invitations." : nil
        if nextNotice != lastNotice {
            lastNotice = nextNotice; notice(nextNotice)
        }
        let ids = Set(owned.map(\.id))
        for id in Array(listeners.keys) where !ids.contains(id) {
            listeners.removeValue(forKey: id)?.cancel()
            for sessionID in Array(sessions.keys) where sessions[sessionID]?.networkID == id && sessions[sessionID]?.completion == nil {
                finish(sessionID, result: .failure(NearbyNetworkError.unavailable))
            }
        }
        for network in owned where listeners[network.id] == nil {
            do {
                try network.validateSignature()
                let listener = try NWListener(using: parameters())
                listener.service = NWListener.Service(name: nil, type: Self.serviceType, txtRecord: NWTXTRecord([
                    "v": "1", "id": network.id.uuidString, "name": RoomDiscovery.text(network.name),
                    "owner": network.owner.userID]))
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, networkID: network.id) }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listeners[network.id] === listener else { return }
                    if case .failed(let error) = state {
                        self.failed(Self.discoveryErrorMessage(error)); listener.cancel(); self.listeners[network.id] = nil
                    }
                }
                listeners[network.id] = listener; listener.start(queue: queue)
            } catch { failed(error.localizedDescription) }
        }
    }

    static func discoveryErrorMessage(_ error: NWError) -> String {
        switch error {
        case .dns(-65570), .posix(.EACCES), .posix(.EPERM):
            return "Local Network access is blocked. Allow ALO in Settings → Privacy & Security → Local Network, then retry nearby networks."
        default: return error.localizedDescription
        }
    }

    public func stop() {
        queue.async { [self] in
            browser?.cancel(); browser = nil
            listeners.values.forEach { $0.cancel() }; listeners = [:]; endpoints = [:]
            for id in Array(sessions.keys) { finish(id, result: .failure(NearbyNetworkError.unavailable)) }
            changed([])
        }
    }

    public func request(networkID: UUID) async throws -> NetworkInvitation {
        let id = UUID(), cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    guard let (network, endpoint) = endpoints[networkID] else { throw NearbyNetworkError.unavailable }
                    guard hasSessionCapacity(outbound: true) else { throw NearbyNetworkError.busy }
                    let connection = NWConnection(to: endpoint, using: try parameters())
                    let session = Session(connection, networkID: networkID)
                    session.completion = { continuation.resume(with: $0) }
                    sessions[id] = session
                    connection.stateUpdateHandler = { [weak self] state in
                        guard let self, self.sessions[id] != nil else { return }
                        if case .ready = state { self.receive(id, limit: 8192) { message in
                            guard message.kind == "hello", message.networkID == networkID,
                                  let remote = message.binding, let nonce = message.nonce,
                                  remote.userIdentity.userID == network.ownerID else {
                                throw NearbyNetworkError.invalidMessage
                            }
                            try self.verify(remote, connection: connection)
                            self.armTimeout(id, seconds: 120)
                            let proof = try NearbyNetworkJoinProof(user: self.user, device: self.binding, networkID: networkID, nonce: nonce)
                            self.send(Message(kind: "request", networkID: networkID, proof: proof), id: id)
                            self.receive(id, limit: NetworkManifest.maximumEncodedBytes + 8192) { response in
                                let invitation = try Self.validatedInvitation(response, networkID: networkID,
                                    owner: remote.userIdentity, recipient: self.binding.userIdentity)
                                self.finish(id, result: .success(invitation))
                            }
                        } }
                        if case .failed(let error) = state { self.finish(id, result: .failure(error)) }
                    }
                    armTimeout(id, seconds: 10); connection.start(queue: queue)
                } catch { continuation.resume(throwing: error) }
            }
          }
        }, onCancel: { [self] in
            cancellation.cancel()
            queue.async { self.finish(id, result: .failure(CancellationError())) }
        })
    }

    private func accept(_ connection: NWConnection, networkID: UUID, approvalTimeout: TimeInterval = 120) {
        guard hasSessionCapacity(outbound: false) else { connection.cancel(); return }
        guard case .hostPort(let host, _) = connection.endpoint else { connection.cancel(); return }
        let remoteHost = String(describing: host)
        guard Self.permitsRemoteSession(existingCount: sessions.values.filter {
            $0.completion == nil && $0.remoteHost == remoteHost
        }.count) else { connection.cancel(); return }
        let id = UUID(); sessions[id] = Session(connection, networkID: networkID)
        sessions[id]?.remoteHost = remoteHost
        let nonce = UUID()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.sessions[id] != nil else { return }
            if case .ready = state {
                do {
                    let hash = try SecureNetworkParameters.peerIdentity(connection: connection).publicKeyHash
                    guard Self.permitsRemoteSession(existingCount: self.sessions.values.filter {
                        $0.completion == nil && $0.remoteKeyHash == hash
                    }.count) else { throw NearbyNetworkError.busy }
                    self.sessions[id]?.remoteKeyHash = hash
                } catch { self.finish(id, result: .failure(error)); return }
                self.send(Message(kind: "hello", networkID: networkID, binding: self.binding, nonce: nonce), id: id)
                self.receive(id, limit: 8192) { message in
                    guard message.kind == "request", message.networkID == networkID, let proof = message.proof else {
                        throw NearbyNetworkError.invalidMessage
                    }
                    let peer = try SecureNetworkParameters.peerIdentity(connection: connection)
                    try proof.verify(networkID: networkID, nonce: nonce, installationHash: peer.publicKeyHash)
                    let remote = proof.device
                    guard !self.pending.values.contains(where: { $0.networkID == networkID && $0.identity == remote.userIdentity }) else {
                        throw NearbyNetworkError.busy
                    }
                    self.pending[id] = NearbyNetworkJoinRequest(id: id, networkID: networkID,
                        displayName: remote.deviceName, identity: remote.userIdentity)
                    self.armTimeout(id, seconds: approvalTimeout); self.publishRequests()
                    // Keep a read outstanding while the owner decides. EOF must
                    // retire Cancel/disconnect promptly; extra bytes are invalid
                    // because this protocol accepts exactly one join request.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, error in
                        self?.finish(id, result: .failure(error ?? NearbyNetworkError.unavailable))
                    }
                }
            }
            if case .failed(let error) = state { self.finish(id, result: .failure(error)) }
        }
        armTimeout(id, seconds: 10); connection.start(queue: queue)
    }

    private func hasSessionCapacity(outbound: Bool) -> Bool {
        let outgoing = sessions.values.filter { $0.completion != nil }.count
        return Self.permitsSession(inboundCount: sessions.count - outgoing, outboundCount: outgoing, outbound: outbound)
    }

    /// Separate reservations keep remote approval traffic from consuming all
    /// locally initiated Join capacity. Each direction permits at most 16.
    static func permitsSession(inboundCount: Int, outboundCount: Int, outbound: Bool) -> Bool {
        (outbound ? outboundCount : inboundCount) < 16
    }
    static func permitsRemoteSession(existingCount: Int) -> Bool { existingCount < 2 }

    private func verify(_ device: DeviceIdentityBinding, connection: NWConnection) throws {
        let peer = try SecureNetworkParameters.peerIdentity(connection: connection)
        try device.verify(expectedInstallationPublicKeyHash: peer.publicKeyHash)
    }

    public func respond(id: UUID, invitation: NetworkInvitation?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                // A repeated owner action must not cancel the response already
                // being sent, or resume its first caller with a false failure.
                guard sessions[id]?.deliveryCompletion == nil else {
                    continuation.resume(throwing: NearbyNetworkError.busy); return
                }
                do {
                    guard let request = pending[id], let session = sessions[id] else {
                        throw NearbyNetworkError.unavailable
                    }
                    if let invitation {
                        guard invitation.manifest.id == request.networkID, invitation.recipient == request.identity,
                              invitation.manifest.owner == binding.userIdentity else { throw NearbyNetworkError.invalidMessage }
                        _ = try invitation.encoded()
                    }
                    session.deliveryCompletion = { continuation.resume(with: $0) }
                    send(Message(kind: invitation == nil ? "rejected" : "approved", networkID: request.networkID,
                                 invitation: invitation), id: id, close: true)
                } catch {
                    continuation.resume(throwing: error)
                    finish(id, result: .failure(error))
                }
            }
        }
    }

    /// Resolve approval against live transport state, rather than a possibly
    /// stale presentation snapshot. The owner's explicit approval begins here.
    public func requestAwaitingApproval(id: UUID) async throws -> NearbyNetworkJoinRequest {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let request = pending[id], sessions[id] != nil else {
                    continuation.resume(throwing: NearbyNetworkError.unavailable); return
                }
                continuation.resume(returning: request)
            }
        }
    }

    public func cancelRequest(networkID: UUID) {
        queue.async { [self] in
            for id in Array(sessions.keys) where sessions[id]?.networkID == networkID && sessions[id]?.completion != nil {
                finish(id, result: .failure(CancellationError()))
            }
        }
    }

    /// Internal endpoint injection keeps transport tests independent of Bonjour
    /// permissions and discovery. Production always uses the browse-result map.
    func request(network: NearbyNetwork, endpoint: NWEndpoint) async throws -> NetworkInvitation {
        await withCheckedContinuation { continuation in
            queue.async { self.endpoints[network.id] = (network, endpoint); continuation.resume() }
        }
        return try await request(networkID: network.id)
    }

    enum LoopbackConfigurationError: Error { case invalidApprovalTimeout }

    func listenOnLoopback(network: NetworkManifest, approvalTimeout: TimeInterval = 120) async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard approvalTimeout.isFinite, approvalTimeout > 0, approvalTimeout <= 120 else {
                        throw LoopbackConfigurationError.invalidApprovalTimeout
                    }
                    try network.validateSignature()
                    guard network.owner == binding.userIdentity else { throw NetworkAuthorityError.ownerRequired }
                    let profile = try parameters()
                    profile.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: profile)
                    listeners[network.id] = listener
                    var returned = false
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection, networkID: network.id, approvalTimeout: approvalTimeout)
                    }
                    listener.stateUpdateHandler = { state in
                        guard !returned else { return }
                        if case .ready = state, let port = listener.port {
                            returned = true; continuation.resume(returning: .hostPort(host: .ipv4(.loopback), port: port))
                        }
                        if case .failed(let error) = state { returned = true; continuation.resume(throwing: error) }
                    }
                    listener.start(queue: queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func publishRequests() { requestsChanged(pending.values.sorted { $0.id.uuidString < $1.id.uuidString }) }
    private func armTimeout(_ id: UUID, seconds: Double) {
        sessions[id]?.timeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.finish(id, result: .failure(NearbyNetworkError.timedOut)) }
        sessions[id]?.timeout = timeout; queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }
    private func finish(_ id: UUID, result: Result<NetworkInvitation, Error>) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.timeout?.cancel(); session.connection.cancel(); session.completion?(result)
        if case .failure(let error) = result { session.deliveryCompletion?(.failure(error)) }
        if pending.removeValue(forKey: id) != nil { publishRequests() }
    }
    private func send(_ message: Message, id: UUID, close: Bool = false) {
        do {
            let data = try JSONEncoder().encode(message)
            guard data.count <= NetworkManifest.maximumEncodedBytes + 8192 else { throw NearbyNetworkError.invalidMessage }
            var length = UInt32(data.count).bigEndian
            let frame = withUnsafeBytes(of: &length) { Data($0) } + data
            sessions[id]?.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error { self?.finish(id, result: .failure(error)) }
                else if close {
                    let delivered = self?.sessions[id]?.deliveryCompletion
                    self?.sessions[id]?.deliveryCompletion = nil
                    delivered?(.success(()))
                    self?.finish(id, result: .failure(NearbyNetworkError.rejected))
                }
            })
        } catch { finish(id, result: .failure(error)) }
    }
    private func receive(_ id: UUID, limit: Int, handle: @escaping (Message) throws -> Void) {
        read(id, count: 4) { header in
            let length = try Self.frameLength(header, limit: limit)
            self.read(id, count: length) { data in
                try handle(Self.decodeMessage(data, limit: limit))
            }
        }
    }
    static func frameLength(_ header: Data, limit: Int) throws -> Int {
        guard header.count == 4 else { throw NearbyNetworkError.invalidMessage }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= limit else { throw NearbyNetworkError.invalidMessage }
        return length
    }
    static func decodeMessage(_ data: Data, limit: Int) throws -> Message {
        guard data.count <= limit else { throw NearbyNetworkError.invalidMessage }
        let message = try JSONDecoder().decode(Message.self, from: data)
        guard message.version == 1 else { throw NearbyNetworkError.invalidMessage }
        return message
    }
    static func validatedInvitation(_ response: Message, networkID: UUID, owner: PublicUserIdentity,
                                    recipient: PublicUserIdentity) throws -> NetworkInvitation {
        guard response.networkID == networkID else { throw NearbyNetworkError.invalidMessage }
        guard response.kind == "approved" else { throw NearbyNetworkError.rejected }
        guard let invitation = response.invitation, invitation.manifest.id == networkID,
              invitation.manifest.owner == owner, invitation.recipient == recipient else { throw NearbyNetworkError.invalidMessage }
        // The wire wrapper needs extra JSON overhead; independently enforce the
        // invitation's own document limit before handing it to the repository.
        _ = try invitation.encoded()
        return invitation
    }
    private func read(_ id: UUID, count: Int, handle: @escaping (Data) throws -> Void) {
        sessions[id]?.connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, self.sessions[id] != nil else { return }
            do {
                if let error { throw error }
                // A peer can close after its approval deadline without sending a
                // response. EOF is not evidence of a failed identity check.
                guard let data, data.count == count else { throw NearbyNetworkError.connectionClosed }
                try handle(data)
            } catch { self.finish(id, result: .failure(error)) }
        }
    }
}
