import AppKit
import CoreMedia
import CoreVideo
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ALOCore

extension Notification.Name {
    static let aloWillPresentScreenPicker = Notification.Name("in.werai.screen-picker.will-present")
}

@MainActor
final class ScreenContentPicker: NSObject, SCContentSharingPickerObserver {
    nonisolated static let menuDismissDelay: Duration = .milliseconds(150)
    nonisolated static let selectionTimeout: Duration = .seconds(45)

    private var continuation: CheckedContinuation<SCContentFilter, Error>?
    private var isCancelled = false
    private var presentationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let presentationDelay: Duration
    private let timeout: Duration
    private let activateApplication: @MainActor () -> Void
    private let presentPicker: @MainActor (SCContentSharingPicker) -> Void

    init(
        presentationDelay: Duration = ScreenContentPicker.menuDismissDelay,
        timeout: Duration = ScreenContentPicker.selectionTimeout,
        activateApplication: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        },
        presentPicker: @escaping @MainActor (SCContentSharingPicker) -> Void = { picker in
            picker.present()
        }
    ) {
        self.presentationDelay = presentationDelay
        self.timeout = timeout
        self.activateApplication = activateApplication
        self.presentPicker = presentPicker
        super.init()
    }

    static func configuration(excludingBundleID bundleID: String?) -> SCContentSharingPickerConfiguration {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let bundleID { configuration.excludedBundleIDs = [bundleID] }
        return configuration
    }

    func selectDisplayOrWindow() async throws -> SCContentFilter {
        guard !isCancelled else { throw CancellationError() }
        guard continuation == nil else { throw ALOError("A screen picker is already open.") }
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
                NotificationCenter.default.post(name: .aloWillPresentScreenPicker, object: nil)
                // A transient menu-bar popover can swallow the system picker's
                // presentation. Give it one turn to close, then foreground ALO.
                presentationTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: self.presentationDelay)
                    guard !Task.isCancelled, self.continuation != nil else { return }
                    self.activateApplication()
                    self.presentPicker(picker)
                }
                timeoutTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: self.timeout)
                    guard !Task.isCancelled, self.continuation != nil else { return }
                    self.finish(
                        with: .failure(ALOError("Screen selection timed out. Try sharing again.")),
                        picker: picker
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        deactivate()
    }

    /// Keep the system picker active while its stream is alive. Deactivation
    /// happens only when sharing stops or selection fails.
    func deactivate() {
        isCancelled = true
        presentationTask?.cancel()
        presentationTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
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
            // `present()` requests a new selection and therefore reports no
            // associated stream. Ignore updates for another active app stream.
            guard stream == nil else { return }
            guard let continuation else { return }
            self.continuation = nil
            presentationTask?.cancel()
            presentationTask = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(returning: filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            guard stream == nil else { return }
            finish(with: .failure(CancellationError()), picker: picker)
        }
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
        presentationTask?.cancel()
        presentationTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        picker.remove(self)
        picker.isActive = false
        continuation.resume(with: result)
    }
}

