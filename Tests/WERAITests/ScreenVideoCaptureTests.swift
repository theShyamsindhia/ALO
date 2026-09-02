import Testing
@testable import WERAI

struct ScreenVideoCaptureTests {
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
