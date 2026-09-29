import AppKit
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
            try await capture(SmokingQuickLogView(store: store, onHistory: {}), size: NSSize(width: 340, height: 400),
                              name: "smoking-quick", dark: dark)
            try await capture(SmokingHistoryView(store: store, profileName: "Preview profile"),
                              size: NSSize(width: 560, height: 680), name: "smoking-history", dark: dark)
            try await capture(SmokingHistoryView(store: store, profileName: "Preview profile", period: .day),
                              size: NSSize(width: 560, height: 680), name: "smoking-day", dark: dark)
            try await capture(SmokingHistoryView(store: store, profileName: "Preview profile", period: .month),
                              size: NSSize(width: 680, height: 760), name: "smoking-month", dark: dark)
            try await capture(SmokingEntryForm(store: store, entry: store.entries.first).padding(24),
                              size: NSSize(width: 380, height: 300), name: "smoking-edit", dark: dark)
            let empty = SmokingLogStore(userID: "empty-preview", directory: directory)
            try await capture(SmokingHistoryView(store: empty, profileName: "Preview profile"),
                              size: NSSize(width: 680, height: 760), name: "smoking-empty", dark: dark)
        }

        private func capture<V: View>(_ view: V, size: NSSize, name: String, dark: Bool) async throws {
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -2400, y: 0), size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .active)
                .transaction { $0.disablesAnimations = true }
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
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
