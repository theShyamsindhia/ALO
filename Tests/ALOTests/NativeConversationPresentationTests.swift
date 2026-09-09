import AppKit
import SwiftUI
import Testing
import ALONetworkUI
import ALOCore
@testable import ALO

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct NativeConversationPresentationTests {
        @Test func referenceLayoutDimensions() {
            #expect(ALONativeNetworkLayout.sidebarWidth(for: 1120) == 280)
            #expect(ALONativeNetworkLayout.sidebarWidth(for: 640) == 210)
            #expect(ALONativeNetworkLayout.sidebarWidth(for: 1600) == 280)
            #expect(ALONativeNetworkLayout.panelInset == 8)
            #expect(ALONativeNetworkLayout.panelRadius == 12)
        }

        @Test func nowPlayingKeepsTheSameTypeScaleInCompactLayout() throws {
            _ = NSApplication.shared
            func render(compact: Bool) throws -> Data {
                let view = NSHostingView(rootView: NetworkNowPlayingCard(title: "Selfless", artist: "The Strokes",
                    channel: "Music", artwork: nil, isPlaying: true, openChannel: {})
                    .environment(\.aloCompactNetworkLayout, compact)
                    .environment(\.colorScheme, .dark)
                    .frame(width: 186, height: 80))
                view.frame = NSRect(x: 0, y: 0, width: 186, height: 80)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                return try #require(bitmap.representation(using: .png, properties: [:]))
            }
            #expect(try render(compact: true) == render(compact: false))
        }

        @Test(arguments: [false, true], ["conversation", "long", "empty"])
        func populatedConversationRenders(dark: Bool, state: String) async throws {
            _ = NSApplication.shared
            for size in [NSSize(width: 1120, height: 860), NSSize(width: 960, height: 700),
                         NSSize(width: 900, height: 600), NSSize(width: 880, height: 600),
                         NSSize(width: 960, height: 580),
                         NSSize(width: 640, height: 440)] {
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -2000, y: 0), size: size),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                NetworkSetupWindowPresentation.configure(window, identityReady: true)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let imageURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALO_UI_PREVIEW_IMAGE"]
                    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().appendingPathComponent("Resources/ALOSetupSlide-1.jpg").path)
                #expect(FileManager.default.fileExists(atPath: imageURL.path))
                let view = NSHostingView(rootView: NativeConversationFixture(state: state, imageURL: imageURL)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.controlActiveState, .active)
                    .transaction { $0.disablesAnimations = true })
                window.contentView = view
                window.setContentSize(size)
                window.orderBack(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(350))
                view.layoutSubtreeIfNeeded()
                #expect(view.bounds.size == size)
                try NetworkShellAssertions.verify(view, in: window)
                let frameView = try #require(view.superview)
                let bitmap = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(data.count > 1000)
                if let directory = ProcessInfo.processInfo.environment["ALO_NETWORKS_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "chat-\(state)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height)).png"))
                }
            }
        }
    }
}

/// Real production views, public sample content, no live account or media sessions.
struct NativeConversationFixture: View {
    var state = "conversation"
    var imageURL: URL? = nil
    @State private var networkID: String? = "imai"
    @State private var channelID = "main"
    @State private var draft = ""
    @State private var notificationMode = ChatNotificationMode.all

    private var messages: [RoomChatMessage] {
        guard state != "empty" else { return [] }
        return [
            .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, senderID: "raj", sender: "Raj",
                  text: "Anyone up for a listening session?", sentNanos: 1),
            .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, senderID: "me", sender: "Shyam",
                  text: "Yes, give me a minute.", sentNanos: 2),
            .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, senderID: "raj", sender: "Raj",
                  text: "", sentNanos: 3, attachment: .init(fileName: "Cover inspiration.jpg", contentType: "public.jpeg", byteCount: 120000)),
            .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, senderID: "raj", sender: "Raj",
                  text: state == "long" ? String(repeating: "A longer message should wrap without hiding the composer. ", count: 9)
                    : "A little inspiration for the cover.", sentNanos: 3),
            .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, senderID: "sammy", sender: "Sammy",
                  text: "@Shyam we’re in Music whenever you’re ready.", sentNanos: 4, mentionedParticipantIDs: ["me"]),
            .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, senderID: "sammy", sender: "Sammy",
                  text: "I’ve queued up the next track.", sentNanos: 5)
        ]
    }

    var body: some View {
        ALONativeNetworkColumns {
            ALONetworkSidebar(networks: [.init(id: "imai", name: "IMAI", memberCount: 4, isOwner: true)],
                selectedNetworkID: $networkID, identityName: "Shyam", identityFingerprint: "preview",
                onCreateNetwork: {}, onImportNetwork: {}, onExportPublicIdentity: {},
                nearbyNetworks: [.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, name: "Studio")],
                channels: [.init(id: "main", name: "Main", isPrivate: false, isMain: true),
                           .init(id: "music", name: "Music", isPrivate: false),
                           .init(id: "design", name: "Design", isPrivate: true)],
                selectedChannelID: channelID, onOpenChannel: { channelID = $0 },
                nowPlaying: state == "empty" ? nil : AnyView(NetworkNowPlayingCard(title: "Selfless", artist: "The Strokes",
                    channel: "Music", artwork: imageURL.flatMap { try? Data(contentsOf: $0) }, isPlaying: true,
                    openChannel: { channelID = "music" })))
        } detail: {
            RoomChatPanel(messages: messages, currentParticipantID: "me", roomTitle: "Main",
                firstUnreadMessageID: state == "conversation" ? messages.first(where: { $0.senderID == "sammy" })?.id : nil,
                unreadCount: 2, isPresented: true, accent: .blue,
                onLatestVisibilityChanged: { _, _ in }, send: { _ in true }, sendAttachment: { _, _ in true },
                attachmentURL: { _ in imageURL }, draft: $draft, notificationMode: $notificationMode,
                mentionNames: ["Raj", "Sammy", "Shyam"], usesNativeLayout: true, subtitle: "IMAI · 4 people connected",
                headerActions: AnyView(HStack(spacing: 12) {
                    Button("Members", systemImage: "person.2") {}
                    Button("Voice controls", systemImage: "mic") {}
                    Button("Share screen", systemImage: "display") {}
                }))
        }
    }
}
