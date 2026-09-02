import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import WERAICore

final class ScreenVideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias Handler = (_ pixelBuffer: CVPixelBuffer, _ captureTimeNanos: UInt64) -> Void

    private let queue = DispatchQueue(label: "in.werai.video.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var handler: Handler?

    func start(handler: @escaping Handler) async throws {
        self.handler = handler
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw WERAIError("No display is available for screen sharing.")
        }

        let currentBundleID = Bundle.main.bundleIdentifier
        let excludedApplications = content.applications.filter {
            currentBundleID != nil && $0.bundleIdentifier == currentBundleID
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        let scale = min(1, min(1280 / Double(display.width), 720 / Double(display.height)))
        configuration.capturesAudio = false
        configuration.width = max(2, Int(Double(display.width) * scale) / 2 * 2)
        configuration.height = max(2, Int(Double(display.height) * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        handler = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        handler?(pixelBuffer, Self.captureTimeNanos(for: sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Screen sharing stopped: \(error.localizedDescription)\n", stderr)
    }

    private static func captureTimeNanos(for sampleBuffer: CMSampleBuffer) -> UInt64 {
        let time = sampleBuffer.presentationTimeStamp
        guard time.isValid, !time.isIndefinite else { return MonotonicClock.nowNanos() }
        let nanos = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value
        return nanos >= 0 ? UInt64(nanos) : MonotonicClock.nowNanos()
    }
}
