import Foundation
import CryptoKit

public struct MediaSubscriptionTicket: Sendable {
    public let roomID: UUID
    public let senderID: UUID
    public let receiverID: UUID
    public let sessionID: UUID
    public let generation: UInt64
    public let subscriptionSequence: UInt64
    public let broadcasterEpoch: UInt64
    public let channels: Set<DatagramChannel>
    public let expiresAt: TimeInterval
    public let validForSeconds: TimeInterval

    private struct Wire: Codable {
        let roomID: UUID, senderID: UUID, receiverID: UUID, sessionID: UUID
        let generation: UInt64, broadcasterEpoch: UInt64
        let subscriptionSequence: UInt64?
        let channels: [DatagramChannel]
        let expiresAt: TimeInterval
        let validForSeconds: TimeInterval
    }
    /// Expiry is server-monotonic metadata; a receiver must not compare it to its local clock.
    public init(encoded: Data) throws {
        guard encoded.count <= 2_048 else { throw SecureTransportError.oversized }
        let wire = try JSONDecoder().decode(Wire.self, from: encoded)
        guard wire.channels.count <= 3, Set(wire.channels).count == wire.channels.count else { throw SecureTransportError.malformed }
        try self.init(roomID: wire.roomID, senderID: wire.senderID, receiverID: wire.receiverID,
            sessionID: wire.sessionID, generation: wire.generation, broadcasterEpoch: wire.broadcasterEpoch,
            channels: Set(wire.channels), expiresAt: wire.expiresAt, validForSeconds: wire.validForSeconds,
            subscriptionSequence: wire.subscriptionSequence ?? 0)
    }
    public func encoded() throws -> Data {
        try JSONEncoder().encode(Wire(roomID: roomID, senderID: senderID, receiverID: receiverID,
            sessionID: sessionID, generation: generation, broadcasterEpoch: broadcasterEpoch, subscriptionSequence: subscriptionSequence,
            channels: channels.sorted { $0.rawValue < $1.rawValue }, expiresAt: expiresAt, validForSeconds: validForSeconds))
    }

    public init(roomID: UUID, senderID: UUID, receiverID: UUID, sessionID: UUID,
                generation: UInt64, broadcasterEpoch: UInt64, channels: Set<DatagramChannel>,
                expiresAt: TimeInterval, validForSeconds: TimeInterval = 30, subscriptionSequence: UInt64 = 0) throws {
        guard senderID != receiverID, !channels.isEmpty, !channels.contains(.returnPath), expiresAt.isFinite,
              validForSeconds.isFinite, validForSeconds > 0, validForSeconds <= 300 else {
            throw SecureTransportError.malformed
        }
        self.roomID = roomID; self.senderID = senderID; self.receiverID = receiverID
        self.sessionID = sessionID; self.generation = generation; self.broadcasterEpoch = broadcasterEpoch
        self.channels = channels; self.expiresAt = expiresAt
        self.subscriptionSequence = subscriptionSequence
        self.validForSeconds = validForSeconds
    }

    public func context(for channel: DatagramChannel) -> SecureDatagramContext {
        .init(roomID: roomID, senderID: senderID, receiverID: receiverID,
              broadcasterEpoch: broadcasterEpoch, sessionID: sessionID, generation: generation, channel: channel)
    }
}

/// Fixed-size 128-byte authenticated path proofs. Each challenge is no larger than its
/// triggering probe; media is forbidden until a response arrives on that same flow.
public enum MediaReturnPathProof {
    public static let packetSize = 128
    private static let zeroFlow = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    struct Parsed {
        let kind: UInt8
        let flowBytes: Data
        let nonce: Data
    }

