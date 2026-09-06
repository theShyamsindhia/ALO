import Testing
@testable import ALO

@MainActor
struct StickFightLibraryTests {
    @Test func builtInGameOpensWithoutDownloadingAndLibraryStopsPractice() {
        let arena = ArenaSession()
        arena.openStickFight()
        #expect(arena.selectedGameID == "stick-fight")
        #expect(!arena.loadingGame)
        #expect(arena.gameLoadError == nil)
        arena.stickFight.practice()
        #expect(arena.stickFight.playing)
        arena.returnToLibrary()
        #expect(arena.selectedGameID == nil)
        #expect(!arena.stickFight.playing)
        arena.disconnect()
    }

    @Test func roomIdentityAndDisconnectReachBuiltInGame() {
        let arena = ArenaSession()
        arena.localName = "Test fighter"
        arena.localParticipantID = "test-id"
        arena.names = ["friend": "Friend"]
        arena.send = { _, _ in }
        #expect(arena.stickFight.localName == "Test fighter")
        #expect(arena.stickFight.localParticipantID == "test-id")
        #expect(arena.stickFight.names["friend"] == "Friend")
        #expect(arena.stickFight.roomConnected)
        arena.stickFight.host()
        arena.disconnect()
        #expect(!arena.stickFight.roomConnected)
        #expect(!arena.stickFight.playing)
        #expect(arena.stickFight.lobbies.isEmpty)
    }
}
