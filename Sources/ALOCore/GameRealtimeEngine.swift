import Foundation

/// Every real-time library game uses these budgets. Simulation rules remain game-specific.
public enum GameRealtimePolicy {
    public static let step = 1.0 / 60
    public static let snapshotInterval = 1.0 / 30
    public static let idleInterval = 0.25
    public static let maximumCatchUpSteps = 6
    public static let maximumPredictionSteps = 6
    public static let staleInputAfter = 0.2
    public static let reconnectAfter = 2.0
    public static let memberTimeout = 6.0
    public static let connectionTimeout = 12.0
    public static let maximumPacketBytes = 8192
    public static func pausesWorld(multiplayer: Bool, menuOpen: Bool) -> Bool { menuOpen && !multiplayer }
}

public struct GameMotion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var vx: Double
    public var vy: Double
    /// Changes on respawn, elimination, or another discontinuity that must never be interpolated.
    public var continuity: Int
    public init(x: Double, y: Double, vx: Double, vy: Double, continuity: Int = 0) {
        self.x = x; self.y = y; self.vx = vx; self.vy = vy; self.continuity = continuity
    }
}

/// Shared fixed-step scheduling, acknowledged prediction history and jitter-buffered presentation.
/// One instance owns one activity's state; there is only one implementation for all game engines.
public struct GameRealtimeEngine<Input: Sendable>: Sendable {
    public struct Frame: Sendable {
        public let steps: Int
        public let publishSnapshot: Bool
    }
    private var previousTime: Double?
    private var accumulator = 0.0
    private var totalSteps = 0
    private struct Pending: Sendable { let sequence: Int; let input: Input; let steps: Int }
    private var pending: [Pending] = []
    private struct Snapshot: Sendable { let frame: Int; let time: Double; let arrival: Double; let motion: [GameMotion] }
    private var snapshots: [Snapshot] = []
    private var epoch = ""
    private var timelineOffset: Double?
    private var jitter = 0.0
    public var interpolationDelay: Double { min(0.083, GameRealtimePolicy.snapshotInterval + jitter * 2) }
    public var pendingInputCount: Int { pending.count }
    public var latestAuthoritativeFrame: Int? { snapshots.last?.frame }
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func rebaseClock(at now: Double) { previousTime = now; accumulator = 0 }
    public mutating func advance(at now: Double, running: Bool) -> Frame {
        guard now.isFinite else { return Frame(steps: 0, publishSnapshot: false) }
        if let previousTime, now < previousTime { return Frame(steps: 0, publishSnapshot: false) }
        let elapsed = min(Double(GameRealtimePolicy.maximumCatchUpSteps) * GameRealtimePolicy.step, max(0, now - (previousTime ?? now)))
        previousTime = now
        guard running else { accumulator = 0; return Frame(steps: 0, publishSnapshot: false) }
        accumulator += elapsed
        let steps = min(GameRealtimePolicy.maximumCatchUpSteps, Int((accumulator + 1e-9) / GameRealtimePolicy.step))
        accumulator = max(0, accumulator - Double(steps) * GameRealtimePolicy.step)
        let before = totalSteps / 2; totalSteps += steps
        return Frame(steps: steps, publishSnapshot: totalSteps / 2 > before)
    }
    public mutating func recordInput(sequence: Int, input: Input, steps: Int) {
        guard steps > 0 else { return }
        pending.append(Pending(sequence: sequence, input: input, steps: min(steps, GameRealtimePolicy.maximumCatchUpSteps)))
        if pending.count > 12 { pending.removeFirst(pending.count - 12) }
    }
    public mutating func acknowledge(_ sequence: Int?) -> [Input] {
        guard let sequence else { pending.removeAll(); return [] } // Older hosts have no prediction acknowledgement.
        pending.removeAll { $0.sequence <= sequence }
        return Array(pending.flatMap { Array(repeating: $0.input, count: $0.steps) }.suffix(GameRealtimePolicy.maximumPredictionSteps))
    }
    public mutating func clearPrediction() { pending.removeAll() }
    @discardableResult public mutating func receiveSnapshot(frame: Int, epoch: String, at now: Double, motion: [GameMotion]) -> Bool {
        guard now.isFinite, frame >= 0, (1...4).contains(motion.count), motion.allSatisfy({ [$0.x, $0.y, $0.vx, $0.vy].allSatisfy(\.isFinite) }) else { return false }
        if self.epoch != epoch { self.epoch = epoch; snapshots.removeAll(); timelineOffset = nil; jitter = 0; pending.removeAll() }
        guard frame > (snapshots.last?.frame ?? -1) else { return false }
        let time = Double(frame) * GameRealtimePolicy.step
        let offset = now - time
        if let previous = snapshots.last {
            let deviation = abs((now - previous.arrival) - (time - previous.time))
            jitter += (min(0.1, deviation) - jitter) * 0.1
            // Smooth arrival jitter; quickly recover from a genuine long clock discontinuity.
            if let old = timelineOffset { timelineOffset = abs(offset - old) > 0.5 ? offset : old + (offset - old) * 0.08 }
        } else { timelineOffset = offset }
        snapshots.append(Snapshot(frame: frame, time: time, arrival: now, motion: motion))
        if snapshots.count > 8 { snapshots.removeFirst(snapshots.count - 8) }
        return true
    }
    public func position(for index: Int, at now: Double, fallback: GameMotion, remote: Bool) -> GameMotion {
        guard remote, let latest = snapshots.last, latest.motion.indices.contains(index), let offset = timelineOffset else { return fallback }
        let targetTime = now - offset - interpolationDelay
        let current = latest.motion[index]
        // Never draw the old life of a fighter after an authoritative knockout/respawn.
        guard current.continuity == fallback.continuity else { return fallback }
        if targetTime >= latest.time {
            let dt = min(GameRealtimePolicy.snapshotInterval, max(0, targetTime - latest.time))
            return GameMotion(x: current.x + current.vx * dt, y: current.y + current.vy * dt, vx: current.vx, vy: current.vy, continuity: current.continuity)
        }
        if snapshots.count >= 2 {
            for i in 1..<snapshots.count {
                let a = snapshots[i - 1], b = snapshots[i]
                guard a.time <= targetTime, b.time >= targetTime, a.motion.indices.contains(index), b.motion.indices.contains(index) else { continue }
                let left = a.motion[index], right = b.motion[index]
                guard left.continuity == current.continuity, right.continuity == current.continuity,
                      hypot(right.x - left.x, right.y - left.y) < 180 else { return current }
                let t = max(0, min(1, (targetTime - a.time) / max(1e-9, b.time - a.time)))
                return GameMotion(x: left.x + (right.x - left.x) * t, y: left.y + (right.y - left.y) * t, vx: right.vx, vy: right.vy, continuity: right.continuity)
            }
        }
        return snapshots.first.flatMap { $0.motion.indices.contains(index) && $0.motion[index].continuity == current.continuity ? $0.motion[index] : nil } ?? current
    }
}
