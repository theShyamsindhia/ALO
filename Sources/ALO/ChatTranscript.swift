import AppKit
import SwiftUI

/// Keeps scroll behavior local to each visible chat surface.
struct ChatTranscript<Row: View>: View {
    let messages: [RoomMessage]
    let currentParticipantID: String?
    let firstUnreadMessageID: UUID?
    let unreadCount: Int
    let isPresented: Bool
    let accent: Color
    let onLatestVisibilityChanged: (UUID, Bool) -> Void
    @ViewBuilder var row: (RoomMessage, Bool) -> Row

    @State private var viewportID = UUID()
    @State private var scrollState = ChatScrollState()
    @State private var latestLayout = ChatScrollLayout()
    @State private var unreadBoundary: UUID?
    @State private var scrollGeneration = 0
    @State private var nativeScroll = ChatScrollViewReference()

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            VStack(spacing: 6) {
                                if message.id == unreadBoundary {
                                    HStack(spacing: 8) {
                                        Rectangle().frame(height: 0.5)
                                        Text("New messages")
                                            .font(.system(size: 9, weight: .medium))
                                            .fixedSize()
                                        Rectangle().frame(height: 0.5)
                                    }
                                    .foregroundStyle(accent)
                                    .padding(.vertical, 6)
                                }
                                row(message, index == 0 || messages[index - 1].senderID != message.senderID)
                            }
                            .id(ChatScrollState.Target.message(message.id))
                        }
                        Color.clear
                            .frame(height: 11)
                            .id(ChatScrollState.Target.latest)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(
                                key: ChatLayoutPreference.self,
                                value: ChatScrollLayout(
                                    contentFrame: content.frame(in: .named(viewportID)),
                                    viewportHeight: viewport.size.height
                                )
                            )
                        }
                    }
                    .background(ChatScrollActivity(reference: nativeScroll, onResize: {
                        if isPresented && scrollState.shouldFollowLatest {
                            scroll(.latest, proxy: proxy)
                        }
                    }) { scrolling in
                        if scrolling {
                            scrollGeneration &+= 1
                            scrollState.userStartedScrolling()
                        } else {
                            scrollState.userEndedScrolling()
                        }
                    })
                }
                .coordinateSpace(name: viewportID)
                .scrollIndicators(.hidden)
                .onPreferenceChange(ChatLayoutPreference.self) { layout in
                    latestLayout = layout
                    guard isPresented else { return }
                    updateScroll(layout, proxy: proxy)
                }
                .onChange(of: messages.last?.id) {
                    guard isPresented else { return }
                    if let target = scrollState.messagesChanged(lastOwnMessageID: lastOwnMessageID) {
                        scroll(target, proxy: proxy)
                    }
                }
                .onChange(of: isPresented, initial: true) { _, visible in
                    if visible {
                        unreadBoundary = firstUnreadMessageID
                        scrollState = ChatScrollState(
                            firstUnreadMessageID: firstUnreadMessageID,
                            lastOwnMessageID: lastOwnMessageID
                        )
                        updateScroll(latestLayout, proxy: proxy)
                    } else {
                        scrollGeneration &+= 1
                        onLatestVisibilityChanged(viewportID, false)
                    }
                }
                .onDisappear {
                    scrollGeneration &+= 1
                    onLatestVisibilityChanged(viewportID, false)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !messages.isEmpty, !scrollState.followsLatest {
                        Button {
                            scroll(scrollState.jumpToLatest(), proxy: proxy)
                        } label: {
                            Label(unreadCount > 0 ? "\(unreadCount) new" : "Latest", systemImage: "arrow.down")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Scroll to the latest message")
                        .accessibilityLabel(unreadCount > 0 ? "\(unreadCount) new messages. Scroll to latest" : "Scroll to latest")
                        .padding(10)
                    }
                }
            }
        }
    }

    private var lastOwnMessageID: UUID? {
        messages.last { $0.senderID == currentParticipantID }?.id
    }

    private func updateScroll(_ layout: ChatScrollLayout, proxy: ScrollViewProxy) {
        let request = scrollState.layoutChanged(layout)
        if layout.viewportHeight > 0, layout.contentFrame.height > 0 {
            onLatestVisibilityChanged(viewportID, scrollState.isAtLatest)
        }
        if let request { scroll(request, proxy: proxy) }
    }

    private func scroll(_ target: ChatScrollState.Target, proxy: ScrollViewProxy) {
        scrollGeneration &+= 1
        let generation = scrollGeneration
        // Coalesce layout changes; the native resize observer also corrects the
        // position when AppKit adopts a SwiftUI row's new height on a later pass.
        DispatchQueue.main.async {
            guard generation == scrollGeneration else { return }
            if target == .latest, let scrollView = nativeScroll.view,
               let document = scrollView.documentView {
                document.layoutSubtreeIfNeeded()
                let clip = scrollView.contentView
                let y = document.isFlipped ? max(0, document.frame.height - clip.bounds.height) : 0
                // Resolve the real document edge, including lazy row height corrections.
                // ScrollViewReader can retain an estimated frame for its last row.
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scrollView.reflectScrolledClipView(clip)
            } else {
                withAnimation(nil) { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }
}

private struct ChatLayoutPreference: PreferenceKey {
    static var defaultValue = ChatScrollLayout()
    static func reduce(value: inout ChatScrollLayout, nextValue: () -> ChatScrollLayout) {
        let next = nextValue()
        if next.viewportHeight > 0 { value = next }
    }
}

private final class ChatScrollViewReference {
    weak var view: NSScrollView?
}

/// A trackpad/wheel gesture takes priority over an in-flight automatic scroll.
private struct ChatScrollActivity: NSViewRepresentable {
    let reference: ChatScrollViewReference
    let onResize: () -> Void
    let onScroll: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onScroll = onScroll
        view.onResize = onResize
        view.reference = reference
    }

    final class ObserverView: NSView {
        var onScroll: ((Bool) -> Void)?
        var onResize: (() -> Void)?
        var reference: ChatScrollViewReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, let scrollView = self.enclosingScrollView else { return }
                NotificationCenter.default.removeObserver(self)
                self.reference?.view = scrollView
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(startedScrolling),
                    name: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(endedScrolling),
                    name: NSScrollView.didEndLiveScrollNotification,
                    object: scrollView
                )
                if let document = scrollView.documentView {
                    document.postsFrameChangedNotifications = true
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(contentResized),
                        name: NSView.frameDidChangeNotification,
                        object: document
                    )
                }
            }
        }

        @objc private func startedScrolling() { onScroll?(true) }
        @objc private func endedScrolling() { onScroll?(false) }
        @objc private func contentResized() { onResize?() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
