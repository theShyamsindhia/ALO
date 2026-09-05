import Foundation

public struct TransportToken: Hashable, Sendable {
    public let lifecycle: UInt64
    public let generation: UInt64
}

public struct ConnectionTimingPolicy: Equatable, Sendable {
    public let connectTimeout: TimeInterval
    public let authenticationTimeout: TimeInterval
    public let synchronizationTimeout: TimeInterval
    public let candidateCooldown: TimeInterval
    public init(connectTimeout: TimeInterval = 15, authenticationTimeout: TimeInterval = 5,
                synchronizationTimeout: TimeInterval = 15, candidateCooldown: TimeInterval = 30) {
        // Invalid configuration fails closed to the documented defaults, never infinite deadlines.
        self.connectTimeout = connectTimeout.isFinite && connectTimeout > 0 ? connectTimeout : 15
        self.authenticationTimeout = authenticationTimeout.isFinite && authenticationTimeout > 0 ? authenticationTimeout : 5
        self.synchronizationTimeout = synchronizationTimeout.isFinite && synchronizationTimeout > 0 ? synchronizationTimeout : 15
        self.candidateCooldown = candidateCooldown.isFinite && candidateCooldown >= 0 ? candidateCooldown : 30
    }
    public func retryDelay(attempt: Int, jitterUnit: Double) -> TimeInterval {
        let unit = jitterUnit.isFinite ? min(1, max(0, jitterUnit)) : 0.5
        let base = min(15, 0.5 * pow(2, Double(min(5, max(0, attempt)))))
        return min(15, base * (0.8 + 0.4 * unit))
    }
}

public enum ConnectionPhase: String, Equatable, Sendable {
    case stopped, discovering, connecting, authenticating, synchronizing, active
    case reconnecting, permissionRequired, suspended
}

public enum ConnectionAction: Equatable, Sendable {
    case discover(lifecycle: UInt64)
    case connect(TransportToken)
    case cancel(TransportToken)
    case retryScheduled(lifecycle: UInt64, at: TimeInterval)
    case becameActive(TransportToken, replacing: TransportToken?)
    case candidateReady(TransportToken)
    case cutoverPrepared(TransportToken, captureFrame: UInt64)
}

/// Pure deterministic state machine. The adapter owns Network objects and timers and must
/// return each callback with its token. Time is monotonic seconds supplied by that adapter.
/// Authentication success must only follow the TLS/admission checks; synchronized means
/// fresh state sync and demonstrated application progress, not just a socket ready callback.
public struct ConnectionSupervisor: Sendable {
    private enum Stage: Sendable { case connecting, authenticating, synchronizing, ready }
    private struct Attempt: Sendable {
        let token: TransportToken
        var stage: Stage
        var deadline: TimeInterval
        var cutoverFrame: UInt64?
    }
    public private(set) var lifecycle: UInt64 = 0
    public private(set) var phase: ConnectionPhase = .stopped
    public private(set) var activeToken: TransportToken?
    public var candidateToken: TransportToken? { activeToken == nil ? nil : attempt?.token }
    public var pendingToken: TransportToken? { attempt?.token }
    public private(set) var retryAt: TimeInterval?
    public let policy: ConnectionTimingPolicy
    private var generation: UInt64 = 0
    private var retryAttempt = 0
    private var attempt: Attempt?
    private var lastCandidateAt: TimeInterval?
    private var lastTime: TimeInterval = -.infinity
    private var discoveryDeadline: TimeInterval?

    public init(policy: ConnectionTimingPolicy = .init()) { self.policy = policy }

    private mutating func acceptsTime(_ now: TimeInterval) -> Bool {
        guard now.isFinite, now >= lastTime else { return false }
        lastTime = now
        return true
    }

    /// Begins lifecycle-owned discovery. Only resolved(lifecycle:now:) can start the socket.
    public mutating func start(now: TimeInterval) -> [ConnectionAction] {
        guard acceptsTime(now) else { return [] }
        let cancellations = invalidate(to: .discovering)
        guard phase == .discovering else { return cancellations }
        discoveryDeadline = now + policy.connectTimeout
        return cancellations + [.discover(lifecycle: lifecycle)]
    }

