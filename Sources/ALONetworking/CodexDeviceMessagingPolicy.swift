import Foundation
import CryptoKit
import ALOIdentity

public enum CodexDeviceMessagingError: Error, Equatable {
    case disabled, unauthorized, expired, invalidEnvelope, capacity, rateLimited
    case duplicateConflict, invalidTransition, clockRegressed
}

/// Snapshot of an independently authenticated context, used only to scope local
/// consent. This policy does not authenticate TLS, verify signatures, or acquire
/// the membership fence. Its caller uses NetworkDeviceAuthorization.withCurrentContext.
fileprivate struct CodexDeviceMessagingScope: Codable, Hashable, Sendable {
    let networkID: UUID
    let generation: UUID
    let owner: PublicUserIdentity
    let sender: PublicUserIdentity
    let receiver: PublicUserIdentity
    let senderSPKIHash: Data
    let receiverSPKIHash: Data
    let purpose: String
    let policyRevision: UInt64
    init(_ context: NetworkDeviceAuthorization.Context) {
        networkID = context.networkID; generation = context.generation
        owner = context.owner; sender = context.sender; receiver = context.receiver
        senderSPKIHash = context.senderSPKIHash; receiverSPKIHash = context.receiverSPKIHash
        purpose = context.purpose
        policyRevision = context.policyRevision
    }
}

/// Text-only peer envelope: no task ID, executable, model, or permission knobs.
/// The transport separately enforces its 24KiB frame bound before decoding.
public struct CodexDeviceMessageEnvelope: Codable, Equatable, Sendable {
    public let grantID: UUID
    public let messageID: UUID
    public let text: String
    public init(grantID: UUID, messageID: UUID = UUID(), text: String) {
        self.grantID = grantID; self.messageID = messageID; self.text = text
    }
}

/// Pure receiver-side state. Serialize access on one executor; it performs no
/// transport, filesystem, CLI, task discovery, or task execution operations.
/// Before returning an acceptance receipt or executing a Dispatch, atomically
/// persist the resulting checkpoint. Persistence failure means DO NOT dispatch.
/// Journal durability and policy/dispatch fencing belong to the caller.
public struct CodexDeviceMessagingPolicy: Sendable {
    public static let maximumTextBytes = 16 * 1024
    public static let maximumFrameBytes = 24 * 1024
    public static let maximumQueuedMessages = 32
    public static let maximumQueuedBytes = 256 * 1024
    public static let maximumGrants = 32
    public static let maximumReceipts = 1024
    public static let maximumGrantReceipts = 256
    public static let maximumGrantQueuedMessages = 8
    public static let maximumGrantQueuedBytes = 64 * 1024
    public static let maximumGrantLifetimeNanos: UInt64 = 24 * 60 * 60 * 1_000_000_000

    public enum Receipt: String, Codable, Sendable {
        /// Authenticated and admitted to ALO's local queue, not Codex delivery.
        case received, dispatching, codexQueued, delivered, uncertain, cancelled
    }
    public enum DispatchResult: Sendable { case queued, definitelyNotQueued, uncertain }
    public struct Dispatch: Sendable {
        public let messageID: UUID
        public let localTaskID: UUID
        public let peerText: String
        public let sender: PublicUserIdentity
    }
    fileprivate struct Grant: Codable, Sendable, Equatable {
        let scope: CodexDeviceMessagingScope
        let taskID: UUID
        let expiresAt: UInt64
        var revoked = false
        var tokens = 5.0
        var lastRefill: UInt64
    }
    fileprivate struct Key: Codable, Hashable, Sendable {
        let grantID: UUID
        let messageID: UUID
    }
    fileprivate struct Record: Codable, Sendable, Equatable {
        let digest: Data
        let byteCount: Int
        var text: String?
        var receipt: Receipt
        var nativeAttempt: UUID?
        // Live dispatch needs text; restart never restores/replays it.
        // Keep it in memory but exclude plaintext from every durable encoding.
        enum CodingKeys: String, CodingKey { case digest, byteCount, receipt, nativeAttempt }
    }
    /// Local-only durable data contains private task mappings. Never send this
    /// to a peer. No decoder accepts a replacement checkpoint from the network.
    public struct Checkpoint: Codable, Sendable, Equatable {
        fileprivate var grants: [UUID: Grant]
        fileprivate var records: [Key: Record]
    }
    public private(set) var isEnabled = false
    private var grants: [UUID: Grant] = [:]
    private var records: [Key: Record] = [:]
    private var lastNow: UInt64?

