import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ALOCore
import ALONetworkUI

/// The complete chat surface is independent of room navigation and playback.
struct RoomChatPanel: View {
    @Environment(\.aloCompactNetworkLayout) private var compactLayout
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
    @State private var sendError = "There is no active channel connection. Your draft has been kept."
    @State private var selectedSuggestion = 0
    @State private var dismissedMentionDraft: String?
    @State private var choosesAttachment = false
    @State private var attachmentDropTargeted = false
    @Binding var draft: String
    @Binding var notificationMode: ChatNotificationMode
    let mentionNames: [String]
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool
    var avatar: ((String, String, CGFloat) -> AnyView)? = nil
    var mentionMembers: [RoomMentionMember] = []
    var usesNativeLayout = false
    var showsHeader = true
    var subtitle = ""
    var headerActions: AnyView? = nil
    var channelMenu: AnyView? = nil
    @StateObject var composer = RoomChatComposerContext()

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
        return (hasText || (composer.editing == nil && composer.pendingAttachment != nil))
            && draft.count <= RoomChatOperation.maximumTextLength
    }
    var body: some View {
        VStack(spacing: 0) {
            if usesNativeLayout && showsHeader {
                NetworkConversationHeader(title: roomTitle, subtitle: subtitle) {
                    headerActions
                    chatMenu
                }
            }
            if !usesNativeLayout || showsSearch || onlyPins {
            HStack(spacing: 8) {
                if showsSearch {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search messages", text: $query).textFieldStyle(.plain).focused($searchFocused)
                        .onKeyPress(keys: [.escape], phases: .down) { _ in closeSearch(); return .handled }
                        .accessibilityLabel("Search channel history")
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
                if !usesNativeLayout || !showsHeader { chatMenu }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .frame(height: showsSearch || onlyPins ? 32 : 24)
            }
            ChatTranscript(messages: filtered, currentParticipantID: currentParticipantID,
                firstUnreadMessageID: query.isEmpty && !onlyPins ? firstUnreadMessageID : nil,
                unreadCount: unreadCount, isPresented: isPresented && query.isEmpty && !onlyPins,
                accent: accent, onLatestVisibilityChanged: onLatestVisibilityChanged,
                usesNativeLayout: usesNativeLayout, horizontalInset: isNotch ? 0 : nil) { message, showsSender in
                    messageRow(message, showsSender: showsSender)
                }
                .overlay {
                    if filtered.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: onlyPins ? "pin" : "bubble.left.and.bubble.right").font(.title2)
                            Text(messages.isEmpty ? "Start the conversation" : "No matching messages").font(.callout)
                            if messages.isEmpty { Text("Everyone in the channel can see your messages.").font(.caption) }
                        }.foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
            Divider().opacity(0.4)
            if let target = composer.editing ?? composer.replyTo, let message = messages.first(where: { $0.id == target }) {
                HStack {
                    Label(composer.editing == nil ? "Reply to \(message.sender)" : "Editing your message", systemImage: composer.editing == nil ? "arrowshape.turn.up.left" : "pencil")
                    Text(message.text).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { composer.editing = nil; composer.replyTo = nil; draft = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Cancel")
                }.font(.caption).padding(.horizontal, 14).padding(.top, 8)
            }
            if !mentionSuggestions.isEmpty { mentionPicker }
            if let pendingAttachment = composer.pendingAttachment { pendingAttachmentPreview(pendingAttachment) }
            HStack(alignment: .center, spacing: 8) {
                if usesNativeLayout && !showsHeader { chatMenu }
                Button { choosesAttachment = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: usesNativeLayout ? 16 : 12, weight: .medium))
                        .frame(width: usesNativeLayout ? 32 : 24, height: usesNativeLayout ? 32 : 24)
                        .background(.primary.opacity(usesNativeLayout ? 0.045 : 0), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(composer.editing != nil)
                .help("Attach a file up to 8 MB")
                .accessibilityLabel("Attach file")
                if !usesNativeLayout { messageAvatar(id: currentParticipantID ?? "", name: "You", size: 22)
                    .accessibilityHidden(true)
                }
                HStack(spacing: 8) {
                TextField(usesNativeLayout && !showsHeader ? "Message…" : "Message \(roomTitle)", text: $draft, axis: .vertical)
                    .accessibilityLabel("Message \(roomTitle)")
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
                    Image(systemName: composer.editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: usesNativeLayout ? 28 : 22)).foregroundStyle(accent)
                }.buttonStyle(.plain).disabled(!validDraft).help(composer.editing == nil ? "Send message" : "Save edit")
                    .accessibilityLabel(composer.editing == nil ? "Send message" : "Save edit")
                }
                .padding(.leading, usesNativeLayout ? 16 : 0).padding(.trailing, usesNativeLayout ? 7 : 0)
                .padding(.vertical, usesNativeLayout ? 7 : 0)
                .background(.primary.opacity(usesNativeLayout ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 23))
                .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.primary.opacity(usesNativeLayout ? 0.1 : 0)))
            }.font(isNotch ? .system(size: 13) : usesNativeLayout ? ALONetworkTypography.body : .system(size: 12))
                .padding(.horizontal, usesNativeLayout ? (!showsHeader ? 0 : (compactLayout ? 16 : 24)) : 10)
                .padding(.vertical, usesNativeLayout ? (compactLayout ? 10 : 14) : 7)
                .background(.primary.opacity(usesNativeLayout ? 0 : 0.045), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, usesNativeLayout ? 0 : 10).padding(.vertical, usesNativeLayout ? 0 : 6)

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
            if value.isEmpty { composer.chosenMentionIDs = [] }
        }
        .onKeyPress(keys: ["k"], phases: .down) { press in
            guard isPresented, press.modifiers == .command else { return .ignored }
            openSearch(); return .handled
        }
        .onChange(of: isPresented) { _, visible in if visible { focused = !showsSearch; searchFocused = showsSearch } }
        .onAppear { if !showsHeader && isPresented { focused = true } }
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
        composer.chosenMentionIDs.insert(member.id); dismissedMentionDraft = draft; focused = true
    }
    private func openSearch() {
        guard isPresented else { return }
        onlyPins = false; showsSearch = true; focused = false
        DispatchQueue.main.async { searchFocused = true }
    }
    private func closeSearch() { query = ""; showsSearch = false; searchFocused = false; focused = true }

    private var chatMenu: some View {
        Menu {
            if let channelMenu { channelMenu; Divider() }
            Button("Search messages", systemImage: "magnifyingglass", action: openSearch)
                .keyboardShortcut("k", modifiers: .command).disabled(!isPresented)
            Button(onlyPins ? "Show all messages" : "Pinned messages", systemImage: "pin") {
                onlyPins.toggle(); query = ""; showsSearch = false
            }
            Menu("Mention a member") {
                if mentionMembers.isEmpty { Text("No other channel members") }
                ForEach(mentionMembers) { member in
                    Button(member.name) { insertMention(member) }
                }
            }
            Menu("Collapsed chat previews") {
                Picker("Show a snippet while chat is collapsed", selection: $notificationMode) {
                    ForEach(ChatNotificationMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                }
                Text("Controls snippets in the compact channel bar. Direct mentions also notify you when ALO is in the background, if macOS notifications are allowed.")
            }
            Divider()
            Button("History", systemImage: "info.circle") { showsHistory = true }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                .foregroundStyle(usesNativeLayout ? accent : .secondary)
                .frame(width: usesNativeLayout ? 28 : 24, height: usesNativeLayout ? 32 : 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Chat options").accessibilityLabel("Chat options")
        .popover(isPresented: $showsHistory) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Channel history").font(.headline)
                Text("Up to 500 chat events are retained. Edits and reactions count toward this limit; older messages may disappear.")
                Text("Pins do not bypass retention. All members need an updated app for replies, reactions and edits.")
                Text("Files up to 8 MB are transferred directly to members currently connected to the channel and cached on each Mac.")
                Text("Collapsed chat previews show incoming snippets in the compact channel bar. This setting applies across channels; unread counts remain visible when muted.")
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

    private func displayText(_ text: String, own: Bool) -> AttributedString {
        var result = AttributedString(text)
        if usesNativeLayout && !own {
            for name in mentionNames {
                if let range = result.range(of: "@" + name) {
                    result[range].foregroundColor = accent
                    result[range].font = ALONetworkTypography.label
                }
            }
        }
        return result
    }

    private var isNotch: Bool { usesNativeLayout && !showsHeader }

    private func messageRow(_ message: RoomChatMessage, showsSender: Bool) -> some View {
        let own = message.senderID == currentParticipantID
        let localAttachmentURL = message.attachment == nil ? nil : attachmentURL(message)
        return HStack(alignment: .bottom, spacing: isNotch ? 8 : usesNativeLayout ? (compactLayout ? 10 : 16) : 8) {
            if own { Spacer(minLength: isNotch ? 8 : 36) }
            else {
                messageAvatar(id: message.senderID, name: message.sender, size: usesNativeLayout && !isNotch ? 32 : 24)
                    .opacity(showsSender ? 1 : 0).accessibilityHidden(true)
            }
            VStack(alignment: own ? .trailing : .leading, spacing: 6) {
            if usesNativeLayout && showsSender && !own {
                Text(message.sender).font(ALONetworkTypography.caption).foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 5) {
                if showsSender && !usesNativeLayout { Text(own ? "You" : message.sender).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                if let id = message.replyTo {
                    let original = messages.first { $0.id == id }
                    Label(original.map { "\($0.sender): \($0.text)" } ?? "Earlier message unavailable", systemImage: "arrowshape.turn.up.left")
                        .font(usesNativeLayout ? ALONetworkTypography.caption : .system(size: 10))
                        .foregroundStyle(usesNativeLayout && own ? Color.white.opacity(0.85) : .secondary).lineLimit(2)
                }
                if !message.text.isEmpty || message.deleted {
                    Text(displayText(message.text, own: own))
                        .font(isNotch ? .system(size: 13) : usesNativeLayout ? ALONetworkTypography.body : .system(size: 12)).textSelection(.enabled)
                        .foregroundStyle(usesNativeLayout && own ? Color.white : message.deleted ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.deleted, let attachment = message.attachment {
                    if usesNativeLayout, let localAttachmentURL,
                       attachment.contentType.flatMap(UTType.init)?.conforms(to: .image) == true {
                        ChatInlineImage(url: localAttachmentURL, name: attachment.fileName) {
                            attachmentCard(attachment, localURL: localAttachmentURL)
                        }
                    } else {
                        attachmentCard(attachment, localURL: localAttachmentURL)
                    }
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
                            }.foregroundStyle(usesNativeLayout && own ? Color.white : accent).padding(8)
                                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).help("Open \(url.absoluteString) in your browser. Preview uses only the URL; the website has not been fetched.")
                    }
                }
                if message.edited || message.pinned {
                    HStack(spacing: 6) {
                        if message.edited { Text("edited") }
                        if message.pinned { Label("Pinned", systemImage: "pin.fill") }
                    }.font(.system(size: 9)).foregroundStyle(usesNativeLayout && own ? Color.white.opacity(0.8) : .secondary)
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
            .padding(.horizontal, usesNativeLayout ? (message.text.isEmpty && message.attachment != nil ? 0 : isNotch ? 10 : compactLayout ? 12 : 16) : 11)
            .padding(.vertical, usesNativeLayout ? (message.text.isEmpty && message.attachment != nil ? 0 : isNotch || compactLayout ? 8 : 11) : 8)
            .background(usesNativeLayout && message.text.isEmpty && message.attachment != nil ? .clear :
                own ? accent.opacity(usesNativeLayout ? 1 : 0.2) : Color.primary.opacity(usesNativeLayout ? 0.055 : 0.07),
                in: RoundedRectangle(cornerRadius: usesNativeLayout ? 18 : 13))
            }
            .contextMenu {
                if !message.deleted {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { composer.replyTo = message.id; composer.editing = nil; focused = true }
                    Menu("React") { ForEach(RoomChatOperation.emoji, id: \.self) { emoji in Button(emoji) { react(emoji, to: message) } } }
                    Button(message.pinned ? "Unpin for channel" : "Pin for channel", systemImage: "pin") { _ = send(.init(kind: .pin, target: message.id, enabled: !message.pinned)) }
                    if own {
                        Button("Edit", systemImage: "pencil") { composer.editing = message.id; composer.replyTo = nil; composer.pendingAttachment = nil; draft = message.text; composer.chosenMentionIDs = Set(message.mentionedParticipantIDs ?? []); focused = true }
                        Button("Delete message", systemImage: "trash", role: .destructive) { _ = send(.init(kind: .delete, target: message.id)) }
                    }
                    if let localAttachmentURL {
                        Divider()
                        Button("Open attachment", systemImage: "arrow.up.right.square") {
                            NSWorkspace.shared.open(localAttachmentURL)
                        }
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([localAttachmentURL])
                        }
                    }
                }
            }
            if !own { Spacer(minLength: isNotch ? 8 : 36) }
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
            return composer.chosenMentionIDs.contains(member.id) || mentionMembers.filter { $0.name.caseInsensitiveCompare(member.name) == .orderedSame }.count == 1
        }.map(\.id)
        let operation = RoomChatOperation(kind: composer.editing == nil ? .message : .edit,
                                          target: composer.editing ?? composer.replyTo,
                                          text: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                          mentionedParticipantIDs: Array(Set(ids)).sorted(),
                                          attachment: composer.editing == nil ? composer.pendingAttachment?.metadata : nil)
        guard operation.encoded != nil else {
            sendError = ids.count > 8 ? "Use at most eight mentions in one message. Your draft has been kept." : "This message is too large to send with its mentions. Shorten it and try again."
            sendFailed = true; return
        }
        let sent = composer.pendingAttachment.map { sendAttachment(operation, $0.url) } ?? send(operation)
        guard sent else { sendError = "The message or attachment could not be sent. Your draft has been kept."; sendFailed = true; return }
        draft = ""; composer.reset(); focused = true
    }

    private func selectAttachment(_ url: URL) -> Bool {
        guard composer.editing == nil, url.isFileURL else { return false }
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
        composer.pendingAttachment = PendingChatAttachment(url: url, metadata: metadata)
        focused = true
        return true
    }

    private func pendingAttachmentPreview(_ attachment: PendingChatAttachment) -> some View {
        HStack(spacing: 9) {
            filePreview(url: attachment.url, contentType: attachment.metadata.contentType,
                        allowsImagePreview: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.metadata.fileName).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.metadata.byteCount), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { composer.pendingAttachment = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).help("Remove attachment").accessibilityLabel("Remove attachment")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10).padding(.top, 6)
    }

    private func attachmentCard(_ attachment: RoomChatAttachment, localURL: URL?) -> some View {
        HStack(spacing: 4) {
            Button {
                if let localURL { NSWorkspace.shared.open(localURL) }
            } label: {
                HStack(spacing: 9) {
                    filePreview(url: localURL, contentType: attachment.contentType,
                                allowsImagePreview: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName).font(usesNativeLayout ? ALONetworkTypography.label : .system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(localURL == nil
                             ? "Waiting for file…"
                             : ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                            .font(usesNativeLayout ? ALONetworkTypography.caption : .system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: localURL == nil ? "arrow.down.circle" : "arrow.up.right.square")
                        .font(.system(size: 11)).foregroundStyle(accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(localURL == nil)
            .help(localURL == nil ? "The sender must be connected for this file to transfer" : "Open attachment")
            if let localURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([localURL])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
                .accessibilityLabel("Show \(attachment.fileName) in Finder")
            }
        }
        .padding(usesNativeLayout ? 12 : 8).frame(minWidth: 190)
        .background(usesNativeLayout ? Color(nsColor: .controlBackgroundColor) : accent.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: usesNativeLayout ? 14 : 9))
    }

    @ViewBuilder
    private func filePreview(url: URL?, contentType: String?, allowsImagePreview: Bool) -> some View {
        if allowsImagePreview, let url,
           contentType.flatMap(UTType.init)?.conforms(to: .image) == true,
           let image = Self.boundedThumbnail(at: url) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            Image(systemName: "doc.fill")
                .font(.system(size: 16)).foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    fileprivate static func boundedThumbnail(at url: URL, maximumPixelSize: Int = 96) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) == 1,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width > 0, height > 0, width <= 8_192, height <= 8_192,
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

struct PendingChatAttachment {
    let url: URL
    let metadata: RoomChatAttachment
}

/// The notch owns this context across page changes and collapse. Other chat
/// hosts retain their own StateObject, preserving their existing lifecycle.
@MainActor
final class RoomChatComposerContext: ObservableObject {
    @Published var chosenMentionIDs = Set<String>()
    @Published var pendingAttachment: PendingChatAttachment?
    @Published var replyTo: UUID?
    @Published var editing: UUID?

    func reset() {
        chosenMentionIDs = []
        pendingAttachment = nil
        replyTo = nil
        editing = nil
    }
}

/// Decode once per local file, never fetch a remote preview or decode full-size media.
private struct ChatInlineImage<Fallback: View>: View {
    let url: URL
    let name: String
    @ViewBuilder var fallback: () -> Fallback
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .frame(maxWidth: 350, maxHeight: 210, alignment: .leading)
                }
                .buttonStyle(.plain).accessibilityLabel("Open image: \(name)")
                .help(name)
            } else { fallback() }
        }
        .task(id: url) {
            thumbnail = RoomChatPanel.boundedThumbnail(at: url, maximumPixelSize: 700)
        }
    }
}
