import Foundation
import Testing
import VideoToolbox
@testable import ALO

@Suite("Bounded video capture admission")
struct VideoEncodeAdmissionTests {
    @Test func configuredSingleSlotEncoderMakesProgressWithoutAnotherSubmittedInput() {
        let admission = VideoEncodeAdmission<Int>()
        let encoder = LookaheadEncoder(minimumInputs: 2)
        let configured = VideoEncoder.configureImmediateOutput(setDelay: { delay in
            encoder.minimumInputs = delay + 1; return 0
        }, readDelay: { encoder.minimumInputs - 1 })
        #expect(configured)
        func submit(_ work: VideoEncodeAdmission<Int>.Work) {
            encoder.submit(work.frame) {
                if let next = admission.finish(work.id) { submit(next) }
            }
        }
        for frame in 0..<30 { if let work = admission.offer(frame) { submit(work) } }
        #expect(!encoder.output.isEmpty, "A one-slot encoder must not depend on a second hardware input to emit its first output")
    }

    @Test func oneSlotOutputContractRejectsUnsupportedOrIgnoredProperty() {
        var reads = 0
        let unsupported = VideoEncoder.configureImmediateOutput(setDelay: { _ in -1 }, readDelay: { reads += 1; return 0 })
        #expect(!unsupported && reads == 0)
        let ignored = VideoEncoder.configureImmediateOutput(setDelay: { _ in 0 }, readDelay: { -1 })
        #expect(!ignored)
        let unreadable = VideoEncoder.configureImmediateOutput(setDelay: { _ in 0 }, readDelay: { nil })
        #expect(!unreadable)
        let effectiveZero = VideoEncoder.configureImmediateOutput(setDelay: { _ in kVTPropertyNotSupportedErr }, readDelay: { 0 })
        #expect(effectiveZero)
        let nonzero = VideoEncoder.configureImmediateOutput(setDelay: { _ in kVTPropertyNotSupportedErr }, readDelay: { 1 })
        #expect(!nonzero)
    }
    @Test func oneSlotAdmissionRequiresAnImmediateOutputEncoderContract() {
        // Model a legal default-unlimited compression window: input N does not
        // produce output until input N+1 arrives. Exercise the production gate,
        // not a hard-coded count or a replacement admission implementation.
        let admission = VideoEncodeAdmission<Int>()
        let encoder = LookaheadEncoder(minimumInputs: 2)
        func submit(_ work: VideoEncodeAdmission<Int>.Work) {
            encoder.submit(work.frame) {
                if let next = admission.finish(work.id) { submit(next) }
            }
        }
        for frame in 0..<30 { if let work = admission.offer(frame) { submit(work) } }
        #expect(encoder.submitted == [0])
        #expect(encoder.output.isEmpty) // Neither side can release the other.
        encoder.flushOne()
        #expect(encoder.output == [0])
        #expect(encoder.submitted == [0, 29]) // Bounded newest capture was retained.
        admission.stop()
        encoder.flushOne()
        #expect(encoder.submitted == [0, 29]) // Stale completion cannot restart.
    }

    @Test func zeroLookaheadContractMakesProgressWithTheSameOneSlotGate() {
        let admission = VideoEncodeAdmission<Int>()
        let encoder = LookaheadEncoder(minimumInputs: 1)
        func submit(_ work: VideoEncodeAdmission<Int>.Work) {
            encoder.submit(work.frame) {
                if let next = admission.finish(work.id) { submit(next) }
            }
        }
        for frame in 0..<30 { if let work = admission.offer(frame) { submit(work) } }
        #expect(encoder.submitted == Array(0..<30))
        #expect(encoder.output == Array(0..<30))
    }
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

private final class LookaheadEncoder {
    var minimumInputs: Int
    var submitted: [Int] = [], output: [Int] = []
    private var pending: [(Int, () -> Void)] = []
    init(minimumInputs: Int) { self.minimumInputs = minimumInputs }
    func submit(_ frame: Int, completed: @escaping () -> Void) {
        submitted.append(frame); pending.append((frame, completed))
        if pending.count >= minimumInputs { flushOne() }
    }
    func flushOne() {
        guard !pending.isEmpty else { return }
        let item = pending.removeFirst(); output.append(item.0); item.1()
    }
}
