import AppKit
import SwiftUI
import ALONetworking

@MainActor
final class DirectFileSharingController: ObservableObject {
    struct Progress: Identifiable {
        enum State: Equatable {
            case connecting, awaitingAcceptance, offered, transferring, verifying
            case delivered, received, declined, cancelled, failed(String)

            var isFinished: Bool {
                switch self {
                case .delivered, .received, .declined, .cancelled, .failed: true
                default: false
                }
            }
        }
        let id: UUID
        let title: String
        var fraction: Double
        var transfer: DirectFileTransfer?
        var state: State = .connecting
        var peerID: UUID?
        var peerName = ""
        var fileName = ""
        var byteCount: Int64 = 0
        var sourceURL: URL?
        var receivedURL: URL?
        var hasSavedCopy = false

        var status: String {
            switch state {
            case .connecting: "Connecting to \(peerName)…"
            case .awaitingAcceptance: "Waiting for \(peerName) to accept"
            case .offered: "\(peerName) wants to share a file"
            case .transferring: "Transferring · \(Int(fraction * 100))%"
            case .verifying: "Verifying delivery…"
            case .delivered: "Delivered to \(peerName)"
            case .received: "Received from \(peerName)"
            case .declined: "Declined"
            case .cancelled: "Cancelled"
            case .failed(let reason): reason
            }
        }
    }
    @Published var progress: [Progress] = []
    @Published var message: String?
    @Published private(set) var busyFileIDs: Set<UUID> = []
    var names: () -> [String: String] = { [:] }
    var openChannel: ((UUID, @escaping (Result<(SecurePeerChannel, AuthenticatedPeer), Error>) -> Void) -> Void)?
    /// Returns true only when the host can present these actions in the notch.
    /// A disabled/hidden notch must never swallow an incoming decision.
    var presentInNotch: (() -> Bool)?
    private var transfers: [UUID: DirectFileTransfer] = [:]
    private var windows: [UUID: SharedMediaWindow] = [:]
    private var directories: [UUID: URL] = [:]
    private let inboxIO: any DirectFileInboxIO
    private var receivedBytes: Int64 = 0
    private var active = true
    private var pendingConnections = 0
    private var progressPanel: NSPanel?
    private var incomingIDs: Set<UUID> = []
    private var incomingSizes: [UUID: Int64] = [:]
    private var cancelledIDs: Set<UUID> = []
    private var stoppingTransferIDs: Set<UUID> = []

    init(inboxIO: any DirectFileInboxIO = LocalDirectFileInboxIO()) {
        self.inboxIO = inboxIO
    }

