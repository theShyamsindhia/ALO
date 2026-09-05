import Foundation

/// Timing at the image-handler boundary, not a measurement of physical display
/// scanout or speaker-to-screen skew. No new frames can mean a static screen.
struct VideoPresentationTimingSnapshot: Sendable, Equatable {
    let measuredAtNanos: UInt64
    let latestHandoffAtNanos: UInt64?
    let latestDeadlineMissNanos: UInt64?
    let maximumDeadlineMissNanos: UInt64
    let presentedCount: UInt64
    let pendingCount: Int
    let oldestPendingDeadlineNanos: UInt64?
}

/// One timer owns a bounded set of frames. Reset releases them immediately,
/// including frames whose remote timestamp would otherwise retain them for years.
final class VideoPresentationQueue<Image> {
    static var maximumLeadNanos: UInt64 { 2_000_000_000 }
    private struct Frame { let image: Image; let deadline: UInt64; let bytes: Int; let isCurrent: () -> Bool }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var frames = [Frame]()
    private var timer: DispatchSourceTimer?
    private let handler: (Image) -> Void
    private let now: () -> UInt64
    private var latestHandoffAtNanos: UInt64?
    private var latestDeadlineMissNanos: UInt64?
    private var maximumDeadlineMissNanos: UInt64 = 0
    private var presentedCount: UInt64 = 0
    private var generation: UInt64 = 0
    var pendingCount: Int { lock.withLock { frames.count } }

    var timingSnapshot: VideoPresentationTimingSnapshot {
        lock.withLock {
            VideoPresentationTimingSnapshot(measuredAtNanos: now(),
                latestHandoffAtNanos: latestHandoffAtNanos,
                latestDeadlineMissNanos: latestDeadlineMissNanos,
                maximumDeadlineMissNanos: maximumDeadlineMissNanos,
                presentedCount: presentedCount, pendingCount: frames.count,
                oldestPendingDeadlineNanos: frames.first?.deadline)
        }
    }

    // The clock must be thread-safe. Deliver directly on the UI executor so a
    // blocked main thread retains bounded frames here, not unbounded UI closures.
    init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         deliveryQueue: DispatchQueue = .main, handler: @escaping (Image) -> Void) {
        self.now = now; self.queue = deliveryQueue; self.handler = handler
    }
    deinit { timer?.cancel() }

    static func deadline(capture: UInt64, offset: Int64, delay: UInt64, now: UInt64) -> UInt64? {
        let local: UInt64
        if offset >= 0 {
            guard capture >= UInt64(offset) else { return nil }
            local = capture - UInt64(offset)
        } else {
            let result = capture.addingReportingOverflow(offset.magnitude)
            guard !result.overflow else { return nil }
            local = result.partialValue
        }
        let result = local.addingReportingOverflow(delay)
        guard !result.overflow else { return nil }
        let target = result.partialValue
        guard target <= now || target - now <= maximumLeadNanos else { return nil }
        return target
    }

    func enqueue(_ image: Image, deadline: UInt64, bytes: Int, isCurrent: @escaping () -> Bool) {
        lock.withLock {
            let time = now()
            guard bytes >= 0, bytes <= 64 * 1_024 * 1_024,
                  deadline <= time || deadline - time <= Self.maximumLeadNanos, isCurrent() else { return }
            frames.removeAll { !$0.isCurrent() }
            while !frames.isEmpty && (frames.count >= 8 || frames.reduce(0, { $0 + $1.bytes }) + bytes > 64 * 1_024 * 1_024) {
                frames.removeFirst()
            }
            frames.append(Frame(image: image, deadline: deadline, bytes: bytes, isCurrent: isCurrent))
            frames.sort { $0.deadline < $1.deadline }
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(4))
                timer.setEventHandler { [weak self] in self?.drain() }
                self.timer = timer; timer.resume()
            }
        }
    }

    // Invalidate handoffs not yet admitted. A callback already admitted/executing
    // cannot be rewound; user handlers always execute outside the queue lock.
    func reset() {
        lock.withLock {
            generation &+= 1
            frames.removeAll(); timer?.cancel(); timer = nil
            latestHandoffAtNanos = nil; latestDeadlineMissNanos = nil
            maximumDeadlineMissNanos = 0; presentedCount = 0
        }
    }

    private func drain() {
        let extracted: (frames: [Frame], generation: UInt64) = lock.withLock {
            let time = now()
            let due = frames.filter { $0.deadline <= time }
            frames.removeAll { $0.deadline <= time || !$0.isCurrent() }
            if frames.isEmpty { timer?.cancel(); timer = nil }
            return (due, generation)
        }
        // Present the most recent frame after a scheduler delay, avoiding a burst of stale UI work.
        if let frame = extracted.frames.last, frame.isCurrent() {
            let admitted = lock.withLock {
                guard generation == extracted.generation else { return false }
                let time = now()
                let miss = time > frame.deadline ? time - frame.deadline : 0
                latestHandoffAtNanos = time; latestDeadlineMissNanos = miss
                maximumDeadlineMissNanos = max(maximumDeadlineMissNanos, miss)
                if presentedCount < .max { presentedCount += 1 }
                return true
            }
            if admitted { handler(frame.image) }
        }
    }
}
