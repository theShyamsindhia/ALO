import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ALOCore
import ALONotchRuntime

@MainActor
final class NotchRoomNavigation: ObservableObject {
    enum Page: String, CaseIterable {
        case home = "Room", conversation = "Chat", files = "Files", canvas = "Canvas", tools = "Tools"
        var symbol: String {
            switch self {
            case .home: "person.2.fill"
            case .conversation: "bubble.left.and.bubble.right.fill"
            case .files: "tray.full.fill"
            case .canvas: "pencil.and.outline"
            case .tools: "square.grid.2x2.fill"
            }
        }
    }
    @Published var page: Page = .home
    @Published var pendingFiles: [URL] = []
    @Published var choosingRecipient = false
    @Published var fileSection = 0
    let composer = RoomChatComposerContext()
    var layout: RoomNotchLayout {
        switch page {
        case .home: .tray
        case .tools: .tools
        case .conversation: .conversation
        case .files: choosingRecipient ? .recipients : .files
        case .canvas: .canvasPreview
        }
    }

    func stage(_ urls: [URL]) {
        pendingFiles = urls; choosingRecipient = true; page = .files
    }
}

struct ALONotchRoomWorkspace: View {
    @ObservedObject var model: ALOViewModel
    @ObservedObject var navigation: NotchRoomNavigation
    @ObservedObject var runtime: EmbeddedNotchRuntime
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if navigation.page != .home { workspaceHeader }
            Group {
                if model.phase != .live {
                    Text("You left the room. Join again to continue.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
                } else if navigation.page == .home {
                    HStack(spacing: 10) {
                        ForEach(NotchRoomNavigation.Page.allCases.filter { $0 != .home }, id: \.self) { page in
                            RoomNotchTile(page.rawValue, flexibleWidth: true, action: { navigation.page = page }) {
                                Image(systemName: page.symbol)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 88)
                } else if navigation.page == .conversation {
                    RoomChatPanel(messages: model.messages, currentParticipantID: model.currentParticipantID,
                        roomTitle: model.roomTitle, firstUnreadMessageID: model.firstUnreadMessageID,
                        unreadCount: model.unreadMessageCount, isPresented: runtime.isRoomInteractionExpanded, accent: .accentColor,
                        onLatestVisibilityChanged: model.setChatViewportAtLatest,
                        send: model.sendChatOperation, sendAttachment: model.sendChatAttachment,
                        attachmentURL: model.chatAttachmentURL, draft: $model.draftMessage,
                        notificationMode: $model.chatNotificationMode,
                        mentionNames: members.map(\.name),
                        mentionMembers: members.map { RoomMentionMember(id: $0.id, name: $0.name) },
                        usesNativeLayout: true, showsHeader: false, composer: navigation.composer)
                        .onAppear { model.notchChatIsPresented = runtime.isRoomInteractionExpanded }
                        .onChange(of: runtime.isRoomInteractionExpanded) { _, visible in model.notchChatIsPresented = visible }
                        .onDisappear { model.notchChatIsPresented = false }
                } else if navigation.page == .canvas {
                    if let canvas = model.roomCanvas {
                        NotchRoomCanvas(controller: canvas, participants: model.participants,
                            onSessionChanged: { active in
                                runtime.setRoomInteractionLayout(active && !canvas.isPoppedOut ? .canvas : .canvasPreview)
                            })
                            .onAppear {
                                canvas.onPopoutChanged = { poppedOut in
                                    guard navigation.page == .canvas else { return }
                                    runtime.setRoomInteractionLayout(poppedOut ? .canvasPreview : (canvas.snapshot != nil || canvas.state != nil ? .canvas : .canvasPreview))
                                }
                            }
                    } else {
                        Text("Join an ALO network channel to draw together.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
                    }
                } else if navigation.page == .tools {
                    runtime.roomToolsView(onShare: { urls in
                        guard model.phase == .live else { return }
                        navigation.stage(urls)
                    }, onTransfers: { navigation.fileSection = 0; navigation.choosingRecipient = false; navigation.page = .files })
                } else if let sharing = model.roomFileSharing {
                    NotchRoomFiles(model: model, sharing: sharing, navigation: navigation, runtime: runtime,
                        downloads: model.roomTrayDownloads)
                } else {
                    Text("Reconnect to this room to share files.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if navigation.page == .home { workspaceHeader }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear { model.notchChatIsPresented = false }
        .onChange(of: navigation.page) { _, page in
            runtime.updateRoomInteractionPreview(title: model.roomTitle, subtitle: page.rawValue)
            runtime.setRoomInteractionLayout(currentLayout)
        }
        .onAppear { runtime.setRoomInteractionLayout(currentLayout) }
        .onChange(of: navigation.choosingRecipient) { _, _ in
            if navigation.page == .files { runtime.setRoomInteractionLayout(navigation.layout) }
        }
        .accessibilityIdentifier("ALO.Notch.RoomWorkspace")
    }

    private var headerTitle: String {
        if navigation.page == .home { return model.roomTitle }
        if navigation.page == .tools, let toolTitle = runtime.selectedRoomToolTitle { return toolTitle }
        if navigation.page == .files && navigation.choosingRecipient {
            return navigation.pendingFiles.isEmpty
                ? "Share files"
                : navigation.pendingFiles.count == 1
                    ? navigation.pendingFiles[0].lastPathComponent
                    : "\(navigation.pendingFiles.count) files ready"
        }
        return navigation.page.rawValue
    }

    private func navigateBack() {
        if navigation.page == .tools, runtime.selectedRoomToolTitle != nil {
            runtime.clearSelectedRoomTool()
        } else if navigation.page == .files && navigation.choosingRecipient {
            navigation.pendingFiles = []
            navigation.choosingRecipient = false
        } else {
            navigation.page = .home
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 8) {
            if navigation.page != .home {
                Button(action: navigateBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.11), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.09), lineWidth: 0.75) }
                }
                .buttonStyle(.plain)
                .help("Back to room actions")
                .accessibilityLabel("Back to room actions")
            }
            Text(headerTitle)
                .font(.system(size: 12, weight: navigation.page == .home ? .medium : .semibold))
                .foregroundStyle(navigation.page == .home ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if navigation.page != .conversation, model.unreadMessageCount > 0 {
                    Button { navigation.page = .conversation } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text("\(model.unreadMessageCount)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(.white.opacity(0.11), in: Capsule())
                        .overlay { Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.75) }
                    }
                    .buttonStyle(.plain)
                    .help("Unread messages in this room")
                    .accessibilityLabel("\(model.unreadMessageCount) unread messages. Open conversation")
                }
                if let sharing = model.roomFileSharing {
                    NotchPendingFileButton(sharing: sharing) {
                        navigation.fileSection = 0
                        navigation.choosingRecipient = false
                        navigation.page = .files
                    }
                }
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.11), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.09), lineWidth: 0.75) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close room workspace")
            }
        }
    }

    private var members: [RoomParticipant] { model.participants.filter { $0.id != model.currentParticipantID } }
    private var currentLayout: RoomNotchLayout {
        if navigation.page == .tools { return runtime.roomToolsLayout }
        if navigation.page == .canvas, let canvas = model.roomCanvas,
           (canvas.snapshot != nil || canvas.state != nil), !canvas.isPoppedOut { return .canvas }
        return navigation.layout
    }
}

