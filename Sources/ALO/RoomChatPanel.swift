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
    @State private var sendFailed = false
    @State private var sendError = "There is no active room connection. Your draft has been kept."
    @State private var selectedSuggestion = 0
    @State private var dismissedMentionDraft: String?
    @State private var chosenMentionIDs = Set<String>()
    @Binding var draft: String
    @Binding var notificationMode: ChatNotificationMode
    let mentionNames: [String]
    @State private var replyTo: UUID?
    @State private var editing: UUID?
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool
    var avatar: ((String, String, CGFloat) -> AnyView)? = nil
    var mentionMembers: [RoomMentionMember] = []

    private var mentionToken: RoomMentionCompletion.Token? {
        guard focused, dismissedMentionDraft != draft else { return nil }
        return RoomMentionCompletion.token(in: draft, selection: NSRange(location: draft.utf16.count, length: 0))
    }
    private var mentionSuggestions: [RoomMentionMember] {
        guard let token = mentionToken else { return [] }
        return Array(RoomMentionCompletion.suggestions(for: token, members: mentionMembers).prefix(6))
    }
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
                    TextField("Search messages", text: $query).textFieldStyle(.plain).focused($searchFocused)
                        .onKeyPress(keys: [.escape], phases: .down) { _ in closeSearch(); return .handled }
                        .accessibilityLabel("Search room history")
                    Button(action: closeSearch) { Image(systemName: "xmark") }
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
            if !mentionSuggestions.isEmpty { mentionPicker }
            HStack(alignment: .center, spacing: 8) {
                messageAvatar(id: currentParticipantID ?? "", name: "You", size: 22)
                    .accessibilityHidden(true)
                TextField("Message \(roomTitle)", text: $draft, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.plain).focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        if !mentionSuggestions.isEmpty { chooseSuggestion() } else { submit() }
                        return .handled
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down) { press in
                        guard !mentionSuggestions.isEmpty else { return .ignored }
                        switch press.key {
                        case .upArrow: selectedSuggestion = (selectedSuggestion + mentionSuggestions.count - 1) % mentionSuggestions.count
                        case .downArrow: selectedSuggestion = (selectedSuggestion + 1) % mentionSuggestions.count
                        case .tab: chooseSuggestion()
                        default: dismissedMentionDraft = draft
                        }
                        return .handled
                    }
                if draft.count > 600 { Text("\(draft.count)/700").font(.caption2).foregroundStyle(draft.count > 700 ? .red : .secondary) }
                Button(action: submit) {
                    Image(systemName: editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 22)).foregroundStyle(accent)
                }.buttonStyle(.plain).disabled(!validDraft).help(editing == nil ? "Send message" : "Save edit")
            }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 10).padding(.vertical, 6)

        }
        .dropDestination(for: URL.self) { urls, _ in
            let links = urls.filter(RoomChatPresentation.isWebURL).prefix(3).map(\.absoluteString).joined(separator: " ")
            let proposed = draft + (draft.isEmpty ? "" : " ") + links
            guard !links.isEmpty, proposed.count <= RoomChatOperation.maximumTextLength else { return false }
            draft = proposed; focused = true; return true
        }
        .alert("Message not sent", isPresented: $sendFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sendError)
        }
        .onChange(of: draft) { _, value in
            selectedSuggestion = 0
            if value.isEmpty { chosenMentionIDs = [] }
        }
        .onKeyPress(keys: ["k"], phases: .down) { press in
            guard isPresented, press.modifiers == .command else { return .ignored }
            openSearch(); return .handled
        }
        .onChange(of: isPresented) { _, visible in if visible { focused = !showsSearch; searchFocused = showsSearch } }
    }

    private var mentionPicker: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(mentionSuggestions.enumerated()), id: \.element.id) { index, member in
                Button { insertMention(member) } label: {
                    HStack(spacing: 8) {
                        messageAvatar(id: member.id, name: member.name, size: 22)
                        Text(member.name).lineLimit(1)
                        Spacer()
                        if index == selectedSuggestion { Text("↵").foregroundStyle(.secondary) }
                    }.font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(index == selectedSuggestion ? accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityLabel("Mention \(member.name)")
            }
        }.padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 10).padding(.top, 5)
    }
    private func chooseSuggestion() {
        guard mentionSuggestions.indices.contains(selectedSuggestion) else { return }
        insertMention(mentionSuggestions[selectedSuggestion])
    }
    private func insertMention(_ member: RoomMentionMember) {
        if let token = mentionToken, let inserted = RoomMentionCompletion.inserting(member, at: token, in: draft) {
            draft = inserted.text
        } else {
            let proposed = draft + (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + "@" + member.name + " "
            guard proposed.count <= RoomChatOperation.maximumTextLength else { return }
            draft = proposed
        }
        chosenMentionIDs.insert(member.id); dismissedMentionDraft = draft; focused = true
    }
    private func openSearch() {
        guard isPresented else { return }
        onlyPins = false; showsSearch = true; focused = false
        DispatchQueue.main.async { searchFocused = true }
    }
    private func closeSearch() { query = ""; showsSearch = false; searchFocused = false; focused = true }

    private var chatMenu: some View {
        Menu {
            Button("Search messages", systemImage: "magnifyingglass", action: openSearch)
                .keyboardShortcut("k", modifiers: .command).disabled(!isPresented)
            Button(onlyPins ? "Show all messages" : "Pinned messages", systemImage: "pin") {
                onlyPins.toggle(); query = ""; showsSearch = false
            }
            Menu("Mention a member") {
                if mentionMembers.isEmpty { Text("No other room members") }
                ForEach(mentionMembers) { member in
                    Button(member.name) { insertMention(member) }
                }
            }
            Menu("Collapsed chat previews") {
                Picker("Show a snippet while chat is collapsed", selection: $notificationMode) {
                    ForEach(ChatNotificationMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                }
                Text("Shows an incoming-message snippet in the compact room bar when chat is collapsed. No macOS notifications are sent.")
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
                Text("Collapsed chat previews show incoming snippets in the compact room bar. This setting applies across rooms; unread counts remain visible when muted.")
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
                        Button("Edit", systemImage: "pencil") { editing = message.id; replyTo = nil; draft = message.text; chosenMentionIDs = Set(message.mentionedParticipantIDs ?? []); focused = true }
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
        let ids = mentionMembers.filter { member in
            guard RoomChatPresentation.containsMention(of: member.name, in: draft) else { return false }
            return chosenMentionIDs.contains(member.id) || mentionMembers.filter { $0.name.caseInsensitiveCompare(member.name) == .orderedSame }.count == 1
        }.map(\.id)
        let operation = RoomChatOperation(kind: editing == nil ? .message : .edit, target: editing ?? replyTo, text: draft.trimmingCharacters(in: .whitespacesAndNewlines), mentionedParticipantIDs: Array(Set(ids)).sorted())
        guard operation.encoded != nil else {
            sendError = ids.count > 8 ? "Use at most eight mentions in one message. Your draft has been kept." : "This message is too large to send with its mentions. Shorten it and try again."
            sendFailed = true; return
        }
        guard send(operation) else { sendError = "There is no active room connection. Your draft has been kept."; sendFailed = true; return }
        draft = ""; editing = nil; replyTo = nil; chosenMentionIDs = []; focused = true
    }
}
