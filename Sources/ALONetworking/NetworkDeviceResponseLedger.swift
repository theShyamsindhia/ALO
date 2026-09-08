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
        if pending[key] != nil { return false }
        guard pending.count < 32 else { throw CodexDeviceMessagingError.capacity }
        pending[key] = Observation(digest: nil); return true
    }
    /// Returns false for an identical intermediate update. Terminal observations
    /// are released; subsequent evidence requires a new explicit status query.
    mutating func resolve(_ key: Key, receipt: CodexDeviceMessagingPolicy.Receipt) throws -> Bool {
        guard var observation = pending[key] else { throw CodexDeviceMessagingError.unauthorized }
        if observation.receipt == receipt { return false }
        if observation.receipt == .dispatching, receipt == .received {
            throw CodexDeviceMessagingError.unauthorized
        }
        if receipt == .received || receipt == .dispatching {
            observation.receipt = receipt; pending[key] = observation
        } else { pending.removeValue(forKey: key) }
        return true
    }
    mutating func reject(_ key: Key, reason: String?) throws {
        guard reason == "rateLimited" || reason == "capacity" else { throw CodexDeviceMessagingError.unauthorized }
        guard let observation = pending[key], observation.receipt == nil else {
            throw CodexDeviceMessagingError.unauthorized
        }
        pending.removeValue(forKey: key)
    }
    mutating func receivedGrant(_ id: UUID) throws {
        guard grants.count < CodexDeviceMessagingPolicy.maximumGrants,
              grants.insert(id).inserted else { throw CodexDeviceMessagingError.unauthorized }
    }
}