    public init() {}

    /// Monotonic deadlines cannot survive a process/device restart reliably.
    /// Restoring never re-enables old grants or retries a possibly queued side
    /// effect. Reapproval creates a fresh opaque capability, not an old ID.
    public init(restoring checkpoint: Checkpoint) throws {
        guard checkpoint.grants.count <= Self.maximumGrants,
              checkpoint.records.count <= Self.maximumReceipts,
              checkpoint.records.allSatisfy({ key, record in
                  checkpoint.grants[key.grantID] != nil && record.digest.count == 32
                      && (1...Self.maximumTextBytes).contains(record.byteCount)
              }) else { throw CodexDeviceMessagingError.capacity }
        grants = checkpoint.grants
        records = checkpoint.records
        for id in Array(grants.keys) { grants[id]?.revoked = true }
        for key in Array(records.keys) {
            if records[key]?.receipt == .dispatching { records[key]?.receipt = .uncertain }
            else if records[key]?.receipt == .received { records[key]?.receipt = .cancelled }
            records[key]?.text = nil
        }
    }

    public var checkpoint: Checkpoint { Checkpoint(grants: grants, records: records) }
    public struct LocalGrant: Sendable {
        public let id: UUID
        public let localTaskID: UUID
        public let expiresAtNanos: UInt64
        public let revoked: Bool
        public let recordCount: Int
    }
    /// Receiver-local settings only; never encoded in the peer protocol.
    public var localGrants: [LocalGrant] {
        grants.map { id, grant in
            LocalGrant(id: id, localTaskID: grant.taskID, expiresAtNanos: grant.expiresAt,
                       revoked: grant.revoked, recordCount: records.keys.filter { $0.grantID == id }.count)
        }
    }
    /// Cheap local lookup for the transient pre-policy query gate, never an
    /// authorization result. Current membership/expiry is still checked later.
    func matchesQueryScope(grantID: UUID, context: NetworkDeviceAuthorization.Context) -> Bool {
        guard let grant = grants[grantID], !grant.revoked else { return false }
        return grant.scope == CodexDeviceMessagingScope(context)
    }
    /// Receiver-local inspection only. Remote retries go through receive's
    /// authorization checks rather than exposing this lookup as an endpoint.
    public func receipt(grantID: UUID, messageID: UUID) -> Receipt? {
        records[Key(grantID: grantID, messageID: messageID)]?.receipt
    }
    public var queuedMessageCount: Int {
        records.values.filter { $0.receipt == .received || $0.receipt == .dispatching }.count
    }
    public var queuedByteCount: Int {
        records.values.reduce(0) {
            $0 + (($1.receipt == .received || $1.receipt == .dispatching) ? $1.byteCount : 0)
        }
    }

