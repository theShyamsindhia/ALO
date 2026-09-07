/// Untrusted nearby requests must not repeatedly raise windows or demand focus.
/// Notify only on an empty-to-nonempty transition, with a monotonic cooldown.
public struct NetworkJoinAttentionGate {
    private var hasPending = false
    private var lastNotification: Double?
    public init() {}

    public mutating func shouldNotify(pending: Bool, now: Double) -> Bool {
        let newlyPending = pending && !hasPending
        hasPending = pending
        guard newlyPending, now.isFinite,
              lastNotification.map({ now - $0 >= 60 }) ?? true else { return false }
        lastNotification = now
        return true
    }
}
