import Foundation

enum NetworkDeviceAdmissionLimits {
    static func acceptsConnection(total: Int, admitted: Int) -> Bool {
        total >= admitted && admitted >= 0 && admitted <= 16 && total < 24 && total - admitted < 8
    }
    static func acceptsTLS(known: Bool, unknownCount: Int) -> Bool {
        unknownCount >= 0 && (known || unknownCount < 4)
    }
}

/// Owner-queue-only bounded protocol bookkeeping. Digests retain no peer text.
struct NetworkDeviceResponseLedger {
    struct Key: Hashable { let grant: UUID; let message: UUID }
    private struct Observation {
        let digest: Data?
        var receipt: CodexDeviceMessagingPolicy.Receipt?
        var queryInFlight = false
        var subscriptionEnded = false
    }
    private var pending: [Key: Observation] = [:]
    private var grants = Set<UUID>()
    var pendingCount: Int { pending.count }
    /// False coalesces an identical in-flight send without a second frame.
    mutating func reserve(_ key: Key, digest: Data) throws -> Bool {
        if let old = pending[key] {
            guard old.digest == digest else { throw CodexDeviceMessagingError.duplicateConflict }
            return false
        }
        guard pending.count < 32 else { throw CodexDeviceMessagingError.capacity }
        pending[key] = Observation(digest: digest); return true
    }
    /// Explicit status observation never resends the original text.
    mutating func reserveQuery(_ key: Key) throws -> Bool {
        if var old = pending[key] {
            guard old.receipt != nil, !old.queryInFlight else { return false }
            old.queryInFlight = true; pending[key] = old; return true
        }
        guard pending.count < 32 else { throw CodexDeviceMessagingError.capacity }
        pending[key] = Observation(digest: nil, queryInFlight: true); return true
    }
    /// Returns false for an identical intermediate update. Terminal observations
    /// are released; subsequent evidence requires a new explicit status query.
    mutating func resolve(_ key: Key, receipt: CodexDeviceMessagingPolicy.Receipt) throws -> Bool {
        try resolve(key, receipt: receipt, queryResponse: false)
    }
    mutating func resolveQuery(_ key: Key, receipt: CodexDeviceMessagingPolicy.Receipt) throws -> Bool {
        try resolve(key, receipt: receipt, queryResponse: true)
    }
    private mutating func resolve(_ key: Key, receipt: CodexDeviceMessagingPolicy.Receipt, queryResponse: Bool) throws -> Bool {
        guard var observation = pending[key] else { throw CodexDeviceMessagingError.unauthorized }
        if queryResponse {
            guard observation.queryInFlight, !observation.subscriptionEnded else { throw CodexDeviceMessagingError.unauthorized }
            observation.queryInFlight = false
        } else {
            guard !observation.subscriptionEnded, observation.digest != nil || observation.receipt != nil else {
                throw CodexDeviceMessagingError.unauthorized
            }
        }
        if observation.receipt == .dispatching, receipt == .received {
            throw CodexDeviceMessagingError.unauthorized
        }
        if let old = observation.receipt, Self.isTerminal(old), old != receipt {
            guard (old == .codexQueued || old == .uncertain), receipt == .delivered else {
                throw CodexDeviceMessagingError.unauthorized
            }
        }
        let changed = observation.receipt != receipt
        observation.receipt = receipt
        store(observation, for: key)
        return changed
    }
    mutating func queryUnavailable(_ key: Key, reason: CodexDeviceMessagingError) throws {
        guard var observation = pending[key], observation.queryInFlight,
              reason == .statusUnknown || reason == .grantExpired || reason == .rateLimited else {
            throw CodexDeviceMessagingError.unauthorized
        }
        // Historical accepted evidence must not be replaced by "unknown".
        guard reason != .statusUnknown || observation.receipt == nil else {
            throw CodexDeviceMessagingError.unauthorized
        }
        observation.queryInFlight = false
        if reason == .grantExpired { observation.subscriptionEnded = true }
        store(observation, for: key)
    }
    mutating func endSubscription(_ key: Key) throws {
        guard var observation = pending[key], observation.receipt != nil,
              !observation.subscriptionEnded else { throw CodexDeviceMessagingError.unauthorized }
        observation.subscriptionEnded = true
        store(observation, for: key)
    }
    private mutating func store(_ observation: Observation, for key: Key) {
        if !observation.queryInFlight && (observation.subscriptionEnded || (observation.receipt.map(Self.isTerminal) ?? true)) {
            pending.removeValue(forKey: key)
        } else { pending[key] = observation }
    }
    private static func isTerminal(_ receipt: CodexDeviceMessagingPolicy.Receipt) -> Bool {
        receipt != .received && receipt != .dispatching
    }
    mutating func reject(_ key: Key, reason: String?) throws {
        guard reason == "rateLimited" || reason == "capacity" else { throw CodexDeviceMessagingError.unauthorized }
        guard let observation = pending[key], observation.receipt == nil,
              observation.digest != nil, !observation.queryInFlight else {
            throw CodexDeviceMessagingError.unauthorized
        }
        pending.removeValue(forKey: key)
    }
    mutating func receivedGrant(_ id: UUID) throws {
        guard grants.count < CodexDeviceMessagingPolicy.maximumGrants,
              grants.insert(id).inserted else { throw CodexDeviceMessagingError.unauthorized }
    }
}