    func chooseFile(to peerID: String) {
        guard let peer = UUID(uuidString: peerID) else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.prompt = "Send"; picker.message = "Send a file to \(names()[peerID] ?? "this device")"
        picker.begin { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            self?.send(url, to: peer)
        }
    }
    func send(_ url: URL, to peer: UUID) {
        guard active else { return }
        guard names()[peer.uuidString] != nil, let openChannel else {
            message = "This device is no longer in the channel."; showProgress(); return
        }
        guard transfers.count + pendingConnections < 4 else { message = DirectFileError.busy.localizedDescription; showProgress(); return }
        pendingConnections += 1
        let pendingID = UUID()
        let peerName = names()[peer.uuidString] ?? "Device"
        progress.append(.init(id: pendingID, title: url.lastPathComponent, fraction: 0,
            peerID: peer, peerName: peerName, fileName: url.lastPathComponent, sourceURL: url))
        pruneFinishedHistory()
        message = nil; showProgress()
        openChannel(peer) { [weak self] result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingConnections -= 1
                    guard self.active, let index = self.progress.firstIndex(where: { $0.id == pendingID }),
                          !self.progress[index].state.isFinished else { return }
                    self.progress[index].state = .failed("Couldn’t connect. Check that both Macs are still in the room. \(error.localizedDescription)")
                    self.pruneFinishedHistory()
                }
            case .success(let (channel, remote)):
                let transfer = Self.makeTransfer(channel: channel, peer: remote.nodeID, source: url, owner: self)
                DispatchQueue.main.async {
                    guard let self else { transfer.cancel(); return }
                    self.pendingConnections -= 1
                    guard self.active, let index = self.progress.firstIndex(where: { $0.id == pendingID }),
                          !self.progress[index].state.isFinished else { transfer.cancel(); return }
                    self.transfers[transfer.id] = transfer
                    self.progress[index] = .init(id: transfer.id, title: url.lastPathComponent, fraction: 0,
                        transfer: transfer, state: .awaitingAcceptance, peerID: peer,
                        peerName: peerName, fileName: url.lastPathComponent, sourceURL: url)
                    transfer.start()
                }
            }
        }
    }
    /// Called on the mesh executor. Bind first; marshal decisions to the UI.
    nonisolated func receive(_ channel: SecurePeerChannel, peer: AuthenticatedPeer) {
        let transfer = Self.makeTransfer(channel: channel, peer: peer.nodeID, source: nil, owner: self)
        DispatchQueue.main.async {
            self.registerIncoming(transfer)
        }
    }

    func registerIncoming(_ transfer: DirectFileTransfer) {
        guard active, transfers.count + pendingConnections < 4,
              names()[transfer.peerID.uuidString] != nil else { transfer.cancel(); return }
        transfers[transfer.id] = transfer
        transfer.start()
    }
    nonisolated private static func makeTransfer(channel: SecurePeerChannel, peer: UUID, source: URL?, owner: DirectFileSharingController?) -> DirectFileTransfer {
        DirectFileTransfer(channel: channel, peerID: peer, source: source,
            onOffer: { [weak owner] transfer, name, size in
                MainActor.assumeIsolated { owner?.offer(transfer, name: name, size: size) }
            }, onProgress: { [weak owner] id, fraction in
                MainActor.assumeIsolated {
                    guard let owner, let index = owner.progress.firstIndex(where: { $0.id == id }) else { return }
                    owner.progress[index].fraction = fraction
                    if !owner.progress[index].state.isFinished {
                        owner.progress[index].state = fraction >= 1 ? .verifying : .transferring
                    }
                }
            }, onEnd: { [weak owner] id, result in
                MainActor.assumeIsolated { owner?.finished(id, result: result) }
            })
    }
    func offer(_ transfer: DirectFileTransfer, name: String, size: Int64) {
        guard active, transfers[transfer.id] != nil,
              let sender = names()[transfer.peerID.uuidString] else { transfer.cancel(); return }
        guard incomingSizes[transfer.id] == nil else { return }
        guard size >= 0, size <= DirectFileWire.maximumFileBytes,
              receivedBytes + size <= 2 * DirectFileWire.maximumFileBytes, incomingSizes.count < 32 else {
            transfer.decline(); message = "The temporary inbox is full. Save files you want to keep, then discard their temporary copies to receive more."; showProgress(); return
        }
        receivedBytes += size
        incomingSizes[transfer.id] = size
        incomingIDs.insert(transfer.id)
        progress.append(.init(id: transfer.id, title: name, fraction: 0, transfer: transfer,
            state: .offered, peerID: transfer.peerID, peerName: sender, fileName: name, byteCount: size))
        pruneFinishedHistory()
        // Media follows the same consent flow as every other file. Receiving a
        // file must never automatically launch a viewer or steal keyboard focus.
        showProgress()
    }
    func finished(_ id: UUID, result: Result<URL?, Error>) {
        // A repeated completion must not resurrect a discarded result or alter
        // capacity twice. Transfers cancelled during stop may still finish.
        guard transfers[id] != nil || stoppingTransferIDs.remove(id) != nil else { return }
        let wasIncoming = incomingIDs.remove(id) != nil
        transfers.removeValue(forKey: id)
        let cancelled = cancelledIDs.remove(id) != nil
        guard active else {
            if case .success(let url?) = result {
                Task { try? await inboxIO.remove(url.deletingLastPathComponent()) }
            }
            return
        }
        guard let index = progress.firstIndex(where: { $0.id == id }) else { return }
        progress[index].transfer = nil
        if cancelled, case .success(let url?) = result {
            if wasIncoming { receivedBytes -= incomingSizes.removeValue(forKey: id) ?? 0 }
            progress[index].state = .cancelled
            Task { try? await inboxIO.remove(url.deletingLastPathComponent()) }
            pruneFinishedHistory()
            return
        }
        switch result {
        case .failure(let error):
            if wasIncoming { receivedBytes -= incomingSizes.removeValue(forKey: id) ?? 0 }
            progress[index].state = cancelled ? .cancelled
                : (error as? DirectFileError == .declined ? .declined : .failed(error.localizedDescription))
        case .success(nil):
            progress[index].state = .delivered
            progress[index].fraction = 1
        case .success(let url?):
            directories[id] = url.deletingLastPathComponent()
            progress[index].state = .received
            progress[index].fraction = 1
            progress[index].receivedURL = url
        }
        pruneFinishedHistory()
    }

    func accept(_ id: UUID) {
        guard let index = progress.firstIndex(where: { $0.id == id }), progress[index].state == .offered else { return }
        progress[index].state = .transferring
        transfers[id]?.accept()
    }

    func decline(_ id: UUID) {
        guard let index = progress.firstIndex(where: { $0.id == id }), progress[index].state == .offered else { return }
        progress[index].state = .declined
        transfers[id]?.decline()
    }

    func cancel(_ id: UUID) {
        guard let index = progress.firstIndex(where: { $0.id == id }), !progress[index].state.isFinished else { return }
        progress[index].state = .cancelled
        if let transfer = transfers[id] { cancelledIDs.insert(id); transfer.cancel() }
    }

    func retry(_ id: UUID) {
        guard let item = progress.first(where: { $0.id == id }), item.state.isFinished,
              let source = item.sourceURL, let peer = item.peerID else { return }
        progress.removeAll { $0.id == id }
        send(source, to: peer)
    }

    func save(_ id: UUID) {
        guard active, !busyFileIDs.contains(id), let item = progress.first(where: { $0.id == id }), item.receivedURL != nil else { return }
        let picker = NSSavePanel()
        picker.nameFieldStringValue = item.fileName
        picker.message = "Save file from \(item.peerName)"
        picker.begin { [weak self] response in
            guard let self, self.active, response == .OK, let destination = picker.url else { return }
            Task { await self.export(id, to: destination) }
        }
    }

    @discardableResult
    func export(_ id: UUID, to destination: URL) async -> Bool {
        guard active, !busyFileIDs.contains(id), let item = progress.first(where: { $0.id == id }),
              item.state == .received, let url = item.receivedURL, directories[id] != nil else { return false }
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard !directories.values.contains(where: {
            target.starts(with: $0.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
        }) else { message = "Choose a location outside ALO’s temporary inbox."; return false }
        busyFileIDs.insert(id)
        defer { finishFileOperation(id) }
        do {
            try await inboxIO.export(url, to: destination)
            if active, let index = progress.firstIndex(where: { $0.id == id }) {
                progress[index].hasSavedCopy = true
                message = "Saved \(item.fileName). Your saved copy stays after you leave."
            }
            return true
        } catch {
            if active { message = "Couldn’t save the file. \(error.localizedDescription)" }
            return false
        }
    }

    func dismiss(_ id: UUID) {
        guard let item = progress.first(where: { $0.id == id }), item.state.isFinished,
              item.receivedURL == nil, transfers[id] == nil, !busyFileIDs.contains(id) else { return }
        progress.removeAll { $0.id == id }
    }

    /// Called only after the UI confirms removal of the temporary received copy.
    func discard(_ id: UUID) async {
        guard canDiscard(id), let item = progress.first(where: { $0.id == id }),
              item.state == .received, directories[id] != nil else { return }
        busyFileIDs.insert(id)
        defer { finishFileOperation(id) }
        windows.removeValue(forKey: id)?.close()
        do {
            try await removeOwnedDirectory(id)
            guard active else { return }
            receivedBytes -= incomingSizes.removeValue(forKey: id) ?? 0
            progress.removeAll { $0.id == id }
            message = "Temporary copy discarded. Saved copies are unchanged."
        } catch {
            if active { message = "Couldn’t discard the temporary copy. \(error.localizedDescription)" }
        }
    }

    func canDiscard(_ id: UUID) -> Bool {
        guard active, !busyFileIDs.contains(id), let directory = directories[id] else { return false }
        // An annotated image sent back from Preview may still be borrowed by
        // an outgoing transfer. Discard must not delete its source underneath it.
        let prefix = directory.standardizedFileURL.pathComponents
        return !progress.contains { item in
            guard let source = item.sourceURL,
                  !item.state.isFinished || transfers[item.id] != nil else { return false }
            return source.standardizedFileURL.pathComponents.starts(with: prefix)
        }
    }

    private func removeOwnedDirectory(_ id: UUID) async throws {
        guard let directory = directories[id] else { return }
        try await inboxIO.remove(directory)
        directories.removeValue(forKey: id)
    }

    private func finishFileOperation(_ id: UUID) {
        busyFileIDs.remove(id)
        if !active { Task { try? await removeOwnedDirectory(id) } }
    }

    private func pruneFinishedHistory() {
        let dismissible = progress.filter {
            $0.state.isFinished && $0.receivedURL == nil && transfers[$0.id] == nil && !busyFileIDs.contains($0.id)
        }
        let expired = Set(dismissible.prefix(max(0, dismissible.count - 100)).map(\.id))
        progress.removeAll { expired.contains($0.id) }
    }

    func preview(_ id: UUID) {
        guard active, !busyFileIDs.contains(id), let item = progress.first(where: { $0.id == id }), let url = item.receivedURL else { return }
        busyFileIDs.insert(id)
        Task {
            defer { finishFileOperation(id) }
            let kind = await SharedMediaKind.validate(url)
            guard active else { return }
            guard let kind else {
                message = "Preview is unavailable for this file. Save it to open with an app you choose."
                return
            }
            windows[id]?.close()
            windows[id] = SharedMediaWindow(url: url, sender: item.peerName, kind: kind,
                sendBack: { [weak self] edited in
                    guard let peer = item.peerID else { return }; self?.send(edited, to: peer)
                }, closed: { [weak self] in self?.windows.removeValue(forKey: id) })
        }
    }
    func stop() {
        active = false; openChannel = nil; presentInNotch = nil
        stoppingTransferIDs.formUnion(transfers.keys)
        for transfer in transfers.values { transfer.cancel() }
        transfers.removeAll()
        for window in Array(windows.values) { window.close() }; windows.removeAll()
        progressPanel?.close(); progressPanel = nil
        for id in directories.keys where !busyFileIDs.contains(id) {
            Task { try? await removeOwnedDirectory(id) }
        }
        progress.removeAll(); message = nil
        incomingIDs.removeAll(); incomingSizes.removeAll(); cancelledIDs.removeAll(); receivedBytes = 0
    }
    private func showProgress() {
        if presentInNotch?() == true { progressPanel?.orderOut(nil); return }
        if progressPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "File transfers"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: FileTransferProgressView(model: self))
            panel.center(); progressPanel = panel
        }
        progressPanel?.orderFrontRegardless()
    }
}

