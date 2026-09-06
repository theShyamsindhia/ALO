import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct NotchSettingsPresentationTests {
    @Test func openingFromMenuKeepsSettingsWithPlayerAndCollapsesUpperContent() {
        let model = ALOViewModel(discoverRooms: false)
        model.setMenuBarPopoverVisible(true)
        model.floatingBarHidden = true
        model.floatingSection = .chat
        model.showNotchSettingsBelowPlayer()
        #expect(model.notchSettingsVisible)
        #expect(model.notchSettingsHeight == 430)
        #expect(model.floatingSection == .collapsed)
        #expect(model.floatingBarHidden, "Opening inline must not move a menu-bar player into another window")
        model.notchSettingsVisible = false
        #expect(model.notchSettingsHeight == 0)
    }

    @Test func openingOutsideMenuRevealsPlayerEvenWithoutRoomMedia() {
        let model = ALOViewModel(discoverRooms: false)
        model.floatingBarHidden = true
        model.showNotchSettingsBelowPlayer()
        #expect(model.notchSettingsVisible)
        #expect(!model.floatingBarHidden)
        #expect(model.nowPlaying.isEmpty)
    }
}
