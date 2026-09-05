import AppKit
import Testing
@testable import ALO

@MainActor
struct RoomTouchBarTests {
    @Test("Room Touch Bar disables actions outside a live room")
    func unavailableRoom() {
        let state = RoomTouchBarController.Availability(live: false, playback: true, broadcaster: true, localIdentity: true, busy: false, games: true)
        #expect(RoomTouchBarController.Action.allCases.allSatisfy { !state.enabled($0) })
    }
    @Test("Touch Bar local sync requires a broadcaster and a local target")
    func localSyncAvailability() {
        var state = RoomTouchBarController.Availability(live: true, playback: true, broadcaster: true, localIdentity: true, busy: false, games: true)
        #expect(state.enabled(.syncThisMac))
        state.localIdentity = false
        #expect(!state.enabled(.syncThisMac))
        #expect(state.enabled(.mute))
        state.localIdentity = true; state.broadcaster = false
        #expect(!state.enabled(.syncThisMac))
        state.broadcaster = true; state.busy = true
        #expect(!state.enabled(.syncThisMac))
        #expect(!state.enabled(.playback))
        #expect(state.enabled(.chat))
    }
    @Test("Missing Games navigation hook disables its Touch Bar item")
    func optionalGames() {
        let state = RoomTouchBarController.Availability(live: true, playback: false, broadcaster: false, localIdentity: false, busy: false, games: false)
        #expect(!state.enabled(.games))
        #expect(state.enabled(.people))
    }
}
