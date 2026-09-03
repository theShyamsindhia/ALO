import Testing
@testable import WERAI

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
