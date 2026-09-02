import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import WERAICore

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias AudioHandler = (_ samples: [Int16], _ captureTimeNanos: UInt64) -> Void

    private let captureQueue = DispatchQueue(label: "in.werai.audio.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var audioHandler: AudioHandler?

    func start(audioHandler: @escaping AudioHandler) async throws {
        self.audioHandler = audioHandler

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw WERAIError("No display is available for system-audio capture.")
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(AudioPacket.sampleRate)
        configuration.channelCount = Int(AudioPacket.channelCount)
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        let captureNanos = Self.captureTimeNanos(for: sampleBuffer)

        guard outputType == .audio,
              let samples = Self.int16StereoSamples(from: sampleBuffer)
        else { return }
        audioHandler?(samples, captureNanos)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Screen and audio capture stopped: \(error.localizedDescription)\n", stderr)
    }

    private static func captureTimeNanos(for sampleBuffer: CMSampleBuffer) -> UInt64 {
        let presentationTime = sampleBuffer.presentationTimeStamp
        guard presentationTime.isValid, !presentationTime.isIndefinite else {
            return MonotonicClock.nowNanos()
        }
        let nanos = CMTimeConvertScale(
            presentationTime,
            timescale: 1_000_000_000,
            method: .default
        ).value
        return nanos >= 0 ? UInt64(nanos) : MonotonicClock.nowNanos()
    }

    private static func int16StereoSamples(from sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let formatDescription = sampleBuffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        let format = description.pointee
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mSampleRate == Double(AudioPacket.sampleRate),
              format.mChannelsPerFrame == UInt32(AudioPacket.channelCount)
        else { return nil }

        let maximumBuffers = Int(format.mChannelsPerFrame)
        let audioBufferList = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
        defer { free(audioBufferList.unsafeMutablePointer) }

        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: maximumBuffers),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }

        let frameCount = sampleBuffer.numSamples
        let flags = format.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        guard isFloat || isSignedInteger else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList.unsafeMutablePointer)
        var output = [Int16](repeating: 0, count: frameCount * Int(AudioPacket.channelCount))

        if isFloat, format.mBitsPerChannel == 32 {
            if isNonInterleaved {
                guard buffers.count >= Int(AudioPacket.channelCount) else { return nil }
                for channel in 0..<Int(AudioPacket.channelCount) {
                    guard let data = buffers[channel].mData else { return nil }
                    let source = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frameCount {
                        output[frame * 2 + channel] = quantize(source[frame])
                    }
                }
            } else {
                guard let data = buffers.first?.mData else { return nil }
                let source = data.assumingMemoryBound(to: Float.self)
                for index in output.indices {
                    output[index] = quantize(source[index])
                }
            }
            return output
        }

        if isSignedInteger, format.mBitsPerChannel == 16 {
            if isNonInterleaved {
                guard buffers.count >= Int(AudioPacket.channelCount) else { return nil }
                for channel in 0..<Int(AudioPacket.channelCount) {
                    guard let data = buffers[channel].mData else { return nil }
                    let source = data.assumingMemoryBound(to: Int16.self)
                    for frame in 0..<frameCount {
                        output[frame * 2 + channel] = Int16(littleEndian: source[frame])
                    }
                }
            } else {
                guard let data = buffers.first?.mData else { return nil }
                let source = data.assumingMemoryBound(to: Int16.self)
                for index in output.indices {
                    output[index] = Int16(littleEndian: source[index])
                }
            }
            return output
        }

        return nil
    }

    private static func quantize(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        return Int16(clamping: Int(clamped * Float(Int16.max)))
    }
}
