import SwiftUI
import AppKit
import ALOCore

/// The complete chat surface is independent of room navigation and playback.
struct RoomChatPanel: View {
    let messages: [RoomChatMessage]
    let currentParticipantID: String?
    let roomTitle: String
    let firstUnreadMessageID: UUID?
    let unreadCount: Int
    let isPresented: Bool
    let accent: Color
    let onLatestVisibilityChanged: (UUID, Bool) -> Void
    let send: (RoomChatOperation) -> Bool
    @State private var query = ""
    @State private var onlyPins = false
    @State private var showsSearch = false
    @State private var showsHistory = false
    @Binding var draft: String
    @Binding var notificationMode: ChatNotificationMode
    let mentionNames: [String]
    @State private var replyTo: UUID?
    @State private var editing: UUID?
    @FocusState private var focused: Bool
    var avatar: ((String, String, CGFloat) -> AnyView)? = nil

    private var filtered: [RoomChatMessage] {
        messages.filter { (!onlyPins || $0.pinned) && (query.isEmpty || (!$0.deleted && ($0.text.localizedCaseInsensitiveContains(query) || $0.sender.localizedCaseInsensitiveContains(query)))) }
    }
    private var validDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= RoomChatOperation.maximumTextLength
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if showsSearch {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search messages", text: $query).textFieldStyle(.plain)
                        .accessibilityLabel("Search room history")
                    Button { query = ""; showsSearch = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Close search").accessibilityLabel("Close search")
                } else if onlyPins {
                    Label("Pinned messages", systemImage: "pin.fill").foregroundStyle(.secondary)
                    Spacer()
                    Button { onlyPins = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Show all messages").accessibilityLabel("Show all messages")
                } else {
                    Spacer(minLength: 0)
                }
                chatMenu
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .frame(height: showsSearch || onlyPins ? 32 : 24)
            ChatTranscript(messages: filtered, currentParticipantID: currentParticipantID,
                firstUnreadMessageID: query.isEmpty && !onlyPins ? firstUnreadMessageID : nil,
                unreadCount: unreadCount, isPresented: isPresented && query.isEmpty && !onlyPins,
                accent: accent, onLatestVisibilityChanged: onLatestVisibilityChanged) { message, showsSender in
                    messageRow(message, showsSender: showsSender)
                }
                .overlay {
                    if filtered.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: onlyPins ? "pin" : "bubble.left.and.bubble.right").font(.title2)
                            Text(messages.isEmpty ? "Start the conversation" : "No matching messages").font(.callout)
                            if messages.isEmpty { Text("Everyone in the room can see your messages.").font(.caption) }
                        }.foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
            Divider().opacity(0.4)
            if let target = editing ?? replyTo, let message = messages.first(where: { $0.id == target }) {
                HStack {
                    Label(editing == nil ? "Reply to \(message.sender)" : "Editing your message", systemImage: editing == nil ? "arrowshape.turn.up.left" : "pencil")
                    Text(message.text).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { editing = nil; replyTo = nil; draft = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Cancel")
                }.font(.caption).padding(.horizontal, 14).padding(.top, 8)
            }
            HStack(alignment: .center, spacing: 8) {
                messageAvatar(id: currentParticipantID ?? "", name: "You", size: 26)
                    .accessibilityHidden(true)
                TextField("Message \(roomTitle)", text: $draft, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.plain).focused($focused)
                    .onSubmit(submit)
                if draft.count > 600 { Text("\(draft.count)/700").font(.caption2).foregroundStyle(draft.count > 700 ? .red : .secondary) }
                Button(action: submit) {
                    Image(systemName: editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 25)).foregroundStyle(accent)
                }.buttonStyle(.plain).disabled(!validDraft).help(editing == nil ? "Send message" : "Save edit")
            }.font(.system(size: 12)).padding(12)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 10).padding(.vertical, 10)

        }
        .dropDestination(for: URL.self) { urls, _ in
            let links = urls.filter(RoomChatPresentation.isWebURL).prefix(3).map(\.absoluteString).joined(separator: " ")
            let proposed = draft + (draft.isEmpty ? "" : " ") + links
            guard !links.isEmpty, proposed.count <= RoomChatOperation.maximumTextLength else { return false }
            draft = proposed; focused = true; return true
        }
        .onChange(of: isPresented) { _, visible in if visible { focused = true } }
    }

    private var chatMenu: some View {
        Menu {
            Button("Search messages", systemImage: "magnifyingglass") { onlyPins = false; showsSearch = true }
            Button(onlyPins ? "Show all messages" : "Pinned messages", systemImage: "pin") {
                onlyPins.toggle(); query = ""; showsSearch = false
            }
            Menu("Mention a member") {
                if mentionNames.isEmpty { Text("No other room members") }
                ForEach(Array(Set(mentionNames)).sorted(), id: \.self) { name in
                    Button(name) { draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + "@" + name + " "; focused = true }
                }
            }
            Menu("Message previews") {
                Picker("Message previews", selection: $notificationMode) {
                    ForEach(ChatNotificationMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                }
            }
            Divider()
            Button("History", systemImage: "info.circle") { showsHistory = true }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 24, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Chat options").accessibilityLabel("Chat options")
        .popover(isPresented: $showsHistory) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Room history").font(.headline)
                Text("Up to 500 chat events are retained. Edits and reactions count toward this limit; older messages may disappear.")
                Text("Pins do not bypass retention. All members need an updated app for replies, reactions and edits.")
                Text("Message preview preferences apply across rooms. Unread counts remain visible when previews are muted.")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                .padding(16).frame(width: 280)
        }
    }

    @ViewBuilder
    private func messageAvatar(id: String, name: String, size: CGFloat) -> some View {
        if let avatar { avatar(id, name, size) }
        else {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(accent).frame(width: size, height: size)
                .background(accent.opacity(0.18), in: Circle())
        }
    }

    private func messageRow(_ message: RoomChatMessage, showsSender: Bool) -> some View {
        let own = message.senderID == currentParticipantID
        return HStack(alignment: .bottom) {
            if own { Spacer(minLength: 36) }
            else {
                messageAvatar(id: message.senderID, name: message.sender, size: 24)
                    .opacity(showsSender ? 1 : 0).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                if showsSender { Text(own ? "You" : message.sender).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                if let id = message.replyTo {
                    let original = messages.first { $0.id == id }
                    Label(original.map { "\($0.sender): \($0.text)" } ?? "Earlier message unavailable", systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(message.text).font(.system(size: 12)).textSelection(.enabled)
                    .foregroundStyle(message.deleted ? .secondary : .primary)
                if !message.deleted {
                    ForEach(RoomChatPresentation.links(in: message.text), id: \.absoluteString) { url in
                        Button {
                            if RoomChatPresentation.isWebURL(url) { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "link").font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.host ?? "Website").font(.system(size: 11, weight: .semibold))
                                    Text(url.path.isEmpty || url.path == "/" ? "Open website" : url.path.removingPercentEncoding ?? url.path)
                                        .font(.system(size: 10)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.system(size: 9))
                            }.foregroundStyle(accent).padding(8)
                                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).help("Open \(url.absoluteString) in your browser. Preview uses only the URL; the website has not been fetched.")
                    }
                }
                if message.edited || message.pinned {
                    HStack(spacing: 6) {
                        if message.edited { Text("edited") }
                        if message.pinned { Label("Pinned", systemImage: "pin.fill") }
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if !message.deleted {
                    HStack(spacing: 4) {
                        ForEach(RoomChatOperation.emoji.filter { !(message.reactions[$0] ?? []).isEmpty }, id: \.self) { emoji in
                            Button { react(emoji, to: message) } label: {
                                Text("\(emoji) \(message.reactions[emoji]?.count ?? 0)")
                                    .font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(accent.opacity(message.reactions[emoji]?.contains(currentParticipantID ?? "") == true ? 0.25 : 0.08), in: Capsule())
                            }.buttonStyle(.plain).help("Toggle your \(emoji) reaction")
                        }
                    }
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(own ? accent.opacity(0.2) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
            .contextMenu {
                if !message.deleted {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { replyTo = message.id; editing = nil; focused = true }
                    Menu("React") { ForEach(RoomChatOperation.emoji, id: \.self) { emoji in Button(emoji) { react(emoji, to: message) } } }
                    Button(message.pinned ? "Unpin for room" : "Pin for room", systemImage: "pin") { _ = send(.init(kind: .pin, target: message.id, enabled: !message.pinned)) }
                    if own {
                        Button("Edit", systemImage: "pencil") { editing = message.id; replyTo = nil; draft = message.text; focused = true }
                        Button("Delete message", systemImage: "trash", role: .destructive) { _ = send(.init(kind: .delete, target: message.id)) }
                    }
                }
            }
            if !own { Spacer(minLength: 36) }
        }
        .help("Right-click a message to reply, react, or pin it")
    }

    private func react(_ emoji: String, to message: RoomChatMessage) {
        _ = send(.init(kind: .reaction, target: message.id, text: emoji, enabled: !(message.reactions[emoji]?.contains(currentParticipantID ?? "") ?? false)))
    }
    private func submit() {
        guard validDraft else { return }
        let operation = RoomChatOperation(kind: editing == nil ? .message : .edit, target: editing ?? replyTo, text: draft.trimmingCharacters(in: .whitespacesAndNewlines))
        guard operation.encoded != nil else { return }
        guard send(operation) else { return }
        draft = ""; editing = nil; replyTo = nil; focused = true
    }
}
