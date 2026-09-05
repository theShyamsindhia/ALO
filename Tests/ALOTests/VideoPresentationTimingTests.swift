import Foundation
import Testing
@testable import ALO

@Suite(.serialized)
struct VideoPresentationTimingTests {
    private final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        private var time: UInt64 = 1_000_000_000
        private var images: [Int] = []
        var now: UInt64 { lock.withLock { time } }
        var delivered: [Int] { lock.withLock { images } }
        func advance(to value: UInt64) { lock.withLock { time = value } }
        func accept(_ image: Int) { lock.withLock { images.append(image) } }
    }

    @Test
    func blockedMainExecutorRetainsFramesUntilPresentationCanRun() throws {
        let blocked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let presented = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            blocked.signal()
            _ = release.wait(timeout: .now() + 3)
        }
        defer { release.signal() }
        try #require(blocked.wait(timeout: .now() + 1) == .success)
        let queue = VideoPresentationQueue<Int>(now: { 1_000 }) { _ in
            #expect(Thread.isMainThread)
            presented.signal()
        }
        queue.enqueue(1, deadline: 900, bytes: 1, isCurrent: { true })
        #expect(presented.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
        #expect(queue.pendingCount == 1)
        release.signal()
        #expect(presented.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func stalledExecutorCoalescesMeasuresLatenessAndRecoversWithoutIdleFalseAlarm() throws {
        let fixture = Fixture()
        let executor = DispatchQueue(label: "test.video.blocked-presentation")
        let blocked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let presented = DispatchSemaphore(value: 0)
        executor.async { blocked.signal(); _ = release.wait(timeout: .now() + 3) }
        defer { release.signal() }
        try #require(blocked.wait(timeout: .now() + 1) == .success)
        let queue = VideoPresentationQueue<Int>(now: { fixture.now }, deliveryQueue: executor) {
            fixture.accept($0); presented.signal()
        }
        for index in 0..<20 {
            queue.enqueue(index, deadline: 810_000_000 + UInt64(index) * 10_000_000,
                          bytes: 1, isCurrent: { true })
        }
        fixture.advance(to: 1_150_000_000)
        let blockedSnapshot = queue.timingSnapshot
        #expect(blockedSnapshot.pendingCount == 8)
        #expect(blockedSnapshot.presentedCount == 0)
        #expect(blockedSnapshot.latestDeadlineMissNanos == nil)
        #expect(blockedSnapshot.oldestPendingDeadlineNanos == 930_000_000)
        release.signal()
        try #require(presented.wait(timeout: .now() + 1) == .success)
        #expect(fixture.delivered == [19])
        #expect(queue.timingSnapshot.latestDeadlineMissNanos == 150_000_000)
        #expect(queue.timingSnapshot.latestHandoffAtNanos == 1_150_000_000)

        fixture.advance(to: 1_200_000_000)
        queue.enqueue(20, deadline: fixture.now, bytes: 1, isCurrent: { true })
        try #require(presented.wait(timeout: .now() + 1) == .success)
        let recovered = queue.timingSnapshot
        #expect(fixture.delivered == [19, 20])
        #expect(recovered.latestDeadlineMissNanos == 0)
        #expect(recovered.maximumDeadlineMissNanos == 150_000_000)
        #expect(recovered.presentedCount == 2)
        #expect(recovered.pendingCount == 0)

        // A static screen produces no new handoffs: elapsed time alone must not
        // fabricate a late frame or a stall measurement.
        fixture.advance(to: 9_000_000_000)
        #expect(queue.timingSnapshot.latestHandoffAtNanos == recovered.latestHandoffAtNanos)
        #expect(queue.timingSnapshot.latestDeadlineMissNanos == 0)
        #expect(queue.timingSnapshot.oldestPendingDeadlineNanos == nil)
        queue.reset()
        #expect(queue.timingSnapshot.latestHandoffAtNanos == nil)
        #expect(queue.timingSnapshot.maximumDeadlineMissNanos == 0)
    }

    @Test
    func resetWhileExecutorIsBlockedPreventsStaleHandoffAndMeasurement() throws {
        let fixture = Fixture()
        let executor = DispatchQueue(label: "test.video.reset-presentation")
        let blocked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        executor.async { blocked.signal(); _ = release.wait(timeout: .now() + 3) }
        defer { release.signal() }
        try #require(blocked.wait(timeout: .now() + 1) == .success)
        let queue = VideoPresentationQueue<Int>(now: { fixture.now }, deliveryQueue: executor) {
            fixture.accept($0)
        }
        queue.enqueue(1, deadline: 900_000_000, bytes: 1, isCurrent: { true })
        queue.reset()
        release.signal()
        executor.sync {}
        #expect(fixture.delivered.isEmpty)
        #expect(queue.timingSnapshot.pendingCount == 0)
        #expect(queue.timingSnapshot.presentedCount == 0)
        #expect(queue.timingSnapshot.latestDeadlineMissNanos == nil)
    }
}
