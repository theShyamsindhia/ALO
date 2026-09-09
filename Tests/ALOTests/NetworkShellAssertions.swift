import AppKit
import Testing
import ALONetworkUI

@MainActor
enum NetworkShellAssertions {
    static func verify(_ hosting: NSView, in window: NSWindow) throws {
        let effect = views(in: hosting).first {
            $0.identifier?.rawValue == "ALO.Network.WindowBlur"
        } as? NSVisualEffectView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            #expect(effect == nil)
        } else {
            let blur = try #require(effect)
            #expect(blur.blendingMode == .behindWindow)
            #expect(blur.material == .sidebar)
            #expect(blur.state == .followsWindowActiveState)
            #expect(blur.convert(blur.bounds, to: hosting) == hosting.bounds)
        }
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        // Test rendered header actions, not SwiftUI's lazy accessibility tree
        // (which can be empty in a test process without an accessibility client).
        // A vertically centered empty-state stack puts these below this band.
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let left = Int((ALONativeNetworkLayout.sidebarWidth(for: hosting.bounds.width) + 16) * scale)
        let right = bitmap.pixelsWide - Int(16 * scale)
        var bluePixels = 0
        for y in Int(8 * scale)..<Int(60 * scale) {
            for x in left..<right {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.blueComponent > 0.6, color.redComponent < 0.4,
                   color.blueComponent > color.greenComponent * 1.25 {
                    bluePixels += 1
                }
            }
        }
        #expect(bluePixels > 4)
    }

    static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

}
