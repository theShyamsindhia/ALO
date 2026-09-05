import CoreGraphics
import CoreVideo
import Foundation
import Testing
import ALOCore
import ALOAppleMedia
@testable import ALO

@Suite struct VideoCodecLoopbackTests {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        private var dimensions: CGSize?
        func accept(_ image: CGImage) {
            lock.withLock { dimensions = CGSize(width: image.width, height: image.height) }
        }
        var size: CGSize? { lock.withLock { dimensions } }
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
}
