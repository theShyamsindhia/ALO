import Foundation
import Security
import Testing
import ALOCore
@testable import ALOAppleMedia
@testable import ALO

@Suite("Project review regressions")
struct ReviewRegressionTests {
    @Test func slicedAudioPacketAndMalformedSlices() {
        let packet = AudioPacket(sequence: 2, frameIndex: 240, captureTimeNanos: 123, samples: [1, -2])
        let data = (Data(repeating: 0, count: 13) + packet.encoded()).dropFirst(13)
        #expect(data.startIndex == 13)
        #expect(AudioPacket(data: data) == packet)
        #expect(AudioPacket(data: data.dropLast()) == nil)
        #expect(AudioPacket(data: data.dropFirst()) == nil)
    }

    @Test func counterPoisoningDoesNotPreventNextBroadcaster() {
        var replica = MeshRoomReplica()
        let bad = MeshRoomEvent(roomID: "room", version: .init(counter: .max, nodeID: "attacker"), kind: .broadcaster,
            broadcasterID: "attacker", broadcasterEpoch: .max, mediaServiceName: "bad", isBroadcasting: true)
        #expect(replica.merge([bad]).isEmpty)
        let badEpoch = MeshRoomEvent(roomID: "room", version: .init(counter: 1, nodeID: "attacker"), kind: .broadcaster,
            broadcasterID: "attacker", broadcasterEpoch: .max, mediaServiceName: "bad", isBroadcasting: true)
        #expect(replica.merge([badEpoch]).isEmpty)
        let next = MeshRoomEvent(roomID: "room", version: replica.nextVersion(nodeID: "local"), kind: .broadcaster,
            broadcasterID: "local", broadcasterEpoch: replica.highestBroadcasterEpoch + 1, mediaServiceName: "good", isBroadcasting: true)
        replica.merge([next])
        #expect(replica.broadcaster?.nodeID == "local")
        #expect(replica.logicalClock == 1)
    }

    @Test func retentionBoundsHistoryAndDoesNotResurrectStoppedBroadcaster() {
        let artwork = Data(repeating: 1, count: 20_000)
        var events = [MeshRoomEvent]()
        for counter in 1...1_000 {
            let chatVersion = MeshVersion(counter: UInt64(counter * 2), nodeID: "a")
            let playbackVersion = MeshVersion(counter: UInt64(counter * 2 + 1), nodeID: "a")
            events.append(MeshRoomEvent(id: "chat-\(counter)", roomID: "r", version: chatVersion, kind: .chat, text: "chat"))
            let media = NowPlayingMedia(title: "\(counter)", artworkData: artwork)
            events.append(MeshRoomEvent(id: "play-\(counter)", roomID: "r", version: playbackVersion, kind: .playback, nowPlaying: media))
        }
        var replica = MeshRoomReplica(events: events)
        #expect(replica.chatEvents.count == 500)
        #expect(replica.events.count == 501)
        #expect(replica.nowPlaying.title == "1000")
        #expect(replica.merge(events).isEmpty)
        let claim = MeshRoomEvent(roomID: "r", version: .init(counter: 3_000, nodeID: "a"), kind: .broadcaster,
            broadcasterID: "a", broadcasterEpoch: 1, mediaServiceName: "source", isBroadcasting: true)
        let stop = MeshRoomEvent(roomID: "r", version: .init(counter: 3_001, nodeID: "a"), kind: .broadcaster,
            broadcasterID: "a", broadcasterEpoch: 1, isBroadcasting: false)
        replica.merge([stop, claim])
        #expect(replica.broadcaster == nil)
        #expect(replica.merge([claim]).isEmpty)
        #expect(replica.broadcaster == nil)
    }

    @Test func artworkCompletionPreservesPauseAndIgnoresAnotherPlayer() throws {
        let paused = NowPlayingMedia(title: "Song", sourceURL: "https://open.spotify.com/track/abc", isPlaying: false)
        let updated = try #require(NowPlayingMonitor.applyingSpotifyArtwork(Data([1]), trackID: "abc", to: paused))
        #expect(updated.isPlaying == false)
        #expect(updated.artworkData == Data([1]))
        #expect(NowPlayingMonitor.applyingSpotifyArtwork(Data([1]), trackID: "abc", to: NowPlayingMedia(title: "Music", isPlaying: true)) == nil)
    }

    @Test func failedKeychainUpdateDoesNotDeleteOrReplaceSecret() {
        var adds = 0
        let store = RoomSecretStore(update: { _, _ in errSecInteractionNotAllowed }, add: { _ in adds += 1; return errSecSuccess })
        #expect(throws: NSError.self) { try store.write("replacement", roomID: "room") }
        #expect(adds == 0)
    }

    @Test func keychainInsertRaceRetriesUpdate() throws {
        var updates = 0, adds = 0
        let store = RoomSecretStore(update: { _, _ in updates += 1; return updates == 1 ? errSecItemNotFound : errSecSuccess },
                                   add: { _ in adds += 1; return errSecDuplicateItem })
        try store.write("secret", roomID: "room")
        #expect(updates == 2 && adds == 1)
    }

    @Test func pendingPersistenceKeepsLatestAndForgetRemovesQueuedWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomStore(fileURL: directory.appendingPathComponent("rooms.json"))
        for counter in 1...100 {
            store.saveEvents([MeshRoomEvent(roomID: "r", version: .init(counter: UInt64(counter), nodeID: "a"), kind: .chat, text: "\(counter)")], roomID: "r")
            store.saveRoomStateDocument(Data([UInt8(counter)]), roomID: "r")
        }
        #expect(store.loadEvents(roomID: "r").first?.text == "100")
        #expect(store.loadRoomStateDocument(roomID: "r") == Data([100]))
        try store.forget(roomID: "r")
        store.saveEvents([MeshRoomEvent(roomID: "r", version: .init(counter: 101, nodeID: "a"), kind: .chat, text: "stale")], roomID: "r")
        store.saveRoomStateDocument(Data([101]), roomID: "r")
        #expect(store.loadEvents(roomID: "r").isEmpty)
        #expect(store.loadRoomStateDocument(roomID: "r") == nil)
    }

    @Test func presentationBoundsRejectRemoteFutureAndReleaseOnReset() {
        final class Frame {}
        final class WeakFrame { weak var value: Frame? }
        let scheduler = VideoPresentationQueue<Frame>(now: { 1_000 }) { _ in }
        var frame: Frame? = Frame()
        let retained = WeakFrame()
        retained.value = frame
        scheduler.enqueue(frame!, deadline: 1_000 + 1_000_000_000, bytes: 1) { true }
        frame = nil
        #expect(retained.value != nil)
        for _ in 0..<20 { scheduler.enqueue(Frame(), deadline: 1_000 + 1_000_000_000, bytes: 1) { true } }
        #expect(scheduler.pendingCount == 8)
        scheduler.reset()
        #expect(retained.value == nil && scheduler.pendingCount == 0)
        scheduler.enqueue(Frame(), deadline: .max, bytes: 1) { true }
        #expect(scheduler.pendingCount == 0)
        #expect(VideoPresentationQueue<Frame>.deadline(capture: .max, offset: 0, delay: 1, now: 0) == nil)
        #expect(VideoPresentationQueue<Frame>.deadline(capture: .max, offset: .min, delay: 0, now: 0) == nil)
    }
}