private struct NotchPendingFileButton: View {
    @ObservedObject var sharing: DirectFileSharingController
    let open: () -> Void
    var body: some View {
        let count = sharing.progress.filter { $0.state == .offered }.count
        if count > 0 {
            Button(action: open) {
                HStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(.white.opacity(0.11), in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.75) }
            }
            .buttonStyle(.plain)
            .help("\(count) file offers waiting for your decision")
            .accessibilityLabel("\(count) file offers. Open transfers")
        }
    }
}

struct NotchRoomFiles: View {
    @ObservedObject var model: ALOViewModel
    @ObservedObject var sharing: DirectFileSharingController
    @ObservedObject var navigation: NotchRoomNavigation
    let runtime: EmbeddedNotchRuntime
    @ObservedObject var downloads: RoomTrayDownloads
    @State private var fileError: String?
    @State private var roomShelfTargeted = false

    private var otherParticipants: [RoomParticipant] {
        model.participants.filter { $0.id != model.currentParticipantID }
    }

    var body: some View {
        VStack(spacing: 10) {
            if navigation.choosingRecipient {
                VStack(spacing: 8) {
                    if !otherParticipants.isEmpty {
                        if otherParticipants.count <= 4 {
                            HStack(spacing: 8) {
                                ForEach(otherParticipants) { person in
                                    personTarget(person, flexible: true)
                                }
                            }
                            .frame(height: 82)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(otherParticipants) { person in
                                        personTarget(person, flexible: false)
                                    }
                                }
                            }
                            .frame(height: 82)
                        }
                    }
                    HStack(spacing: 8) {
                        NotchPersonFileTarget(name: "Everyone", subtitle: "This channel", symbol: "person.2", choose: chooseRoomFiles,
                            receive: { urls in
                                model.addRoomTrayFiles(urls)
                                navigation.fileSection = 1; navigation.choosingRecipient = false
                            })
                        NotchPersonFileTarget(name: "My shelf", subtitle: "Only you", symbol: "tray", choose: {
                            navigation.fileSection = 2
                            if !navigation.pendingFiles.isEmpty { keepLocally(navigation.pendingFiles) }
                            else { navigation.choosingRecipient = false }
                        }, receive: keepLocally)
                        NotchPersonFileTarget(name: "AirDrop", subtitle: "Nearby", symbol: "antenna.radiowaves.left.and.right", choose: {
                            if !navigation.pendingFiles.isEmpty { airDrop(navigation.pendingFiles) }
                            else {
                                let picker = NSOpenPanel(); picker.allowsMultipleSelection = true; picker.canChooseDirectories = false
                                picker.begin { if $0 == .OK { airDrop(picker.urls) } }
                            }
                        }, receive: airDrop)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Picker("Files", selection: $navigation.fileSection) {
                        Text("Transfers").tag(0)
                        Text("Room shelf").tag(1)
                        Text("My shelf").tag(2)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 190)

                    Spacer(minLength: 8)

                    if navigation.fileSection == 1 {
                        Button(action: chooseRoomFiles) {
                            Label("Add…", systemImage: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.white.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isImportingRoomFiles)
                    }

                    Button { navigation.choosingRecipient = true } label: {
                        Label(navigation.pendingFiles.isEmpty ? "Share…" : "Resume…", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .controlSize(.small)

                if navigation.fileSection == 0 {
                    FileTransferProgressView(model: sharing, showsShareAction: true)
                } else if navigation.fileSection == 2 {
                    runtime.localFileShelfView
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.isImportingRoomFiles {
                            ProgressView("Preparing files…").controlSize(.small)
                        }
                        if let notice = model.roomTrayNotice {
                            Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if model.roomTrayItems.isEmpty {
                            Button(action: chooseRoomFiles) {
                                VStack(spacing: 6) {
                                    Image(systemName: "person.2.fill")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.75))
                                    Text("Drop files here or click to share with everyone")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                    Text("Shared with everyone in this channel · Up to 8 MB per file")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(.white.opacity(roomShelfTargeted ? 0.12 : 0.06))
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(
                                            roomShelfTargeted ? Color.accentColor.opacity(0.8) : .white.opacity(0.09),
                                            lineWidth: 0.75
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isImportingRoomFiles)
                        } else {
                            runtime.roomFileShelfView
                                .frame(maxWidth: .infinity, maxHeight: 136)
                        }
                        ForEach(model.roomTrayItems.filter { downloads.activeIDs.contains($0.id) }) { item in
                            HStack {
                                Text("Downloading \(item.attachment.fileName)…").font(.caption).lineLimit(1)
                                Spacer(minLength: 4)
                                Button("Cancel") { downloads.cancel(item.id) }.controlSize(.small)
                            }
                        }
                        ForEach(model.roomTrayItems.filter { downloads.error(for: $0.id) != nil }) { item in
                            Text("\(item.attachment.fileName): \(downloads.error(for: item.id) ?? "")")
                                .font(.caption).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $roomShelfTargeted) { providers in
                        NotchFileDrop.receive(providers, action: model.addRoomTrayFiles)
                    }
                }
            }
            if let fileError { Text(fileError).font(.caption).foregroundStyle(.red).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: navigation.pendingFiles) { old, new in
            if !old.isEmpty && new.isEmpty { navigation.choosingRecipient = false }
        }
    }

    private func personTarget(_ person: RoomParticipant, flexible: Bool) -> some View {
        NotchPersonFileTarget(
            name: person.name,
            subtitle: "Private",
            person: person,
            flexibleWidth: flexible,
            choose: {
                if navigation.pendingFiles.isEmpty {
                    sharing.chooseFile(to: person.id)
                    navigation.choosingRecipient = false
                } else if let peer = UUID(uuidString: person.id) {
                    navigation.pendingFiles.forEach { sharing.send($0, to: peer) }
                    navigation.pendingFiles = []
                }
                navigation.fileSection = 0
            },
            receive: { urls in
                guard let peer = UUID(uuidString: person.id) else { return }
                urls.forEach { sharing.send($0, to: peer) }
                navigation.fileSection = 0
                navigation.choosingRecipient = false
            }
        )
    }

    private func chooseRoomFiles() {
        navigation.fileSection = 1
        if !navigation.pendingFiles.isEmpty {
            model.addRoomTrayFiles(navigation.pendingFiles)
            navigation.pendingFiles = []
            return
        }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = true
        picker.prompt = "Share with room"
        picker.begin { response in
            if response == .OK {
                model.addRoomTrayFiles(picker.urls)
                navigation.choosingRecipient = false
            }
        }
    }

    private func keepLocally(_ urls: [URL]) {
        Task {
            do {
                try await runtime.keepFilesLocally(urls)
                navigation.pendingFiles = []; navigation.fileSection = 2; navigation.choosingRecipient = false; fileError = nil
            } catch { fileError = error.localizedDescription }
        }
    }

    private func airDrop(_ urls: [URL]) {
        if runtime.shareFilesViaAirDrop(urls) {
            navigation.pendingFiles = []; navigation.choosingRecipient = false; fileError = nil
        }
        else { fileError = "AirDrop could not accept these files." }
    }

}

struct NotchPersonFileTarget: View {
    let name: String
    let subtitle: String
    var symbol: String? = nil
    var person: RoomParticipant? = nil
    var flexibleWidth: Bool = true
    let choose: () -> Void
    let receive: ([URL]) -> Void
    @State private var targeted = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: choose) {
            VStack(spacing: 4) {
                Group {
                    if let person {
                        let appearance = DeviceAppearance.generated(from: person.id)
                        DeviceAvatar(emoji: person.icon ?? appearance.icon,
                                     colorHex: person.colorHex ?? appearance.colorHex,
                                     profileImageData: person.profileImageData, size: 32)
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.accentColor).frame(height: 25)
                    }
                }.scaleEffect(targeted && !reduceMotion ? 1.08 : 1)
                Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(targeted ? "Drop here" : subtitle)
                    .font(.system(size: 9)).foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .frame(width: flexibleWidth ? nil : 76)
            .frame(maxWidth: flexibleWidth ? .infinity : nil)
            .background(targeted ? Color.accentColor.opacity(0.18) : Color.white.opacity(hovered ? 0.12 : 0.07),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(targeted ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
            .buttonStyle(.plain)
            .frame(maxWidth: flexibleWidth ? .infinity : nil)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: targeted)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .accessibilityLabel(symbol == nil ? "Send a file privately to \(name)" : "Choose \(name) as the file destination")
            .help(symbol == nil ? "Private file offer to \(name)" : name == "Everyone" ? "Share on the room shelf" : name == "My shelf" ? "Keep a private copy" : "Open Apple’s AirDrop interface")
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) {
                NotchFileDrop.receive($0, action: receive)
            }
    }
}

enum NotchFileDrop {
    @MainActor
    static func receive(_ providers: [NSItemProvider], action: @escaping ([URL]) -> Void) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }
        // Preserve drop order. Membership and transport limits are checked by
        // the owning controller again after asynchronous pasteboard loading.
        Task { @MainActor in
            var urls: [URL] = []
            for provider in accepted {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            if !urls.isEmpty { action(urls) }
        }
        return true
    }
}
