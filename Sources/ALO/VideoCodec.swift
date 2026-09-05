import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import ALOCore

final class VideoEncoder {
    typealias FrameHandler = (VideoFrame) -> Void

    private let queue = DispatchQueue(label: "in.werai.video.encode", qos: .userInteractive)
    private let frameHandler: FrameHandler
    private var session: VTCompressionSession?
    private var dimensions: (width: Int32, height: Int32)?
    private var hasEncodedFrame = false
    private var forceNextKeyframe = false

    func requestKeyframe() {
        queue.async { [weak self] in self?.forceNextKeyframe = true }
    }

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
            forceNextKeyframe = false
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
        let properties: CFDictionary? = forceNextKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceNextKeyframe = false
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: properties,
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
