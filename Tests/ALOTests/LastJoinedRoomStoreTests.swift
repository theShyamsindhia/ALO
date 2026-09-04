import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite("Last joined room restoration")
struct LastJoinedRoomStoreTests {
    @Test("The last successfully joined room survives relaunch")
    func joinedRoomSurvives() {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let room = RoomConfiguration(id: "room-a", name: "Private name")

        fixture.store.markJoined(room)

        #expect(fixture.store.roomToRestore(from: [room]) == room)
    }

    @Test("Leaving or forgetting the active room clears restoration")
    func explicitClear() {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let room = RoomConfiguration(id: "room-a", name: "Room")
        fixture.store.markJoined(room)

        fixture.store.clear(ifMatching: "different-room")
        #expect(fixture.store.roomToRestore(from: [room]) == room)

        fixture.store.clear(ifMatching: room.id)
        #expect(fixture.store.roomToRestore(from: [room]) == nil)
    }

    @Test("A forgotten or unavailable saved room removes a stale restoration marker")
    func staleRoomIsDiscarded() {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let room = RoomConfiguration(id: "room-a", name: "Room")
        fixture.store.markJoined(room)

        #expect(fixture.store.roomToRestore(from: []) == nil)
        #expect(fixture.store.roomToRestore(from: [room]) == nil)
    }

    private func fixture() -> (store: LastJoinedRoomStore, cleanup: () -> Void) {
        let suite = "in.werai.tests.last-room.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (
            LastJoinedRoomStore(defaults: defaults),
            { defaults.removePersistentDomain(forName: suite) }
        )
    }
}
