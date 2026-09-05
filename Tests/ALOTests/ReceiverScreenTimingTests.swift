import Testing
@testable import ALO

struct ReceiverScreenTimingTests {
    @Test
    func restartedSharingRequiresAHandoffAfterItsEnableNotification() {
        func frame(at handoff: UInt64) -> VideoPresentationTimingSnapshot {
            VideoPresentationTimingSnapshot(measuredAtNanos: 10_000, latestHandoffAtNanos: handoff,
                latestDeadlineMissNanos: 0, maximumDeadlineMissNanos: 0, presentedCount: 1,
                pendingCount: 0, oldestPendingDeadlineNanos: nil)
        }
        var timing = ReceiverScreenTiming()
        // On the initial share, video can beat its separate control notification.
        timing.update(enabled: true, at: 100)
        #expect(timing.presentationSnapshot(frame(at: 90)).latestHandoffAtNanos == 90)
        timing.update(enabled: false, at: 200)
        timing.update(enabled: true, at: 300)
        let stale = timing.presentationSnapshot(frame(at: 90))
        #expect(stale.latestHandoffAtNanos == nil)
        #expect(stale.presentedCount == 0)
        #expect(stale.relativeTimingReport.latestHandoffAgeNanos == nil)
        // A queued old frame can be handed off while disabled. It cannot prove
        // the restarted stream is delivering, even though it follows the stop.
        #expect(timing.presentationSnapshot(frame(at: 250)).latestHandoffAtNanos == nil)
        #expect(timing.presentationSnapshot(frame(at: 300)).latestHandoffAtNanos == nil)
        #expect(timing.presentationSnapshot(frame(at: 350)).latestHandoffAtNanos == 350)
        timing.update(enabled: true, at: 400)
        #expect(timing.presentationSnapshot(frame(at: 350)).latestHandoffAtNanos == 350,
            "Repeated control state must not invalidate an already displayed static screen")
        timing = ReceiverScreenTiming()
        #expect(!timing.videoEnabled)
    }
}