    public mutating func resolved(lifecycle expected: UInt64, now: TimeInterval) -> [ConnectionAction] {
        guard expected == lifecycle, phase == .discovering, acceptsTime(now) else { return [] }
        guard discoveryDeadline.map({ now < $0 }) ?? false else { return resolutionFailed(lifecycle: expected, now: now) }
        discoveryDeadline = nil
        return connect(now: now)
    }

    public mutating func resolutionFailed(lifecycle expected: UInt64, now: TimeInterval,
                                           jitterUnit: Double = 0.5) -> [ConnectionAction] {
        guard expected == lifecycle, phase == .discovering, acceptsTime(now) else { return [] }
        discoveryDeadline = nil; phase = .reconnecting
        let at = now + policy.retryDelay(attempt: retryAttempt, jitterUnit: jitterUnit)
        retryAttempt = min(retryAttempt + 1, 30); retryAt = at
        return [.retryScheduled(lifecycle: lifecycle, at: at)]
    }

    private mutating func connect(now: TimeInterval) -> [ConnectionAction] {
        guard generation < .max else { return invalidate(to: .stopped) }
        generation += 1
        let token = TransportToken(lifecycle: lifecycle, generation: generation)
        attempt = Attempt(token: token, stage: .connecting, deadline: now + policy.connectTimeout)
        if activeToken == nil { phase = .connecting }
        retryAt = nil
        return [.connect(token)]
    }

    public mutating func ready(_ token: TransportToken, now: TimeInterval) -> [ConnectionAction] {
        guard acceptsTime(now), let current = attempt, current.token == token, current.stage == .connecting else { return [] }
        guard now < current.deadline else { return fail(token, now: now) }
        attempt?.stage = .authenticating
        attempt?.deadline = now + policy.authenticationTimeout
        if activeToken == nil { phase = .authenticating }
        return []
    }

    public mutating func authenticated(_ token: TransportToken, now: TimeInterval) -> [ConnectionAction] {
        guard acceptsTime(now), let current = attempt, current.token == token, current.stage == .authenticating else { return [] }
        guard now < current.deadline else { return fail(token, now: now) }
        attempt?.stage = .synchronizing
        attempt?.deadline = now + policy.synchronizationTimeout
        if activeToken == nil { phase = .synchronizing }
        return []
    }

    public mutating func synchronized(_ token: TransportToken, madeProgress: Bool, now: TimeInterval) -> [ConnectionAction] {
        guard acceptsTime(now), let current = attempt, current.token == token, current.stage == .synchronizing else { return [] }
        guard now < current.deadline else { return fail(token, now: now) }
        guard madeProgress else { return [] }
        if activeToken != nil {
            attempt?.stage = .ready
            // A ready candidate also has bounded lifetime while cutover is negotiated.
            attempt?.deadline = now + policy.synchronizationTimeout
            return [.candidateReady(token)]
        }
        activeToken = token; attempt = nil; phase = .active; retryAttempt = 0
        lastCandidateAt = now
        return [.becameActive(token, replacing: nil)]
    }

    public mutating func prepareCandidate(now: TimeInterval) -> [ConnectionAction] {
        guard acceptsTime(now), activeToken != nil, attempt == nil,
              lastCandidateAt.map({ now - $0 >= policy.candidateCooldown }) ?? true else { return [] }
        lastCandidateAt = now
        return connect(now: now)
    }

    public mutating func agreeCutover(_ token: TransportToken, captureFrame: UInt64, now: TimeInterval) -> [ConnectionAction] {
        guard acceptsTime(now), activeToken != nil, let current = attempt,
              current.token == token, current.stage == .ready, current.cutoverFrame == nil else { return [] }
        guard now < current.deadline else { return fail(token, now: now) }
        attempt?.cutoverFrame = captureFrame
        return [.cutoverPrepared(token, captureFrame: captureFrame)]
    }

