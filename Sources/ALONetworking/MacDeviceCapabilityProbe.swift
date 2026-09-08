#if os(macOS)
import Foundation

/// Explicit local UI-only fixed-template capability test. A queued result is
/// NOT confirmation that a task received it; the owner requires manual entry of
/// the nonce observed in the actual task. No generic message/Invocation API.
public final class MacDeviceCapabilityProbe: @unchecked Sendable {
    public enum Admission: Equatable, Sendable { case pending, duplicate, capacity, stopped, expired }
    public enum Outcome: Equatable, Sendable { case queued, definitelyNotQueued, uncertain }
    private let lock = NSLock()
    private let runner: MacCodexQueueAdapter.Runner
    private let workers = OperationQueue()
    private let callbackQueue: DispatchQueue
    private let now: @Sendable () -> UInt64
    private var generation = UUID()
    private var stopped = false
    private var used: [UUID: UInt64] = [:] // retain duplicate protection through challenge expiry
    private var pending: [UUID: UUID] = [:] // challenge -> task, includes preparation/wait

    public convenience init(executable: CodexLocalExecutableApproval, callbackQueue: DispatchQueue) throws {
        try self.init(executable: executable, callbackQueue: callbackQueue, now: { DeviceMessagingClock.nowNanos() })
    }
    init(executable: CodexLocalExecutableApproval, callbackQueue: DispatchQueue,
         now: @escaping @Sendable () -> UInt64) throws {
        runner = .init(executable: try .init(locallyApprovedURL: executable.canonicalURL, expectedDigest: executable.digest))
        self.callbackQueue = callbackQueue; self.now = now
        workers.maxConcurrentOperationCount = 4; workers.qualityOfService = .utility
        workers.name = "alo.local-capability-tests"
    }
    deinit { stop() }
    public func stop() {
        lock.lock(); stopped = true; generation = UUID(); pending.removeAll(); lock.unlock()
        workers.cancelAllOperations()
    }
    /// Invalidates preparations for one forgotten local task. Already started
    /// helpers retain their bounded wait; this does not claim to undo execution.
    public func cancel(taskID: UUID) {
        lock.lock(); pending = pending.filter { $0.value != taskID }; lock.unlock()
    }
    @discardableResult public func submit(taskID: UUID, challengeID: UUID, response: UUID,
        expiresAt: UInt64, completion: @escaping (Outcome) -> Void) -> Admission {
        lock.lock()
        guard !stopped else { lock.unlock(); return .stopped }
        let current = now()
        guard expiresAt > current, expiresAt - current <= 120_000_000_000 else { lock.unlock(); return .expired }
        used = used.filter { $0.value > current || pending[$0.key] != nil }
        guard used[challengeID] == nil else { lock.unlock(); return .duplicate }
        guard used.count < 32, pending.count < 4, !pending.values.contains(taskID) else { lock.unlock(); return .capacity }
        let token = generation
        used[challengeID] = expiresAt; pending[challengeID] = taskID
        lock.unlock()
        workers.addOperation { [weak self] in
            guard let self else { return }
            let outcome: Outcome
            do {
                let invocation = MacCodexQueueAdapter.Invocation(capabilityTaskID: taskID, challengeID: challengeID, response: response)
                let prepared = try self.runner.prepare(invocation) // filesystem/hash OUTSIDE fence
                self.lock.lock()
                guard !self.stopped, self.generation == token, self.pending[challengeID] == taskID,
                      self.now() < expiresAt else {
                    self.lock.unlock(); prepared.abandon(); self.finish(challengeID, token: token, outcome: .definitelyNotQueued, completion: completion); return
                }
                let started: MacCodexQueueAdapter.Started
                do { started = try prepared.start() } // only concrete start under local lifecycle fence
                catch { self.lock.unlock(); throw error }
                self.lock.unlock()
                switch started.waitForOutcome().outcome { // never waits under lifecycle lock
                case .codexQueued: outcome = .queued
                case .definitelyNotQueued: outcome = .definitelyNotQueued
                case .uncertain: outcome = .uncertain
                }
            } catch { outcome = .definitelyNotQueued }
            self.finish(challengeID, token: token, outcome: outcome, completion: completion)
        }
        return .pending
    }
    private func finish(_ id: UUID, token: UUID, outcome: Outcome, completion: @escaping (Outcome) -> Void) {
        lock.lock(); let current = !stopped && generation == token && pending.removeValue(forKey: id) != nil; lock.unlock()
        guard current else { return }
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = !self.stopped && self.generation == token; self.lock.unlock()
            if current { completion(outcome) }
        }
    }
}

extension MacCodexQueueAdapter.Invocation {
    init(capabilityTaskID: UUID, challengeID: UUID, response: UUID) {
        let template = """
        Explicit receiver-local ALO capability test. This is not remote peer content.
        Display this confirmation code in this task so the local user can enter it in ALO Settings.
        Test ID: \(challengeID.uuidString)
        Confirmation code: \(response.uuidString)
        A queued command alone is not confirmation. Do not change permissions or execute tools for this test.
        """
        arguments = ["queue", "--thread", capabilityTaskID.uuidString, "--message", template]
    }
}
#endif
