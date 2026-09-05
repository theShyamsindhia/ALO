import AppKit
import Testing
@testable import ALO
import ALOCore

struct ArenaInputTests {
    @Test func bothActionLayoutsAndSimultaneousAliasesWork() {
        for codes: [UInt16] in [[38, 40, 37], [6, 7, 8]] {
            var keyboard = ArenaKeyboardInput()
            for code in codes { keyboard.press(code) }
            #expect(keyboard.input.light && keyboard.input.heavy && keyboard.input.dodge)
            keyboard.reset()
            #expect(!keyboard.input.light && !keyboard.input.heavy && !keyboard.input.dodge)
        }
        var keyboard = ArenaKeyboardInput()
        keyboard.press(38); keyboard.press(6); keyboard.release(38)
        #expect(keyboard.input.light)
        keyboard.release(6)
        #expect(!keyboard.input.light)
    }

    @Test func zAndXReachRealCombatAttacks() {
        for code: UInt16 in [38, 6, 40, 7] {
            var sim = ArenaSimulation()
            sim.countdown = 0
            sim.fighters[0].x = 400; sim.fighters[1].x = 440
            sim.fighters[0].grounded = true; sim.fighters[1].grounded = true
            sim.fighters[0].y = sim.arenaPlatforms[0].top
            sim.fighters[1].y = sim.arenaPlatforms[0].top
            var keyboard = ArenaKeyboardInput()
            keyboard.press(code)
            sim.tick([keyboard.input, ArenaInput()])
            #expect(sim.fighters[0].attackFrames > 0)
            #expect(sim.fighters[0].attackHeavy == (code == 40 || code == 7))
            keyboard.release(code)
            for _ in 0..<24 { sim.tick([keyboard.input, ArenaInput()]) }
            #expect(sim.fighters[1].damage > 0)
        }
    }

    @MainActor @Test func quickNativeAttackTapIsBufferedAndMenuDiscardsHeldKeys() throws {
        _ = NSApplication.shared
        let session = ArenaSession()
        defer { session.disconnect() }
        session.practice()
        let view = ArenaSKView(); view.session = session
        func event(_ type: NSEvent.EventType, code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        view.keyDown(with: try event(.keyDown, code: 38))
        view.keyUp(with: try event(.keyUp, code: 38))
        #expect(session.sampledInput().light)
        session.togglePause()
        view.keyDown(with: try event(.keyDown, code: 6))
        #expect(!session.sampledInput().light)
        session.closeMenu()
        view.keyDown(with: try event(.keyDown, code: 2))
        let resumed = session.sampledInput()
        #expect(resumed.horizontal == 1)
        #expect(!resumed.light && !resumed.heavy && !resumed.dodge)
    }

    @MainActor @Test func nativeFocusUpdatesControllerOwnershipAndResumeRequestsItAgain() {
        _ = NSApplication.shared
        let session = ArenaSession()
        defer { session.disconnect() }
        session.practice()
        let view = ArenaSKView()
        view.session = session
        #expect(view.becomeFirstResponder())
        #expect(session.controlsFocused)
        #expect(view.resignFirstResponder())
        #expect(!session.controlsFocused)
        let initial = session.inputFocusRequest
        session.togglePause()
        #expect(session.paused && session.showsMenu)
        session.closeMenu()
        #expect(!session.paused && !session.showsMenu)
        #expect(session.inputFocusRequest > initial)
    }
}
