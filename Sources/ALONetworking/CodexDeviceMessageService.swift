import Foundation
import ALOIdentity
import ALOCore

/// Receiver-side service boundary shared by TLS transport and the future local
/// adapter. No task enumeration or execution. All consent methods are LOCAL APIs.
public final class CodexDeviceMessageService: @unchecked Sendable {
    private let policy: NetworkPolicyCenter
    private let authorization: NetworkDeviceAuthorization
    private let journal: CodexDeviceMessageJournal
    private let lock = NSLock()
    private let nowNanos: @Sendable () -> UInt64
    private var state: CodexDeviceMessagingPolicy
    private var sessions: [UUID: NetworkDeviceAuthorization.Session] = [:]
    private var sessionQueryContexts: [UUID: NetworkDeviceAuthorization.Context] = [:]
    private var connectionClosures: [UUID: () -> Void] = [:]
    private var observation: UUID?
    private var faulted = false

    public init(policy: NetworkPolicyCenter, localDevice: DeviceIdentityBinding,
                actualLocalTLSHash: Data, journal: CodexDeviceMessageJournal,
                nowNanos: @escaping @Sendable () -> UInt64 = DeviceMessagingClock.nowNanos,
                policyChangeDelivery: ((@escaping () -> Void) -> Void)? = nil) throws {
        self.policy = policy; self.journal = journal
        self.nowNanos = nowNanos
        authorization = try .init(policy: policy, localDevice: localDevice, actualLocalTLSHash: actualLocalTLSHash)
        if let saved = try journal.load() { state = try .init(restoring: saved) } else { state = .init() }
        // Every applied policy change invalidates sessions/grants conservatively.
        // This also prevents remove/re-add from reviving old queued authority.
        // Optional callback delivery control is for adversarial scheduling tests.
        // Synchronous revision checks, not this callback, enforce authority.
        observation = policy.observe { [weak self] in
            let invalidate: () -> Void = { [weak self] in self?.policyChanged() }
            if let policyChangeDelivery { policyChangeDelivery { invalidate() } }
            else { invalidate() }
        }
    }
    deinit { if let observation { policy.removeObserver(observation) } }

