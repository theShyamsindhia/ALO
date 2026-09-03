import AppKit
import Testing
@testable import WERAI

@MainActor
struct MainMenuTests {
    @Test("Edit menu sends standard shortcuts through the first responder")
    func editCommands() {
        let editMenu = makeALOEditMenu()
        let commands: [String: (String, String, NSEvent.ModifierFlags)] = Dictionary(
            uniqueKeysWithValues: editMenu.items.compactMap { item in
                guard !item.isSeparatorItem, let action = item.action else { return nil }
                return (item.title, (NSStringFromSelector(action), item.keyEquivalent, item.keyEquivalentModifierMask))
            }
        )

        #expect(commands["Undo"]?.0 == "undo:")
        #expect(commands["Redo"]?.0 == "redo:")
        #expect(commands["Cut"]?.0 == "cut:")
        #expect(commands["Copy"]?.0 == "copy:")
        #expect(commands["Paste"]?.0 == "paste:")
        #expect(commands["Paste and Match Style"]?.0 == "pasteAsPlainText:")
        #expect(commands["Delete"]?.0 == "delete:")
        #expect(commands["Select All"]?.0 == "selectAll:")
        #expect(commands["Select All"]?.1 == "a")
        #expect(commands["Select All"]?.2 == NSEvent.ModifierFlags.command)
        #expect(commands["Redo"]?.2 == NSEvent.ModifierFlags([.command, .shift]))
        #expect(editMenu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target == nil })
    }
}
