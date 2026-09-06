import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite("Playback progress")
struct PlaybackProgressTests {
    @Test @MainActor func roomClockUsesRenderingWhenPlaybackFlagIsMissingButHonorsPause() {
        let unknown = NowPlayingMedia(title: "Track", elapsedTime: 20, duration: 100)
        let paused = NowPlayingMedia(title: "Track", isPlaying: false, elapsedTime: 20, duration: 100)
        #expect(ALOViewModel.playbackPosition(media: unknown, audioIsRendering: true, elapsedSinceReceipt: 5) == 25)
        #expect(ALOViewModel.playbackPosition(media: unknown, audioIsRendering: false, elapsedSinceReceipt: 5) == 20)
        #expect(ALOViewModel.playbackPosition(media: paused, audioIsRendering: true, elapsedSinceReceipt: 5) == 20)
        #expect(ALOViewModel.playbackPosition(media: unknown, audioIsRendering: true, elapsedSinceReceipt: 200) == 100)
        #expect(ALOViewModel.playbackPosition(media: NowPlayingMedia(title: "Untimed"), audioIsRendering: true, elapsedSinceReceipt: 5) == nil)
    }

    @Test("Progress advances only while playback is active and stays bounded")
    func progressCalculation() throws {
        let playing = NowPlayingMedia(isPlaying: true, elapsedTime: 30, duration: 120)
        let paused = NowPlayingMedia(isPlaying: false, elapsedTime: 30, duration: 120)

        #expect(try #require(playing.playbackProgress(elapsedSinceReceipt: 15)) == 0.375)
        #expect(try #require(paused.playbackProgress(elapsedSinceReceipt: 15)) == 0.25)
        #expect(try #require(playing.playbackProgress(elapsedSinceReceipt: 1_000)) == 1)
        #expect(NowPlayingMedia(isPlaying: true, elapsedTime: 2, duration: 0).playbackProgress() == nil)
        #expect(NowPlayingMedia(isPlaying: true, elapsedTime: nil, duration: 120).playbackProgress() == nil)
    }

    @Test("MediaRemote timestamps advance stale elapsed values")
    func timestampAnchoring() throws {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(NowPlayingMonitor.currentElapsedTime(
            elapsedTime: 0,
            timestamp: anchor,
            playbackRate: 1,
            duration: 120,
            at: anchor.addingTimeInterval(30)
        ) == 30)
        #expect(NowPlayingMonitor.currentElapsedTime(
            elapsedTime: 118,
            timestamp: anchor,
            playbackRate: 1,
            duration: 120,
            at: anchor.addingTimeInterval(30)
        ) == 120)
        #expect(NowPlayingMonitor.currentElapsedTime(
            elapsedTime: 45,
            timestamp: anchor,
            playbackRate: 0,
            duration: 120,
            at: anchor.addingTimeInterval(30)
        ) == 45)
    }

    @Test("Source notifications preserve timing for the same track without carrying it to the next")
    func timingPreservation() throws {
        let previous = NowPlayingMedia(
            title: "Yesterday",
            artist: "The Marías",
            isPlaying: true,
            elapsedTime: 40,
            duration: 180
        )
        let paused = NowPlayingMedia(title: "Yesterday", artist: "The Marías", isPlaying: false)
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000)
        let update = NowPlayingMonitor.preservingPlaybackTiming(
            in: paused,
            from: previous,
            previousReceivedAt: anchor,
            receivedAt: anchor.addingTimeInterval(2.5)
        )

        #expect(update.elapsedTime == 42.5)
        #expect(update.duration == 180)
        let next = NowPlayingMonitor.preservingPlaybackTiming(
            in: NowPlayingMedia(title: "Next song", artist: "The Marías", isPlaying: true),
            from: update,
            previousReceivedAt: anchor,
            receivedAt: anchor.addingTimeInterval(3)
        )
        #expect(next.elapsedTime == nil)
        #expect(next.duration == nil)
    }

    @Test("Playback timing remains compatible with older room messages")
    func codingCompatibility() throws {
        let legacy = try JSONDecoder().decode(
            NowPlayingMedia.self,
            from: Data(#"{"title":"Yesterday","isPlaying":true}"#.utf8)
        )
        #expect(legacy.elapsedTime == nil)
        #expect(legacy.duration == nil)
        #expect(legacy.playbackControlsAvailable == nil)

        let current = NowPlayingMedia(
            title: "Yesterday",
            isPlaying: true,
            elapsedTime: 12.5,
            duration: 150
        )
        let roundTrip = try JSONDecoder().decode(
            NowPlayingMedia.self,
            from: JSONEncoder().encode(current)
        )
        #expect(roundTrip == current)

        let scoped = NowPlayingMedia(title: "Safari", artist: "Shared app audio",
                                     playbackControlsAvailable: false)
        let scopedRoundTrip = try JSONDecoder().decode(
            NowPlayingMedia.self,
            from: JSONEncoder().encode(scoped)
        )
        #expect(scopedRoundTrip.playbackControlsAvailable == false)
    }
}
