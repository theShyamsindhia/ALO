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
        case .home, .tools: .tray
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
            HStack(spacing: 8) {
                if navigation.page != .home {
                    Button { navigation.page = .home } label: {
                        Image(systemName: "chevron.left").frame(width: 24, height: 24)
                    }.buttonStyle(.plain).help("Back to room actions").accessibilityLabel("Back to room actions")
                }
                Label(navigation.page == .home ? model.roomTitle : navigation.page.rawValue,
                      systemImage: navigation.page.symbol)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if navigation.page != .conversation, model.unreadMessageCount > 0 {
                    Button { navigation.page = .conversation } label: {
                        Label("\(model.unreadMessageCount)", systemImage: "bubble.left")
                    }
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
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("Close room workspace")
            }
            Group {
            if model.phase != .live {
                Text("You left the room. Join again to continue.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else if navigation.page == .home {
                RoomNotchTray {
                    ForEach(NotchRoomNavigation.Page.allCases.filter { $0 != .home }, id: \.self) { page in
                        RoomNotchTile(page.rawValue, action: { navigation.page = page }) {
                            Image(systemName: page.symbol)
                        }
                    }
                }
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
                        onSessionChanged: { active in runtime.setRoomInteractionLayout(active ? .canvas : .canvasPreview) })
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
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private var members: [RoomParticipant] { model.participants.filter { $0.id != model.currentParticipantID } }
    private var currentLayout: RoomNotchLayout {
        if navigation.page == .canvas, let canvas = model.roomCanvas,
           canvas.snapshot != nil || canvas.state != nil { return .canvas }
        return navigation.layout
    }
}

private struct NotchPendingFileButton: View {
    @ObservedObject var sharing: DirectFileSharingController
    let open: () -> Void
    var body: some View {
        let count = sharing.progress.filter { $0.state == .offered }.count
        if count > 0 {
            Button(action: open) { Label("\(count)", systemImage: "tray.and.arrow.down") }
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

    var body: some View {
        VStack(spacing: 10) {
          if navigation.choosingRecipient {
            HStack {
                Text(navigation.pendingFiles.isEmpty ? "Drop onto a person or destination"
                     : navigation.pendingFiles.count == 1 ? navigation.pendingFiles[0].lastPathComponent
                     : "\(navigation.pendingFiles.count) files ready")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel") { navigation.pendingFiles = []; navigation.choosingRecipient = false }
                    .controlSize(.small)
            }
            RoomNotchTray {
                    ForEach(model.participants.filter { $0.id != model.currentParticipantID }) { person in
                        NotchPersonFileTarget(name: person.name, choose: {
                            if navigation.pendingFiles.isEmpty {
                                sharing.chooseFile(to: person.id)
                                navigation.choosingRecipient = false
                            }
                            else if let peer = UUID(uuidString: person.id) {
                                navigation.pendingFiles.forEach { sharing.send($0, to: peer) }
                                navigation.pendingFiles = []
                            }
                            navigation.fileSection = 0
                        },
                            receive: { urls in
                                guard let peer = UUID(uuidString: person.id) else { return }
                                urls.forEach { sharing.send($0, to: peer) }
                                navigation.fileSection = 0; navigation.choosingRecipient = false
                            })
                    }
                    NotchPersonFileTarget(name: "Everyone", symbol: "person.2", choose: chooseRoomFiles,
                        receive: { urls in
                            model.addRoomTrayFiles(urls)
                            navigation.fileSection = 1; navigation.choosingRecipient = false
                        })
                    NotchPersonFileTarget(name: "My shelf", symbol: "tray", choose: {
                        navigation.fileSection = 2
                        if !navigation.pendingFiles.isEmpty { keepLocally(navigation.pendingFiles) }
                        else { navigation.choosingRecipient = false }
                    }, receive: keepLocally)
                    NotchPersonFileTarget(name: "AirDrop", symbol: "airplay.audio", choose: {
                        if !navigation.pendingFiles.isEmpty { airDrop(navigation.pendingFiles) }
                        else {
                            let picker = NSOpenPanel(); picker.allowsMultipleSelection = true; picker.canChooseDirectories = false
                            picker.begin { if $0 == .OK { airDrop(picker.urls) } }
                        }
                    }, receive: airDrop)
            }
          } else {
            HStack {
                Picker("Files", selection: $navigation.fileSection) {
                    Text("Transfers").tag(0)
                    Text("Room shelf").tag(1)
                    Text("My shelf").tag(2)
                }.labelsHidden().frame(maxWidth: 180)
                Spacer(minLength: 8)
                Button { navigation.choosingRecipient = true } label: {
                    Label(navigation.pendingFiles.isEmpty ? "Share…" : "Resume sharing…", systemImage: "square.and.arrow.up")
                }
            }.controlSize(.small)
            if navigation.fileSection == 0 {
                FileTransferProgressView(model: sharing, showsShareAction: true)
            } else if navigation.fileSection == 2 {
                runtime.localFileShelfView
            } else {
                ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Shared with everyone · up to 8 MB").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add…", action: chooseRoomFiles).controlSize(.small)
                            .disabled(model.isImportingRoomFiles)
                    }
                    if model.isImportingRoomFiles { ProgressView("Preparing files…").controlSize(.small) }
                    if let notice = model.roomTrayNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if model.roomTrayItems.isEmpty {
                        Text("Drop a file here to share it with the room.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        runtime.roomFileShelfView.frame(height: 144)
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
                            .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                }
                }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                    NotchFileDrop.receive(providers, action: model.addRoomTrayFiles)
                }
            }
          }
          if let fileError { Text(fileError).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: navigation.pendingFiles) { old, new in
            if !old.isEmpty && new.isEmpty { navigation.choosingRecipient = false }
        }
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

private struct NotchPersonFileTarget: View {
    let name: String
    var symbol: String? = nil
    let choose: () -> Void
    let receive: ([URL]) -> Void
    @State private var targeted = false
    var body: some View {
        RoomNotchTile(name, action: choose) {
                Group {
                    if let symbol { Image(systemName: symbol) }
                    else { Text(String(name.prefix(1)).uppercased()) }
                }.foregroundStyle(targeted ? Color.accentColor : .white)
        }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
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
