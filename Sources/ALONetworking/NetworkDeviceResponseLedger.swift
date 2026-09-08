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
    private var pending: [Key: Data] = [:]
    private var grants = Set<UUID>()
    var pendingCount: Int { pending.count }
    /// False coalesces an identical in-flight send without a second frame.
    mutating func reserve(_ key: Key, digest: Data) throws -> Bool {
        if let old = pending[key] {
            guard old == digest else { throw CodexDeviceMessagingError.duplicateConflict }
            return false
        }
        guard pending.count < 32 else { throw CodexDeviceMessagingError.capacity }
        pending[key] = digest; return true
    }
    mutating func resolve(_ key: Key) throws {
        guard pending.removeValue(forKey: key) != nil else { throw CodexDeviceMessagingError.unauthorized }
    }
    mutating func reject(_ key: Key, reason: String?) throws {
        guard reason == "rateLimited" || reason == "capacity" else { throw CodexDeviceMessagingError.unauthorized }
        try resolve(key)
    }
    mutating func receivedGrant(_ id: UUID) throws {
        guard grants.count < CodexDeviceMessagingPolicy.maximumGrants,
              grants.insert(id).inserted else { throw CodexDeviceMessagingError.unauthorized }
    }
}
