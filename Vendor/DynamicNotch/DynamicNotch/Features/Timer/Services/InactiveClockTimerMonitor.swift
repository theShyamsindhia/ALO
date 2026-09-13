import Foundation

final class InactiveClockTimerMonitor: ClockTimerMonitoring {
    nonisolated deinit {}

    var onSnapshotChange: ((ClockTimerSnapshot?) -> Void)?

    func startMonitoring() {
        onSnapshotChange?(nil)
    }

    func stopMonitoring() {}
}