final class ScreenVideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias Handler = (_ pixelBuffer: CVPixelBuffer, _ captureTimeNanos: UInt64) -> Void
    typealias MetadataHandler = (_ metadata: CapturedFrameMetadata) -> Void
    typealias StopHandler = (_ error: Error) -> Void

    private let queue = DispatchQueue(label: "in.werai.video.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var handler: Handler?
    private var metadataHandler: MetadataHandler?
    private var latestMetadata: CapturedFrameMetadata?
    private var stopHandler: StopHandler?
    private var stopping = false

    // Full-screen capture needs the complete display list. On macOS 15,
    // requesting only on-screen windows can also restrict the associated
    // displays returned by ScreenCaptureKit.
    static let discoversOnlyOnScreenWindows = false

    static let discoveryAttemptLimit = 20

    func start(
        displayID: CGDirectDisplayID,
        metadata: @escaping MetadataHandler = { _ in },
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
            throw ALOError(
                "This Mac's main display is not available to ScreenCaptureKit. "
                    + "Check Screen Recording access and try sharing again."
            )
        }

        let currentBundleID = Bundle.main.bundleIdentifier
        let excludedApplications = availableApplications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
                || (currentBundleID != nil && $0.bundleIdentifier == currentBundleID)
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        try await startPrepared(filter: filter, desktopOverlaySupported: !excludedApplications.isEmpty,
                                metadata: metadata, handler: handler, stopped: stopped)
    }

    func start(
        filter: SCContentFilter,
        metadata: @escaping MetadataHandler = { _ in },
        handler: @escaping Handler,
        stopped: @escaping StopHandler = { _ in }
    ) async throws {
        let selection = try await Self.excludingOwnApplication(from: filter)
        try await startPrepared(filter: selection.filter, desktopOverlaySupported: selection.desktopOverlaySupported,
                                metadata: metadata, handler: handler, stopped: stopped)
    }

    private func startPrepared(
        filter: SCContentFilter,
        desktopOverlaySupported: Bool,
        metadata: @escaping MetadataHandler,
        handler: @escaping Handler,
        stopped: @escaping StopHandler
    ) async throws {
        queue.sync {
            self.handler = handler
            self.metadataHandler = metadata
            self.latestMetadata = CapturedFrameMetadata(
                captureTimeNanos: 0,
                contentRect: .zero,
                screenRect: filter.contentRect,
                contentScale: 1,
                scaleFactor: Double(filter.pointPixelScale),
                status: .unavailable,
                desktopOverlaySupported: desktopOverlaySupported
            )
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
        // Window shadows are outside the selected window's screen rectangle.
        // Keeping them out makes the captured content and annotation bounds agree.
        configuration.ignoreShadowsSingleWindow = true

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

    /// Picker exclusions affect selection, not the pixels captured from a display.
    /// Build a filter for exactly that selected display, removing this process so
    /// every current and future annotation panel stays out of the video stream.
    /// currentProcess is explicitly consent-free; never request broader discovery
    /// to turn a picker grant into screen-recording permission.
    private static func excludingOwnApplication(
        from filter: SCContentFilter
    ) async throws -> (filter: SCContentFilter, desktopOverlaySupported: Bool) {
        // A desktop-independent window stream contains only its selected window.
        if filter.style == .window { return (filter, true) }
        guard filter.style == .display else { return (filter, false) }
        guard #available(macOS 14.4, *) else { return (filter, false) }
        let content: SCShareableContent
        do { content = try await SCShareableContent.currentProcess }
        catch {
            throw ALOError("Screen sharing could not safely exclude this app from the selected display: \(error.localizedDescription)")
        }
        let display: SCDisplay?
        if #available(macOS 15.2, *) {
            display = filter.includedDisplays.count == 1 ? filter.includedDisplays.first : nil
        } else {
            // Prior to 15.2 the picker does not expose selected display IDs. Only
            // a unique exact bounds match can preserve the original selection.
            let matches = content.displays.filter { $0.frame == filter.contentRect }
            display = matches.count == 1 ? matches.first : nil
        }
        guard let display else { return (filter, false) }
        let ownApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
                || (Bundle.main.bundleIdentifier != nil && $0.bundleIdentifier == Bundle.main.bundleIdentifier)
        }
        guard !ownApplications.isEmpty else { return (filter, false) }
        let excluded = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        if #available(macOS 14.2, *) { excluded.includeMenuBar = filter.includeMenuBar }
        return (excluded, true)
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
            metadataHandler = nil
            latestMetadata = nil
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
        guard outputType == .screen, sampleBuffer.isValid, !stopping else { return }
        let timestamp = Self.captureTimeNanos(for: sampleBuffer)
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
        let frameMetadata = Self.frameMetadata(
            attachments: attachments, captureTimeNanos: timestamp, previous: latestMetadata
        )
        latestMetadata = frameMetadata
        metadataHandler?(frameMetadata)
        guard frameMetadata.status == .complete || frameMetadata.status == .started,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        handler?(pixelBuffer, timestamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Screen sharing stopped: \(error.localizedDescription)\n", stderr)
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            let callback = self.stopHandler
            self.handler = nil
            if var metadata = self.latestMetadata {
                metadata.status = .stopped
                self.metadataHandler?(metadata)
            }
            self.metadataHandler = nil
            self.latestMetadata = nil
            self.stopHandler = nil
            self.stopping = true
            callback?(error)
        }
    }

    /// Kept separate from CMSampleBuffer parsing so resize and unavailable-frame
    /// transitions can be tested without starting screen capture or requesting access.
    static func frameMetadata(
        attachments: [SCStreamFrameInfo: Any],
        captureTimeNanos: UInt64,
        previous: CapturedFrameMetadata?
    ) -> CapturedFrameMetadata {
        let status: CapturedFrameMetadata.Status
        switch (attachments[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)) {
        case .complete: status = .complete
        case .idle: status = .idle
        case .blank: status = .blank
        case .suspended: status = .suspended
        case .started: status = .started
        case .stopped: status = .stopped
        default: status = .unavailable
        }
        return CapturedFrameMetadata(
            captureTimeNanos: captureTimeNanos,
            contentRect: attachmentRect(attachments[.contentRect]) ?? previous?.contentRect ?? .zero,
            screenRect: attachmentRect(attachments[.screenRect]) ?? previous?.screenRect,
            contentScale: (attachments[.contentScale] as? NSNumber)?.doubleValue ?? previous?.contentScale ?? 1,
            scaleFactor: (attachments[.scaleFactor] as? NSNumber)?.doubleValue ?? previous?.scaleFactor ?? 1,
            status: status,
            desktopOverlaySupported: previous?.desktopOverlaySupported ?? false
        )
    }

    private static func attachmentRect(_ value: Any?) -> CGRect? {
        if let rect = value as? CGRect { return rect }
        if let value = value as? NSValue { return value.rectValue }
        if let dictionary = value as? NSDictionary {
            return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }
        return nil
    }

    private static func captureTimeNanos(for sampleBuffer: CMSampleBuffer) -> UInt64 {
        let time = sampleBuffer.presentationTimeStamp
        guard time.isValid, !time.isIndefinite else { return MonotonicClock.nowNanos() }
        let nanos = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value
        return nanos >= 0 ? UInt64(nanos) : MonotonicClock.nowNanos()
    }
}
