import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import ALOCore

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

final class VideoEncoder {
    typealias FrameHandler = (VideoFrame) -> Void

    private let queue = DispatchQueue(label: "in.werai.video.encode", qos: .userInteractive)
    private let frameHandler: FrameHandler
    private var session: VTCompressionSession?
    private var dimensions: (width: Int32, height: Int32)?
    private var hasEncodedFrame = false

    init(frameHandler: @escaping FrameHandler) {
        self.frameHandler = frameHandler
    }

    func encode(_ pixelBuffer: CVPixelBuffer, captureTimeNanos: UInt64) {
        queue.async { [weak self] in
            self?.encodeOnQueue(pixelBuffer, captureTimeNanos: captureTimeNanos)
        }
    }

    func stop() {
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
            dimensions = nil
            hasEncodedFrame = false
        }
    }

    private func encodeOnQueue(_ pixelBuffer: CVPixelBuffer, captureTimeNanos: UInt64) {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || dimensions?.width != width || dimensions?.height != height {
            guard configure(width: width, height: height) else { return }
        }
        guard let session else { return }

        let presentationTime = CMTime(value: Int64(clamping: captureTimeNanos), timescale: 1_000_000_000)
        let duration = CMTime(value: 1, timescale: 30)
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.emit(sampleBuffer, captureTimeNanos: captureTimeNanos, width: width, height: height)
        }
        if status != noErr {
            fputs("Video encode failed: \(status)\n", stderr)
        }
    }

    private func configure(width: Int32, height: Int32) -> Bool {
        if let session {
            VTCompressionSessionInvalidate(session)
        }

        var created: VTCompressionSession?
        let encoderSpecification = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            fputs("Could not start the hardware video encoder: \(status)\n", stderr)
            return false
        }

        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: 4_000_000 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(created)

        session = created
        dimensions = (width, height)
        return true
    }

    private func emit(
        _ sampleBuffer: CMSampleBuffer,
        captureTimeNanos: UInt64,
        width: Int32,
        height: Int32
    ) {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }
        let isKeyframe = !(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            .flatMap { $0 as? [[CFString: Any]] }?
            .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        let payloadLength = CMBlockBufferGetDataLength(dataBuffer)
        var payload = Data(count: payloadLength)
        let status = payload.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: payloadLength,
                destination: bytes.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else { return }

        var first = Data()
        var second = Data()
        if isKeyframe, let format = sampleBuffer.formatDescription {
            first = Self.parameterSet(format, index: 0)
            second = Self.parameterSet(format, index: 1)
        }
        frameHandler(VideoFrame(
            captureTimeNanos: captureTimeNanos,
            width: UInt32(width),
            height: UInt32(height),
            isKeyframe: isKeyframe,
            parameterSet1: first,
            parameterSet2: second,
            payload: payload
        ))
        if !hasEncodedFrame {
            hasEncodedFrame = true
            print("Screen sharing started (hardware H.264, \(width)×\(height), 30 fps).")
        }
    }

    private static func parameterSet(_ format: CMFormatDescription, index: Int) -> Data {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: index,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard status == noErr, let pointer else { return Data() }
        return Data(bytes: pointer, count: size)
    }
}

final class VideoDecoder {
    typealias ImageHandler = (CGImage) -> Void

    private let queue = DispatchQueue(label: "in.werai.video.decode", qos: .userInteractive)
    private let displayQueue = DispatchQueue(label: "in.werai.video.display", qos: .userInteractive)
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

    init(imageHandler: @escaping ImageHandler) {
        self.imageHandler = imageHandler
    }

    func updateClockOffsetNanos(_ nanos: Int64) {
        timingLock.lock()
        clockOffsetNanos = nanos
        timingLock.unlock()
    }

    func setTargetLatencyNanos(_ nanos: UInt64) {
        timingLock.lock()
        targetLatencyNanos = RoomTiming.clampedPlayoutDelay(nanos)
        timingLock.unlock()
    }

    func accept(_ frame: VideoFrame) {
        guard let admission = resyncGate.admission(
            forCaptureTimeNanos: frame.captureTimeNanos
        ) else { return }
        queue.async { [weak self] in
            self?.decodeOnQueue(frame, admission: admission)
        }
    }

    func forceResync(atOrAfterCaptureNanos cutoverCaptureNanos: UInt64? = nil) {
        resyncGate.reset(atOrAfterCaptureNanos: cutoverCaptureNanos)
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
    func resetTiming() {
        timingLock.lock()
        clockOffsetNanos = nil
        timingLock.unlock()
        forceResync()
    }

    func stop() {
        resyncGate.reset(atOrAfterCaptureNanos: nil)
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
                guard configure(parameterSets: sets) else { return }
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
        if status != noErr {
            fputs("Video decode failed: \(status)\n", stderr)
        }
    }

    private func configure(parameterSets: [Data]) -> Bool {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }

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

    private func present(
        _ image: CGImage,
        captureTimeNanos: UInt64,
        admission: VideoPresentationResyncGate.Admission
    ) {
        timingLock.lock()
        let offset = clockOffsetNanos
        let delay = targetLatencyNanos
        timingLock.unlock()
        guard let offset else { return }
        let localCapture = offset >= 0
            ? captureTimeNanos > UInt64(offset) ? captureTimeNanos - UInt64(offset) : 0
            : captureTimeNanos &+ UInt64(-offset)
        let target = localCapture &+ delay
        let now = MonotonicClock.nowNanos()
        if target <= now {
            if resyncGate.isCurrent(admission) { imageHandler(image) }
            return
        }
        displayQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: target - now))) { [imageHandler, resyncGate] in
            guard resyncGate.isCurrent(admission) else { return }
            imageHandler(image)
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
