import CoreMedia
import CoreVideo
import CoreGraphics
import Foundation
import ScreenCaptureKit
import WERAICore

final class ScreenVideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias Handler = (_ pixelBuffer: CVPixelBuffer, _ captureTimeNanos: UInt64) -> Void
    typealias StopHandler = (_ error: Error) -> Void

    private let queue = DispatchQueue(label: "in.werai.video.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var handler: Handler?
    private var stopHandler: StopHandler?
    private var stopping = false

    func start(
        displayID: CGDirectDisplayID,
        handler: @escaping Handler,
        stopped: @escaping StopHandler = { _ in }
    ) async throws {
        queue.sync {
            self.handler = handler
            self.stopHandler = stopped
            self.stopping = false
        }
        var selectedDisplay: SCDisplay?
        var availableApplications = [SCRunningApplication]()
        // WindowServer publishes a new CGVirtualDisplay asynchronously. Give it
        // a bounded moment to appear rather than intermittently failing the
        // first video start after the user grants permission.
        for attempt in 0..<12 {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            if let match = content.displays.first(where: { $0.displayID == displayID }) {
                selectedDisplay = match
                availableApplications = content.applications
                break
            }
            if attempt < 11 { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard let display = selectedDisplay else {
            throw WERAIError("ALO Display is not available for screen sharing.")
        }

        let currentBundleID = Bundle.main.bundleIdentifier
        let excludedApplications = availableApplications.filter {
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
        let accepted = queue.sync {
            guard !stopping else { return false }
            self.stream = stream
            return true
        }
        guard accepted else {
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }

    static func selectsRequestedDisplay(
        _ requested: CGDirectDisplayID,
        from available: [CGDirectDisplayID]
    ) -> CGDirectDisplayID? {
        available.first(where: { $0 == requested })
    }

    func stop() async {
        let activeStream = queue.sync {
            stopping = true
            let active = stream
            stream = nil
            handler = nil
            stopHandler = nil
            return active
        }
        try? await activeStream?.stopCapture()
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
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            let callback = self.stopHandler
            self.handler = nil
            self.stopHandler = nil
            self.stopping = true
            callback?(error)
        }
    }

    private static func captureTimeNanos(for sampleBuffer: CMSampleBuffer) -> UInt64 {
        let time = sampleBuffer.presentationTimeStamp
        guard time.isValid, !time.isIndefinite else { return MonotonicClock.nowNanos() }
        let nanos = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value
        return nanos >= 0 ? UInt64(nanos) : MonotonicClock.nowNanos()
    }
}
