import AppKit
import SwiftUI
import Testing
@testable import ALO

@Suite(.serialized) @MainActor
struct ChatTranscriptLayoutTests {
    @Test("Sent messages stay inside the transcript viewport after long bubbles and rapid replies")
    func sentMessageIsVisible() async throws {
        let fixture = TranscriptFixture()
        let window = makeWindow(fixture)
        defer { window.close() }
        let scrollView = try await waitForScrollView(in: window)
        try await waitUntil { atBottom(scrollView) && fixture.atLatest }

        // Read older messages, then send a long message followed by a reply before
        // SwiftUI has performed another layout pass.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await waitUntil { !fixture.atLatest }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        fixture.messages.append(message(sender: "me", text: String(repeating: "A multiline message stays fully visible. ", count: 12)))
        fixture.messages.append(message(sender: "friend", text: "Got it"))
        try await waitUntil { atBottom(scrollView) && fixture.atLatest }

        // A native viewport resize must keep the latest row above the composer.
        window.setContentSize(NSSize(width: 480, height: 180))
        try await waitUntil { abs(scrollView.contentView.bounds.height - 180) < 2 && atBottom(scrollView) }
    }

    @Test("Receiving a message while reading history does not move the native scroll position")
    func incomingPreservesHistory() async throws {
        let fixture = TranscriptFixture()
        let window = makeWindow(fixture)
        defer { window.close() }
        let scrollView = try await waitForScrollView(in: window)
        try await waitUntil { atBottom(scrollView) && fixture.atLatest }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 150))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await waitUntil { !fixture.atLatest }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        let position = scrollView.contentView.bounds.minY
        fixture.messages.append(message(sender: "friend", text: "A new reply while you read"))
        try await Task.sleep(for: .milliseconds(350))
        #expect(abs(scrollView.contentView.bounds.minY - position) < 2)
        #expect(!fixture.atLatest)
    }

    @Test("Reopening a hidden chat lands at unread history without marking the latest as seen")
    func reopenUnreadHistory() async throws {
        let fixture = TranscriptFixture()
        fixture.isPresented = false
        fixture.firstUnreadMessageID = fixture.messages[30].id
        let window = makeWindow(fixture)
        defer { window.close() }
        let scrollView = try await waitForScrollView(in: window)
        #expect(!fixture.atLatest)
        fixture.isPresented = true
        try await waitUntil { scrollView.documentVisibleRect.minY > 500 }
        #expect(!atBottom(scrollView))
        #expect(!fixture.atLatest)
    }

    private func makeWindow(_ fixture: TranscriptFixture) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: 0, width: 560, height: 250),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TranscriptFixtureView(fixture: fixture))
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func waitForScrollView(in window: NSWindow) async throws -> NSScrollView {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        try await waitUntil { window.contentView.flatMap(find) != nil }
        return try #require(window.contentView.flatMap(find))
    }

    private func atBottom(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView, document.frame.height > 0 else { return false }
        return document.frame.maxY - scroll.documentVisibleRect.maxY <= 2
    }

    private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private func message(sender: String, text: String) -> RoomMessage {
        RoomMessage(senderID: sender, sender: sender, text: text, sentNanos: 0)
    }
}

@MainActor
private final class TranscriptFixture: ObservableObject {
    @Published var messages = (0..<60).map {
        RoomMessage(senderID: "friend", sender: "Friend", text: "Earlier message \($0)", sentNanos: UInt64($0))
    }
    @Published var isPresented = true
    @Published var firstUnreadMessageID: UUID?
    var atLatest = false
}

private struct TranscriptFixtureView: View {
    @ObservedObject var fixture: TranscriptFixture

    var body: some View {
        ChatTranscript(
            messages: fixture.messages,
            currentParticipantID: "me",
            firstUnreadMessageID: fixture.firstUnreadMessageID,
            unreadCount: 0,
            isPresented: fixture.isPresented,
            accent: .blue,
            onLatestVisibilityChanged: { _, value in fixture.atLatest = value }
        ) { message, _ in
            Text(message.text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
