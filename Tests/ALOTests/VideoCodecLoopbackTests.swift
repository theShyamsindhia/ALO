import CoreGraphics
import CoreVideo
import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite struct VideoCodecLoopbackTests {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        private var dimensions: CGSize?
        private var images = 0
        func accept(_ image: CGImage) {
            lock.withLock { dimensions = CGSize(width: image.width, height: image.height); images += 1 }
        }
        var size: CGSize? { lock.withLock { dimensions } }
        var count: Int { lock.withLock { images } }
    }

    @Test func syntheticH264FrameReachesSharedDecoderAndScheduledPresentation() async throws {
        let output = Output()
        let decoder = VideoDecoder { output.accept($0) }
        decoder.updateClockOffsetNanos(0)
        decoder.setTargetLatencyNanos(RoomTiming.defaultPlayoutDelayNanos)
        let encoder = VideoEncoder { decoder.accept($0) }
        defer { encoder.stop(); decoder.stop() }

        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(created)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        let address = try #require(CVPixelBufferGetBaseAddress(buffer))
        address.initializeMemory(as: UInt8.self, repeating: 255,
            count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        encoder.encode(buffer, captureTimeNanos: MonotonicClock.nowNanos())
        // Flush the finite synthetic input; unlike a real capture stream there
        // will be no following frames to prompt the encoder to drain.
        encoder.stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while output.size == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(output.size == CGSize(width: 64, height: 64))
    }

    @Test func droppingAReferenceFrameForTimingRequiresANewKeyframeButStaleResyncFramesDoNot() async throws {
        let fixture = try encodedFixture()
        let output = Output()
        let decoder = VideoDecoder { output.accept($0) }
        decoder.updateClockOffsetNanos(0)
        defer { decoder.stop() }
        decoder.accept(retimed(fixture, capture: MonotonicClock.nowNanos()))
        let firstPresented = try await waitForImages(1, output: output)
        #expect(firstPresented)
        #expect(!decoder.requiresKeyframeForTesting)

        // The payload is genuine encoder output; only its timestamp is moved
        // beyond the presentation queue's bounded future horizon.
        decoder.accept(retimed(fixture, capture: MonotonicClock.nowNanos() + 3_000_000_000))
        #expect(decoder.requiresKeyframeForTesting, "Dropping a reference frame must close dependent-frame admission")
        decoder.accept(retimed(fixture, capture: MonotonicClock.nowNanos(), keyframe: false))
        #expect(decoder.requiresKeyframeForTesting, "A following P-frame cannot repair the missing reference")

        let cutover = MonotonicClock.nowNanos()
        decoder.forceResync(atOrAfterCaptureNanos: cutover)
        decoder.accept(retimed(fixture, capture: cutover))
        let freshPresented = try await waitForImages(2, output: output)
        #expect(freshPresented)
        #expect(!decoder.requiresKeyframeForTesting)
        decoder.accept(retimed(fixture, capture: cutover - 1))
        #expect(!decoder.requiresKeyframeForTesting, "A pre-cutover frame must not invalidate the fresh generation")
    }

    @Test func asynchronousDecodeErrorRequiresKeyframeOnlyForCurrentGeneration() async throws {
        let fixture = try encodedFixture()
        let output = Output()
        let decoder = VideoDecoder { output.accept($0) }
        decoder.updateClockOffsetNanos(0)
        defer { decoder.stop() }
        let firstCapture = MonotonicClock.nowNanos()
        decoder.accept(retimed(fixture, capture: firstCapture))
        let firstPresented = try await waitForImages(1, output: output)
        #expect(firstPresented)
        #expect(!decoder.requiresKeyframeForTesting)
        let oldCompletion = try #require(decoder.decodeStatusHandlerForTesting(captureTimeNanos: firstCapture))
        #expect(!oldCompletion(-1))
        #expect(decoder.requiresKeyframeForTesting, "An asynchronous decoder failure must close dependent-frame admission")

        let cutover = MonotonicClock.nowNanos()
        decoder.forceResync(atOrAfterCaptureNanos: cutover)
        decoder.accept(retimed(fixture, capture: cutover))
        let freshPresented = try await waitForImages(2, output: output)
        #expect(freshPresented)
        #expect(!decoder.requiresKeyframeForTesting)
        #expect(!oldCompletion(-1))
        #expect(!decoder.requiresKeyframeForTesting, "A stale asynchronous error must not invalidate a fresh reference chain")
        let freshCompletion = try #require(decoder.decodeStatusHandlerForTesting(captureTimeNanos: cutover))
        #expect(freshCompletion(0))
        #expect(!decoder.requiresKeyframeForTesting)
        #expect(!freshCompletion(-1))
        #expect(decoder.requiresKeyframeForTesting)
    }

    private func retimed(_ frame: VideoFrame, capture: UInt64, keyframe: Bool = true) -> VideoFrame {
        VideoFrame(captureTimeNanos: capture, width: frame.width, height: frame.height, isKeyframe: keyframe,
                   parameterSet1: frame.parameterSet1, parameterSet2: frame.parameterSet2, payload: frame.payload)
    }
    private func waitForImages(_ count: Int, output: Output) async throws -> Bool {
        for _ in 0..<250 {
            if output.count >= count { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return output.count >= count
    }
    private func encodedFixture() throws -> VideoFrame {
        final class Frames: @unchecked Sendable {
            let lock = NSLock()
            var values: [VideoFrame] = []
        }
        let frames = Frames()
        let encoder = VideoEncoder { frame in frames.lock.withLock { frames.values.append(frame) } }
        defer { encoder.stop() }
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(created)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        let address = try #require(CVPixelBufferGetBaseAddress(buffer))
        address.initializeMemory(as: UInt8.self, repeating: 127,
            count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        encoder.encode(buffer, captureTimeNanos: MonotonicClock.nowNanos())
        encoder.stop()
        return try #require(frames.lock.withLock { frames.values.first })
    }
}
