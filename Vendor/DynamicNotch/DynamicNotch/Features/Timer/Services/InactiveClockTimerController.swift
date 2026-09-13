import Foundation

@MainActor
final class InactiveClockTimerController: ClockTimerControlling {
    nonisolated deinit {}

    func togglePauseResume() async -> Bool { false }
    func stopTimer() async -> Bool { false }
}
