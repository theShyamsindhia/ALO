import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite("Playback progress")
struct PlaybackProgressTests {
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
    }
}
