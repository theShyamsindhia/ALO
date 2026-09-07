import AppKit
import SwiftUI
import Testing
@testable import ALO

@Suite(.serialized)
@MainActor
struct NetworkWindowPresentationTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NetworkSetupWindowPresentation.initialContentSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func nativeChromeAndCloseRetainReusableWindow() throws {
        let window = makeWindow()
        NetworkSetupWindowPresentation.configure(window, identityReady: true)
        #expect(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .visible)
        #expect(window.isOpaque)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.contentMinSize == NSSize(width: 640, height: 440))
        window.setContentSize(NSSize(width: 920, height: 680))
        let resized = window.frame
        window.orderOut(nil)
        // Reapplying chrome is independent of phase and must not resize content.
        NetworkSetupWindowPresentation.configure(window, identityReady: true)
        #expect(window.frame == resized)
        window.close()
        #expect(window.isReleasedWhenClosed == false)
        #expect(window.frame == resized)
    }

    @Test func onboardingChromeRemainsCustomUntilIdentityReady() {
        let window = makeWindow()
        NetworkSetupWindowPresentation.configure(window, identityReady: false)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.titleVisibility == .hidden)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(!window.isOpaque)
        NetworkSetupWindowPresentation.configure(window, identityReady: true)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.styleMask.contains(.resizable))
        window.close()
    }

    @Test func obsoleteIdentityNotificationDoesNotApplyChromeOrInitialSize() {
        #expect(!NetworkSetupWindowPresentation.shouldApplyIdentityUpdate(false, currentReady: true))
        #expect(!NetworkSetupWindowPresentation.shouldApplyIdentityUpdate(true, currentReady: false))
        #expect(NetworkSetupWindowPresentation.shouldApplyIdentityUpdate(true, currentReady: true))
        #expect(NetworkSetupWindowPresentation.shouldApplyIdentityUpdate(false, currentReady: false))
    }

    /// Only public fixture values. Does not initialize the application model,
    /// identities, discovery, or playback. Opt-in PNGs include native frame chrome.
    @Test(arguments: ["empty", "owner-empty", "member-empty", "pending", "long", "error", "populated"])
    func nativeWindowFixtures(state: String) throws {
        for dark in [false, true] {
            for size in [NSSize(width: 640, height: 440), NSSize(width: 760, height: 520)] {
                let window = makeWindow()
                NetworkSetupWindowPresentation.configure(window, identityReady: true)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                var sidebarProbe: NSView?
                window.contentView = NSHostingView(rootView: NetworkBrowserFixture(state: state,
                    onSidebarProbe: { sidebarProbe = $0 }))
                window.setContentSize(size)
                window.contentView?.layoutSubtreeIfNeeded()
                let frameView = try #require(window.contentView?.superview)
                #expect(window.contentLayoutRect.width >= size.width)
                // Render/layout before reading native geometry, including runs
                // without PNG export. Pixel dimensions alone missed a centered
                // intrinsic-width empty HStack with an unwanted leading strip.
                let bitmap = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                let probe = try #require(sidebarProbe)
                let bounds = probe.convert(probe.bounds, to: window.contentView)
                #expect(abs(bounds.minX) < 0.5)
                #expect(abs(bounds.width - 230) < 0.5)
                if let directory = ProcessInfo.processInfo.environment["ALO_NETWORK_SNAPSHOT_DIRECTORY"] {
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("\(state)-\(dark ? "dark" : "light")-\(Int(size.width)).png"))
                }
                window.close()
            }
        }
    }
}
