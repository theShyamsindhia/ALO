import AppKit
import SwiftUI
import Testing
import ALONetworkUI
@testable import ALO

extension NativePresentationTests {
@Suite(.serialized)
@MainActor
struct NetworkWindowPresentationTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NetworkBrowserWindow(contentRect: NSRect(origin: .zero, size: NetworkSetupWindowPresentation.initialContentSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func nativeSidebarToggleResizesAndRestoresWithoutLosingDraft() async throws {
        let window = makeWindow()
        defer { window.close() }
        NetworkSetupWindowPresentation.configure(window, identityReady: true)
        let state = SidebarFixtureState()
        var detail: NSView?
        let host = NSHostingView(rootView: SidebarToggleFixture(state: state, onDetail: { detail = $0 }))
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(350))
        window.setContentSize(NSSize(width: 960, height: 700))
        host.layoutSubtreeIfNeeded()
        let split = try #require(NetworkShellAssertions.views(in: host).compactMap { $0 as? NSSplitView }.first)
        let controller = try #require(split.delegate as? NSSplitViewController)
        let sidebar = try #require(controller.splitViewItems.first)
        #expect(sidebar.canCollapse)
        #expect(window.toolbar == nil)
        let originalDetail = try #require(detail)
        let initialWidth = originalDetail.bounds.width
        split.setPosition(230, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        let sidebarWidth = split.arrangedSubviews[0].frame.width
        #expect(abs(sidebarWidth - 230) < 2)
        state.draft = "Keep this draft"
        let menu = makeALOViewMenu()
        let item = try #require(menu.items.first)
        #expect(item.action == #selector(NetworkBrowserWindow.toggleNetworkSidebar(_:)))
        #expect(item.keyEquivalentModifierMask == [.command, .control])
        // This is the native command used by both the menu and toolbar.
        window.makeFirstResponder(originalDetail)
        #expect(window.firstResponder?.tryToPerform(try #require(item.action), with: item) == true)
        // A sidebar transition must not move or snap the window controls.
        for _ in 0..<24 {
            window.update()
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                let button = try #require(window.standardWindowButton(type))
                let bounds = button.convert(button.bounds, to: nil)
                #expect(abs(bounds.midX - (30 + CGFloat(index) * 20)) < 0.5)
                #expect(abs(window.frame.height - bounds.midY - 31) < 0.5)
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        #expect(sidebar.isCollapsed)
        window.update()
        let light = try #require(window.standardWindowButton(.closeButton))
        let lightBounds = light.convert(light.bounds, to: nil)
        #expect(abs(lightBounds.midX - 30) < 0.5)
        #expect(abs(window.frame.height - lightBounds.midY - 31) < 0.5)
        #expect(originalDetail.bounds.width > initialWidth + 150)
        #expect(detail === originalDetail)
        #expect(state.draft == "Keep this draft")
        window.setContentSize(NSSize(width: 760, height: 520))
        controller.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        #expect(!sidebar.isCollapsed)
        window.update()
        #expect(abs(light.convert(light.bounds, to: nil).midX - 30) < 0.5)
        #expect(abs(split.arrangedSubviews[0].frame.width - sidebarWidth) < 2)
        #expect(detail === originalDetail)
        #expect(state.draft == "Keep this draft")
        try NetworkShellAssertions.verify(host, in: window)
    }

    @Test func conversationWithSidebarHiddenRendersInBothAppearances() async throws {
        for dark in [false, true] {
            let window = makeWindow()
            defer { window.close() }
            NetworkSetupWindowPresentation.configure(window, identityReady: true)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: NativeConversationFixture()
                .environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(350))
            window.setContentSize(NSSize(width: 760, height: 520))
            let split = try #require(NetworkShellAssertions.views(in: host).compactMap { $0 as? NSSplitView }.first)
            let controller = try #require(split.delegate as? NSSplitViewController)
            controller.toggleSidebar(nil)
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            #expect(controller.splitViewItems[0].isCollapsed)
            window.update()
            let detail = controller.splitViewItems[1].viewController.view
            // Rendering other fixtures can delay AppKit's animation/layout pass.
            // Wait for the actual geometry, with a bounded timeout, not just 400 ms.
            for _ in 0..<40 where detail.bounds.width < 750 {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
            }
            #expect(detail.bounds.width >= 750)
            if let directory = ProcessInfo.processInfo.environment["ALO_NETWORKS_SNAPSHOT_DIR"] {
                let frame = try #require(host.superview)
                let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sidebar-hidden-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test func nativeChromeAndCloseRetainReusableWindow() throws {
        let window = makeWindow()
        NetworkSetupWindowPresentation.configure(window, identityReady: true)
        #expect(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(!window.isOpaque)
        #expect(window.isMovableByWindowBackground)
        #expect(window.collectionBehavior.contains(.fullScreenNone))
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

    @Test func nativeIdentityTransitionFitsTheScreenWhilePreservingCenterWhenPossible() throws {
        let window = makeWindow()
        NetworkSetupWindowPresentation.configure(window, identityReady: false)
        window.setContentSize(NSSize(width: 800, height: 640))
        window.setFrameOrigin(NSPoint(x: 173, y: 217))
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let screen = try #require(window.screen ?? NSScreen.main)
        let expected = NetworkSetupWindowPresentation.browserFrame(center: center, visibleFrame: screen.visibleFrame)
        NetworkSetupWindowPresentation.enterBrowserPreservingCenter(window)
        #expect(window.frame == expected)
        window.close()
    }

    @Test func conceptCornersClipTheWholeFrameAndSurviveResize() throws {
        let window = makeWindow()
        defer { window.close() }
        NetworkSetupWindowPresentation.configure(window, identityReady: true)
        window.contentView = NSHostingView(rootView: NetworkBrowserFixture(state: "empty"))
        for size in [NetworkSetupWindowPresentation.minimumContentSize,
                     NetworkSetupWindowPresentation.initialContentSize] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            let frame = try #require(window.contentView?.superview?.layer)
            #expect(frame.cornerRadius == 34)
            #expect(frame.cornerCurve == .continuous)
            #expect(frame.masksToBounds)
            #expect(ALONativeNetworkLayout.panelRadius == 28)
            #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
            let frameView = try #require(window.contentView?.superview)
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                let button = try #require(window.standardWindowButton(type))
                let bounds = button.convert(button.bounds, to: frameView)
                #expect(bounds.midX == 30 + CGFloat(index) * 20)
                #expect(frameView.bounds.height - bounds.midY == 31)
                #expect(frameView.hitTest(NSPoint(x: bounds.midX, y: bounds.midY)) === button)
            }
        }
        NetworkSetupWindowPresentation.configure(window, identityReady: false)
        #expect(window.contentView?.superview?.layer?.masksToBounds == false)
        #expect(window.contentView?.superview?.layer?.cornerRadius == 0)
    }

    @Test func initialFrameFitsShortAndOffsetDisplays() {
        for visible in [NSRect(x: 0, y: 25, width: 1280, height: 650),
                        NSRect(x: -1440, y: 40, width: 1440, height: 860),
                        NSRect(x: 100, y: -700, width: 800, height: 600)] {
            for center in [NSPoint(x: visible.midX, y: visible.midY), NSPoint(x: visible.maxX, y: visible.maxY)] {
                let frame = NetworkSetupWindowPresentation.browserFrame(center: center, visibleFrame: visible)
                #expect(visible.insetBy(dx: 24, dy: 24).contains(frame))
                #expect(frame.width <= 960 && frame.height <= 700)
                #expect(frame.width >= 640 && frame.height >= 440)
            }
        }
        let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let centered = NetworkSetupWindowPresentation.browserFrame(center: NSPoint(x: 800, y: 500), visibleFrame: screen)
        #expect(centered.midX == 800 && centered.midY == 500)
    }

    @Test func nativeBackdropRemainsUnmaskedAndRespectsReduceTransparency() async throws {
        let window = makeWindow()
        defer { window.close() }
        NetworkSetupWindowPresentation.configure(window, identityReady: true)
        func backdrop(in view: NSView) -> NSVisualEffectView? {
            if view.identifier?.rawValue == "ALO.Network.WindowBlur" {
                return view as? NSVisualEffectView
            }
            return view.subviews.lazy.compactMap { backdrop(in: $0) }.first
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let host = NSHostingView(rootView: ALONetworkWindowBackground())
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        if reduced {
            #expect(backdrop(in: host) == nil)
        } else {
            let effect = try #require(backdrop(in: host))
            #expect(effect.material == .underWindowBackground)
            #expect(effect.blendingMode == .behindWindow)
            #expect(effect.state == .followsWindowActiveState)
            #expect(effect.maskImage == nil)
            #expect(effect.alphaValue == 1)
        }
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

    @Test func nativeSheetCanPresentItsExistingContentAboveMinimumWindow() async throws {
        let window = makeWindow()
        NetworkSetupWindowPresentation.configure(window, identityReady: true)
        window.setContentSize(NetworkSetupWindowPresentation.minimumContentSize)
        var contentProbe: NSView?
        window.contentView = NSHostingView(rootView: NetworkSheetFixture(onProbe: { contentProbe = $0 }))
        window.setFrameOrigin(NSPoint(x: -2000, y: 0))
        window.orderBack(nil)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
        // Presentation is asynchronous. Wait for observable attachment/layout,
        // not a presumed animation duration; absence is a fixture prerequisite.
        for _ in 0..<100 {
            if let sheet = window.attachedSheet, let probe = contentProbe,
               probe.window === sheet, probe.bounds.width > 0, probe.bounds.height > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try #require(window.attachedSheet)
        let contentView = try #require(sheet.contentView)
        contentView.layoutSubtreeIfNeeded()
        let probe = try #require(contentProbe)
        let bounds = probe.convert(probe.bounds, to: contentView)
        #expect(bounds.width >= 600)
        #expect(bounds.height >= 520)
        #expect(contentView.bounds.contains(bounds))
        print("NETWORK_SHEET parent=\(window.contentLayoutRect.size) sheet=\(contentView.bounds.size) content=\(bounds.size)")
    }

    /// Only public fixture values. Does not initialize the application model,
    /// identities, discovery, or playback. Opt-in PNGs include native frame chrome.
    @Test(arguments: ["empty", "owner-empty", "member-empty", "pending", "long", "error", "populated"])
    func nativeWindowFixtures(state: String) async throws {
        for dark in [false, true] {
            for size in [NSSize(width: 640, height: 440), NSSize(width: 760, height: 520)] {
                let window = makeWindow()
                defer { window.close() }
                NetworkSetupWindowPresentation.configure(window, identityReady: true)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                var sidebarProbe: NSView?
                var detailProbe: NSView?
                window.contentView = NSHostingView(rootView: NetworkBrowserFixture(state: state,
                    onSidebarProbe: { sidebarProbe = $0 }, onDetailProbe: { detailProbe = $0 })
                    .environment(\.controlActiveState, .active)
                    .transaction { $0.disablesAnimations = true })
                try await Task.sleep(for: .milliseconds(300))
                // Exercise a real window resize before inspecting the shell.
                window.setContentSize(size)
                window.contentView?.layoutSubtreeIfNeeded()
                let frameView = try #require(window.contentView?.superview)
                #expect(window.contentView?.bounds.size == size)
                #expect(window.contentLayoutRect.width == size.width)
                // Render/layout before reading native geometry, including runs
                // without PNG export. Pixel dimensions alone missed a centered
                // intrinsic-width empty HStack with an unwanted leading strip.
                let bitmap = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                let probe = try #require(sidebarProbe)
                let bounds = probe.convert(probe.bounds, to: window.contentView)
                #expect(abs(bounds.minX - ALONativeNetworkLayout.panelInset) < 0.5)
                #expect(bounds.width >= ALONativeNetworkLayout.minimumSidebarWidth - 2 * ALONativeNetworkLayout.panelInset)
                #expect(bounds.width <= ALONativeNetworkLayout.maximumSidebarWidth - 2 * ALONativeNetworkLayout.panelInset)
                let detail = try #require(detailProbe)
                let detailBounds = detail.convert(detail.bounds, to: window.contentView)
                #expect(abs(detailBounds.minX - bounds.maxX - ALONativeNetworkLayout.panelInset) < 0.5)
                #expect(abs(bounds.minY - detailBounds.minY) < 0.5)
                #expect(abs(bounds.height - detailBounds.height) < 0.5)
                #expect(abs(detailBounds.maxX - (size.width - ALONativeNetworkLayout.panelInset)) < 0.5)
                #expect(abs(detailBounds.minY - ALONativeNetworkLayout.panelInset) < 0.5)
                #expect(abs(detailBounds.height - (size.height - 2 * ALONativeNetworkLayout.panelInset)) < 0.5)
                if let directory = ProcessInfo.processInfo.environment["ALO_NETWORKS_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("window-\(state)-\(dark ? "dark" : "light")-\(Int(size.width)).png"))
                }
            }
        }
    }
}
}

@MainActor private final class SidebarFixtureState: ObservableObject {
    @Published var draft = ""
}

private struct SidebarToggleFixture: View {
    @ObservedObject var state: SidebarFixtureState
    let onDetail: (NSView) -> Void
    var body: some View {
        ALONativeNetworkColumns {
            Text("Spaces").frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            TextField("Message", text: $state.draft)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NetworkSheetProbe(onCreate: onDetail))
        }
    }
}

private struct NetworkSheetFixture: View {
    let onProbe: (NSView) -> Void
    @State private var presented = false
    var body: some View {
        Color.clear
            .sheet(isPresented: $presented) {
                ALOCreateChannelView(networkName: "Studio", name: .constant("Music"),
                    isPrivate: .constant(false), selectedMemberIDs: .constant([]), members: [],
                    onCreate: {}, onCancel: { presented = false })
                    .frame(width: 600, height: 520)
                    .background(NetworkSheetProbe(onCreate: onProbe))
            }
            .task { presented = true }
    }
}

private struct NetworkSheetProbe: NSViewRepresentable {
    let onCreate: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let view = NSView(); onCreate(view); return view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
