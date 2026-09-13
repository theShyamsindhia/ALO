import AppKit
import SwiftUI
import Testing
import ALOCore
@testable import ALO

@Suite("Notch conversation continuity", .serialized) @MainActor
struct NotchConversationRenderTests {
    @Test func conversationRemountKeepsReplyAttachmentAndMentions() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Review notes.txt")
        try Data("Review the shared image".utf8).write(to: url)
        let message = RoomChatMessage(senderID: "raj", sender: "Raj",
            text: "Can we look at the entrance together?", sentNanos: 1)
        let context = NotchRoomNavigation().composer
        context.replyTo = message.id
        context.chosenMentionIDs = ["raj"]
        context.pendingAttachment = PendingChatAttachment(url: url,
            metadata: .init(fileName: "Review notes.txt", contentType: "public.plain-text", byteCount: 23))

        // Rebuild the complete conversation surface around the same room-owned
        // context, as happens when returning from Files or reopening the notch.
        for width in [360.0, 540.0] {
            let panel = RoomChatPanel(messages: [message], currentParticipantID: "me", roomTitle: "Main",
                firstUnreadMessageID: nil, unreadCount: 0, isPresented: true, accent: .blue,
                onLatestVisibilityChanged: { _, _ in }, send: { _ in false }, sendAttachment: { _, _ in false },
                attachmentURL: { _ in nil }, draft: .constant("@Raj Here are my notes"),
                notificationMode: .constant(.all), mentionNames: ["Raj"], usesNativeLayout: true,
                showsHeader: false, composer: context)
            let bounds = NSRect(x: 0, y: 0, width: width, height: 400)
            let host = NSHostingView(rootView: panel.frame(width: width, height: bounds.height)
                .environment(\.colorScheme, .dark).background(Color.black))
            let window = NSWindow(contentRect: bounds.offsetBy(dx: -3000, dy: -3000),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1_500)
            if let directory = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("room-conversation-\(Int(width)).png"))
            }
            window.close()
            #expect(context.replyTo == message.id)
            #expect(context.pendingAttachment?.url == url)
            #expect(context.chosenMentionIDs == ["raj"])
        }
        context.reset()
        #expect(context.replyTo == nil)
        #expect(context.pendingAttachment == nil)
        #expect(context.chosenMentionIDs.isEmpty)
    }
}
