import Foundation

/// One scheduled executor hop for a bounded batch, never one Task per packet.
/// Overflow fails the bridge closed so an ACK/control event cannot silently be
/// lost while later audio is delivered. No callbacks execute under the lock.
public final class BoundedMediaEventBridge<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumEvents: Int
    private let maximumBytes: Int
    private let schedule: (@escaping @Sendable () -> Void) -> Void
    private let receive: ([Event]) -> Void
    private let overflow: () -> Void
    private var events: [Event] = []
    private var bytes = 0
    private var scheduled = false, closed = false, failed = false
    public init(maximumEvents: Int = 128, maximumBytes: Int = 256 * 1_024,
                schedule: @escaping (@escaping @Sendable () -> Void) -> Void,
                receive: @escaping ([Event]) -> Void, overflow: @escaping () -> Void) {
        self.maximumEvents = max(1, min(512, maximumEvents))
        // Annotation snapshots may legally span 8 MiB. Callers opt into a
        // larger bounded budget; audio/control bridges retain the 256 KiB default.
        self.maximumBytes = max(1, min(16 * 1_024 * 1_024, maximumBytes))
        self.schedule = schedule; self.receive = receive; self.overflow = overflow
    }
    @discardableResult public func submit(_ event: Event, byteCount: Int = 0) -> Bool {
        lock.lock()
        guard !closed else { lock.unlock(); return false }
        let accepted = byteCount >= 0 && byteCount <= maximumBytes - bytes && events.count < maximumEvents
        if accepted { events.append(event); bytes += byteCount }
        else { events.removeAll(); bytes = 0; closed = true; failed = true }
        let needsSchedule = !scheduled; scheduled = true
        lock.unlock()
        if needsSchedule { schedule { [weak self] in self?.drain() } }
        return accepted
    }
    public func close() {
        lock.lock(); closed = true; failed = false; events.removeAll(); bytes = 0; lock.unlock()
    }
    private func drain() {
        lock.lock()
        let batch = events, notifyFailure = failed
        events.removeAll(keepingCapacity: true); bytes = 0; failed = false; scheduled = false
        lock.unlock()
        if notifyFailure { overflow() } else if !batch.isEmpty { receive(batch) }
    }
}
