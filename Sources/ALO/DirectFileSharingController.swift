import AppKit
import SwiftUI
import ALONetworking

@MainActor
final class DirectFileSharingController: ObservableObject {
    struct Progress: Identifiable {
        let id: UUID
        let title: String
        var fraction: Double
        var transfer: DirectFileTransfer?
    }
    @Published var progress: [Progress] = []
    @Published var message: String?
    var names: () -> [String: String] = { [:] }
    var openChannel: ((UUID, @escaping (Result<(SecurePeerChannel, AuthenticatedPeer), Error>) -> Void) -> Void)?
    private var transfers: [UUID: DirectFileTransfer] = [:]
    private var windows: [UUID: SharedMediaWindow] = [:]
    private var directories: Set<URL> = []
    private var receivedBytes: Int64 = 0
    private var active = true
    private var pendingConnections = 0
    private var progressPanel: NSPanel?
    private var offers: [UUID: NSPanel] = [:]
    private var incomingIDs: Set<UUID> = []

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
        guard active, names()[peer.uuidString] != nil, let openChannel else {
            message = "This device is no longer in the channel."; showProgress(); return
        }
        guard transfers.count + pendingConnections < 4 else { message = DirectFileError.busy.localizedDescription; showProgress(); return }
        pendingConnections += 1
        let pendingID = UUID()
        progress.append(.init(id: pendingID, title: "Connecting to \(names()[peer.uuidString] ?? "device")…", fraction: 0))
        message = nil; showProgress()
        openChannel(peer) { [weak self] result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingConnections -= 1; self.progress.removeAll { $0.id == pendingID }
                    self.message = "Couldn’t establish a secure connection to this device. Make sure both Macs have updated and rejoined the channel. \(error.localizedDescription)"
                }
            case .success(let (channel, remote)):
                let transfer = Self.makeTransfer(channel: channel, peer: remote.nodeID, source: url, owner: self)
                DispatchQueue.main.async {
                    guard let self else { transfer.cancel(); return }
                    self.pendingConnections -= 1; self.progress.removeAll { $0.id == pendingID }
                    guard self.active else { transfer.cancel(); return }
                    self.transfers[transfer.id] = transfer
                    self.progress.append(.init(id: transfer.id, title: "Sending \(url.lastPathComponent)", fraction: 0, transfer: transfer))
                    transfer.start()
                }
            }
        }
    }
    /// Called on the mesh executor. Bind first; marshal decisions to the UI.
    nonisolated func receive(_ channel: SecurePeerChannel, peer: AuthenticatedPeer) {
        let transfer = Self.makeTransfer(channel: channel, peer: peer.nodeID, source: nil, owner: self)
        DispatchQueue.main.async {
            guard self.active, self.transfers.count < 4,
                  self.names()[peer.nodeID.uuidString] != nil else { transfer.cancel(); return }
            self.transfers[transfer.id] = transfer
            transfer.start()
        }
    }
    nonisolated private static func makeTransfer(channel: SecurePeerChannel, peer: UUID, source: URL?, owner: DirectFileSharingController?) -> DirectFileTransfer {
        DirectFileTransfer(channel: channel, peerID: peer, source: source,
            onOffer: { [weak owner] transfer, name, size in
                MainActor.assumeIsolated { owner?.offer(transfer, name: name, size: size) }
            }, onProgress: { [weak owner] id, fraction in
                MainActor.assumeIsolated {
                    guard let owner, let index = owner.progress.firstIndex(where: { $0.id == id }) else { return }
                    owner.progress[index].fraction = fraction
                }
            }, onEnd: { [weak owner] id, result in
                MainActor.assumeIsolated { owner?.finished(id, result: result) }
            })
    }
    private func offer(_ transfer: DirectFileTransfer, name: String, size: Int64) {
        guard active, transfers[transfer.id] != nil,
              let sender = names()[transfer.peerID.uuidString] else { transfer.cancel(); return }
        guard receivedBytes + size <= 2 * DirectFileWire.maximumFileBytes else {
            transfer.decline(); message = "The temporary file inbox is full. Leave and rejoin the channel to clear it."; showProgress(); return
        }
        receivedBytes += size
        incomingIDs.insert(transfer.id)
        progress.append(.init(id: transfer.id, title: "Receiving \(name) from \(sender)", fraction: 0, transfer: transfer))
        if SharedMediaKind.candidate(name) != nil {
            transfer.accept(); showProgress(); return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Incoming file"; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
            Text("\(sender) wants to send you a file").font(.headline)
            Text(name).lineLimit(2)
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Decline") { [weak self] in self?.offers.removeValue(forKey: transfer.id)?.close(); transfer.decline() }
                Button("Accept") { [weak self] in self?.offers.removeValue(forKey: transfer.id)?.close(); transfer.accept(); self?.showProgress() }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(20))
        offers[transfer.id] = panel; panel.center(); panel.orderFrontRegardless()
    }
    private func finished(_ id: UUID, result: Result<URL?, Error>) {
        let wasIncoming = incomingIDs.remove(id) != nil
        offers.removeValue(forKey: id)?.close()
        let transfer = transfers.removeValue(forKey: id)
        progress.removeAll { $0.id == id }
        guard active else {
            if case .success(let url?) = result { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return
        }
        switch result {
        case .failure(let error):
            if wasIncoming, error as? DirectFileError == .declined { return }
            message = error.localizedDescription; showProgress()
        case .success(nil): message = "File delivered."; showProgress()
        case .success(let url?):
            directories.insert(url.deletingLastPathComponent())
            guard let transfer else { return }
            let sender = names()[transfer.peerID.uuidString] ?? "Device"
            Task {
                let kind = await SharedMediaKind.validate(url)
                guard active else { return }
                if let kind {
                    if windows.count >= 4, let oldest = windows.keys.sorted(by: { $0.uuidString < $1.uuidString }).first { windows[oldest]?.close() }
                    windows[id] = SharedMediaWindow(url: url, sender: sender, kind: kind,
                        sendBack: { [weak self] edited in self?.send(edited, to: transfer.peerID) },
                        closed: { [weak self] in self?.windows.removeValue(forKey: id) })
                    if progress.isEmpty { progressPanel?.orderOut(nil) }
                } else {
                    // Even a misleading media extension never launches an app.
                    let picker = NSSavePanel(); picker.nameFieldStringValue = url.lastPathComponent
                    picker.message = "Save file from \(sender)"
                    picker.begin { response in
                        guard self.active, response == .OK, let destination = picker.url else { return }
                        do { try Data(contentsOf: url, options: .mappedIfSafe).write(to: destination, options: .atomic) }
                        catch { self.message = error.localizedDescription; self.showProgress() }
                    }
                }
            }
        }
    }
    func stop() {
        active = false; openChannel = nil
        for transfer in transfers.values { transfer.cancel() }
        transfers.removeAll()
        for panel in offers.values { panel.close() }; offers.removeAll()
        for window in Array(windows.values) { window.close() }; windows.removeAll()
        progressPanel?.close(); progressPanel = nil
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }
    private func showProgress() {
        if progressPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "File transfers"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: FileTransferProgressView(model: self))
            panel.center(); progressPanel = panel
        }
        progressPanel?.orderFrontRegardless()
    }
}

private struct FileTransferProgressView: View {
    @ObservedObject var model: DirectFileSharingController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.progress) { item in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(item.title).lineLimit(2)
                            Spacer()
                            if let transfer = item.transfer { Button("Cancel") { transfer.cancel() } }
                        }
                        ProgressView(value: item.fraction)
                    }
                }
                if let message = model.message { Text(message).font(.callout) }
            }.padding(20)
        }
    }
}
