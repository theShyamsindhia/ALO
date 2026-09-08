#if os(macOS)
import Foundation
import Network
import ALOIdentity

/// Receiver-local explicit executable approval. Never constructed from peer
/// data or restored from a path without its actual saved approval-time digest.
public struct CodexLocalExecutableApproval {
    fileprivate let executable: MacCodexQueueAdapter.ApprovedExecutable
    public var digest: Data { executable.approvedDigest }
    public var canonicalURL: URL { executable.url }
    public init(locallyApprovedURL: URL, expectedDigest: Data? = nil) throws {
        executable = try .init(locallyApprovedURL: locallyApprovedURL, expectedDigest: expectedDigest)
    }
}

/// Public facade owns verified outer-transport to inner-session translation.
/// It never accepts Invocation, peer task IDs, replacement bodies, or outcomes.
public final class MacDeviceMessageReceiver: @unchecked Sendable {
    public struct Connection: Hashable, Sendable {
        fileprivate let owner: UUID
        fileprivate let transport: UUID
    }
    public enum DispatchAdmission: Equatable, Sendable {
        case scheduled, alreadyScheduled, capacity, stopped, invalidConnection
    }
    public enum ReviewReason: Sendable { case capacity, disconnected, unavailable }
    public enum Event {
        case authenticated(Connection, NetworkDeviceAuthorization.Context)
        case received(Connection, grantID: UUID, messageID: UUID)
        case completion(Connection, grantID: UUID, messageID: UUID, recorded: Bool)
        /// Not a terminal receipt: a post-start persistence error may mean the
        /// outcome is uncertain. Query authoritative state; never auto-retry.
        case dispatchFailed(Connection, grantID: UUID, messageID: UUID)
        /// Local review information is independent of a closed peer connection.
        /// Its receipt is immutable evidence, not permission to retry.
        case reviewNeeded(grantID: UUID, messageID: UUID, receipt: CodexDeviceMessagingPolicy.Receipt, ReviewReason)
        case closed(Connection)
    }
    private let issuer = UUID()
    private let service: CodexDeviceMessageService
    private let runner: MacCodexQueueAdapter.Runner
    private let queue: DispatchQueue
    private let workers: OperationQueue
    private let admission = ReceiverDispatchAdmission()
    private let event: (Event) -> Void
    private var listener: NetworkDeviceTextListener?
    private var sessions: [UUID: UUID] = [:]
    private var stopped = false
    private var dispatchDeliveryForTesting: ((@escaping () -> Void) -> Void)?

