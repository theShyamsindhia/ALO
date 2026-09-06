import Foundation
import ALOCore

/// Shared native wake-up driver. Reconfiguring an unchanged mode never resets the frame clock.
@MainActor
final class GameRealtimeLoop {
    private var timer: Timer?
    private var interval: Double?
    @discardableResult func configure(active: Bool, realtime: Bool, update: @escaping @MainActor (Double) -> Void) -> Bool {
        guard active else { let changed = timer != nil; stop(); return changed }
        let desired = realtime ? GameRealtimePolicy.step : GameRealtimePolicy.idleInterval
        guard timer == nil || interval != desired else { return false }
        stop(); interval = desired
        let timer = Timer(timeInterval: desired, repeats: true) { _ in
            MainActor.assumeIsolated { update(ProcessInfo.processInfo.systemUptime) }
        }
        timer.tolerance = realtime ? 0.002 : 0.025
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        return true
    }
    func stop() { timer?.invalidate(); timer = nil; interval = nil }
    deinit { timer?.invalidate() }
}
