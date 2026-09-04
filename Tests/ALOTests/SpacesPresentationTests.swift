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
              arguments: [false, true], ["rooms", "empty", "private", "create", "nearby"])
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
            model.selectedRoomID = state == "private" ? "private" : "music"
            model.mode = state == "create" ? .share : .listen
            model.roomName = ""
            let initialRooms = model.savedRooms
            if state == "nearby" {
                model.nearbyRooms = [NearbyRoom(id: "music", name: "Listening room", isPrivate: false,
                    peerCount: 3, accessProof: nil, memberNames: ["Raj", "Shyam", "Bishal"],
                    trackTitle: "A song with a very long name", isPlaying: true,
                    icon: RoomIcon(symbol: "headphones", version: MeshVersion(counter: 1, nodeID: "a")))]
            }
            let window = NSWindow(
                contentRect: NSRect(x: -2000, y: 0, width: 306, height: 426),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var updateRequested = false
            let hosting = NSHostingView(rootView: ALOView(model: model, checkForUpdates: { updateRequested = true })
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
                let table = try #require(views.compactMap { $0 as? NSTableView }.first)
                #expect(table.selectedRow == -1, "Remembered rooms must not appear selected")
                if state == "private" {
                    #expect(table.visibleRect.contains(table.rect(ofRow: table.numberOfRows - 1)))
                }
            }
            // Presenting any state must never join, rename or forget a room.
            #expect(model.phase == .idle)
            #expect(model.savedRooms == initialRooms)
            #expect(model.privateRoomKey.isEmpty)
            #expect(!model.canStartSharing)
            #expect(!updateRequested)

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
