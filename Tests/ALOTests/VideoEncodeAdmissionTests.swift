import Testing
@testable import ALO

@Suite("Bounded video capture admission")
struct VideoEncodeAdmissionTests {
    @Test func stalledEncoderRetainsOnlyNewestWaitingFrame() throws {
        let admission = VideoEncodeAdmission<Int>()
        let first = try #require(admission.offer(0))
        for frame in 1...10_000 { #expect(admission.offer(frame) == nil) }
        let next = try #require(admission.finish(first.id))
        #expect(next.frame == 10_000)
        #expect(admission.finish(first.id) == nil)
        #expect(admission.finish(next.id) == nil)
        #expect(admission.offer(10_001)?.frame == 10_001)
    }

    @Test func stopInvalidatesQueuedAndHardwareCallbacks() throws {
        let admission = VideoEncodeAdmission<Int>()
        let first = try #require(admission.offer(0))
        #expect(admission.offer(1) == nil)
        admission.stop()
        #expect(!admission.accepts(first.id))
        #expect(admission.finish(first.id) == nil)
        #expect(admission.offer(2) == nil)
    }
}
