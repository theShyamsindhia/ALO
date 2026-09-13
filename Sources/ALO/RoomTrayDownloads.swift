import Combine
import Foundation

/// One bounded, cancellable request per item. The room file's identity and
/// digest remain authoritative; a timeout from an older attempt cannot end a retry.
@MainActor
final class RoomTrayDownloads: ObservableObject {
    enum State: Equatable {
        case requesting(UUID)
        case failed(String)
    }
    @Published private(set) var states: [String: State] = [:]
    private let timeout: Duration
    private var tasks: [String: Task<Void, Never>] = [:]

    init(timeout: Duration = .seconds(20)) { self.timeout = timeout }

    var activeIDs: Set<String> {
        Set(states.compactMap { id, state in if case .requesting = state { id } else { nil } })
    }

    func error(for id: String) -> String? {
        if case .failed(let message) = states[id] { return message }
        return nil
    }

    func attempt(for id: String) -> UUID? {
        if case .requesting(let token) = states[id] { return token }
        return nil
    }

    @discardableResult
    func begin(_ id: String, send: () -> Void) -> Bool {
        guard !activeIDs.contains(id) else { return false }
        guard activeIDs.count < 4 else {
            states[id] = .failed("Four downloads are already active. Try again when one finishes.")
            return false
        }
        let attempt = UUID()
        states[id] = .requesting(attempt)
        tasks[id] = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.expire(id, attempt: attempt)
        }
        send()
        return true
    }

    func expire(_ id: String, attempt: UUID) {
        guard states[id] == .requesting(attempt) else { return }
        finish(id, attempt: attempt, error: "No copy arrived. Ask someone with this file to reconnect, then retry.")
    }

    func finish(_ id: String, attempt: UUID, error: String? = nil) {
        guard states[id] == .requesting(attempt) else { return }
        tasks.removeValue(forKey: id)?.cancel()
        states[id] = error.map(State.failed)
    }

    func cancel(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        states.removeValue(forKey: id)
    }

    func retain(_ ids: Set<String>) {
        for id in Array(states.keys) where !ids.contains(id) { cancel(id) }
    }

    func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); states.removeAll()
    }
}