    public mutating func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { for id in Array(grants.keys) { revoke(grantID: id) } }
    }

    /// Must be invoked ONLY by a local consent action, never a remote request.
    /// Opaque IDs are minted here; peer input cannot choose/replace task mappings.
    public mutating func grant(context: NetworkDeviceAuthorization.Context, localTaskID: UUID,
                               now: UInt64, expiresAt: UInt64) throws -> UUID {
        try advance(now)
        guard isEnabled else { throw CodexDeviceMessagingError.disabled }
        guard now < context.sessionValidUntilNanos, expiresAt > now,
              expiresAt - now <= Self.maximumGrantLifetimeNanos else { throw CodexDeviceMessagingError.expired }
        guard grants.count < Self.maximumGrants else { throw CodexDeviceMessagingError.capacity }
        let id = UUID()
        grants[id] = Grant(scope: CodexDeviceMessagingScope(context), taskID: localTaskID, expiresAt: expiresAt, lastRefill: now)
        return id
    }

    public mutating func revoke(grantID: UUID) {
        grants[grantID]?.revoked = true
        for key in Array(records.keys) where key.grantID == grantID {
            if records[key]?.receipt == .received { records[key]?.receipt = .cancelled }
            else if records[key]?.receipt == .dispatching { records[key]?.receipt = .uncertain }
            records[key]?.text = nil
        }
    }

    /// Local-only deliberate evidence deletion, never automatic replay eviction.
    /// In-flight/uncertain receipts can be lost only with explicit acknowledgment.
    /// Removing the capability leaves every old envelope unauthorized, including
    /// after restart; future approval always generates a new opaque grant ID.
    public mutating func retireGrant(grantID: UUID, now: UInt64, acknowledgeReceiptLoss: Bool) throws {
        try advance(now)
        guard let grant = grants[grantID], grant.revoked || now >= grant.expiresAt else {
            throw CodexDeviceMessagingError.unauthorized
        }
        guard acknowledgeReceiptLoss || !records.keys.contains(where: { $0.grantID == grantID }) else {
            throw CodexDeviceMessagingError.invalidTransition
        }
        records = records.filter { $0.key.grantID != grantID }
        grants.removeValue(forKey: grantID)
    }

    /// Rechecks scope/membership supplied by verified CURRENT context even for
    /// duplicate receipts. Never evict dedupe IDs to admit new work: a full
    /// journal fails closed until explicitly retired with its grants.
    public mutating func receive(_ envelope: CodexDeviceMessageEnvelope,
                                 context: NetworkDeviceAuthorization.Context, now: UInt64) throws -> Receipt {
        try advance(now)
        var grant = try authorized(envelope.grantID, context: context, now: now)
        let size = envelope.text.utf8.count
        guard size > 0, size <= Self.maximumTextBytes,
              try JSONEncoder().encode(envelope).count <= Self.maximumFrameBytes else {
            throw CodexDeviceMessagingError.invalidEnvelope
        }
        let key = Key(grantID: envelope.grantID, messageID: envelope.messageID)
        let digest = Data(SHA256.hash(data: Data(envelope.text.utf8)))
        if let old = records[key] {
            guard old.digest == digest else { throw CodexDeviceMessagingError.duplicateConflict }
            return old.receipt
        }
        let grantRecords = records.filter { $0.key.grantID == envelope.grantID }
        let grantQueued = grantRecords.values.filter { $0.receipt == .received || $0.receipt == .dispatching }
        guard records.count < Self.maximumReceipts,
              queuedMessageCount < Self.maximumQueuedMessages,
              queuedByteCount + size <= Self.maximumQueuedBytes,
              grantRecords.count < Self.maximumGrantReceipts,
              grantQueued.count < Self.maximumGrantQueuedMessages,
              grantQueued.reduce(0, { $0 + $1.byteCount }) + size <= Self.maximumGrantQueuedBytes
        else { throw CodexDeviceMessagingError.capacity }
        grant.tokens = min(5, grant.tokens + Double(now - grant.lastRefill) / 6_000_000_000)
        grant.lastRefill = now
        guard grant.tokens >= 1 else { throw CodexDeviceMessagingError.rateLimited }
        grant.tokens -= 1
        grants[envelope.grantID] = grant
        records[key] = Record(digest: digest, byteCount: size, text: envelope.text, receipt: .received)
        return .received
    }

    /// Durable reservation only, not external process-start authorization.
    /// The adapter must revalidate and fence actual start against revocation;
    /// immediacy alone is insufficient. Never wait for process completion under
    /// NetworkPolicyCenter's lock. No external side effect occurs here.
    public mutating func beginDispatch(_ envelope: CodexDeviceMessageEnvelope,
                                       context: NetworkDeviceAuthorization.Context, now: UInt64) throws -> Dispatch {
        try advance(now)
        let grant = try authorized(envelope.grantID, context: context, now: now)
        let key = Key(grantID: envelope.grantID, messageID: envelope.messageID)
        guard let record = records[key], record.receipt == .received, let text = record.text,
              record.digest == Data(SHA256.hash(data: Data(envelope.text.utf8))) else {
            throw CodexDeviceMessagingError.invalidTransition
        }
        records[key]?.receipt = .dispatching
        records[key]?.text = nil
        return Dispatch(messageID: envelope.messageID, localTaskID: grant.taskID, peerText: text, sender: grant.scope.sender)
    }

    public mutating func completeDispatch(grantID: UUID, messageID: UUID, result: DispatchResult) throws {
        let key = Key(grantID: grantID, messageID: messageID)
        guard records[key]?.receipt == .dispatching else { throw CodexDeviceMessagingError.invalidTransition }
        switch result {
        case .queued: records[key]?.receipt = .codexQueued
        case .definitelyNotQueued: records[key]?.receipt = .cancelled
        case .uncertain: records[key]?.receipt = .uncertain
        }
    }

    /// Minted only from an authenticated received record. Native preparation
    /// uses these stored bytes, never a caller-supplied replacement envelope.
    struct NativeSnapshot {
        let grantID: UUID, messageID: UUID, localTaskID: UUID
        let digest: Data
        let text: String
        let sender: PublicUserIdentity
        fileprivate init(grantID: UUID, messageID: UUID, grant: Grant, record: Record, text: String) {
            self.grantID = grantID; self.messageID = messageID
            localTaskID = grant.taskID; digest = record.digest
            self.text = text; sender = grant.scope.sender
        }
    }
    mutating func nativeSnapshot(grantID: UUID, messageID: UUID,
                                context: NetworkDeviceAuthorization.Context, now: UInt64) throws -> NativeSnapshot {
        try advance(now)
        let grant = try authorized(grantID, context: context, now: now)
        guard let record = records[Key(grantID: grantID, messageID: messageID)],
              record.receipt == .received, let text = record.text else {
            throw CodexDeviceMessagingError.invalidTransition
        }
        return NativeSnapshot(grantID: grantID, messageID: messageID, grant: grant, record: record, text: text)
    }
    mutating func reserveNative(_ snapshot: NativeSnapshot, attempt: UUID,
                                context: NetworkDeviceAuthorization.Context, now: UInt64) throws {
        try validateNative(snapshot, attempt: nil, context: context, now: now)
        let key = Key(grantID: snapshot.grantID, messageID: snapshot.messageID)
        records[key]?.receipt = .dispatching
        records[key]?.nativeAttempt = attempt
        records[key]?.text = nil
    }
    /// Reuse the SAME currently-held authorization context after persistence.
    /// No policy-lock acquisition, hashing, or caller callbacks occur here.
    mutating func validateNative(_ snapshot: NativeSnapshot, attempt: UUID?,
                                 context: NetworkDeviceAuthorization.Context, now: UInt64) throws {
        try advance(now)
        let grant = try authorized(snapshot.grantID, context: context, now: now)
        guard let record = records[Key(grantID: snapshot.grantID, messageID: snapshot.messageID)],
              record.digest == snapshot.digest, grant.taskID == snapshot.localTaskID,
              record.receipt == (attempt == nil ? .received : .dispatching),
              attempt == nil || record.nativeAttempt == attempt else {
            throw CodexDeviceMessagingError.invalidTransition
        }
    }
    /// A late completion cannot overwrite revoked uncertainty or recreate a
    /// retired record. The persisted attempt also prevents ticket reuse.
    mutating func finishNative(_ snapshot: NativeSnapshot, attempt: UUID, result: DispatchResult) -> Bool {
        let key = Key(grantID: snapshot.grantID, messageID: snapshot.messageID)
        guard let record = records[key], record.receipt == .dispatching,
              record.nativeAttempt == attempt, record.digest == snapshot.digest else { return false }
        switch result {
        case .queued: records[key]?.receipt = .codexQueued
        case .definitelyNotQueued: records[key]?.receipt = .cancelled
        case .uncertain: records[key]?.receipt = .uncertain
        }
        return true
    }

    /// Only an adapter's independently observed receipt in the selected task
    /// may call this. CLI exit success is queued, never proof of read/delivery.
    public mutating func confirmDelivery(grantID: UUID, messageID: UUID) throws {
        let key = Key(grantID: grantID, messageID: messageID)
        guard records[key]?.receipt == .codexQueued || records[key]?.receipt == .uncertain else {
            throw CodexDeviceMessagingError.invalidTransition
        }
        records[key]?.receipt = .delivered
    }

    private func authorized(_ id: UUID, context: NetworkDeviceAuthorization.Context, now: UInt64) throws -> Grant {
        guard isEnabled else { throw CodexDeviceMessagingError.disabled }
        guard let grant = grants[id], !grant.revoked, grant.scope == CodexDeviceMessagingScope(context) else {
            throw CodexDeviceMessagingError.unauthorized
        }
        guard now < grant.expiresAt, now < context.sessionValidUntilNanos else { throw CodexDeviceMessagingError.expired }
        return grant
    }

    private mutating func advance(_ now: UInt64) throws {
        if let lastNow, now < lastNow {
            setEnabled(false)
            throw CodexDeviceMessagingError.clockRegressed
        }
        lastNow = now
    }
}