    /// Both endpoints must have agreed the candidate and frame before the adapter commits.
    public mutating func commitCutover(_ token: TransportToken, captureFrame: UInt64, now: TimeInterval) -> [ConnectionAction] {
        guard acceptsTime(now), let old = activeToken, let current = attempt,
              current.token == token, current.stage == .ready, current.cutoverFrame == captureFrame else { return [] }
        guard now < current.deadline else { return fail(token, now: now) }
        activeToken = token; attempt = nil; phase = .active; retryAttempt = 0
        return [.becameActive(token, replacing: old), .cancel(old)]
    }

    public mutating func fail(_ token: TransportToken, now: TimeInterval, jitterUnit: Double = 0.5) -> [ConnectionAction] {
        guard acceptsTime(now), token.lifecycle == lifecycle,
              token == activeToken || token == attempt?.token else { return [] }
        if token == attempt?.token, activeToken != nil {
            attempt = nil // An unsuccessful replacement never evicts the working link.
            return [.cancel(token)]
        }
        var actions: [ConnectionAction] = [.cancel(token)]
        if let pending = attempt?.token, pending != token { actions.append(.cancel(pending)) }
        activeToken = nil; attempt = nil; phase = .reconnecting
        let at = now + policy.retryDelay(attempt: retryAttempt, jitterUnit: jitterUnit)
        retryAttempt = min(retryAttempt + 1, 30); retryAt = at
        actions.append(.retryScheduled(lifecycle: lifecycle, at: at))
        return actions
    }

    /// Timer callbacks use the lifecycle that scheduled them; stale callbacks are inert.
    public mutating func advance(lifecycle expected: UInt64, now: TimeInterval, jitterUnit: Double = 0.5) -> [ConnectionAction] {
        guard expected == lifecycle, acceptsTime(now) else { return [] }
        if phase == .discovering, let deadline = discoveryDeadline, now >= deadline {
            return resolutionFailed(lifecycle: expected, now: now, jitterUnit: jitterUnit)
        }
        if let pending = attempt, now >= pending.deadline { return fail(pending.token, now: now, jitterUnit: jitterUnit) }
        if phase == .reconnecting, let retryAt, now >= retryAt {
            self.retryAt = nil; phase = .discovering
            discoveryDeadline = now + policy.connectTimeout
            return [.discover(lifecycle: lifecycle)] // Re-resolve, never reuse a terminal socket/address.
        }
        return []
    }

    public mutating func permissionRequired() -> [ConnectionAction] { invalidate(to: .permissionRequired) }
    public mutating func suspend() -> [ConnectionAction] { invalidate(to: .suspended) }
    public mutating func stop() -> [ConnectionAction] { invalidate(to: .stopped) }

    private mutating func invalidate(to newPhase: ConnectionPhase) -> [ConnectionAction] {
        var actions = [ConnectionAction]()
        if let activeToken { actions.append(.cancel(activeToken)) }
        if let pending = attempt?.token { actions.append(.cancel(pending)) }
        activeToken = nil; attempt = nil; retryAt = nil; retryAttempt = 0; lastCandidateAt = nil; discoveryDeadline = nil
        if lifecycle == .max { phase = .stopped } else { lifecycle += 1; phase = newPhase }
        return actions
    }

    /// Apply only among authenticated simultaneous initial candidates. An existing active
    /// connection must be replaced through prepare/ready/commit, never by this tie breaker.
    public static func preferredConnectionID(_ first: UUID, _ second: UUID) -> UUID {
        first.uuidString < second.uuidString ? first : second
    }
}

/// Receiver overlap deduplication is bounded and resets only for an authenticated new epoch.
public struct MediaFrameDeduplicator: Sendable {
    public let broadcasterEpoch: UInt64
    private var replay = AuthenticatedReplayWindow()
    public init(broadcasterEpoch: UInt64) { self.broadcasterEpoch = broadcasterEpoch }
    public mutating func accept(epoch: UInt64, frame: UInt64) -> Bool {
        guard epoch == broadcasterEpoch, replay.accepts(frame) else { return false }
        replay.record(frame); return true
    }
}
