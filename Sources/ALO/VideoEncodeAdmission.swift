import Foundation

/// At most one submitted hardware frame and one newest waiting capture. Dropping
/// an unencoded frame needs no H.264 dependency repair: it never entered the GOP.
/// The backend MUST enforce MaxFrameDelayCount == 0: an output cannot require
/// the next input, because the next input waits for this work's completion.
final class VideoEncodeAdmission<Frame>: @unchecked Sendable {
    struct Work { let id: UUID; let frame: Frame }
    private let lock = NSLock()
    private var active: UUID?
    private var latest: Frame?
    private var stopped = false

    func offer(_ frame: Frame) -> Work? {
        lock.withLock {
            guard !stopped else { return nil }
            guard active == nil else { latest = frame; return nil }
            let work = Work(id: UUID(), frame: frame)
            active = work.id
            return work
        }
    }

    func accepts(_ id: UUID) -> Bool { lock.withLock { !stopped && active == id } }

    func finish(_ id: UUID) -> Work? {
        lock.withLock {
            guard !stopped, active == id else { return nil }
            active = nil
            guard let frame = latest else { return nil }
            latest = nil
            let work = Work(id: UUID(), frame: frame)
            active = work.id
            return work
        }
    }

    func stop() { lock.withLock { stopped = true; active = nil; latest = nil } }
}