    static func key(ticket: MediaSubscriptionTicket, secret: SymmetricKey) throws -> SymmetricKey {
        guard secret.bitCount >= 256 else { throw SecureTransportError.invalidCredentials }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: Data("ALO/return-path/v2".utf8),
            info: ticket.context(for: .returnPath).binding, outputByteCount: 32)
    }
    static func encode(kind: UInt8, ticket: MediaSubscriptionTicket, flowID: UUID, nonce: Data, key: SymmetricKey) -> Data {
        var wire = WireBytes(); wire.append(UInt32(0x414C4F50)); wire.append(UInt8(2)); wire.append(kind)
        wire.append(UInt16(0)); wire.append(ticket.sessionID); wire.append(ticket.generation)
        wire.append(flowID); wire.append(nonce); wire.append(Data(repeating: 0, count: 16))
        let tag = HMAC<SHA256>.authenticationCode(for: wire.data, using: key)
        return wire.data + Data(tag)
    }
    static func parse(_ packet: Data, ticket: MediaSubscriptionTicket, key: SymmetricKey, expectedKind: UInt8) throws -> Parsed {
        guard packet.count == packetSize else { throw SecureTransportError.malformed }
        guard HMAC<SHA256>.isValidAuthenticationCode(packet.suffix(32), authenticating: packet.prefix(96), using: key) else {
            throw SecureTransportError.invalidCredentials
        }
        var reader = WireReader(data: packet)
        guard try reader.integer(UInt32.self) == 0x414C4F50, try reader.integer(UInt8.self) == 2,
              try reader.integer(UInt8.self) == expectedKind, try reader.integer(UInt16.self) == 0 else {
            throw SecureTransportError.malformed
        }
        var session = WireBytes(); session.append(ticket.sessionID)
        guard try reader.bytes(16) == session.data, try reader.integer(UInt64.self) == ticket.generation else {
            throw SecureTransportError.wrongContext
        }
        let flow = try reader.bytes(16), nonce = try reader.bytes(32)
        guard try reader.bytes(16) == Data(repeating: 0, count: 16) else { throw SecureTransportError.malformed }
        return Parsed(kind: expectedKind, flowBytes: flow, nonce: nonce)
    }
    static func randomNonce() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    public static func makeProbe(ticket: MediaSubscriptionTicket, secret: SymmetricKey) throws -> Data {
        encode(kind: 1, ticket: ticket, flowID: zeroFlow, nonce: randomNonce(), key: try key(ticket: ticket, secret: secret))
    }
    public static func answerChallenge(_ challenge: Data, ticket: MediaSubscriptionTicket, secret: SymmetricKey) throws -> Data {
        let proofKey = try key(ticket: ticket, secret: secret)
        _ = try parse(challenge, ticket: ticket, key: proofKey, expectedKind: 2)
        // The response authenticates the exact challenge, including its server-chosen flow binding.
        var body = Data(challenge.prefix(96))
        body[body.startIndex + 5] = 3
        return body + Data(HMAC<SHA256>.authenticationCode(for: body, using: proofKey))
    }
}

public struct MediaSubscriptionLimits: Sendable {
    public let maximumSubscriptions: Int
    public let maximumPending: Int
    public let maximumPerPeer: Int
    public init(maximumSubscriptions: Int = 64, maximumPending: Int = 16, maximumPerPeer: Int = 4) {
        self.maximumSubscriptions = min(1024, max(1, maximumSubscriptions))
        self.maximumPending = min(self.maximumSubscriptions, max(1, maximumPending))
        self.maximumPerPeer = min(self.maximumSubscriptions, max(1, maximumPerPeer))
    }
}

/// Serial-executor-owned registry. This implements private-room admission only. The Network
/// adapter must obtain exporter/key hashes from verified TLS and pass a fresh UUID identifying
/// the actual accepted UDP flow (never a flow identifier claimed by a remote packet).
public final class MediaSubscriptionRegistry {
    private struct Entry {
        let ticket: MediaSubscriptionTicket
        let secret: SymmetricKey
        let proofKey: SymmetricKey
        var credentials: AuthenticatedChannelCredentials? = nil
        var flowID: UUID?
        var challengeNonce: Data?
        var challengeDeadline: TimeInterval?
        var validated = false
        var challengeCount = 0
        var sealers: [DatagramChannel: DatagramSealer] = [:]
    }
    private var entries: [UUID: Entry] = [:]
    public let limits: MediaSubscriptionLimits
    public var count: Int { entries.count }
    public var pendingCount: Int { entries.values.filter { !$0.validated }.count }
    public init(limits: MediaSubscriptionLimits = .init()) { self.limits = limits }

