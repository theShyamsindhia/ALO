import Foundation

final class InactiveLockScreenMonitoringService: LockScreenMonitoring {
    nonisolated deinit {}

    var onLockStateChange: ((Bool) -> Void)?

    func startMonitoring() {}
    func stopMonitoring() {}
}
