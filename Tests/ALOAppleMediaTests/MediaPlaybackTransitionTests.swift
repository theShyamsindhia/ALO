import Foundation
import Testing
import ALOCore
@testable import ALOAppleMedia

struct MediaPlaybackTransitionTests {
    private func packet(_ frame: UInt64, _ capture: UInt64) -> AudioPacket {
        .init(sequence: UInt32(frame / 240), frameIndex: frame, captureTimeNanos: capture,
              samples: Array(repeating: 1, count: 480))
    }
    @Test func preparationPreservesLivePlaybackUntilCommittedBoundary() throws {
        var output = MediaPlaybackTransition()
        let old = UUID(), new = UUID()
        try output.prepare(id: old, anchor: .init(captureTimeNanos: 0, hostPlaybackTimeNanos: 100_000_000),
                           offsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try output.commit(id: old, nowNanos: 0)
        try output.prepare(id: new, anchor: .init(captureTimeNanos: 50_000_000, hostPlaybackTimeNanos: 150_000_000),
                           offsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try output.enqueue(packet(0, 0), nowNanos: 0)
        #expect(output.drain(nowNanos: 0).map(\.trackID) == [old])
        #expect(output.trackIDs == [old])
        try output.commit(id: new, nowNanos: 10_000_000)
        try output.enqueue(packet(240, 5_000_000), nowNanos: 10_000_000)
        try output.enqueue(packet(2_400, 50_000_000), nowNanos: 10_000_000)
        let scheduled = output.drain(nowNanos: 60_000_000)
        #expect(scheduled.map(\.trackID) == [old, new])
        #expect(scheduled.map { $0.buffer.renderTimeNanos } == [105_000_000, 150_000_000])
        #expect(output.activeID == old)
        _ = output.drain(nowNanos: 150_000_000)
        #expect(output.trackIDs == [new])
    }
    @Test func failedOrExpiredProposalNeverStopsPredecessor() throws {
        var output = MediaPlaybackTransition()
        let old = UUID(), new = UUID()
        try output.prepare(id: old, anchor: .init(captureTimeNanos: 0, hostPlaybackTimeNanos: 100_000_000),
                           offsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try output.commit(id: old, nowNanos: 0)
        try output.prepare(id: new, anchor: .init(captureTimeNanos: 50_000_000, hostPlaybackTimeNanos: 150_000_000),
                           offsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        #expect(throws: AppleMediaError.invalidAnchor) { try output.commit(id: new, nowNanos: 151_000_000) }
        try output.enqueue(packet(9_600, 200_000_000), nowNanos: 201_000_000)
        #expect(output.drain(nowNanos: 201_000_000).map(\.trackID) == [old])
        output.reset()
        #expect(throws: AppleMediaError.invalidAnchor) { try output.commit(id: new, nowNanos: 0) }
        #expect(output.trackIDs.isEmpty)
    }
    @Test func alreadyScheduledOverlapRejectsCommitWithoutStoppingOldTrack() throws {
        var output = MediaPlaybackTransition()
        let old = UUID(), new = UUID()
        try output.prepare(id: old, anchor: .init(captureTimeNanos: 0, hostPlaybackTimeNanos: 100_000_000),
                           offsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try output.commit(id: old, nowNanos: 0)
        try output.prepare(id: new, anchor: .init(captureTimeNanos: 50_000_000, hostPlaybackTimeNanos: 150_000_000),
                           offsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try output.enqueue(packet(2_400, 50_000_000), nowNanos: 60_000_000)
        _ = output.drain(nowNanos: 60_000_000)
        #expect(throws: AppleMediaError.invalidAnchor) { try output.commit(id: new, nowNanos: 60_000_000) }
        #expect(output.trackIDs == [old])
    }
    @Test func boundedBridgeCoalescesAndFailsClosed() {
        var tasks: [@Sendable () -> Void] = [], received: [Int] = [], failures = 0
        let bridge = BoundedMediaEventBridge<Int>(maximumEvents: 2, maximumBytes: 10,
            schedule: { tasks.append($0) }, receive: { received += $0 }, overflow: { failures += 1 })
        #expect(bridge.submit(1, byteCount: 5))
        #expect(bridge.submit(2, byteCount: 5))
        #expect(tasks.count == 1)
        #expect(!bridge.submit(3))
        tasks.removeFirst()()
        #expect(received.isEmpty)
        #expect(failures == 1)
        #expect(!bridge.submit(4))
    }
    @Test func precommitTailTransfersEvenWhenTransportDeduplicatesSuccessorCopy() throws {
        var output = MediaPlaybackTransition()
        let old = UUID(), new = UUID()
        try output.prepare(id: old, anchor: .init(captureTimeNanos: 0, hostPlaybackTimeNanos: 100_000_000),
                           offsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try output.commit(id: old, nowNanos: 0)
        // Not yet scheduled: predecessor maps this capture to 150 ms, successor
        // maps it to 200 ms. The transport already delivered this frame through
        // the old ticket, so it will not deliver another copy after commit.
        try output.enqueue(packet(2_400, 50_000_000), nowNanos: 0)
        try output.prepare(id: new, anchor: .init(captureTimeNanos: 50_000_000, hostPlaybackTimeNanos: 200_000_000),
                           offsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try output.commit(id: new, nowNanos: 0)
        let deliveries = output.drain(nowNanos: 100_000_000)
        #expect(deliveries.map(\.trackID) == [new])
        #expect(deliveries.map { $0.buffer.renderTimeNanos } == [200_000_000])
        #expect(deliveries.map { $0.buffer.token.frameIndex } == [2_400])
        #expect(deliveries.first?.buffer.samples == Array(repeating: Int16(1), count: 480))
    }
    @Test func closedBridgeDoesNotDeliverQueuedPreviousTransport() {
        var tasks: [@Sendable () -> Void] = [], received: [Int] = []
        let bridge = BoundedMediaEventBridge<Int>(schedule: { tasks.append($0) }, receive: { received += $0 }, overflow: {})
        bridge.submit(1); bridge.close(); tasks.removeFirst()()
        #expect(received.isEmpty)
    }
    @Test func clockUpdatesCannotMoveCommittedBuffersAcrossFixedCutover() throws {
        var output = MediaPlaybackTransition()
        let old = UUID(), new = UUID()
        try output.prepare(id: old, anchor: .init(captureTimeNanos: 0, hostPlaybackTimeNanos: 100_000_000),
                           offsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try output.commit(id: old, nowNanos: 0)
        try output.prepare(id: new, anchor: .init(captureTimeNanos: 50_000_000, hostPlaybackTimeNanos: 150_000_000),
                           offsetNanos: 0, outputLatencyNanos: 0, nowNanos: 0)
        try output.commit(id: new, nowNanos: 0)
        output.updateClockOffset(100_000_000)
        try output.enqueue(packet(0, 0), nowNanos: 0)
        try output.enqueue(packet(2_400, 50_000_000), nowNanos: 0)
        let deliveries = output.drain(nowNanos: 50_000_000)
        #expect(deliveries.map { $0.buffer.renderTimeNanos } == [100_000_000, 150_000_000])
        #expect(output.activeID == old)
    }
}
