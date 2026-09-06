import Foundation
import Network
import Testing
import ALOCore
@testable import ALO

struct RoomDiscoveryTests {
    @Test func secureDiscoveryOnlyListsCurrentGeneration() throws {
        let room = RoomConfiguration.secure(name: "Current", isPrivate: false)
        let current = RoomDiscovery.record(room: room, nodeID: "a", displayName: "A", appVersion: "current",
            accessProof: nil, icon: nil, media: nil)
        var old = current; old.removeValue(forKey: "roomGeneration"); old["nodeID"] = "b"
        var future = current; future["roomGeneration"] = "999"; future["nodeID"] = "c"
        let found = RoomDiscovery.rooms(from: [current, old, future].map(NWTXTRecord.init), transportPolicy: .secureV2)
        #expect(found.count == 1)
        #expect(found.first?.peerCount == 1)
    }
    @Test func nearbyActivityAndDuplicateInterfaces() throws {
        let room = RoomConfiguration(id: "room", name: "Music")
        let icon = RoomIcon(symbol: "headphones", version: MeshVersion(counter: 2, nodeID: "a"))
        let first = RoomDiscovery.record(room: room, nodeID: "a", displayName: "Shyam",
            appVersion: "0", accessProof: nil, icon: icon,
            media: NowPlayingMedia(title: "Selfless", isPlaying: true))
        let second = RoomDiscovery.record(room: room, nodeID: "b", displayName: "Raj",
            appVersion: "0", accessProof: nil, icon: nil, media: nil)
        let discovered = try #require(RoomDiscovery.rooms(from: [first, first, second].map(NWTXTRecord.init)).first)
        #expect(discovered.peerCount == 2)
        #expect(discovered.memberNames == ["Shyam", "Raj"])
        #expect(discovered.detail == "Shyam + 1 · Selfless")
        #expect(discovered.activityHelp.contains("Raj"))
        #expect(discovered.icon == icon)
    }

    @Test func privateRoomsNeverExposeActivity() throws {
        let room = RoomConfiguration(id: "private", name: "Private", isPrivate: true, accessKey: "secret")
        var record = RoomDiscovery.record(room: room, nodeID: "a", displayName: "Shyam",
            appVersion: "0", accessProof: "proof",
            icon: RoomIcon(symbol: "heart.fill", version: MeshVersion(counter: 1, nodeID: "a")),
            media: NowPlayingMedia(title: "Private song", isPlaying: true))
        #expect(record["memberName"] == nil)
        #expect(record["trackTitle"] == nil)
        #expect(record["roomIcon"] == nil)
        #expect(!record.values.contains("secret"))
        record["memberName"] = "Should not show"
        record["trackTitle"] = "Should not show"
        let discovered = try #require(RoomDiscovery.rooms(from: [NWTXTRecord(record)]).first)
        #expect(discovered.detail == "Private · 1 person")
        #expect(discovered.memberNames.isEmpty)
        #expect(discovered.trackTitle == nil)
    }

    @Test func legacyRoomsAndBoundedText() throws {
        let old = NWTXTRecord(["roomID": "old", "roomName": "Movies", "private": "0"])
        let discovered = try #require(RoomDiscovery.rooms(from: [old]).first)
        #expect(discovered.detail == "Nearby · 1 person")
        #expect(discovered.icon == nil)
        let text = RoomDiscovery.text(String(repeating: "🧑‍🎤", count: 50) + "\n")
        #expect(text.utf8.count <= 120)
        #expect(!text.contains("\n"))
        #expect(!text.contains("�"))
    }

    @Test func pausedAndStoppedBroadcastsDoNotLookLive() throws {
        let room = RoomConfiguration(id: "room", name: "Music")
        let paused = RoomDiscovery.record(room: room, nodeID: "a", displayName: "Raj",
            appVersion: "0", accessProof: nil, icon: nil,
            media: NowPlayingMedia(title: "Selfless", isPlaying: false))
        #expect(RoomDiscovery.rooms(from: [NWTXTRecord(paused)]).first?.detail == "Raj · Paused: Selfless")
        let stopped = RoomDiscovery.record(room: room, nodeID: "a", displayName: "Raj",
            appVersion: "0", accessProof: nil, icon: nil, media: nil)
        #expect(stopped["trackTitle"] == nil)
        #expect(stopped["playing"] == nil)
        #expect(RoomDiscovery.rooms(from: [NWTXTRecord(stopped)]).first?.detail == "Raj is here")
    }
}
