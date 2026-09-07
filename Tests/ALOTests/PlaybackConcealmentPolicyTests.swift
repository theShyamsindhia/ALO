import Testing
@testable import ALO

struct PlaybackConcealmentPolicyTests {
    @Test func allSuccessorSelectionUsesForwardWrapOrder() {
        #expect(PlaybackConcealmentPolicy.earliestSequence([0, 1, .max], from: .max - 1) == .max)
        #expect(PlaybackConcealmentPolicy.earliestSequence([0, 1, .max], from: 0) == 0)
        #expect(PlaybackConcealmentPolicy.earliestSequence([.max], from: 0) == nil)
    }
    @Test func timelySingleLossAndWrapPreserveExactSourceFrames() {
        #expect(PlaybackConcealmentPolicy.canFill(expectedSequence: 1, nextSequence: 2,
            sourceEndFrame: 120, nextFrame: 360, missingRenderNanos: 101, nowNanos: 100))
        #expect(PlaybackConcealmentPolicy.canFill(expectedSequence: .max, nextSequence: 0,
            sourceEndFrame: 240, nextFrame: 480, missingRenderNanos: 101, nowNanos: 100))
    }
    @Test func expiredHugeAmbiguousAndOverflowRangesCannotBackfill() {
        for packets: UInt32 in [0, 11, 200, .max] {
            #expect(!PlaybackConcealmentPolicy.canFill(expectedSequence: 0, nextSequence: packets,
                sourceEndFrame: 0, nextFrame: UInt64(packets) * 240, missingRenderNanos: 101, nowNanos: 100))
        }
        for time: UInt64? in [nil, 0, 100] {
            #expect(!PlaybackConcealmentPolicy.canFill(expectedSequence: 1, nextSequence: 2,
                sourceEndFrame: 240, nextFrame: 480, missingRenderNanos: time, nowNanos: 100))
        }
        for frame: UInt64 in [0, 239, 241, .max] {
            #expect(!PlaybackConcealmentPolicy.canFill(expectedSequence: 1, nextSequence: 2,
                sourceEndFrame: 240, nextFrame: frame, missingRenderNanos: 101, nowNanos: 100))
        }
        #expect(!PlaybackConcealmentPolicy.canFill(expectedSequence: 1, nextSequence: 2,
            sourceEndFrame: .max, nextFrame: 0, missingRenderNanos: .max, nowNanos: 100))
    }
}
