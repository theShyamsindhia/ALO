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
            #expect(blur.material == .underWindowBackground)
            #expect(blur.state == .followsWindowActiveState)
            #expect(blur.convert(blur.bounds, to: hosting) == hosting.bounds)
        }
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        let split = try #require(views(in: hosting).compactMap { $0 as? NSSplitView }.first)
        #expect(split.isVertical)
        #expect(split.arrangedSubviews.count == 2)
        #expect(window.toolbar == nil)
        #expect(split.dividerColor == .clear)
        #expect(split.dividerThickness == 0)
        let nativeController = try #require(split.delegate as? NSSplitViewController)
        if nativeController.splitViewItems.first?.isCollapsed == false {
            #expect(nativeController.splitView(split, additionalEffectiveRectOfDividerAt: 0).width >= 6)
        }
        if #available(macOS 26.0, *) {
            #expect(!views(in: hosting).contains { $0.identifier?.rawValue == "ALO.Network.SidebarBlur" })
            let glass = try #require(views(in: hosting).first {
                $0.identifier?.rawValue == "ALO.Network.SidebarGlass"
            } as? NSGlassEffectView)
            #expect(glass.contentView != nil)
            #expect(glass.cornerRadius == ALONativeNetworkLayout.panelRadius)
            if nativeController.splitViewItems.first?.isCollapsed == false {
                let bounds = glass.convert(glass.bounds, to: hosting)
                #expect(abs(bounds.minY - ALONativeNetworkLayout.panelInset) < 0.5)
                #expect(abs(bounds.maxY - (hosting.bounds.height - ALONativeNetworkLayout.panelInset)) < 0.5)
            }
        } else if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let sidebar = try #require(views(in: hosting).compactMap { $0 as? NSVisualEffectView }
                .first { $0.material == .sidebar })
            #expect(sidebar.material == .sidebar)
            #expect(sidebar.state == .followsWindowActiveState)
            #expect(sidebar.alphaValue == 1)
        }
    }

    static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

}