struct FileTransferProgressView: View {
    @ObservedObject var model: DirectFileSharingController
    var showsShareAction = false
    @State private var discarding: DirectFileSharingController.Progress?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.progress.isEmpty && model.message == nil {
                    if showsShareAction {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.left.arrow.right").font(.title3)
                            Text("No transfers yet").font(.callout.weight(.medium))
                            Text("Choose Share to send a file. Incoming offers appear here for you to accept or decline.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 20)
                    } else {
                    ContentUnavailableView("No transfers yet", systemImage: "arrow.left.arrow.right",
                        description: Text("Drop a file onto someone in the room to send it privately."))
                    }
                }
                ForEach(model.progress) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: item.state == .received || item.state == .delivered ? "checkmark.circle" : "doc")
                            Text(item.fileName).font(.callout.weight(.semibold)).lineLimit(2)
                            Spacer()
                            if !item.state.isFinished && item.state != .offered {
                                Button("Cancel") { model.cancel(item.id) }
                            } else if item.state.isFinished && item.receivedURL == nil {
                                Button { model.dismiss(item.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).accessibilityLabel("Dismiss transfer result for \(item.fileName)")
                            }
                        }
                        Text(item.status).font(.caption).foregroundStyle(.secondary)
                        if item.byteCount > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if item.state == .offered {
                            HStack {
                                Button("Decline") { model.decline(item.id) }
                                Button("Accept file") { model.accept(item.id) }.buttonStyle(.borderedProminent)
                            }
                        } else if item.state == .transferring || item.state == .verifying {
                            ProgressView(value: item.fraction)
                        } else if item.state == .received {
                            HStack {
                                Button("Preview") { model.preview(item.id) }
                                Button("Save…") { model.save(item.id) }
                                Button("Discard…", role: .destructive) { discarding = item }
                                    .disabled(!model.canDiscard(item.id))
                                    .help("Discard the temporary copy after any save or outgoing transfer finishes")
                            }.disabled(model.busyFileIDs.contains(item.id))
                            if model.busyFileIDs.contains(item.id) { ProgressView("Working…").controlSize(.small) }
                            Text(item.hasSavedCopy ? "Saved copy kept · temporary copy can be discarded."
                                 : "Temporary copy · save before leaving the room.").font(.caption).foregroundStyle(.secondary)
                        } else if item.state.isFinished && item.state != .delivered && item.sourceURL != nil {
                            Button("Retry") { model.retry(item.id) }
                        }
                    }
                    .padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
                if let message = model.message { Text(message).font(.callout) }
            }.padding(showsShareAction ? 4 : 20)
        }
        .confirmationDialog("Discard temporary copy?", isPresented: Binding(
            get: { discarding != nil }, set: { if !$0 { discarding = nil } }), presenting: discarding) { item in
                Button("Discard temporary copy", role: .destructive) { Task { await model.discard(item.id) } }
                Button("Cancel", role: .cancel) { discarding = nil }
            } message: { item in
                Text("Remove \(item.fileName) from this inbox? Any copies you saved elsewhere stay untouched. If you haven’t saved it, ask the sender to share it again.")
            }
    }
}
