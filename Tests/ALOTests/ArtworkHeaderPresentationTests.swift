import AppKit
import QuartzCore
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
            // Mount only after the model settles, while retaining the explicit
            // phase marker and native raster-stability barrier from integration.
            let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 560, height: 144),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: VStack(spacing: 0) {
                FloatingRoomView(model: model, presentation: .menuBar)
                WalkieTalkieBar(model: model, showsCloseButton: false)
            }
            .overlay(alignment: .bottomTrailing) {
                ArtworkRenderMarker(model: model).frame(width: 4, height: 4)
            }
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
            .environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = hosting
            defer { window.close() }
            window.orderBack(nil)

                let environment = ProcessInfo.processInfo.environment
                let folder = environment["ALO_SPACES_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? URL(fileURLWithPath: environment["RUNNER_TEMP"] ?? NSTemporaryDirectory(), isDirectory: true)
                        .appendingPathComponent("alo-artwork-snapshots", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent("artwork-header-\(name)-\(dark ? "dark" : "light").png")
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                var previousPNG: Data?
                var consecutiveFrames = 0
                var result: NSBitmapImageRep?
                var phaseWasRendered = false
                var markerDescription = "not captured"
                repeat {
                    // Drain the callback's queued model update, then explicitly
                    // commit AppKit/Core Animation display work. An offscreen
                    // window does not receive regular display-link updates.
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    hosting.layoutSubtreeIfNeeded()
                    hosting.needsDisplay = true
                    window.displayIfNeeded()
                    hosting.displayIfNeeded()
                    CATransaction.flush()
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    result = bitmap
                    let marker = try pixel(bitmap, x: 558, y: 142)
                    markerDescription = marker.description
                    // Native cacheDisplay converts through the display color
                    // profile: even a red marker can gain nonzero green/blue.
                    // Its dominant channel encodes the phase across profiles.
                    let currentPhaseRendered = switch name {
                    case "multicolour": marker.redComponent - max(marker.greenComponent, marker.blueComponent) > 0.35
                    case "paused": marker.greenComponent - max(marker.redComponent, marker.blueComponent) > 0.35
                    default: marker.blueComponent - max(marker.redComponent, marker.greenComponent) > 0.35
                    }
                    phaseWasRendered = phaseWasRendered || currentPhaseRendered
                    consecutiveFrames = currentPhaseRendered && png == previousPNG ? consecutiveFrames + 1 : 0
                    previousPNG = png
                    if consecutiveFrames >= 2 { break }
                    try await Task.sleep(for: .milliseconds(16))
                } while ContinuousClock.now < deadline
                // Keep the actual raster even on failure, without requiring CI
                // to preconfigure the optional local screenshot directory.
                if let png = previousPNG {
                    try png.write(to: destination)
                    print("Artwork snapshot: \(destination.path); phase rendered=\(phaseWasRendered), consecutive identical comparisons=\(consecutiveFrames), marker=\(markerDescription)")
                }
                try #require(consecutiveFrames >= 2,
                    "The current model state did not finish rendering; inspect \(destination.path)")
                return try #require(result)
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
            // Fixed sRGB swatches avoid OS-dependent system color palettes.
            // These three hues also stay chromatic between gradient stops;
            // complementary red/teal interpolation can correctly become gray.
            let colors = [NSColor(srgbRed: 1, green: 0.1, blue: 0.15, alpha: 1),
                          NSColor(srgbRed: 1, green: 0.9, blue: 0.1, alpha: 1),
                          NSColor(srgbRed: 0.8, green: 0.1, blue: 0.9, alpha: 1)]
            for (index, color) in colors.enumerated() {
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

/// A pixel outside the measured header and Talk samples confirms that SwiftUI
/// rendered the requested model update before checking raster stability. A
/// stable image of the previous state must never satisfy the completion barrier.
@MainActor
private struct ArtworkRenderMarker: View {
    @ObservedObject var model: ALOViewModel

    var body: some View {
        Rectangle().fill(model.nowPlaying.title == "Monochrome" ? Color(.sRGB, red: 0, green: 0, blue: 1)
            : model.nowPlaying.isPlaying == false ? Color(.sRGB, red: 0, green: 1, blue: 0)
            : model.nowPlaying.title == "Colour study" ? Color(.sRGB, red: 1, green: 0, blue: 0) : .black)
    }
}
