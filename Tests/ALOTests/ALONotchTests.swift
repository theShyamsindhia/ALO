import AppKit
import ALOCore
import ALONotchRuntime
import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct ALONotchTests {
    @Test func firstMountReplacesAppKitDefaultContentInsteadOfLeavingBlankPanel() throws {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let placeholder = try #require(panel.contentView)
        let originalHost = NSView()
        ALONotchWindowController.mountOriginalContent(in: panel) { originalHost }
        #expect(panel.contentView === originalHost)
        #expect(panel.contentView !== placeholder)
        panel.contentView = nil
        let replacement = NSView()
        ALONotchWindowController.mountOriginalContent(in: panel) { replacement }
        #expect(panel.contentView === replacement)
        panel.close()
    }

    @Test func masterSwitchPersistsWithoutChangingRoomPresentationOrFeatureChoices() throws {
        let name = "alo-notch-master-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "floatingBarHidden")
        let preferences = ALONotchPreferences(defaults: defaults)
        #expect(!preferences.enabled)
        preferences.enabled = true
        #expect(ALONotchPreferences(defaults: defaults).enabled)
        preferences.enabled = false
        #expect(!ALONotchPreferences(defaults: defaults).enabled)
        #expect(defaults.bool(forKey: "floatingBarHidden"))
    }

    @Test func emptyOrDisconnectedRoomsDoNotCreatePlaceholderCards() {
        #expect(ALONotchFeatureBridge.roomSnapshot(media: NowPlayingMedia(), isLive: true,
            audioIsRendering: false, roomName: "Room", isPlaying: false, position: nil, canControl: false) == nil)
        #expect(ALONotchFeatureBridge.roomSnapshot(media: NowPlayingMedia(title: "Track"), isLive: false,
            audioIsRendering: false, roomName: "Room", isPlaying: false, position: nil, canControl: false) == nil)
    }

    @Test func originalPlayerReceivesRoomMetadataAndOnlySupportedCommands() throws {
        let media = NowPlayingMedia(title: "Track", artist: "Artist", album: "Album",
            artworkData: Data([1, 2, 3]), isPlaying: true, elapsedTime: 20, duration: 180)
        let snapshot = try #require(ALONotchFeatureBridge.roomSnapshot(media: media, isLive: true,
            audioIsRendering: true, roomName: "Room", isPlaying: true, position: 23, canControl: true))
        #expect(snapshot.title == "Track" && snapshot.artist == "Artist" && snapshot.album == "Album")
        #expect(snapshot.artworkData == media.artworkData)
        #expect(snapshot.elapsed == 23 && snapshot.duration == 180 && snapshot.isPlaying)
        #expect(snapshot.canTogglePlayback && snapshot.canSkipNext && snapshot.canSkipPrevious)
        #expect(!snapshot.canSeek, "The room transport does not implement seek commands")
        let unavailable = try #require(ALONotchFeatureBridge.roomSnapshot(media: media, isLive: true,
            audioIsRendering: true, roomName: "Room", isPlaying: true, position: 23, canControl: false))
        #expect(!unavailable.canTogglePlayback && !unavailable.canSkipNext && !unavailable.canSkipPrevious)
    }

    @Test func liveAudioWithoutMetadataUsesTheRoomIdentity() throws {
        let snapshot = try #require(ALONotchFeatureBridge.roomSnapshot(media: NowPlayingMedia(), isLive: true,
            audioIsRendering: true, roomName: "Studio", isPlaying: true, position: nil, canControl: false))
        #expect(snapshot.title == "Live channel audio" && snapshot.artist == "Studio")
        #expect(snapshot.duration == 0 && snapshot.elapsed == 0)
    }
}
