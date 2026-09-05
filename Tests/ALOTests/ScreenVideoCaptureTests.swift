import Testing
import CoreGraphics
import ScreenCaptureKit
import ALOCore
@testable import ALO

struct ScreenVideoCaptureTests {
    @Test("Frame metadata uses current screen bounds when a captured window moves or resizes")
    func frameMetadataResize() {
        let initial = CapturedFrameMetadata(
            captureTimeNanos: 1, contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            contentScale: 0.5, scaleFactor: 2, status: .complete
        )
        let movedRect = CGRect(x: -1600, y: -800, width: 800, height: 600)
        let resizedContent = CGRect(x: 0, y: 0, width: 960, height: 720)
        let frame = ScreenVideoCapture.frameMetadata(
            attachments: [.status: SCFrameStatus.complete.rawValue,
                          .screenRect: movedRect.dictionaryRepresentation,
                          .contentRect: resizedContent.dictionaryRepresentation,
                          .contentScale: 0.6, .scaleFactor: 2.0],
            captureTimeNanos: 99, previous: initial
        )
        #expect(frame.captureTimeNanos == 99)
        #expect(frame.screenRect == movedRect)
        #expect(frame.contentRect == resizedContent)
        #expect(frame.contentScale == 0.6)
        #expect(frame.isInteractive)
    }

    @Test("Suspended frames retain alignment metadata but disable interaction")
    func suspendedMetadata() {
        let initial = CapturedFrameMetadata(
            captureTimeNanos: 1, contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            screenRect: CGRect(x: 40, y: 60, width: 800, height: 600),
            contentScale: 1, scaleFactor: 1, status: .complete
        )
        let frame = ScreenVideoCapture.frameMetadata(
            attachments: [.status: SCFrameStatus.suspended.rawValue], captureTimeNanos: 2, previous: initial
        )
        #expect(frame.status == .suspended)
        #expect(frame.screenRect == initial.screenRect)
        #expect(!frame.isInteractive)
        let unknown = ScreenVideoCapture.frameMetadata(attachments: [:], captureTimeNanos: 3, previous: initial)
        #expect(unknown.status == .unavailable)
        #expect(!unknown.isInteractive)
    }

    @Test("Screen picker offers one display or one window")
    @MainActor
    func pickerConfiguration() {
        let configuration = ScreenContentPicker.configuration(excludingBundleID: "in.werai.test")

        #expect(configuration.allowedPickerModes == [.singleDisplay, .singleWindow])
        #expect(!configuration.allowsChangingSelectedContent)
        #expect(configuration.excludedBundleIDs == ["in.werai.test"])
    }

    @Test("Cancelling before presentation does not leave a picker awaiting input")
    @MainActor
    func pickerPrePresentationCancellation() async {
        let picker = ScreenContentPicker()
        picker.cancel()

        await #expect(throws: CancellationError.self) {
            try await picker.selectDisplayOrWindow()
        }
    }

    @Test("Cancelling an awaiting picker resumes its caller")
    @MainActor
    func pickerPendingCancellation() async {
        var presentationEvents = [String]()
        weak var pendingPicker: ScreenContentPicker?
        let picker = ScreenContentPicker(
            presentationDelay: .zero,
            timeout: .seconds(5),
            activateApplication: { presentationEvents.append("activate") },
            presentPicker: { _ in
                presentationEvents.append("present")
                pendingPicker?.cancel()
            }
        )
        pendingPicker = picker

        await #expect(throws: CancellationError.self) {
            try await picker.selectDisplayOrWindow()
        }
        #expect(presentationEvents == ["activate", "present"])
    }

    @Test("An unresponsive system picker times out instead of hanging")
    @MainActor
    func pickerTimeout() async {
        let picker = ScreenContentPicker(
            presentationDelay: .zero,
            timeout: .milliseconds(10),
            activateApplication: {},
            presentPicker: { _ in }
        )

        do {
            _ = try await picker.selectDisplayOrWindow()
            Issue.record("Expected screen selection to time out")
        } catch {
            #expect(error.localizedDescription == "Screen selection timed out. Try sharing again.")
        }
    }

    @Test("Video capture selects only the requested display")
    func exactDisplaySelection() {
        #expect(ScreenVideoCapture.selectsRequestedDisplay(9, from: [2, 9, 4]) == 9)
        #expect(ScreenVideoCapture.selectsRequestedDisplay(7, from: [2, 9, 4]) == nil)
    }

    @Test("Full-screen capture requests the complete display list on macOS 15")
    func macOS15DiscoveryPolicy() {
        #expect(!ScreenVideoCapture.discoversOnlyOnScreenWindows)
        #expect(ScreenVideoCapture.discoveryAttemptLimit == 20)
    }
}
