/// Foreground intent for asynchronous account setup and channel construction.
/// The UI records intent before enqueueing work; later lifecycle events can revoke it.
@MainActor
public final class ForegroundChannelLifecycle {
    public struct Activation: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    public struct JoinIntent: Equatable, Sendable {
        public let activation: Activation
        fileprivate let generation: UInt64
    }

    public private(set) var isForeground = false
    public private(set) var joinGeneration: UInt64 = 0
    private var activationGeneration: UInt64 = 0
    private var activationTask: Task<Void, Never>?

    public init() {}

    deinit { activationTask?.cancel() }

    @discardableResult
    public func activate(refreshIfForeground: Bool = false,
                         _ operation: @escaping @MainActor (Activation) async -> Void) -> Task<Void, Never> {
        // Inactive -> active (e.g. a permission sheet) is not a new foreground
        // session. Neither cancel the user's join nor reconnect an older channel.
        if isForeground {
            guard refreshIfForeground else { return Task {} }
            activationTask?.cancel()
        } else {
            invalidatePendingWork()
        }
        isForeground = true
        let activation = Activation(generation: activationGeneration)
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.accepts(activation) else { return }
            await operation(activation)
        }
        activationTask = task
        return task
    }

    public func suspend() {
        isForeground = false
        invalidatePendingWork()
    }

    /// Leave, retry, and explicit selection supersede any pending automatic reconnect.
    public func invalidatePendingWork() {
        activationTask?.cancel()
        activationTask = nil
        activationGeneration &+= 1
        joinGeneration &+= 1
    }

    public func beginJoin() -> JoinIntent? {
        guard isForeground else { return nil }
        invalidatePendingWork()
        return JoinIntent(activation: Activation(generation: activationGeneration), generation: joinGeneration)
    }

    public func accepts(_ activation: Activation) -> Bool {
        isForeground && activation.generation == activationGeneration
    }

    public func accepts(_ intent: JoinIntent) -> Bool {
        accepts(intent.activation) && intent.generation == joinGeneration
    }
}
