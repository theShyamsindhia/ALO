import Foundation
import Testing
@testable import WERAI

@Suite("Broadcaster playback mode")
struct BroadcasterPlaybackModeTests {
    @Test("Direct source remains the safe fallback while the tap is unavailable")
    func directSourceFallback() {
        let mode = BroadcasterPlaybackMode.resolve(sourceMuteTapActive: false)

        #expect(mode == .directSource)
        #expect(mode.mutesSynchronizedReceiver)
        #expect(mode.activeStatus.contains("not delayed"))
    }

    @Test("An active source mute tap selects the synchronized room return")
    func synchronizedReturn() {
        let mode = BroadcasterPlaybackMode.resolve(sourceMuteTapActive: true)

        #expect(mode == .synchronizedReceiver)
        #expect(!mode.mutesSynchronizedReceiver)
        #expect(mode.activeStatus == "This Mac is playing in sync")
    }

    @Test("Tap setup is attempted once and never duplicated while consent is pending")
    func tapAttemptDecision() {
        #expect(BroadcasterPlaybackMode.shouldAttemptSourceMuteTap(
            alreadyAttempted: false,
            setupInFlight: false,
            tapActive: false
        ))
        #expect(!BroadcasterPlaybackMode.shouldAttemptSourceMuteTap(
            alreadyAttempted: true,
            setupInFlight: false,
            tapActive: false
        ))
        #expect(!BroadcasterPlaybackMode.shouldAttemptSourceMuteTap(
            alreadyAttempted: false,
            setupInFlight: true,
            tapActive: false
        ))
        #expect(!BroadcasterPlaybackMode.shouldAttemptSourceMuteTap(
            alreadyAttempted: false,
            setupInFlight: false,
            tapActive: true
        ))
    }

    @Test("A successful pending tap transfers only to a ready replacement session")
    func pendingTapAdoption() {
        #expect(BroadcasterPlaybackMode.canAdoptSuccessfulTap(
            belongsToOriginalSession: true,
            currentReceiverIsPlaying: false
        ))
        #expect(BroadcasterPlaybackMode.canAdoptSuccessfulTap(
            belongsToOriginalSession: false,
            currentReceiverIsPlaying: true
        ))
        #expect(!BroadcasterPlaybackMode.canAdoptSuccessfulTap(
            belongsToOriginalSession: false,
            currentReceiverIsPlaying: false
        ))
    }

    @Test("The app declares why optional system-audio capture is requested")
    func audioCapturePermissionMetadata() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = repositoryRoot.appending(path: "Resources/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let usage = try #require(plist["NSAudioCaptureUsageDescription"] as? String)

        #expect(!usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(usage.localizedCaseInsensitiveContains("synchron"))
    }
}
