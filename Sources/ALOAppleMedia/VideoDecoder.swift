import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import ALOCore

// Shared macOS/iOS decoder: the desktop facade reuses this implementation.
final class VideoPresentationResyncGate: @unchecked Sendable {
    struct Admission: Sendable {
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var minimumCaptureTimeNanos: UInt64?

    func reset(atOrAfterCaptureNanos cutoverCaptureNanos: UInt64?) {
        lock.withLock {
            generation &+= 1
            minimumCaptureTimeNanos = cutoverCaptureNanos
        }
    }

    func admission(forCaptureTimeNanos captureTimeNanos: UInt64) -> Admission? {
        lock.withLock {
            if let minimumCaptureTimeNanos, captureTimeNanos < minimumCaptureTimeNanos {
                return nil
            }
            return Admission(generation: generation)
        }
    }

    func isCurrent(_ admission: Admission) -> Bool {
        lock.withLock { admission.generation == generation }
    }
}

public final class VideoDecoder {
    public typealias ImageHandler = (CGImage) -> Void

    private let queue = DispatchQueue(label: "in.werai.video.decode", qos: .userInteractive)
    private let presentations: VideoPresentationQueue<CGImage>
    private let admissionLock = NSLock()
    private var pendingDecodes = 0
    private var pendingDecodeBytes = 0
    private var needsKeyframe = true
    private let imageHandler: ImageHandler
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentParameterSets: [Data] = []
    private var hasDecodedFrame = false
    private let timingLock = NSLock()
    private var clockOffsetNanos: Int64?
    private var targetLatencyNanos = RoomTiming.defaultPlayoutDelayNanos
    private let resyncGate = VideoPresentationResyncGate()

    var clockOffsetNanosForTesting: Int64? {
        timingLock.lock()
        defer { timingLock.unlock() }
        return clockOffsetNanos
    }

    public init(imageHandler: @escaping ImageHandler) {
        self.imageHandler = imageHandler
        self.presentations = VideoPresentationQueue(handler: imageHandler)
    }

    public func updateClockOffsetNanos(_ nanos: Int64) {
        timingLock.lock()
        clockOffsetNanos = nanos
        timingLock.unlock()
    }

    public func setTargetLatencyNanos(_ nanos: UInt64) {
        timingLock.lock()
        targetLatencyNanos = RoomTiming.clampedPlayoutDelay(nanos)
        timingLock.unlock()
    }

