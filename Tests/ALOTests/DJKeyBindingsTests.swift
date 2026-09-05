import AppKit
import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct DJKeyBindingsTests {
    @Test func defaultsCoverEveryActionWithoutConflicts() {
        #expect(DJKeyBindings.defaults.count == DJAction.allCases.count)
        #expect(Set(DJKeyBindings.defaults.values).count == DJAction.allCases.count)
        for (index, key) in "1234qwerasdfzxcv".enumerated() {
            #expect(DJKeyBindings.defaults[.pad(index)] == String(key))
            #expect(DJAction.pad(index).padIndex == index)
        }
        #expect(DJKeyBindings.defaults[.stopAll] == "escape")
    }
    @Test func editsPersistRejectConflictsAndReset() throws {
        let suite = "alo.dj.keys.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let bindings = DJKeyBindings(preferences: preferences)
        try bindings.setKey("U", for: .deckAPlay)
        #expect(bindings.action(for: "u") == .deckAPlay)
        #expect(bindings.label(for: .deckAPlay) == "U")
        #expect(DJKeyBindings(preferences: preferences).key(for: .deckAPlay) == "u")
        #expect(throws: (any Error).self) { try bindings.setKey("u", for: .deckBPlay) }
        #expect(bindings.key(for: .deckBPlay) == "y")
        #expect(throws: (any Error).self) { try bindings.setKey("two", for: .deckAPlay) }
        #expect(throws: (any Error).self) { try bindings.setKey("\n", for: .deckAPlay) }
        bindings.resetDefaults()
        #expect(DJKeyBindings(preferences: preferences).mapping == DJKeyBindings.defaults)
        #expect(bindings.action(for: "\u{1b}") == .stopAll)
    }
    @Test func corruptPersistedMappingFallsBackAtomically() throws {
        let suite = "alo.dj.keys.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var saved = Dictionary(uniqueKeysWithValues: DJKeyBindings.defaults.map { ($0.key.rawValue, $0.value) })
        saved[DJAction.deckAPlay.rawValue] = "y"
        preferences.set(saved, forKey: DJKeyBindings.storageKey)
        #expect(DJKeyBindings(preferences: preferences).mapping == DJKeyBindings.defaults)
    }
}

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct DJKeyEventPolicyTests {
        @Test func typingModifiersRepeatsAndOtherWindowsAreExcluded() throws {
            _ = NSApplication.shared
            let window = DJKeyPolicyWindow(contentRect: NSRect(x: -2000, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            func event(modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false, number: Int? = nil) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: number ?? window.windowNumber, context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: repeating, keyCode: 17))
            }
            #expect(DJKeyMonitor.accepts(try event(), window: window))
            #expect(!DJKeyMonitor.accepts(try event(modifiers: .command), window: window))
            #expect(!DJKeyMonitor.accepts(try event(modifiers: .option), window: window))
            #expect(!DJKeyMonitor.accepts(try event(modifiers: .control), window: window))
            #expect(!DJKeyMonitor.accepts(try event(repeating: true), window: window))
            #expect(!DJKeyMonitor.accepts(try event(number: -1), window: window))
            let text = NSTextView(frame: window.contentView!.bounds)
            window.contentView = text
            window.makeFirstResponder(text)
            #expect(!DJKeyMonitor.accepts(try event(), window: window))
        }
    }
}

// Exercise event policy independently of which application owns desktop focus in CI.
private final class DJKeyPolicyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