    public init(identity: InstallationIdentity, service: CodexDeviceMessageService,
                pins: PeerPinStore, executable: CodexLocalExecutableApproval,
                port: NWEndpoint.Port = .any, queue target: DispatchQueue,
                event: @escaping (Event) -> Void) throws {
        self.service = service; runner = .init(executable: executable.executable)
        queue = networkDeviceExecutor(target: target); self.event = event
        workers = OperationQueue(); workers.name = "alo.device-native-workers"
        workers.maxConcurrentOperationCount = 4; workers.qualityOfService = .utility
        listener = try NetworkDeviceTextListener(identity: identity, service: service, pins: pins,
            port: port, queue: queue) { [weak self] transport, value in
                self?.handle(transport, value)
            }
    }
    deinit {
        admission.close(service: service); workers.cancelAllOperations()
        listener?.stop()
    }
    /// Caller must obtain receiver-local consent. Starting the listener does
    /// not enable this default-disabled service or grant any task permission.
    public func setEnabled(_ enabled: Bool) throws {
        try admission.setEnabled(enabled, service: service)
    }
    public func start(ready: @escaping (NWEndpoint.Port) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.admission.isOpen else { return }
            self.listener?.start { [weak self] port in
                guard let self, !self.stopped, self.admission.isOpen else { return }; ready(port)
            }
        }
    }
    public func approve(connection: Connection, receiverChosenTask: UUID, lifetime: TimeInterval) {
        guard connection.owner == issuer, lifetime.isFinite, lifetime > 0, lifetime <= 86_400 else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped, self.admission.isOpen, self.sessions[connection.transport] != nil else { return }
            let duration = UInt64(lifetime * 1_000_000_000)
            let (expiry, overflow) = DeviceMessagingClock.nowNanos().addingReportingOverflow(duration)
            guard !overflow else { return }
            self.listener?.approve(connection: connection.transport, localTaskID: receiverChosenTask, expiresAtNanos: expiry)
        }
    }
    public func localGrants() -> [CodexDeviceMessagingPolicy.LocalGrant] { service.localGrants() }
    public func localReceipt(grantID: UUID, messageID: UUID) -> CodexDeviceMessagingPolicy.Receipt? {
        service.localReceipt(grantID: grantID, messageID: messageID)
    }
    public func revoke(grant: UUID) throws { try service.revoke(grant: grant) }
    public func retire(grant: UUID, acknowledgeReceiptLoss: Bool) throws {
        try service.retireGrant(grant, acknowledgeReceiptLoss: acknowledgeReceiptLoss)
    }
    public func stop() {
        admission.close(service: service); workers.cancelAllOperations()
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true; self.sessions.removeAll(); self.listener?.stop()
        }
    }

    /// Explicit local re-attempt can only target an existing received record;
    /// the fence rejects dispatching/uncertain/terminal state. No automatic retry.
    @discardableResult
    public func dispatchStored(connection: Connection, grantID: UUID, messageID: UUID) -> DispatchAdmission {
        guard connection.owner == issuer else { return .invalidConnection }
        let acquired = admission.acquire(.init(grant: grantID, message: messageID))
        guard let permit = acquired.permit else { return acquired.outcome }
        let process = { [weak self] in
            guard let self, !self.stopped, self.admission.isOpen else { return }
            guard let session = self.sessions[connection.transport] else {
                self.reviewNeeded(grantID, messageID, reason: .disconnected); return
            }
            let service = self.service, runner = self.runner, callbackQueue = self.queue
            self.workers.addOperation { [weak self] in
                defer { permit.release() }
                guard permit.isOpen else { return }
                let recorded: Bool
                do {
                    let native = try service.prepareNativeDispatch(grantID: grantID, messageID: messageID,
                        connection: session, runner: runner)
                    let started = try service.startPrepared(native)
                    if case .recorded = try service.finishStarted(started) { recorded = true }
                    else { recorded = false }
                } catch {
                    callbackQueue.async { [weak self] in
                        guard let self, !self.stopped, self.admission.isOpen else { return }
                        self.listener?.publishCurrentReceipt(grantID: grantID, messageID: messageID)
                        guard self.sessions[connection.transport] == session else {
                            self.reviewNeeded(grantID, messageID, reason: .unavailable); return
                        }
                        self.event(.dispatchFailed(connection, grantID: grantID, messageID: messageID))
                    }
                    return
                }
                callbackQueue.async { [weak self] in
                    guard let self, !self.stopped, self.admission.isOpen else { return }
                    self.listener?.publishCurrentReceipt(grantID: grantID, messageID: messageID)
                    guard self.sessions[connection.transport] == session else { return }
                    self.event(.completion(connection, grantID: grantID, messageID: messageID, recorded: recorded))
                }
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            if let delivery = self.dispatchDeliveryForTesting {
                delivery { [weak self] in self?.queue.async { process() } }
            } else { process() }
        }
        return .scheduled
    }
    private func reviewNeeded(_ grantID: UUID, _ messageID: UUID, reason: ReviewReason) {
        guard !stopped, admission.isOpen,
              let receipt = service.localReceipt(grantID: grantID, messageID: messageID) else { return }
        event(.reviewNeeded(grantID: grantID, messageID: messageID, receipt: receipt, reason))
    }
    /// Holds the real queued admission hop, never the native-start fence.
    func setDispatchDeliveryForTesting(_ delivery: @escaping (@escaping () -> Void) -> Void) {
        queue.sync { dispatchDeliveryForTesting = delivery }
    }
    private func handle(_ transport: UUID, _ value: NetworkDeviceTextTransport.Event) {
        guard !stopped, admission.isOpen else { return }
        let connection = Connection(owner: issuer, transport: transport)
        switch value {
        case .authenticated(let session, let context):
            sessions[transport] = session; event(.authenticated(connection, context))
        case .messageAccepted(let session, let message):
            guard sessions[transport] == session else { return }
            event(.received(connection, grantID: message.grantID, messageID: message.messageID))
            let outcome = dispatchStored(connection: connection, grantID: message.grantID, messageID: message.messageID)
            if outcome == .capacity { reviewNeeded(message.grantID, message.messageID, reason: .capacity) }
        case .closed:
            sessions.removeValue(forKey: transport); event(.closed(connection))
        default: break
        }
    }
}

final class ReceiverDispatchAdmission {
    struct Key: Hashable { let grant: UUID; let message: UUID }
    private let lock = NSLock()
    private var stopped = false
    private var active: [Key: UUID] = [:]
    var countForTesting: Int { lock.lock(); defer { lock.unlock() }; return active.count }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    func acquire(_ key: Key) -> (outcome: MacDeviceMessageReceiver.DispatchAdmission, permit: ReceiverDispatchPermit?) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return (.stopped, nil) }
        guard active[key] == nil else { return (.alreadyScheduled, nil) }
        guard active.count < 32 else { return (.capacity, nil) }
        let token = UUID(); active[key] = token
        return (.scheduled, ReceiverDispatchPermit(owner: self, key: key, token: token))
    }
    func release(_ key: Key, token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if active[key] == token { active.removeValue(forKey: key) }
    }
    /// Same lifecycle lock covers check and service mutation. A concurrent
    /// terminal close cannot be followed by a previously checked enable.
    func setEnabled(_ enabled: Bool, service: CodexDeviceMessageService) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw CodexDeviceMessagingError.disabled }
        try service.setEnabled(enabled)
    }
    func close(service: CodexDeviceMessageService) {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        try? service.setEnabled(false)
    }
}
final class ReceiverDispatchPermit {
    private let owner: ReceiverDispatchAdmission
    private let key: ReceiverDispatchAdmission.Key
    private let token: UUID
    init(owner: ReceiverDispatchAdmission, key: ReceiverDispatchAdmission.Key, token: UUID) {
        self.owner = owner; self.key = key; self.token = token
    }
    var isOpen: Bool { owner.isOpen }
    func release() { owner.release(key, token: token) }
    deinit { release() }
}
#endif
