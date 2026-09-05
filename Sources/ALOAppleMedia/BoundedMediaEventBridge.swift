import Foundation

/// One scheduled executor hop for a bounded batch, never one Task per packet.
/// By default overflow fails closed so an ACK/control cannot silently be lost.
/// Opt-in lossy PCM entries may be evicted oldest-first, never a control entry.
/// No client callbacks (including the classifier) execute under the lock.
public final class BoundedMediaEventBridge<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumEvents: Int
    private let maximumBytes: Int
    private let schedule: (@escaping @Sendable () -> Void) -> Void
    private let receive: ([Event]) -> Void
    private let overflow: () -> Void
    private let droppable: (Event) -> Bool
    private struct Entry {
        let event: Event
        let byteCount: Int
        let droppable: Bool
    }
    private var events: [Entry] = []
    private var bytes = 0
    private var scheduled = false, closed = false, failed = false
    public init(maximumEvents: Int = 128, maximumBytes: Int = 256 * 1_024,
                droppable: @escaping (Event) -> Bool = { _ in false },
                schedule: @escaping (@escaping @Sendable () -> Void) -> Void,
                receive: @escaping ([Event]) -> Void, overflow: @escaping () -> Void) {
        self.maximumEvents = max(1, min(512, maximumEvents))
        // Annotation snapshots may legally span 8 MiB. Callers opt into a
        // larger bounded budget; audio/control bridges retain the 256 KiB default.
        self.maximumBytes = max(1, min(16 * 1_024 * 1_024, maximumBytes))
        self.schedule = schedule; self.receive = receive; self.overflow = overflow
        self.droppable = droppable
    }
    /// True means the bridge remains healthy, not a delivery acknowledgment:
    /// classified PCM may be discarded when only controls occupy the budget.
    /// Invalid byte sizes and a control-only overflow remain terminal.
    @discardableResult public func submit(_ event: Event, byteCount: Int = 0) -> Bool {
        let canDrop = droppable(event)
        lock.lock()
        guard !closed else { lock.unlock(); return false }
        if byteCount >= 0, byteCount <= maximumBytes {
            while byteCount > maximumBytes - bytes || events.count >= maximumEvents {
                guard let oldestPCM = events.firstIndex(where: { $0.droppable }) else {
                    // Preserve queued control order and consent. New PCM is
                    // deliberately lost instead of terminating its transport.
                    if canDrop { lock.unlock(); return true }
                    break
                }
                bytes -= events.remove(at: oldestPCM).byteCount
            }
        }
        let accepted = byteCount >= 0 && byteCount <= maximumBytes - bytes && events.count < maximumEvents
        if accepted { events.append(Entry(event: event, byteCount: byteCount, droppable: canDrop)); bytes += byteCount }
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
        let batch = events.map(\.event), notifyFailure = failed
        events.removeAll(keepingCapacity: true); bytes = 0; failed = false; scheduled = false
        lock.unlock()
        if notifyFailure { overflow() } else if !batch.isEmpty { receive(batch) }
    }
}
