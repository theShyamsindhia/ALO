import Foundation
import Network
import Testing
@testable import ALOCore
@testable import ALONetworking

@Suite("Peer playback timing", .serialized)
struct PeerPlaybackTimingTests {
    @Test func validatesAndExpiresWithoutInventingZero() throws {
        let value = PeerPlaybackTiming(roundTripMilliseconds: 3, driftMilliseconds: -47)
        #expect(value.isValid)
        #expect(value.isFresh(receivedAt: 10, now: 3_000_000_010))
        #expect(!value.isFresh(receivedAt: 10, now: 3_000_000_011))
        #expect(!value.isFresh(receivedAt: 10, now: 9))
        #expect(!PeerPlaybackTiming(roundTripMilliseconds: -1, driftMilliseconds: nil).isValid)
        #expect(!PeerPlaybackTiming(roundTripMilliseconds: nil, driftMilliseconds: .infinity).isValid)
        #expect(PeerPlaybackTiming.unavailable.driftMilliseconds == nil)
        let old = try JSONDecoder().decode(MeshEnvelope.self, from: Data(#"{"type":"heartbeat"}"#.utf8))
        #expect(old.playbackTiming == nil)
        var participant = RoomParticipant(id: "one", name: "One")
        participant.playbackTiming = value
        let restored = try JSONDecoder().decode(RoomParticipant.self, from: JSONEncoder().encode(participant))
        #expect(restored.playbackTiming == nil) // Diagnostic reports never persist as identity.
    }

    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var storedPort: NWEndpoint.Port?
        private var storedPeople = [RoomParticipant]()
        private var storedBroadcaster: String?
        var port: NWEndpoint.Port? { lock.withLock { storedPort } }
        var people: [RoomParticipant] { lock.withLock { storedPeople } }
        var broadcaster: String? { lock.withLock { storedBroadcaster } }
        func port(_ value: NWEndpoint.Port) { lock.withLock { storedPort = value } }
        func people(_ value: [RoomParticipant]) { lock.withLock { storedPeople = value } }
        func replica(_ value: MeshRoomReplica) { lock.withLock { storedBroadcaster = value.broadcaster?.nodeID } }
    }
    private func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return predicate()
    }
    @Test func authenticatedPeerReportsItsOwnTimingAndExpires() throws {
        let room = RoomConfiguration(id: UUID().uuidString, name: "Timing QA", isPrivate: true, accessKey: UUID().uuidString)
        let a = Probe(), b = Probe()
        let host = MeshControlPlane(room: room, nodeID: "timing-a", displayName: "Host", listenerReadyHandler: a.port,
                                    replicaHandler: a.replica, participantsHandler: a.people)
        let guest = MeshControlPlane(room: room, nodeID: "timing-b", displayName: "Guest", listenerReadyHandler: b.port,
                                     replicaHandler: b.replica, participantsHandler: b.people)
        try host.start(advertise: false); try guest.start(advertise: false)
        defer { host.stop(); guest.stop() }
        try #require(wait { b.port != nil })
        host.connectForTesting(to: .hostPort(host: "127.0.0.1", port: try #require(b.port)))
        try #require(wait { a.people.count == 2 && b.people.count == 2 })
        #expect(a.people.allSatisfy { $0.playbackTiming == nil })
        host.publishBroadcaster(active: true, mediaServiceName: "Timing test media")
        try #require(wait { b.broadcaster == "timing-a" })
        let report = PeerPlaybackTiming(roundTripMilliseconds: 7, driftMilliseconds: 53)
        guest.publishPlaybackTiming(report)
        try #require(wait { a.people.first { $0.id == "timing-b" }?.playbackTiming == report })
        #expect(a.people.first { $0.id == "timing-a" }?.playbackTiming == nil)
        try #require(wait { a.people.first { $0.id == "timing-b" }?.playbackTiming == nil })
        guest.publishPlaybackTiming(report)
        try #require(wait { a.people.first { $0.id == "timing-b" }?.playbackTiming == report })
        host.publishBroadcaster(active: false)
        try #require(wait { a.people.first { $0.id == "timing-b" }?.playbackTiming == nil })
    }
}
