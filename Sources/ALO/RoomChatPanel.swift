import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
    let sendAttachment: (RoomChatOperation, URL) -> Bool
    let attachmentURL: (RoomChatMessage) -> URL?
    @State private var query = ""
    @State private var onlyPins = false
    @State private var showsSearch = false
    @State private var showsHistory = false
    @State private var sendFailed = false
    @State private var sendError = "There is no active room connection. Your draft has been kept."
    @State private var selectedSuggestion = 0
    @State private var dismissedMentionDraft: String?
    @State private var chosenMentionIDs = Set<String>()
    @State private var pendingAttachment: PendingChatAttachment?
    @State private var choosesAttachment = false
    @State private var attachmentDropTargeted = false
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
        messages.filter { message in
            (!onlyPins || message.pinned) && (query.isEmpty || (!message.deleted
                && (message.text.localizedCaseInsensitiveContains(query)
                    || message.sender.localizedCaseInsensitiveContains(query)
                    || (message.attachment?.fileName.localizedCaseInsensitiveContains(query) ?? false))))
        }
    }
    private var validDraft: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || (editing == nil && pendingAttachment != nil))
            && draft.count <= RoomChatOperation.maximumTextLength
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
            if let pendingAttachment { pendingAttachmentPreview(pendingAttachment) }
            HStack(alignment: .center, spacing: 8) {
                Button { choosesAttachment = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(editing != nil)
                .help("Attach a file up to 8 MB")
                .accessibilityLabel("Attach file")
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
            if let file = urls.first(where: \.isFileURL), selectAttachment(file) {
                return true
            }
            let links = urls.filter(RoomChatPresentation.isWebURL).prefix(3).map(\.absoluteString).joined(separator: " ")
            let proposed = draft + (draft.isEmpty ? "" : " ") + links
            guard !links.isEmpty, proposed.count <= RoomChatOperation.maximumTextLength else { return false }
            draft = proposed; focused = true; return true
        } isTargeted: { targeted in
            attachmentDropTargeted = targeted
        }
        .overlay {
            if attachmentDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .fill(accent.opacity(0.08))
                    .overlay {
                        Label("Drop file to attach", systemImage: "paperclip")
                            .font(.headline).foregroundStyle(accent)
                            .padding(14).background(.regularMaterial, in: Capsule())
                    }
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent, style: StrokeStyle(lineWidth: 2, dash: [7])))
                    .padding(5).allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $choosesAttachment, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = selectAttachment(url)
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
                Text("Controls snippets in the compact room bar. Direct mentions also notify you when ALO is in the background, if macOS notifications are allowed.")
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
                Text("Files up to 8 MB are transferred directly to members currently connected to the room and cached on each Mac.")
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
                if !message.text.isEmpty || message.deleted {
                    Text(message.text).font(.system(size: 12)).textSelection(.enabled)
                        .foregroundStyle(message.deleted ? .secondary : .primary)
                }
                if !message.deleted, let attachment = message.attachment {
                    attachmentCard(attachment, localURL: attachmentURL(message))
                }
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
                        Button("Edit", systemImage: "pencil") { editing = message.id; replyTo = nil; pendingAttachment = nil; draft = message.text; chosenMentionIDs = Set(message.mentionedParticipantIDs ?? []); focused = true }
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
        let operation = RoomChatOperation(kind: editing == nil ? .message : .edit,
                                          target: editing ?? replyTo,
                                          text: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                          mentionedParticipantIDs: Array(Set(ids)).sorted(),
                                          attachment: editing == nil ? pendingAttachment?.metadata : nil)
        guard operation.encoded != nil else {
            sendError = ids.count > 8 ? "Use at most eight mentions in one message. Your draft has been kept." : "This message is too large to send with its mentions. Shorten it and try again."
            sendFailed = true; return
        }
        let sent = pendingAttachment.map { sendAttachment(operation, $0.url) } ?? send(operation)
        guard sent else { sendError = "The message or attachment could not be sent. Your draft has been kept."; sendFailed = true; return }
        draft = ""; editing = nil; replyTo = nil; chosenMentionIDs = []; pendingAttachment = nil; focused = true
    }

    private func selectAttachment(_ url: URL) -> Bool {
        guard editing == nil, url.isFileURL else { return false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
              values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else {
            sendError = "Choose a regular file that is not empty."
            sendFailed = true
            return false
        }
        guard bytes <= RoomChatAttachment.maximumBytes else {
            sendError = "Attachments can be up to 8 MB."
            sendFailed = true
            return false
        }
        let metadata = RoomChatAttachment(fileName: url.lastPathComponent,
                                          contentType: values.contentType?.identifier,
                                          byteCount: bytes)
        guard metadata.isValid else {
            sendError = "That file cannot be attached."
            sendFailed = true
            return false
        }
        pendingAttachment = PendingChatAttachment(url: url, metadata: metadata)
        focused = true
        return true
    }

    private func pendingAttachmentPreview(_ attachment: PendingChatAttachment) -> some View {
        HStack(spacing: 9) {
            filePreview(url: attachment.url, contentType: attachment.metadata.contentType)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.metadata.fileName).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.metadata.byteCount), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { pendingAttachment = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).help("Remove attachment").accessibilityLabel("Remove attachment")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10).padding(.top, 6)
    }

    private func attachmentCard(_ attachment: RoomChatAttachment, localURL: URL?) -> some View {
        Button {
            if let localURL { NSWorkspace.shared.open(localURL) }
        } label: {
            HStack(spacing: 9) {
                filePreview(url: localURL, contentType: attachment.contentType)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(localURL == nil
                         ? "Waiting for file…"
                         : ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: localURL == nil ? "arrow.down.circle" : "arrow.up.right.square")
                    .font(.system(size: 11)).foregroundStyle(accent)
            }
            .padding(8).frame(minWidth: 190)
            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(localURL == nil)
        .help(localURL == nil ? "The sender must be connected for this file to transfer" : "Open attachment")
    }

    @ViewBuilder
    private func filePreview(url: URL?, contentType: String?) -> some View {
        if let url, contentType.flatMap(UTType.init)?.conforms(to: .image) == true,
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            Image(systemName: "doc.fill")
                .font(.system(size: 16)).foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct PendingChatAttachment {
    let url: URL
    let metadata: RoomChatAttachment
}