    public func setEnabled(_ enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard !faulted else { throw CodexDeviceMessagingError.disabled }
        try commit { $0.setEnabled(enabled) }
        if !enabled { invalidateConnections() }
    }
    public func challenge() throws -> NetworkDeviceAuthorization.Challenge {
        lock.lock(); defer { lock.unlock() }
        try requireEnabled()
        guard sessions.count < 16 else { throw CodexDeviceMessagingError.capacity }
        return try authorization.challenge(nowNanos: nowNanos())
    }
    public func cancelChallenge(_ challenge: NetworkDeviceAuthorization.Challenge) {
        authorization.cancel(challenge)
    }
    public func localGrants() -> [CodexDeviceMessagingPolicy.LocalGrant] {
        lock.lock(); defer { lock.unlock() }; return state.localGrants
    }
    private struct QueryBudget { var tokens = 5.0; var last: UInt64 }
    private var queryBudgets: [UUID: QueryBudget] = [:]
    /// Only transport invokes this with the SPKI extracted from its actual TLS
    /// connection. Returned identifiers are local handles, never wire authority.
    public func authenticate(_ claim: NetworkDeviceAuthorization.Claim, actualPeerTLSHash: Data) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        try requireEnabled()
        guard sessions.count < 16 else { throw CodexDeviceMessagingError.capacity }
        let session = try authorization.accept(claim, actualSenderTLSHash: actualPeerTLSHash, clock: nowNanos)
        let context = try authorization.withCurrentContext(session: session, clock: nowNanos) { context, _ in context }
        let id = UUID(); sessions[id] = session; sessionQueryContexts[id] = context; return id
    }
    public func disconnect(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; sessions.removeValue(forKey: id); connectionClosures.removeValue(forKey: id)
        sessionQueryContexts.removeValue(forKey: id)
    }
    func bindConnection(_ id: UUID, queue: DispatchQueue, close: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard sessions[id] != nil else { queue.async(execute: close); return }
        connectionClosures[id] = { queue.async(execute: close) }
    }
    public func peer(connection: UUID) throws -> NetworkDeviceAuthorization.Context {
        try current(connection) { context, _ in context }
    }
    public func approve(connection: UUID, localTaskID: UUID, expiresAt: UInt64) throws -> UUID {
        try current(connection) { context, now in
            try commit { try $0.grant(context: context, localTaskID: localTaskID, now: now, expiresAt: expiresAt) }
        }
    }
    public func revoke(grant: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try commit { $0.revoke(grantID: grant) }
        invalidateConnections()
    }
    public func retireGrant(_ grant: UUID, acknowledgeReceiptLoss: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let now = nowNanos()
        try commit { try $0.retireGrant(grantID: grant, now: now, acknowledgeReceiptLoss: acknowledgeReceiptLoss) }
        queryBudgets.removeValue(forKey: grant)
    }
    var journalWritesForTesting: Int {
        lock.lock(); defer { lock.unlock() }; return journal.committedWrites
    }
    public func receive(_ envelope: CodexDeviceMessageEnvelope, connection: UUID) throws -> CodexDeviceMessagingPolicy.Receipt {
        try current(connection, queryGrant: envelope.grantID) { context, now in
            try commit { try $0.receive(envelope, context: context, now: now) }
        }
    }
    /// Durable dispatch admission, linearized against locally applied policy
    /// and grant revocation. No external side effect happens here. The adapter
    /// must revalidate and fence actual process start against revocation under
    /// shared serialization. Immediacy alone is insufficient: this API provides
    /// only a durable reservation, not process-start authorization.
    /// Crash after this boundary restores uncertain, not a duplicate enqueue.
    public func takeForDispatch(_ envelope: CodexDeviceMessageEnvelope, connection: UUID) throws -> CodexDeviceMessagingPolicy.Dispatch {
        try current(connection) { context, now in
            try commit { try $0.beginDispatch(envelope, context: context, now: now) }
        }
    }
    public func complete(_ envelope: CodexDeviceMessageEnvelope, result: CodexDeviceMessagingPolicy.DispatchResult) throws {
        lock.lock(); defer { lock.unlock() }
        try commit { try $0.completeDispatch(grantID: envelope.grantID, messageID: envelope.messageID, result: result) }
    }
    public func confirmDelivery(_ envelope: CodexDeviceMessageEnvelope) throws {
        lock.lock(); defer { lock.unlock() }
        try commit { try $0.confirmDelivery(grantID: envelope.grantID, messageID: envelope.messageID) }
    }
    func checkpointForTesting() throws -> CodexDeviceMessagingPolicy.Checkpoint? {
        lock.lock(); defer { lock.unlock() }; return try journal.load()
    }
    private func requireEnabled() throws {
        guard !faulted, state.isEnabled else { throw CodexDeviceMessagingError.disabled }
    }
    private func current<T>(_ connection: UUID, queryGrant: UUID? = nil, _ body: (NetworkDeviceAuthorization.Context, UInt64) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try requireEnabled()
        guard let session = sessions[connection] else { throw CodexDeviceMessagingError.unauthorized }
        // Receiver-owned grant scope retains query limits across reconnects.
        // IDs cannot allocate buckets or charge another sender's grant: cheap
        // verified root/full-SPKI scope matching precedes bucket lookup.
        if let queryGrant {
            guard let context = sessionQueryContexts[connection],
                  state.matchesQueryScope(grantID: queryGrant, context: context) else {
                throw CodexDeviceMessagingError.unauthorized
            }
            let now = nowNanos()
            var budget = queryBudgets[queryGrant] ?? QueryBudget(last: now)
            guard now >= budget.last else {
                faulted = true; state.setEnabled(false); invalidateConnections()
                throw CodexDeviceMessagingError.clockRegressed
            }
            budget.tokens = min(5, budget.tokens + Double(now - budget.last) / 6_000_000_000)
            budget.last = now
            guard budget.tokens >= 1 else { throw CodexDeviceMessagingError.rateLimited }
            budget.tokens -= 1; queryBudgets[queryGrant] = budget
        }
        return try authorization.withCurrentContext(session: session, clock: nowNanos, body: body)
    }
    func holdSerializationForTesting(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }; body()
    }
    private func commit<T>(_ body: (inout CodexDeviceMessagingPolicy) throws -> T) throws -> T {
        var next = state
        let result: T
        do { result = try body(&next) }
        catch {
            if error as? CodexDeviceMessagingError == .clockRegressed {
                faulted = true; state.setEnabled(false); invalidateConnections()
            }
            throw error
        }
        do {
            // Duplicates still pass current authorization/digest checks and
            // update in-memory monotonic observation, but cause no disk writes.
            if next.checkpoint != state.checkpoint { try journal.save(next.checkpoint) }
        }
        catch { faulted = true; state.setEnabled(false); invalidateConnections(); throw error }
        state = next
        return result
    }
    private func policyChanged() {
        lock.lock(); defer { lock.unlock() }
        invalidateConnections()
        do {
            try commit { value in
                let enabled = value.isEnabled
                value.setEnabled(false); value.setEnabled(enabled)
            }
        } catch { /* commit has already failed closed */ }
    }
    private func invalidateConnections() {
        sessions.removeAll()
        sessionQueryContexts.removeAll()
        authorization.cancelAll()
        let callbacks = Array(connectionClosures.values); connectionClosures.removeAll()
        callbacks.forEach { $0() } // These only enqueue transport cancellation.
    }
}
