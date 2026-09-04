import Foundation
import Testing
@testable import ALO
import ALOCore

@Suite("Broadcaster playback mode")
struct BroadcasterPlaybackModeTests {
    @Test("Broadcaster and listener start on the same audible timeline")
    @available(macOS 14.2, *)
    func broadcasterAndListenerStartupAlignment() {
        let tap = SystemAudioTapCapture.tapDescription(excluding: 42)
        let mode = HostSession.synchronizedPlaybackMode
        let broadcasterAudibleDelayNanos: UInt64 = mode == .directSource
            ? 0
            : RoomTiming.defaultPlayoutDelayNanos
        let listenerAudibleDelayNanos = RoomTiming.defaultPlayoutDelayNanos
        let startupOffsetNanos = broadcasterAudibleDelayNanos > listenerAudibleDelayNanos
            ? broadcasterAudibleDelayNanos - listenerAudibleDelayNanos
            : listenerAudibleDelayNanos - broadcasterAudibleDelayNanos

        #expect(tap.muteBehavior == .mutedWhenTapped)
        #expect(!mode.mutesSynchronizedReceiver)
        #expect(
            startupOffsetNanos <= 20_000_000,
            "The production broadcaster path starts \(startupOffsetNanos / 1_000_000) ms away from buffered listeners."
        )
    }

    @Test("Direct source remains the safe fallback while the tap is unavailable")
    func directSourceFallback() {
        let mode = BroadcasterPlaybackMode.resolve(
            sourceMuteTapActive: false,
            sourceMuteTapFeedsRoomAudio: false
        )

        #expect(mode == .directSource)
        #expect(mode.mutesSynchronizedReceiver)
    }

    @Test("A mute tap cannot replace SCK until its samples feed the room")
    func activeTapWithoutRoomFeedStaysSafe() {
        let mode = BroadcasterPlaybackMode.resolve(
            sourceMuteTapActive: true,
            sourceMuteTapFeedsRoomAudio: false
        )

        #expect(mode == .directSource)
        #expect(mode.mutesSynchronizedReceiver)
    }

    @Test("Only a tap that feeds the room may enable synchronized local return")
    func completeTapCaptureCanSynchronizeReturn() {
        let mode = BroadcasterPlaybackMode.resolve(
            sourceMuteTapActive: true,
            sourceMuteTapFeedsRoomAudio: true
        )

        #expect(mode == .synchronizedReceiver)
        #expect(!mode.mutesSynchronizedReceiver)
    }

    @Test("The unified tap declares its required system-audio permission")
    func unifiedTapPermissionMetadata() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appending(path: "Resources/Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let message = try #require(plist["NSAudioCaptureUsageDescription"] as? String)

        #expect(!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(message.localizedCaseInsensitiveContains("synchron"))
    }
}
