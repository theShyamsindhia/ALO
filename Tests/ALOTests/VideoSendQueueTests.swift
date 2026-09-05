import Foundation
import Testing
import ALOCore

@Suite struct VideoSendQueueTests {
    func frame(_ keyframe: Bool, bytes: Int = 8, configuration: Bool = true) -> VideoFrame {
        VideoFrame(captureTimeNanos: 0, width: 16, height: 16, isKeyframe: keyframe,
            parameterSet1: configuration && keyframe ? Data([1]) : Data(),
            parameterSet2: configuration && keyframe ? Data([2]) : Data(),
            payload: Data(repeating: 0, count: bytes))
    }

    @Test func requiresUsableIDRForJoinAndAfterOverflow() {
        var queue = VideoSendQueue(maximumFrames: 2)
        let rejectedDelta = queue.append(frame(false), nowNanos: 0)
        let rejectedMissingConfig = queue.append(frame(true, configuration: false), nowNanos: 0)
        let acceptedIDR = queue.append(frame(true), nowNanos: 0)
        let acceptedDelta = queue.append(frame(false), nowNanos: 1)
        let rejectedOverflow = queue.append(frame(false), nowNanos: 2)
        #expect(!rejectedDelta && !rejectedMissingConfig && acceptedIDR && acceptedDelta && !rejectedOverflow)
        #expect(queue.count == 0 && queue.byteCount == 0 && queue.requiresKeyframe)
        let recovered = queue.append(frame(true), nowNanos: 3)
        let next = queue.takeNext(nowNanos: 3)
        #expect(recovered && next?.frame.isKeyframe == true)
    }

    @Test func ageExpiryDropsDependentFramesToo() {
        var queue = VideoSendQueue(maximumAgeNanos: 10)
        queue.append(frame(true), nowNanos: 0)
        queue.append(frame(false), nowNanos: 5)
        let expired = queue.takeNext(nowNanos: 11)
        #expect(expired == nil)
        #expect(queue.requiresKeyframe && queue.count == 0)
        let refused = queue.append(frame(false), nowNanos: 12)
        #expect(!refused)
    }

    @Test func byteLimitAndRepeatedSlowReceiverRemainBounded() {
        var queue = VideoSendQueue(maximumBytes: 100, maximumFrames: 3)
        for tick in 0..<10_000 {
            queue.append(frame(tick.isMultiple(of: 7)), nowNanos: UInt64(tick))
            #expect(queue.byteCount <= 100 && queue.count <= 3)
        }
        let refused = queue.append(frame(true, bytes: 101), nowNanos: 10_001)
        #expect(!refused)
        #expect(queue.byteCount == 0 && queue.requiresKeyframe)
    }
}
