import Foundation

/// One timer owns a bounded set of frames. Reset releases them immediately,
/// including frames whose remote timestamp would otherwise retain them for years.
final class VideoPresentationQueue<Image> {
    static var maximumLeadNanos: UInt64 { 2_000_000_000 }
    private struct Frame { let image: Image; let deadline: UInt64; let bytes: Int; let isCurrent: () -> Bool }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "in.werai.video.presentation", qos: .userInteractive)
    private var frames = [Frame]()
    private var timer: DispatchSourceTimer?
    private let handler: (Image) -> Void
    private let now: () -> UInt64
    var pendingCount: Int { lock.withLock { frames.count } }

    init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }, handler: @escaping (Image) -> Void) {
        self.now = now; self.handler = handler
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

    func reset() {
        lock.withLock { frames.removeAll(); timer?.cancel(); timer = nil }
    }

    private func drain() {
        let due: [Frame] = lock.withLock {
            let time = now()
            let due = frames.filter { $0.deadline <= time }
            frames.removeAll { $0.deadline <= time || !$0.isCurrent() }
            if frames.isEmpty { timer?.cancel(); timer = nil }
            return due
        }
        // Present the most recent frame after a scheduler delay, avoiding a burst of stale UI work.
        if let frame = due.last, frame.isCurrent() { handler(frame.image) }
    }
}
