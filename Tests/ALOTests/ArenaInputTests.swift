import AppKit
import Testing
@testable import ALO
import ALOCore

struct ArenaInputTests {
    @Test func defaultActionsAndSimultaneousKeysWork() {
        var keyboard = ArenaKeyboardInput()
        for code: UInt16 in [38, 40, 37] { keyboard.press(code) }
        #expect(keyboard.input.light && keyboard.input.heavy && keyboard.input.dodge)
        keyboard.reset()
        #expect(!keyboard.input.light && !keyboard.input.heavy && !keyboard.input.dodge)
    }

    @Test func aimKeysDoNotPretendToBeJump() {
        var keyboard = ArenaKeyboardInput()
        keyboard.press(13)
        #expect(keyboard.input.vertical == 1)
        #expect(!keyboard.input.jump)
        keyboard.release(13); keyboard.press(1)
        #expect(keyboard.input.vertical == -1)
        #expect(!keyboard.input.jump)
        keyboard.press(49)
        #expect(keyboard.input.jump)
    }

    @Test func reboundKeysReachRealCombatAndPersist() {
        let name = "ArenaInputTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var bindings = ArenaKeyBindings.defaults
        bindings.assign(6, to: .light)
        bindings.assign(7, to: .heavy)
        bindings.save(to: defaults)
        let loaded = ArenaKeyBindings.load(from: defaults)
        #expect(loaded[.light] == 6 && loaded[.heavy] == 7)
        #expect(loaded[.dodge] == 37)
        for code: UInt16 in [6, 7] {
            var sim = ArenaSimulation()
            sim.countdown = 0
            sim.fighters[0].x = 400; sim.fighters[1].x = 440
            sim.fighters[0].grounded = true; sim.fighters[1].grounded = true
            sim.fighters[0].y = sim.arenaPlatforms[0].top
            sim.fighters[1].y = sim.arenaPlatforms[0].top
            var keyboard = ArenaKeyboardInput(bindings: loaded)
            keyboard.press(code)
            sim.tick([keyboard.input, ArenaInput()])
            #expect(sim.fighters[0].attackFrames > 0)
            #expect(sim.fighters[0].attackHeavy == (code == 7))
            keyboard.release(code)
            for _ in 0..<24 { sim.tick([keyboard.input, ArenaInput()]) }
            #expect(sim.fighters[1].damage > 0)
        }
    }

    @Test func assigningAnOccupiedKeySwapsActionsAndEscapeStaysReserved() {
        var bindings = ArenaKeyBindings.defaults
        bindings.assign(2, to: .moveLeft)
        #expect(bindings[.moveLeft] == 2)
        #expect(bindings[.moveRight] == 0)
        let before = bindings
        bindings.assign(53, to: .jump)
        #expect(bindings == before)
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
        view.keyDown(with: try event(.keyDown, code: 10))
        #expect(session.sampledInput() == resumed)
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

    @MainActor @Test func commandWIsOwnedByDetachedArenaWindow() throws {
        _ = NSApplication.shared
        let close = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                                  isARepeat: false, keyCode: 13))
        let plain = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                                  isARepeat: false, keyCode: 13))
        #expect(ArenaWindow.isCloseShortcut(close))
        #expect(!ArenaWindow.isCloseShortcut(plain))
    }
}
