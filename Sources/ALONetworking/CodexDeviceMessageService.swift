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
    let localTLSHashForBinding: Data
    #if os(macOS)
    private let nativeIssuer = UUID()
    private let nativeWorkers = DeviceMessageNativeWorkerPool()
    #endif

    public convenience init(policy: NetworkPolicyCenter, localDevice: DeviceIdentityBinding,
                            actualLocalTLSHash: Data, journal: CodexDeviceMessageJournal) throws {
        try self.init(policy: policy, localDevice: localDevice, actualLocalTLSHash: actualLocalTLSHash,
                      journal: journal, nowNanos: { DeviceMessagingClock.nowNanos() })
    }
    init(policy: NetworkPolicyCenter, localDevice: DeviceIdentityBinding,
                actualLocalTLSHash: Data, journal: CodexDeviceMessageJournal,
                nowNanos: @escaping @Sendable () -> UInt64,
                policyChangeDelivery: ((@escaping () -> Void) -> Void)? = nil) throws {
        self.policy = policy; self.journal = journal
        localTLSHashForBinding = actualLocalTLSHash
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
    /// Receiver-local current stored receipt, still readable after disable/revocation.
    /// Revocation changes received to cancelled and dispatching to uncertain;
    /// the returned value is a snapshot, not a stable execution permission.
    /// This is not peer authorization and cannot start or mutate a dispatch.
    public func localReceipt(grantID: UUID, messageID: UUID) -> CodexDeviceMessagingPolicy.Receipt? {
        lock.lock(); defer { lock.unlock() }
        return state.receipt(grantID: grantID, messageID: messageID)
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
        guard !faulted else { throw CodexDeviceMessagingError.disabled }
        try commit { $0.revoke(grantID: grant) }
        invalidateConnections()
    }
    public func retireGrant(_ grant: UUID, acknowledgeReceiptLoss: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard !faulted else { throw CodexDeviceMessagingError.disabled }
        let now = nowNanos()
        try commit { try $0.retireGrant(grantID: grant, now: now, acknowledgeReceiptLoss: acknowledgeReceiptLoss) }
        queryBudgets.removeValue(forKey: grant)
    }
    var journalWritesForTesting: Int {
        lock.lock(); defer { lock.unlock() }; return journal.committedWrites
    }
    var queryBudgetCountForTesting: Int { lock.lock(); defer { lock.unlock() }; return queryBudgets.count }
    public func receive(_ envelope: CodexDeviceMessageEnvelope, connection: UUID) throws -> CodexDeviceMessagingPolicy.Receipt {
        try current(connection, queryGrant: envelope.grantID) { context, now in
            try commit { try $0.receive(envelope, context: context, now: now) }
        }
    }
    /// Wire queries share the stable per-grant replay budget across reconnects.
    func queryReceipt(grantID: UUID, messageID: UUID, connection: UUID) throws -> CodexDeviceMessagingPolicy.Receipt {
        try current(connection, queryGrant: grantID) { context, now in
            try commit { try $0.currentReceipt(grantID: grantID, messageID: messageID, context: context, now: now) }
        }
    }
    /// Local publication uses the same authorization fence, but is not a new
    /// remote query and cannot charge the peer for an unsolicited local change.
    func currentReceipt(grantID: UUID, messageID: UUID, connection: UUID) throws -> CodexDeviceMessagingPolicy.Receipt {
        try current(connection) { context, now in
            try commit { try $0.currentReceipt(grantID: grantID, messageID: messageID, context: context, now: now) }
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
        guard !faulted else { throw CodexDeviceMessagingError.disabled }
        try commit { try $0.completeDispatch(grantID: envelope.grantID, messageID: envelope.messageID, result: result) }
    }
    public func confirmDelivery(_ envelope: CodexDeviceMessageEnvelope) throws {
        lock.lock(); defer { lock.unlock() }
        guard !faulted else { throw CodexDeviceMessagingError.disabled }
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

#if os(macOS)
/// Separate permit lock avoids service-lock reentry during object abandonment.
/// Counts all preparation and started work, including filesystem preflight.
fileprivate final class DeviceMessageNativeWorkerPool {
    private let lock = NSLock()
    private var active: Set<UUID> = []
    func acquire() throws -> DeviceMessageNativePermit {
        lock.lock(); defer { lock.unlock() }
        guard active.count < 32 else { throw CodexDeviceMessagingError.capacity }
        let id = UUID(); active.insert(id)
        return DeviceMessageNativePermit(pool: self, id: id)
    }
    func release(_ id: UUID) { lock.lock(); defer { lock.unlock() }; active.remove(id) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return active.count }
}
fileprivate final class DeviceMessageNativePermit {
    private let pool: DeviceMessageNativeWorkerPool
    private let id: UUID
    init(pool: DeviceMessageNativeWorkerPool, id: UUID) { self.pool = pool; self.id = id }
    func release() { pool.release(id) }
    deinit { release() }
}

extension CodexDeviceMessageService {
    fileprivate struct NativeCandidate {
        let issuer: UUID
        let connection: UUID
        let context: NetworkDeviceAuthorization.Context
        let snapshot: CodexDeviceMessagingPolicy.NativeSnapshot
    }
    fileprivate struct NativePayload {
        let candidate: NativeCandidate
        let prepared: MacCodexQueueAdapter.Prepared
        let permit: DeviceMessageNativePermit
    }
    /// Opaque binding: callers cannot substitute a candidate or invocation.
    final class NativePreparation: @unchecked Sendable {
        fileprivate let issuer: UUID
        private let lock = NSLock()
        private var payload: NativePayload?
        fileprivate init(_ payload: NativePayload) {
            issuer = payload.candidate.issuer; self.payload = payload
        }
        fileprivate func consume() throws -> NativePayload {
            lock.lock(); defer { lock.unlock() }
            guard let payload else { throw CodexDeviceMessagingError.invalidTransition }
            self.payload = nil; return payload
        }
        func abandon() { lock.lock(); defer { lock.unlock() }; payload = nil }
    }
    final class StartedDispatch: @unchecked Sendable {
        fileprivate let candidate: NativeCandidate
        fileprivate let attempt: UUID
        fileprivate let started: MacCodexQueueAdapter.Started
        fileprivate let permit: DeviceMessageNativePermit
        fileprivate init(candidate: NativeCandidate, attempt: UUID,
                         started: MacCodexQueueAdapter.Started, permit: DeviceMessageNativePermit) {
            self.candidate = candidate; self.attempt = attempt
            self.started = started; self.permit = permit
        }
    }
    enum NativeCompletion { case recorded(MacCodexQueueAdapter.Result), superseded }

    /// This internal local API uses IDs only. Snapshot content and destination
    /// come solely from the immutable authenticated received record.
    func prepareNativeDispatch(grantID: UUID, messageID: UUID, connection: UUID,
                               runner: MacCodexQueueAdapter.Runner) throws -> NativePreparation {
        let permit = try nativeWorkers.acquire()
        let candidate = try current(connection) { context, now in
            let snapshot = try commit { try $0.nativeSnapshot(grantID: grantID, messageID: messageID, context: context, now: now) }
            return NativeCandidate(issuer: nativeIssuer, connection: connection, context: context, snapshot: snapshot)
        }
        // Hashing, attribution encoding, filesystem access and pipe setup are
        // outside both service serialization and the stable membership fence.
        let snapshot = candidate.snapshot
        let invocation = try MacCodexQueueAdapter.Invocation(localTaskID: snapshot.localTaskID,
            messageID: snapshot.messageID, sender: snapshot.sender, text: snapshot.text)
        let prepared = try runner.prepare(invocation)
        return NativePreparation(NativePayload(candidate: candidate, prepared: prepared, permit: permit))
    }

    func startPrepared(_ native: NativePreparation) throws -> StartedDispatch {
        guard native.issuer == nativeIssuer else { throw CodexDeviceMessagingError.unauthorized }
        let payload = try native.consume()
        let candidate = payload.candidate
        return try current(candidate.connection) { context, now in
            let attempt = UUID()
            try commit { try $0.reserveNative(candidate.snapshot, attempt: attempt, context: context, now: now) }
            do {
                // The policy lock remains held across durable intent and this
                // fresh clock read. Never recursively reacquire current().
                try commit { try $0.validateNative(candidate.snapshot, attempt: attempt, context: context, now: nowNanos()) }
            } catch {
                if !faulted {
                    _ = try commit { $0.finishNative(candidate.snapshot, attempt: attempt, result: .definitelyNotQueued) }
                }
                throw error
            }
            let started: MacCodexQueueAdapter.Started
            do { started = try payload.prepared.start() }
            catch {
                _ = try commit { $0.finishNative(candidate.snapshot, attempt: attempt, result: .definitelyNotQueued) }
                throw error
            }
            return StartedDispatch(candidate: candidate, attempt: attempt, started: started, permit: payload.permit)
        }
    }

    /// Wait immediately after start, OUTSIDE service/policy locks. Completion is
    /// derived from the bound native handle, never a caller-asserted outcome.
    func finishStarted(_ native: StartedDispatch) throws -> NativeCompletion {
        try finishStartedImpl(native, afterRunningCheck: nil)
    }
    /// Test observation only. Called outside service/policy locks; observers
    /// must not reenter the adapter's wait or mutate the owned child.
    func finishStartedForTesting(_ native: StartedDispatch,
                                 afterRunningCheck: @escaping (Process) -> Void) throws -> NativeCompletion {
        try finishStartedImpl(native, afterRunningCheck: afterRunningCheck)
    }
    private func finishStartedImpl(_ native: StartedDispatch,
                                   afterRunningCheck: ((Process) -> Void)?) throws -> NativeCompletion {
        guard native.candidate.issuer == nativeIssuer else { throw CodexDeviceMessagingError.unauthorized }
        let result = native.started.waitForOutcome(afterRunningCheckForTesting: afterRunningCheck)
        defer { native.permit.release() }
        lock.lock(); defer { lock.unlock() }
        guard !faulted else { throw CodexDeviceMessagingError.disabled }
        let outcome: CodexDeviceMessagingPolicy.DispatchResult
        switch result.outcome {
        case .codexQueued: outcome = .queued
        case .definitelyNotQueued: outcome = .definitelyNotQueued
        case .uncertain: outcome = .uncertain
        }
        return try policy.withStablePolicy {
            let manifest = try policy.snapshot()
            let context = native.candidate.context
            guard manifest.id == context.networkID, manifest.generation == context.generation,
                  manifest.revision == context.policyRevision else {
                // Publication may precede observer delivery. Do not call this
                // late completion queued merely because the observer is held.
                try commit { $0.revoke(grantID: native.candidate.snapshot.grantID) }
                return .superseded
            }
            let recorded = try commit { $0.finishNative(native.candidate.snapshot, attempt: native.attempt, result: outcome) }
            return recorded ? .recorded(result) : .superseded
        }
    }
    var nativeWorkerCountForTesting: Int { nativeWorkers.count }
}
#endif
