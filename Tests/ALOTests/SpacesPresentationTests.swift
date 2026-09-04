import AppKit
import SwiftUI
import Testing
import ALOCore
@testable import ALO

// These fixtures share NSApplication's native window/layout machinery.
@Suite(.serialized) @MainActor
struct NativePresentationTests {}

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct SpacesPresentationTests {
        @Test("Native Spaces fits populated, empty, private and creation states in both appearances",
              arguments: [false, true], ["rooms", "empty", "private", "create"])
        func nativePresentation(dark: Bool, state: String) async throws {
            _ = NSApplication.shared
            let model = ALOViewModel(discoverRooms: false)
            model.currentUserName = "This Mac"
            model.currentDeviceProfileImageData = nil
            model.currentDeviceIcon = "🎧"
            model.savedRooms = state == "empty" ? [] : [
                RoomConfiguration(id: "music", name: "Listening room"),
                RoomConfiguration(id: "movies", name: "Movies"),
                RoomConfiguration(id: "private", name: "Private space", isPrivate: true)
            ]
            model.selectedRoomID = state == "private" ? "private" : nil
            model.mode = state == "create" ? .share : .listen
            model.roomName = ""
            let initialRooms = model.savedRooms
            let window = NSWindow(
                contentRect: NSRect(x: -2000, y: 0, width: 306, height: 426),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: ALOView(model: model)
                .environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = hosting
            defer { window.close() }
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            hosting.layoutSubtreeIfNeeded()

            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            let views = descendants(hosting)
            if state != "create" {
                let scrollView = try #require(views.compactMap { $0 as? NSScrollView }.first)
                #expect(scrollView.frame.height > 80)
                #expect(scrollView.frame.height < 170)
                if state == "private" {
                    let table = try #require(views.compactMap { $0 as? NSTableView }.first)
                    try #require(table.selectedRow >= 0)
                    #expect(table.visibleRect.contains(table.rect(ofRow: table.selectedRow)))
                }
            }
            // Presenting any state must never join, rename or forget a room.
            #expect(model.phase == .idle)
            #expect(model.savedRooms == initialRooms)
            #expect(model.privateRoomKey.isEmpty)
            #expect(!model.canStartSharing)

            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1000)
            if let directory = ProcessInfo.processInfo.environment["ALO_SPACES_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("spaces-\(state)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
