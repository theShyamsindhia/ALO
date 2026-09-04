import AVFoundation
import Foundation

/// Owns the one Core Audio output graph used by a running app session.
///
/// Media and voice used to create independent `AVAudioEngine` instances. That
/// is usually tolerated by built-in speakers, but wireless routes expose each
/// engine as a separate hardware client and can render the later voice client
/// quietly or glitch while the route settles. Keeping one engine also avoids a
/// destructive hardware reopen when a user leaves and rejoins a room.
final class RoomAudioOutputEngine: @unchecked Sendable {
    let engine = AVAudioEngine()

    private let hardwareLock = NSRecursiveLock()
    private let graphLock = NSRecursiveLock()
    private let stateLock = NSLock()
    private let idleStopDelay: DispatchTimeInterval
    private let idleQueue = DispatchQueue(label: "in.werai.room-audio-output-idle")
    private var clientCount = 0
    private var idleStopWorkItem: DispatchWorkItem?
    private var storedStartGeneration: UInt64 = 0

    init(idleStopDelay: DispatchTimeInterval = .seconds(3)) {
        self.idleStopDelay = idleStopDelay
    }

    var identity: ObjectIdentifier { ObjectIdentifier(engine) }

    // AVAudioEngine exposes this as a thread-safe snapshot. Keeping this read
    // lock-free is important: a wireless hardware start can block for hundreds
    // of milliseconds and must not stall the media receive/clock queue.
    var isRunning: Bool { engine.isRunning }

    var startGeneration: UInt64 {
        stateLock.withLock { storedStartGeneration }
    }

    @discardableResult
    func withGraph<Result>(_ body: (AVAudioEngine) throws -> Result) rethrows -> Result {
        hardwareLock.lock()
        defer { hardwareLock.unlock() }
        graphLock.lock()
        defer { graphLock.unlock() }
        return try body(engine)
    }

    func ensureRunning() throws {
        hardwareLock.lock()
        defer { hardwareLock.unlock() }
        guard !engine.isRunning else { return }
        graphLock.lock()
        engine.prepare()
        graphLock.unlock()
        try engine.start()
        stateLock.withLock {
            storedStartGeneration &+= 1
        }
    }

    /// Keep the shared hardware graph alive while it owns at least one attached
    /// media/voice client. A short idle grace absorbs a leave/rejoin without
    /// keeping a Bluetooth route open for the rest of the app's lifetime.
    func retainClient() {
        stateLock.withLock {
            clientCount += 1
            idleStopWorkItem?.cancel()
            idleStopWorkItem = nil
        }
    }

    func releaseClient() {
        let work = stateLock.withLock { () -> DispatchWorkItem? in
            guard clientCount > 0 else { return nil }
            clientCount -= 1
            guard clientCount == 0 else { return nil }
            idleStopWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.stopIfIdle() }
            idleStopWorkItem = work
            return work
        }
        if let work {
            idleQueue.asyncAfter(deadline: .now() + idleStopDelay, execute: work)
        }
    }

    private func stopIfIdle() {
        hardwareLock.lock()
        defer { hardwareLock.unlock() }
        let shouldStop = stateLock.withLock { () -> Bool in
            guard clientCount == 0 else { return false }
            idleStopWorkItem = nil
            return true
        }
        guard shouldStop else { return }
        graphLock.withLock {
            engine.stop()
            engine.reset()
        }
    }

    private func stopImmediately() {
        hardwareLock.withLock {
            graphLock.withLock {
                engine.stop()
                engine.reset()
            }
        }
    }

    deinit {
        stateLock.withLock {
            idleStopWorkItem?.cancel()
            idleStopWorkItem = nil
        }
        stopImmediately()
    }
}

private extension NSLocking {
    @discardableResult
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
