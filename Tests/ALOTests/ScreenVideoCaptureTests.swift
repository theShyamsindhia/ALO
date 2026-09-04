import Testing
@testable import ALO

struct ScreenVideoCaptureTests {
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