    public func reserveAdmittedSubscription(credentials: AuthenticatedChannelCredentials,
        broadcasterEpoch: UInt64, generation: UInt64, channels: Set<DatagramChannel>, now: TimeInterval,
        lifetime: TimeInterval = 30) throws -> MediaSubscriptionTicket {
        guard credentials.isActive, credentials.channelRole == .mediaControl, credentials.localRole == .responder,
              credentials.negotiated.wireVersion == 2 else { throw SecureTransportError.invalidCredentials }
        guard now.isFinite, lifetime.isFinite, lifetime > 0, lifetime <= 300 else { throw SecureTransportError.malformed }
        let requester = credentials.negotiated.initiatorCapabilities
        let publisher = credentials.negotiated.responderCapabilities
        guard !channels.isEmpty, !channels.contains(.returnPath),
              !channels.contains(.audio) || (requester.contains(.receiveAudio) && publisher.contains(.broadcast)),
              !channels.contains(.voice) || (requester.contains(.voice) && publisher.contains(.voice)) else {
            throw SecureTransportError.invalidCredentials
        }
        expire(now: now)
        guard entries.count < limits.maximumSubscriptions, pendingCount < limits.maximumPending,
              entries.values.filter({ $0.ticket.receiverID == credentials.remotePeerID }).count < limits.maximumPerPeer else {
            throw SecureTransportError.capacity
        }
        let ticket = try MediaSubscriptionTicket(roomID: credentials.roomID, senderID: credentials.localPeerID,
            receiverID: credentials.remotePeerID, sessionID: UUID(), generation: generation,
            broadcasterEpoch: broadcasterEpoch, channels: channels, expiresAt: now + lifetime, validForSeconds: lifetime,
            subscriptionSequence: try credentials.nextSubscriptionSequence())
        entries[ticket.sessionID] = Entry(ticket: ticket, secret: credentials.rootSecret,
            proofKey: try MediaReturnPathProof.key(ticket: ticket, secret: credentials.rootSecret), credentials: credentials)
        return ticket
    }

    /// Call only after applying an adapter-level TLS connection/handshake rate limit.
    /// The proof is checked before allocation. A fresh server-selected session ID prevents
    /// a peer from recreating nonce space by choosing an old session/generation.
    public func reservePrivateSubscription(proof: Data, roomSecret: Data, transcript: AdmissionTranscript,
        exporter: Data, broadcasterEpoch: UInt64, generation: UInt64, channels: Set<DatagramChannel>,
        now: TimeInterval, lifetime: TimeInterval = 30) throws -> MediaSubscriptionTicket {
        guard transcript.admissionKind == .privateRoom else { throw SecureTransportError.invalidCredentials }
        guard now.isFinite, lifetime.isFinite, lifetime > 0, lifetime <= 300 else { throw SecureTransportError.malformed }
        expire(now: now)
        guard try TLSBoundAdmissionProof.verify(proof, roomSecret: roomSecret, transcript: transcript,
                                                exporter: exporter, role: .initiator) else {
            throw SecureTransportError.invalidCredentials
        }
        let caps = transcript.negotiated.initiatorCapabilities
        guard !channels.isEmpty, !channels.contains(.returnPath),
              !channels.contains(.audio) || caps.contains(.receiveAudio),
              !channels.contains(.voice) || caps.contains(.voice) else { throw SecureTransportError.invalidCredentials }
        guard entries.count < limits.maximumSubscriptions, pendingCount < limits.maximumPending,
              entries.values.filter({ $0.ticket.receiverID == transcript.initiatorID }).count < limits.maximumPerPeer else {
            throw SecureTransportError.capacity
        }
        let ticket = try MediaSubscriptionTicket(roomID: transcript.roomID, senderID: transcript.responderID,
            receiverID: transcript.initiatorID, sessionID: UUID(), generation: generation,
            broadcasterEpoch: broadcasterEpoch, channels: channels, expiresAt: now + lifetime, validForSeconds: lifetime)
        let secret = try TLSBoundAdmissionProof.channelSecret(roomSecret: roomSecret, transcript: transcript, exporter: exporter)
        entries[ticket.sessionID] = Entry(ticket: ticket, secret: secret,
            proofKey: try MediaReturnPathProof.key(ticket: ticket, secret: secret))
        return ticket
    }

