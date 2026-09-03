import CoreMedia
import CoreVideo
import CoreGraphics
import Foundation
import ScreenCaptureKit
import WERAICore

@MainActor
final class ScreenContentPicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<SCContentFilter, Error>?
    private var isCancelled = false

    static func configuration(excludingBundleID bundleID: String?) -> SCContentSharingPickerConfiguration {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let bundleID { configuration.excludedBundleIDs = [bundleID] }
        return configuration
    }

    func selectDisplayOrWindow() async throws -> SCContentFilter {
        guard !isCancelled else { throw CancellationError() }
        guard continuation == nil else { throw WERAIError("A screen picker is already open.") }
        let picker = SCContentSharingPicker.shared
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                picker.defaultConfiguration = Self.configuration(
                    excludingBundleID: Bundle.main.bundleIdentifier
                )
                picker.add(self)
                picker.isActive = true
                picker.present()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        isCancelled = true
        finish(
            with: .failure(CancellationError()),
            picker: SCContentSharingPicker.shared
        )
    }

    /// Keep the system picker active while its stream is alive. Deactivation
    /// happens only when sharing stops or selection fails.
    func deactivate() {
        isCancelled = true
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in finish(with: .failure(CancellationError()), picker: picker) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            finish(with: .failure(error), picker: SCContentSharingPicker.shared)
        }
    }

    private func finish(
        with result: Result<SCContentFilter, Error>,
        picker: SCContentSharingPicker
    ) {
        guard let continuation else { return }
        self.continuation = nil
        picker.remove(self)
        picker.isActive = false
        continuation.resume(with: result)
    }
}

final class ScreenVideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias Handler = (_ pixelBuffer: CVPixelBuffer, _ captureTimeNanos: UInt64) -> Void
    typealias StopHandler = (_ error: Error) -> Void

    private let queue = DispatchQueue(label: "in.werai.video.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var handler: Handler?
    private var stopHandler: StopHandler?
    private var stopping = false

    // Full-screen capture needs the complete display list. On macOS 15,
    // requesting only on-screen windows can also restrict the associated
    // displays returned by ScreenCaptureKit.
    static let discoversOnlyOnScreenWindows = false

    static let discoveryAttemptLimit = 20

    func start(
        displayID: CGDirectDisplayID,
        handler: @escaping Handler,
        stopped: @escaping StopHandler = { _ in }
    ) async throws {
        var selectedDisplay: SCDisplay?
        var availableApplications = [SCRunningApplication]()
        // ScreenCaptureKit maintains its own display snapshot. Retry briefly if
        // the user changed the main display just before starting the broadcast.
        for attempt in 0..<Self.discoveryAttemptLimit {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: Self.discoversOnlyOnScreenWindows
            )
            if let match = content.displays.first(where: { $0.displayID == displayID }) {
                selectedDisplay = match
                availableApplications = content.applications
                break
            }
            if attempt < Self.discoveryAttemptLimit - 1 {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard let display = selectedDisplay else {
            throw WERAIError(
                "This Mac's main display is not available to ScreenCaptureKit. "
                    + "Check Screen Recording access and try sharing again."
            )
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
        try await start(filter: filter, handler: handler, stopped: stopped)
    }

    func start(
        filter: SCContentFilter,
        handler: @escaping Handler,
        stopped: @escaping StopHandler = { _ in }
    ) async throws {
        queue.sync {
            self.handler = handler
            self.stopHandler = stopped
            self.stopping = false
        }
        let configuration = SCStreamConfiguration()
        let sourceWidth = max(2, Double(filter.contentRect.width) * Double(filter.pointPixelScale))
        let sourceHeight = max(2, Double(filter.contentRect.height) * Double(filter.pointPixelScale))
        let scale = min(1, min(1280 / sourceWidth, 720 / sourceHeight))
        configuration.capturesAudio = false
        configuration.width = max(2, Int(sourceWidth * scale) / 2 * 2)
        configuration.height = max(2, Int(sourceHeight * scale) / 2 * 2)
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
