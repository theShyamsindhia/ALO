import Foundation
import Testing
@testable import ALO

@Suite("Global shortcut mapper")
struct GlobalShortcutTests {
    @Test("Only Talk to everyone has a default shortcut")
    func defaultAssignment() {
        let assignments = GlobalShortcutAssignments.defaults

        #expect(assignments.bindings.count == 1)
        #expect(assignments.key(for: .talkToEveryone) == .talkToEveryoneDefault)
        #expect(GlobalShortcutKey.talkToEveryoneDefault.displayName == "⌃⇧Space")
        for action in GlobalShortcutAction.fixedActions where action != .talkToEveryone {
            #expect(assignments.key(for: action) == nil)
        }
        #expect(assignments.key(for: .talkToDevice("peer-a")) == nil)
    }

    @Test("A shortcut cannot be assigned to two actions")
    func conflictDetection() throws {
        var assignments = GlobalShortcutAssignments()
        let key = GlobalShortcutKey(
            keyCode: 18,
            modifiers: [.control, .option],
            keyLabel: "1"
        )
        let first = GlobalShortcutAction.talkToDevice("peer-a")
        let second = GlobalShortcutAction.talkToDevice("peer-b")
        try assignments.assign(key, to: first)

        #expect(throws: ShortcutAssignmentError.conflict(first)) {
            try assignments.assign(key, to: second)
        }
        #expect(assignments.key(for: first) == key)
        #expect(assignments.key(for: second) == nil)
    }

    @Test("Reassigning, clearing, and resetting are deterministic")
    func mutations() throws {
        let custom = GlobalShortcutKey(
            keyCode: 19,
            modifiers: [.command, .shift],
            keyLabel: "2"
        )
        var assignments = GlobalShortcutAssignments.defaults
        try assignments.assign(custom, to: .talkToEveryone)
        #expect(assignments.key(for: .talkToEveryone) == custom)

        assignments.clear(.talkToEveryone)
        #expect(assignments.bindings.isEmpty)

        assignments.reset()
        #expect(assignments == .defaults)
    }

    @Test("Device shortcuts persist by stable participant ID")
    func deviceIdentityPersistence() throws {
        let action = GlobalShortcutAction.talkToDevice("stable-peer-id")
        let key = GlobalShortcutKey(
            keyCode: 20,
            modifiers: [.control, .shift],
            keyLabel: "3"
        )
        var original = GlobalShortcutAssignments()
        try original.assign(key, to: action)

        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(GlobalShortcutAssignments.self, from: encoded)

        // A rename changes only the participant's display name, so the same
        // stable ID still resolves the binding.
        let renamedDeviceAction = GlobalShortcutAction.talkToDevice("stable-peer-id")
        #expect(restored.key(for: renamedDeviceAction) == key)
    }

    @Test("Modifier glyphs are displayed in a stable macOS order")
    func displayName() {
        let key = GlobalShortcutKey(
            keyCode: 0,
            modifiers: [.command, .option, .control, .shift],
            keyLabel: "A"
        )
        #expect(key.displayName == "⌃⌥⇧⌘A")
    }

    @Test("Press state emits one down and one matching up event")
    func pressState() {
        var state = GlobalShortcutPressState()
        let firstDown = state.shouldDispatch(id: 7, pressed: true)
        let repeatedDown = state.shouldDispatch(id: 7, pressed: true)
        let matchingUp = state.shouldDispatch(id: 7, pressed: false)
        let repeatedUp = state.shouldDispatch(id: 7, pressed: false)
        #expect(firstDown)
        #expect(!repeatedDown)
        #expect(matchingUp)
        #expect(!repeatedUp)
    }
}
