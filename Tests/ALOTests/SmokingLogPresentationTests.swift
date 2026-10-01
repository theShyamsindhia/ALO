import AppKit
import ALOCore
import SwiftUI
import Testing
@testable import ALO

@Suite struct SmokingPresentationTests {
    @Test func summaryContainsOnlyDailyAggregates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [SmokingEntry(userID: "private-owner", brand: .classicConnect, smokedAt: day, context: .stress),
                       SmokingEntry(userID: "private-owner", brand: .marlboroCloveMix, smokedAt: day.addingTimeInterval(60))]
        let text = SmokingPresentation.summary(entries: entries, day: day, calendar: calendar)
        #expect(text.contains("2 cigarettes logged"))
        #expect(text.contains("₹45.50"))
        #expect(!text.contains("private-owner"))
        #expect(!text.contains("Stress"))
        #expect(!text.contains("Classic"))
        #expect(!text.contains("Marlboro"))
        #expect(!text.contains(entries[0].id.uuidString))
        #expect(SmokingPresentation.summary(entries: [entries[0]], day: day, calendar: calendar).contains("1 cigarette logged"))
    }

    @Test func summaryRequiresTheReviewedProfileAndLiveChannel() {
        let draft = SmokingSummaryDraft(ownerID: "owner", channelID: "channel", destination: "Main", text: "Summary")
        #expect(draft.canSend(identityReady: true, currentUserID: "owner", currentChannelID: "channel", isLive: true))
        #expect(!draft.canSend(identityReady: false, currentUserID: "owner", currentChannelID: "channel", isLive: true))
        #expect(!draft.canSend(identityReady: true, currentUserID: "other", currentChannelID: "channel", isLive: true))
        #expect(!draft.canSend(identityReady: true, currentUserID: nil, currentChannelID: "channel", isLive: true))
        #expect(!draft.canSend(identityReady: true, currentUserID: "owner", currentChannelID: "other", isLive: true))
        #expect(!draft.canSend(identityReady: true, currentUserID: "owner", currentChannelID: nil, isLive: true))
        #expect(!draft.canSend(identityReady: true, currentUserID: "owner", currentChannelID: "channel", isLive: false))
    }

    @Test func periodLengthsAreLocalCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        for (period, days) in [(SmokingPeriod.day, 1), (.week, 7), (.month, 30)] {
            let range = period.range(endingOn: date, calendar: calendar)
            #expect(calendar.dateComponents([.day], from: range.start, to: range.end).day == days)
            #expect(range.start <= date && range.end > date)
        }
        #expect(SmokingPeriod.day.range(endingOn: date, calendar: calendar).duration == 23 * 3600)
    }

    @Test func intervalFormattingHandlesEmptyAndShortGaps() {
        #expect(SmokingPresentation.interval(nil) == "—")
        #expect(SmokingPresentation.interval(15) == "<1 min")
        #expect(SmokingPresentation.interval(5400) == "1h 30m")
    }
}

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct SmokingLogRenderTests {
        @Test func realStatusItemPopoverStaysBelowItsAnchorThroughDetailsAndUndo() async throws {
            _ = NSApplication.shared
            let activationPolicy = NSApp.activationPolicy()
            defer { NSApp.setActivationPolicy(activationPolicy) }
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            // SwiftUI otherwise leaves its lazy accessibility tree empty in an in-process fixture.
            let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previousAccessibility = NSApp.accessibilityAttributeValue(enhancedUI)
            NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
            defer { NSApp.accessibilitySetValue(previousAccessibility ?? false, forAttribute: enhancedUI) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-smoking-placement-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SmokingLogStore(userID: "placement-fixture", directory: directory)
            let model = ALOViewModel(discoverRooms: false)
            let item = NSStatusBar.system.statusItem(withLength: 28)
            defer { NSStatusBar.system.removeStatusItem(item) }
            let button = try #require(item.button)
            button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Placement test")
            // AppKit can initially give a new status item an offscreen frame.
            let placementDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < placementDeadline {
                if let window = button.window, let screen = window.screen,
                   window.isVisible, screen.frame.contains(window.convertToScreen(button.convert(button.bounds, to: nil))) {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let anchorWindow = try #require(button.window)
            let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = try #require(anchorWindow.screen)
            try #require(anchorWindow.isVisible && screen.frame.contains(anchor), "Status item must be laid out before testing popover placement")
            let popover = model.smokingLog.presentQuickLog(store: store, from: button)
            defer { popover.close() }
            print("Smoking anchor: flipped=\(button.isFlipped) anchor=\(anchor) visible=\(anchorWindow.isVisible) screen=\(screen.visibleFrame) shown=\(popover.isShown)")
            try await Task.sleep(for: .milliseconds(500))
            let window = try #require(popover.contentViewController?.view.window)
            print("Smoking placement: flipped=\(button.isFlipped) anchor=\(anchor) screen=\(screen.visibleFrame) window=\(window.frame) content=\(popover.contentSize)")
            #expect(popover.isShown)
            #expect(screen.frame.contains(window.frame))
            #expect(window.frame.maxY <= anchor.minY + 2, "Allow AppKit's arrow attachment, but no content above the menu bar")
            #expect(window.convertToScreen(popover.contentViewController!.view.convert(popover.contentViewController!.view.bounds, to: nil)).maxY <= screen.visibleFrame.maxY)
            #expect(model.smokingLog.isQuickLogPresented)
            #expect(popover.contentSize.width == 280)
            #expect(popover.contentSize.height <= 150)
            let compactSize = popover.contentSize
            let top = window.frame.maxY
            let host = try #require(popover.contentViewController?.view)
            try await press("ALO.Smoking.Details", in: host)
            try await Task.sleep(for: .milliseconds(150))
            #expect(popover.contentSize.height > compactSize.height)
            try await press("ALO.Smoking.Earlier", in: host)
            try await Task.sleep(for: .milliseconds(150))
            let expandedSize = popover.contentSize
            #expect(expandedSize.height <= 240)
            #expect(abs(window.frame.maxY - top) < 1, "Details must grow downward without moving the anchor")
            #expect(screen.frame.contains(window.frame))
            try await press("ALO.Smoking.Save", in: host)
            try await Task.sleep(for: .milliseconds(100))
            #expect(store.entries.count == 1)
            #expect(popover.contentSize == expandedSize, "Logged/Undo must not add a row")
            try await press("ALO.Smoking.Undo", in: host)
            try await Task.sleep(for: .milliseconds(100))
            #expect(store.entries.isEmpty)
            #expect(popover.contentSize == expandedSize)
            try await press("ALO.Smoking.Details", in: host)
            try await Task.sleep(for: .milliseconds(100))
            #expect(popover.contentSize == compactSize)
            #expect(abs(window.frame.maxY - top) < 1)
            try await press("ALO.Smoking.Brand.marlboroCloveMix", in: host)
            try await press("ALO.Smoking.Save", in: host)
            try await Task.sleep(for: .milliseconds(100))
            #expect(store.entries.last?.brand == .marlboroCloveMix)
            #expect(popover.contentSize == compactSize)
            try await Task.sleep(for: .milliseconds(6200))
            try await press("ALO.Smoking.Details", in: host)
            #expect(store.entries.count == 1, "The confirmation timeout must not add another entry")
            popover.close()
            #expect(!model.smokingLog.isQuickLogPresented)
        }

        @Test func popoverFitsAtBothScreenEdgesWithEitherCoordinateSystem() async throws {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-smoking-edges-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SmokingLogStore(userID: "edges-fixture", directory: directory)
            let model = ALOViewModel(discoverRooms: false)
            #expect(!NSScreen.screens.isEmpty, "This native test requires a display")
            for screen in NSScreen.screens {
                for flipped in [false, true] {
                    for x in [screen.visibleFrame.minX + 2, screen.visibleFrame.maxX - 30] {
                        let anchorWindow = NSWindow(contentRect: NSRect(x: x, y: screen.visibleFrame.maxY - 28, width: 28, height: 28),
                                                    styleMask: .borderless, backing: .buffered, defer: false)
                        anchorWindow.isReleasedWhenClosed = false
                        let anchor = PlacementAnchor(flipped: flipped)
                        anchorWindow.contentView = anchor
                        anchorWindow.orderFrontRegardless()
                        defer { anchorWindow.close() }
                        let popover = model.smokingLog.presentQuickLog(store: store, from: anchor)
                        defer { popover.close() }
                        try await Task.sleep(for: .milliseconds(150))
                        let window = try #require(popover.contentViewController?.view.window)
                        #expect(screen.frame.contains(window.frame), "Popover must fit near either screen edge")
                        #expect(window.frame.maxY <= anchorWindow.frame.minY + 2)
                    }
                }
            }
        }

        private final class PlacementAnchor: NSView {
            private let usesFlippedCoordinates: Bool
            override var isFlipped: Bool { usesFlippedCoordinates }
            init(flipped: Bool) {
                usesFlippedCoordinates = flipped
                super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            }
            required init?(coder: NSCoder) { fatalError("Test fixture") }
        }

        private func press(_ identifier: String, in root: Any) async throws {
            // SwiftUI's virtual nodes implement the selectors without declaring
            // conformance to AppKit's NSAccessibilityProtocol.
            func find(_ object: Any) -> AnyObject? {
                let element = object as AnyObject
                if element.accessibilityIdentifier?() == identifier { return element }
                for child in element.accessibilityChildren?() ?? [] {
                    if let match = find(child) { return match }
                }
                return nil
            }
            // SwiftUI publishes accessibility changes asynchronously after state updates.
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            var match = find(root)
            while match == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                match = find(root)
            }
            let element = try #require(match, "Missing control: \(identifier)")
            #expect(element.accessibilityPerformPress?() == true, "Control must be operable: \(identifier)")
        }

        @Test func popoverLifecycleTemporarilyYieldsTheNotch() async throws {
            _ = NSApplication.shared
            let suite = "alo-smoking-notch-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let preferences = ALONotchPreferences(defaults: defaults)
            let model = ALOViewModel(discoverRooms: false)
            let controller = model.smokingLog
            let notch = ALONotchWindowController(model: model, preferences: preferences)
            defer {
                preferences.enabled = false
                ALONotchFeatureBridge.shared.setEnabled(false)
                defaults.removePersistentDomain(forName: suite)
                withExtendedLifetime(notch) {}
            }
            preferences.enabled = true
            try await Task.sleep(for: .milliseconds(200))
            let panel = try #require(NSApp.windows.first {
                $0 is NSPanel && $0.contentView.map { String(describing: type(of: $0)).contains("NotchHostingView") } == true
            })
            defer { panel.close() }
            #expect(panel.isVisible)
            #expect(!controller.isQuickLogPresented)
            controller.popoverWillShow(Notification(name: NSPopover.willShowNotification))
            #expect(controller.isQuickLogPresented)
            #expect(!panel.isVisible, "Yield before AppKit draws the popover, not one run-loop later")
            model.nowPlaying = NowPlayingMedia(title: "Fixture track", isPlaying: true)
            try await Task.sleep(for: .milliseconds(120))
            #expect(!panel.isVisible, "Playback updates must not bring the overlay back above the form")
            #expect(preferences.enabled && ALONotchFeatureBridge.shared.runtime?.isEnabled == true)
            controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
            #expect(!controller.isQuickLogPresented)
            #expect(panel.isVisible)
            #expect(model.nowPlaying.isPlaying == true)
            controller.popoverWillShow(Notification(name: NSPopover.willShowNotification))
            #expect(controller.isQuickLogPresented)
            #expect(!panel.isVisible)
            controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
            #expect(!controller.isQuickLogPresented)
            #expect(panel.isVisible)
        }

        @Test("Smoking log fits native compact and history surfaces", arguments: [false, true])
        func render(dark: Bool) async throws {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-smoking-render-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SmokingLogStore(userID: "preview-only", directory: directory)
            let now = Date()
            for offset in [120.0, 4000, 14000] {
                #expect(store.add(brand: .classicConnect, smokedAt: now.addingTimeInterval(-offset), context: nil) != nil)
            }
            #expect(store.add(brand: .marlboroCloveMix, smokedAt: now.addingTimeInterval(-8000), context: .afterFood) != nil)
            try await capture(SmokingQuickLogView(store: store, onHistory: {}),
                              name: "smoking-quick", dark: dark)
            try await capture(SmokingHistoryView(store: store, profileName: "Preview profile"),
                              size: NSSize(width: 560, height: 680), name: "smoking-history", dark: dark)
            try await capture(SmokingHistoryView(store: store, profileName: "Preview profile", period: .day),
                              size: NSSize(width: 560, height: 680), name: "smoking-day", dark: dark)
            try await capture(SmokingHistoryView(store: store, profileName: "Preview profile", period: .month),
                              size: NSSize(width: 680, height: 760), name: "smoking-month", dark: dark)
            try await capture(SmokingEntryForm(store: store, entry: store.entries.first).padding(24),
                              size: NSSize(width: 380, height: 230), name: "smoking-edit", dark: dark)
            let empty = SmokingLogStore(userID: "empty-preview", directory: directory)
            try await capture(SmokingHistoryView(store: empty, profileName: "Preview profile"),
                              size: NSSize(width: 680, height: 760), name: "smoking-empty", dark: dark)
        }

        private func capture<V: View>(_ view: V, size requestedSize: NSSize? = nil, name: String, dark: Bool) async throws {
            let content = view.environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .active)
                .transaction { $0.disablesAnimations = true }
            let host = NSHostingView(rootView: content
                .frame(width: requestedSize?.width, height: requestedSize?.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            let size = requestedSize ?? host.fittingSize
            if requestedSize == nil {
                #expect(size.width == 280)
                #expect(size.height <= 150 && size.height >= 130, "Measure the view, not an arbitrary snapshot canvas")
            }
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -2400, y: 0), size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.close() }
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            window.displayIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            #expect(abs(host.frame.width - size.width) < 1, "Content must not expand the native window width")
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            if let path = ProcessInfo.processInfo.environment["ALO_UI_RENDER_DIR"] {
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