    public func accept(_ frame: VideoFrame) {
        guard presentationDeadline(for: frame.captureTimeNanos) != nil,
              let admission = resyncGate.admission(forCaptureTimeNanos: frame.captureTimeNanos) else { return }
        let byteCount = frame.payload.count + frame.parameterSet1.count + frame.parameterSet2.count
        let accepted = admissionLock.withLock {
            guard byteCount <= 12 * 1_024 * 1_024, pendingDecodes < 8,
                  pendingDecodeBytes + byteCount <= 24 * 1_024 * 1_024 else { needsKeyframe = true; return false }
            guard !needsKeyframe || frame.isKeyframe else { return false }
            needsKeyframe = false
            pendingDecodes += 1
            pendingDecodeBytes += byteCount
            return true
        }
        guard accepted else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.admissionLock.withLock { self.pendingDecodes -= 1; self.pendingDecodeBytes -= byteCount } }
            self.decodeOnQueue(frame, admission: admission)
        }
    }

    public func forceResync(atOrAfterCaptureNanos cutoverCaptureNanos: UInt64? = nil) {
        resyncGate.reset(atOrAfterCaptureNanos: cutoverCaptureNanos)
        presentations.reset()
        admissionLock.withLock { needsKeyframe = true }
        queue.async { [weak self] in
            guard let self else { return }
            if let session {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
            }
            hasDecodedFrame = false
        }
    }

    /// Invalidates both scheduled frames and the host-specific clock model.
    /// A replacement broadcaster may use a completely different monotonic
    /// epoch, so video must wait for the reconnect's fresh pong samples just
    /// like synchronized audio does.
    public func resetTiming() {
        timingLock.lock()
        clockOffsetNanos = nil
        timingLock.unlock()
        forceResync()
    }

    public func stop() {
        resyncGate.reset(atOrAfterCaptureNanos: nil)
        presentations.reset()
        admissionLock.withLock { needsKeyframe = true }
        queue.sync {
            if let session {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
            }
            session = nil
            formatDescription = nil
            currentParameterSets = []
            hasDecodedFrame = false
        }
    }

    private func decodeOnQueue(
        _ frame: VideoFrame,
        admission: VideoPresentationResyncGate.Admission
    ) {
        guard resyncGate.isCurrent(admission) else { return }
        if frame.isKeyframe, !frame.parameterSet1.isEmpty, !frame.parameterSet2.isEmpty {
            let sets = [frame.parameterSet1, frame.parameterSet2]
            if sets != currentParameterSets {
                guard configure(parameterSets: sets) else {
                    admissionLock.withLock { needsKeyframe = true }
                    return
                }
            }
        }
        guard let session, let formatDescription,
              let sampleBuffer = Self.makeSampleBuffer(frame.payload, format: formatDescription, captureTimeNanos: frame.captureTimeNanos)
        else { return }

        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let self, let imageBuffer,
                  self.resyncGate.isCurrent(admission),
                  let image = self.context.createCGImage(CIImage(cvPixelBuffer: imageBuffer), from: CIImage(cvPixelBuffer: imageBuffer).extent)
            else { return }
            if !self.hasDecodedFrame {
                self.hasDecodedFrame = true
                print("Shared screen synchronized to audio.")
            }
            self.present(
                image,
                captureTimeNanos: frame.captureTimeNanos,
                admission: admission
            )
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if status != noErr {
            admissionLock.withLock { needsKeyframe = true }
            fputs("Video decode failed: \(status)\n", stderr)
        }
    }

    private func configure(parameterSets: [Data]) -> Bool {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        currentParameterSets = []
        hasDecodedFrame = false
        guard parameterSets.count == 2, parameterSets.allSatisfy({ !$0.isEmpty }) else { return false }

        var description: CMFormatDescription?
        let status = withUnsafeTemporaryAllocation(of: UnsafePointer<UInt8>.self, capacity: 2) { pointers in
            parameterSets[0].withUnsafeBytes { first in
                parameterSets[1].withUnsafeBytes { second in
                    pointers[0] = first.bindMemory(to: UInt8.self).baseAddress!
                    pointers[1] = second.bindMemory(to: UInt8.self).baseAddress!
                    let sizes = [parameterSets[0].count, parameterSets[1].count]
                    return sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointers.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        guard status == noErr, let description else { return false }
        let size = CMVideoFormatDescriptionGetDimensions(description)
        guard size.width > 0, size.height > 0, size.width <= 4096, size.height <= 4096,
              Int64(size.width) * Int64(size.height) <= 3840 * 2160 else { return false }

        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ] as CFDictionary
        var created: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard createStatus == noErr, let created else { return false }
        formatDescription = description
        currentParameterSets = parameterSets
        session = created
        return true
    }

    private func presentationDeadline(for capture: UInt64) -> UInt64? {
        timingLock.lock()
        let offset = clockOffsetNanos
        let delay = targetLatencyNanos
        timingLock.unlock()
        guard let offset else { return nil }
        return VideoPresentationQueue<CGImage>.deadline(capture: capture, offset: offset,
            delay: delay, now: MonotonicClock.nowNanos())
    }

    private func present(_ image: CGImage, captureTimeNanos: UInt64,
                         admission: VideoPresentationResyncGate.Admission) {
        guard let deadline = presentationDeadline(for: captureTimeNanos) else { return }
        presentations.enqueue(image, deadline: deadline, bytes: image.bytesPerRow * image.height) { [resyncGate] in
            resyncGate.isCurrent(admission)
        }
    }

    private static func makeSampleBuffer(
        _ payload: Data,
        format: CMFormatDescription,
        captureTimeNanos: UInt64
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copied = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(clamping: captureTimeNanos), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }
}
