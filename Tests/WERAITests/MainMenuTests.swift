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

    @Test("Album artwork produces a restrained dominant accent")
    func artworkAccent() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor(red: 0.92, green: 0.18, blue: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()

        let hex = try #require(ArtworkTheme.accentHex(from: image.tiffRepresentation))
        let value = try #require(UInt64(hex, radix: 16))
        let red = (value >> 16) & 0xFF
        let green = (value >> 8) & 0xFF
        let blue = value & 0xFF
        #expect(red > green)
        #expect(red > blue)
        #expect(red < 220)
    }

    @Test("Album artwork preserves more than one usable atmosphere color")
    func artworkPalette() throws {
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        NSColor(red: 0.88, green: 0.16, blue: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 6, height: 8).fill()
        NSColor(red: 0.10, green: 0.32, blue: 0.90, alpha: 1).setFill()
        NSRect(x: 6, y: 0, width: 6, height: 8).fill()
        image.unlockFocus()

        let palette = try #require(ArtworkTheme.palette(from: image.tiffRepresentation))
        #expect(palette.hexes.count == 3)
        #expect(Set(palette.hexes).count >= 2)
    }
}
