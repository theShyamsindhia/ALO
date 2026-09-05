import AppKit
import SwiftUI
import Testing
import ALOCore
@testable import ALO

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct RoomControlsPresentationTests {
        @Test("The setup window toggles without closing or rebuilding its content")
        func setupWindowToggle() {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 306, height: 426),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let draft = NSTextField(string: "Unfinished room name")
            window.contentView = draft
            defer { window.close() }
            let frame = window.frame

            for _ in 0..<3 {
                toggleALOSetupWindow(window)
                #expect(window.isVisible)
                toggleALOSetupWindow(window)
                #expect(!window.isVisible)
                #expect(window.contentView === draft)
                #expect(draft.stringValue == "Unfinished room name")
                #expect(window.frame == frame)
            }
        }

        @Test("Black Talk bar keeps a complete unread badge in light and dark appearances",
              arguments: [false, true], [(0, false), (1, false), (27, false), (100, false), (27, true)])
        func talkBarBadge(dark: Bool, state: (Int, Bool)) async throws {
            _ = NSApplication.shared
            let (unread, floating) = state
            let model = ALOViewModel(discoverRooms: false)
            model.participants = [RoomParticipant(id: "peer", name: "Other Mac", volume: 1,
                                                 isMuted: false, icon: "🎧", colorHex: "7C6FF2")]
            model.unreadMessageCount = unread
            let height: CGFloat = floating ? 94 : 56
            let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: floating ? 568 : 560, height: height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: WalkieTalkieBar(model: model, showsCloseButton: floating)
                .transaction { $0.disablesAnimations = true }
                .environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = hosting
            defer { window.close() }
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / height
            let backgroundY: CGFloat = floating ? 7 : 3
            let background = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(backgroundY * scale))?
                .usingColorSpace(.deviceRGB))
            #expect(background.redComponent < 0.01)
            #expect(background.greenComponent < 0.01)
            #expect(background.blueComponent < 0.01)

            var redRows = Set<Int>()
            for y in 0..<bitmap.pixelsHigh {
                for x in (bitmap.pixelsWide * 3 / 4)..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.redComponent > 0.7 && color.greenComponent < 0.4 && color.blueComponent < 0.4 {
                        redRows.insert(y)
                    }
                }
            }
            if unread == 0 {
                #expect(redRows.isEmpty)
            } else {
                // The old dock clipping removed the badge's top half.
                let top = try #require(redRows.min())
                let bottom = try #require(redRows.max())
                #expect(CGFloat(bottom - top + 1) >= 10 * scale)
                #expect(top > 0)
                #expect(bottom < bitmap.pixelsHigh - 1)
            }
            #expect(model.phase == .idle)
            #expect(model.unreadMessageCount == unread)
            if let directory = ProcessInfo.processInfo.environment["ALO_SPACES_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("talk-bar-\(unread)-\(dark ? "dark" : "light")-\(floating ? "floating" : "menu").png"))
            }
        }
    }
}
