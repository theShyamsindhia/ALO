import AppKit
import SwiftUI
import Testing
import ALOCore
@testable import ALO

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct ArtworkHeaderPresentationTests {
        @Test("Album colours fill the header, change with the track, and keep text readable",
              arguments: [false, true])
        func artworkHeader(dark: Bool) async throws {
            _ = NSApplication.shared
            let model = ALOViewModel(discoverRooms: false)

            func snapshot(_ name: String) async throws -> NSBitmapImageRep {
                // Mount after the model update settles. Mounting first starts
                // the production 1.1-second palette transition, which makes a
                // fixed-delay bitmap capture dependent on runner scheduling.
                let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 560, height: 144),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let hosting = NSHostingView(rootView: VStack(spacing: 0) {
                    FloatingRoomView(model: model, presentation: .menuBar)
                    WalkieTalkieBar(model: model, showsCloseButton: false)
                }
                .transaction { $0.disablesAnimations = true }
                .environment(\.colorScheme, dark ? .dark : .light))
                window.contentView = hosting
                defer { window.close() }
                window.orderBack(nil)
                try await Task.sleep(for: .milliseconds(180))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["ALO_SPACES_SNAPSHOT_DIR"] {
                    let folder = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: folder.appendingPathComponent("artwork-header-\(name)-\(dark ? "dark" : "light").png"))
                }
                return bitmap
            }
            func waitForModel(_ condition: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(2)
                while !condition(), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(condition())
            }
            func pixel(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> NSColor {
                let scale = CGFloat(bitmap.pixelsWide) / 560
                return try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
            }
            func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
                abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
            }
            func paletteColor(_ hex: String) throws -> NSColor {
                let value = try #require(UInt64(hex, radix: 16))
                return NSColor(
                    srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1
                )
            }

            let cover = NSImage(size: NSSize(width: 60, height: 60))
            cover.lockFocus()
            for (index, color) in [NSColor.systemRed, .systemTeal, .systemPurple].enumerated() {
                color.setFill()
                NSRect(x: index * 20, y: 0, width: 20, height: 60).fill()
            }
            cover.unlockFocus()
            model.nowPlayingCallback(NowPlayingMedia(title: "Colour study", artist: "ALO", artworkData: cover.tiffRepresentation))
            try await waitForModel { model.roomArtworkPalette != nil }
            let first = try await snapshot("multicolour")
            let palette = try #require(model.roomArtworkPalette)
            #expect(Set(palette.hexes).count == 3)
            // Assert colour strength at the gradient source. Absolute snapshot
            // chroma varies with the headless runner's display pipeline.
            for color in try palette.hexes.map(paletteColor) {
                #expect(max(color.redComponent, color.greenComponent, color.blueComponent)
                    - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.09)
            }
            let samples = try [CGFloat(170), 320, 535].map { try pixel(first, x: $0, y: 6) }
            #expect(distance(samples[0], samples[1]) > 0.04)
            #expect(distance(samples[1], samples[2]) > 0.04)
            for x in stride(from: CGFloat(150), through: 540, by: 15) {
                let background = try pixel(first, x: x, y: 6)
                // The header's smaller detail text, not just its brighter title.
                let text = dark ? NSColor(srgbRed: 0.82, green: 0.82, blue: 0.80, alpha: 1)
                    : NSColor(srgbRed: 0.25, green: 0.25, blue: 0.24, alpha: 1)
                let values = [luminance(background), luminance(text)].sorted()
                #expect((values[1] + 0.05) / (values[0] + 0.05) >= 4.5)
            }
            let talkBackground = try pixel(first, x: 280, y: 91)
            #expect(max(talkBackground.redComponent, talkBackground.greenComponent, talkBackground.blueComponent) < 0.01)

            // Metadata-only updates for the same song must not flash the theme away.
            model.nowPlayingCallback(NowPlayingMedia(title: "Colour study", artist: "ALO", isPlaying: false))
            try await waitForModel { model.nowPlaying.isPlaying == false }
            _ = try await snapshot("paused")
            #expect(model.roomArtworkPalette == palette)

            // A new monochrome cover falls back to a neutral surface, not stale hues.
            cover.lockFocus()
            NSColor.gray.setFill()
            NSRect(x: 0, y: 0, width: 60, height: 60).fill()
            cover.unlockFocus()
            model.nowPlayingCallback(NowPlayingMedia(title: "Monochrome", artworkData: cover.tiffRepresentation))
            try await waitForModel { model.nowPlaying.title == "Monochrome" && model.roomArtworkPalette == nil }
            let neutral = try await snapshot("neutral")
            #expect(model.roomArtworkPalette == nil)
            let middle = try pixel(neutral, x: 320, y: 6)
            #expect(max(middle.redComponent, middle.greenComponent, middle.blueComponent)
                - min(middle.redComponent, middle.greenComponent, middle.blueComponent) < 0.02)
            #expect(distance(samples[1], middle) > 0.08)
            #expect(model.phase == .idle)
        }

        private func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }
    }
}