    /// Returns at most one 128-byte challenge for each authenticated 128-byte probe; at most
    /// three challenges per admitted subscription. No packet is emitted for failed parsing.
    public func receiveProbe(_ probe: Data, sessionID: UUID, acceptedFlowID: UUID, now: TimeInterval) throws -> Data {
        var entry = try liveEntry(sessionID, now: now)
        guard !entry.validated, entry.challengeCount < 3 else { throw SecureTransportError.invalidState }
        let parsed = try MediaReturnPathProof.parse(probe, ticket: entry.ticket, key: entry.proofKey, expectedKind: 1)
        guard parsed.flowBytes == Data(repeating: 0, count: 16) else { throw SecureTransportError.malformed }
        // One pending flow per ticket. Rebinding requires a new admitted session.
        guard entry.flowID == nil || entry.flowID == acceptedFlowID else { throw SecureTransportError.wrongContext }
        entry.flowID = acceptedFlowID; entry.challengeNonce = MediaReturnPathProof.randomNonce()
        entry.challengeDeadline = min(entry.ticket.expiresAt, now + 10); entry.challengeCount += 1
        let challenge = MediaReturnPathProof.encode(kind: 2, ticket: entry.ticket, flowID: acceptedFlowID,
            nonce: entry.challengeNonce!, key: entry.proofKey)
        entries[sessionID] = entry
        return challenge
    }

    public func receiveResponse(_ response: Data, sessionID: UUID, acceptedFlowID: UUID, now: TimeInterval) throws {
        var entry = try liveEntry(sessionID, now: now)
        guard !entry.validated, entry.flowID == acceptedFlowID,
              let deadline = entry.challengeDeadline, now < deadline,
              let nonce = entry.challengeNonce else { throw SecureTransportError.unvalidatedReturnPath }
        let parsed = try MediaReturnPathProof.parse(response, ticket: entry.ticket, key: entry.proofKey, expectedKind: 3)
        var flow = WireBytes(); flow.append(acceptedFlowID)
        guard parsed.flowBytes == flow.data, parsed.nonce == nonce else { throw SecureTransportError.wrongContext }
        entry.validated = true; entry.challengeNonce = nil; entry.challengeDeadline = nil
        entries[sessionID] = entry
    }

    public func confirmReturnPathResponse(_ response: Data, sessionID: UUID, acceptedFlowID: UUID,
                                          now: TimeInterval) throws -> Data {
        try receiveResponse(response, sessionID: sessionID, acceptedFlowID: acceptedFlowID, now: now)
        let entry = try liveEntry(sessionID, now: now)
        var body = Data(response.prefix(96)); body[body.startIndex + 5] = 4
        return body + Data(HMAC<SHA256>.authenticationCode(for: body, using: entry.proofKey))
    }

    public func containsLiveSubscription(sessionID: UUID, now: TimeInterval) -> Bool {
        (try? liveEntry(sessionID, now: now)) != nil
    }

    /// The only media-producing API enforces admission, expiry, channel authorization, and
    /// the validated accepted flow before allocating/using a sequence-owning channel sealer.
    public func sealMedia(_ payload: Data, sessionID: UUID, acceptedFlowID: UUID,
                          channel: DatagramChannel, now: TimeInterval) throws -> Data {
        var entry = try liveEntry(sessionID, now: now)
        guard entry.validated, entry.flowID == acceptedFlowID else { throw SecureTransportError.unvalidatedReturnPath }
        guard entry.ticket.channels.contains(channel) else { throw SecureTransportError.invalidCredentials }
        let sealer: DatagramSealer
        if let existing = entry.sealers[channel] { sealer = existing }
        else {
            sealer = try DatagramSealer(secret: entry.secret, context: entry.ticket.context(for: channel))
            entry.sealers[channel] = sealer
            entries[sessionID] = entry
        }
        return try sealer.seal(payload)
    }

    public func cancel(sessionID: UUID) { entries.removeValue(forKey: sessionID) }
    public func cancelAll() { entries.removeAll(keepingCapacity: false) }
    public func expire(now: TimeInterval) {
        guard now.isFinite else { return }
        entries = entries.filter { $0.value.ticket.expiresAt > now && ($0.value.credentials?.isActive ?? true) }
    }
    private func liveEntry(_ id: UUID, now: TimeInterval) throws -> Entry {
        guard now.isFinite else { throw SecureTransportError.malformed }
        guard let entry = entries[id] else { throw SecureTransportError.invalidState }
        guard entry.credentials?.isActive ?? true else { entries.removeValue(forKey: id); throw SecureTransportError.invalidCredentials }
        guard now < entry.ticket.expiresAt else { entries.removeValue(forKey: id); throw SecureTransportError.expired }
        return entry
    }
}
