import Foundation

/// Screen-local feedback, separate from unrelated form errors and from the
/// account model's authoritative per-network membership/request state.
public struct ALONearbyJoinFeedback {
    public private(set) var errorMessage: String?
    private var currentAttempt: UUID?

    public init() {}

    public mutating func begin() -> UUID {
        let token = UUID()
        currentAttempt = token
        errorMessage = nil
        return token
    }

    public mutating func finish(_ token: UUID, errorMessage: String? = nil) {
        guard currentAttempt == token else { return }
        currentAttempt = nil
        self.errorMessage = errorMessage
    }

    public mutating func cancel() {
        currentAttempt = nil
        errorMessage = nil
    }

    public mutating func dismissError() { errorMessage = nil }
}
