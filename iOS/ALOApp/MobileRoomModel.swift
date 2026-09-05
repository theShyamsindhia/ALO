import SwiftUI
import Network
import ALOCore
import ALONetworking
import ALOAppleMedia

@MainActor final class MobileRoomModel: ObservableObject {
    @Published private(set) var nearbyRooms: [NearbyPeerHint] = []
    @Published private(set) var discoveryState: NearbyDiscoveryState = .idle
    @Published private(set) var room: RoomConfiguration?
    @Published private(set) var replica = MeshRoomReplica()
    @Published private(set) var participants: [RoomParticipant] = []
    @Published private(set) var connected = false
    @Published private(set) var status = "Ready to find a nearby room"
    @Published var errorMessage: String?
    @Published var displayName = MobileRoomStore.usesTemporarySimulatorIdentity
        ? "ALO Simulator Test" : UserDefaults.standard.string(forKey: "displayName") ?? "iPhone"
    @Published var levels = AudioMixLevels() { didSet { audio.levels = levels } }
    let audio = iOSAudioSessionCoordinator()
    let mediaAvailability = "Media and voice are unavailable in this build. Secure media transport is not connected yet."
    let isTemporarySimulatorSession = MobileRoomStore.usesTemporarySimulatorIdentity
    private(set) var localID = ""
    private var identity: InstallationIdentity?
    private var pins: (any PeerPinStore)?
    private var store: MobileRoomStore?
    private var discovery: DiscoveryCoordinator?
    private var mesh: MeshControlPlane?
    private var generation: UInt64 = 0
    private var foreground = false
    private var started = false
    private var joinTimeout: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    func activate() {
        foreground = true
        if !started {
            started = true
            do {
                let storage = try MobileRoomStore()
                let key = try isTemporarySimulatorSession ? InstallationIdentity.ephemeral()
                    : InstallationIdentity.loadOrCreate(namespace: storage.namespace)
                store = storage; identity = key; localID = key.publicIdentity.nodeID.uuidString
                pins = isTemporarySimulatorSession ? MemoryPeerPinStore()
                    : KeychainPeerPinStore(namespace: storage.namespace)
                let scanner = DiscoveryCoordinator(ownPeerID: key.publicIdentity.nodeID)
                scanner.onChange = { [weak self] state, hints in
                    guard let self else { return }
                    self.discoveryState = state
                    var seen = Set<UUID>()
                    self.nearbyRooms = hints.filter { seen.insert($0.roomID).inserted }
                        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                }
                discovery = scanner
                room = try storage.selectedRoom()
            } catch {
                let code: String
                if case IdentityError.keychain(let status) = error { code = "Keychain \(status)" }
                else if case MobileRoomStore.StoreError.keychain(let status) = error { code = "Keychain \(status)" }
                else { code = "\(String(describing: type(of: error))) \((error as NSError).code)" }
                errorMessage = "Device setup failed (\(code)). Your identity and saved room have not been replaced."
                started = false
                return
            }
        }
        if let room, mesh == nil { connect(room, selected: nil) }
        // Browsing is explicit: opening the app does not trigger Local Network permission.
    }

    func scan() {
        guard foreground, room == nil else { return }
        if !started { activate() }
        discovery?.startScanning()
    }

    func join(_ hint: NearbyPeerHint, secret: String) -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "Enter a name for other people in the room to see."; return false }
        let choice = RoomConfiguration(id: hint.roomID.uuidString, name: hint.displayName,
            isPrivate: hint.isPrivate, accessKey: secret.trimmingCharacters(in: .whitespacesAndNewlines),
            transportPolicy: .secureV2)
        do { try choice.validateForJoining() }
        catch { errorMessage = "Enter the room’s 32-byte base64 invite secret. Ask a room member for the full secret."; return false }
        guard let selected = discovery?.select(hint.id) else {
            errorMessage = "That room is no longer in the current scan. Refresh nearby rooms and try again."
            return false
        }
        displayName = String(name.prefix(80))
        if !isTemporarySimulatorSession { UserDefaults.standard.set(displayName, forKey: "displayName") }
        errorMessage = nil
        room = choice
        connect(choice, selected: selected)
        return true
    }

    func retry() {
        guard foreground, let room else { return }
        disconnectRuntime()
        connect(room, selected: nil)
    }

    func leave() {
        // Clear durable consent first, so a failed Keychain removal is not hidden.
        do { try store?.clearSelectedRoom() }
        catch { errorMessage = "Could not forget the saved room. Unlock your device and try Leave again."; return }
        disconnectRuntime()
        room = nil; replica = MeshRoomReplica(); participants = []
        status = "Ready to find a nearby room"
    }

    func suspend() {
        foreground = false
        discovery?.stop()
        disconnectRuntime()
        audio.suspend()
        if room != nil { status = "Paused while the app is in the background" }
    }

    func sendChat(_ text: String) -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, !message.isEmpty, message.utf8.count <= 4_096 else { return false }
        mesh?.publishChat(message)
        return true
    }

    private func connect(_ choice: RoomConfiguration, selected: NearbyPeerHint?) {
        guard foreground, identity != nil, pins != nil, store != nil else { return }
        discovery?.stop()
        generation &+= 1
        let token = generation
        connected = false; participants = []; status = "Connecting securely…"
        let pendingShutdown = shutdownTask
        Task { [weak self] in
            // stop's completion runs after its final durable document write.
            // Await it before loading a replacement replica, including a quick
            // background/foreground transition, not only an explicit retry.
            await pendingShutdown?.value
            guard let self, self.foreground, self.generation == token else { return }
            self.startRuntime(choice, selected: selected, token: token)
        }
    }

    private func startRuntime(_ choice: RoomConfiguration, selected: NearbyPeerHint?, token: UInt64) {
        guard let identity, let pins, let store else { return }
        let document: Data?
        do { document = try store.document(roomID: choice.id) }
        catch { errorMessage = "Saved room history could not be read. It will resynchronize from peers."; document = nil }
        let runtime = MeshControlPlane(room: choice, nodeID: localID, displayName: displayName,
            deviceIcon: "iphone", initialRoomStateDocument: document,
            replicaHandler: { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.replica = value
                }
            }, participantsHandler: { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.participants = value
                    self.connected = value.contains { $0.id != self.localID }
                    self.status = self.connected ? "Connected · encrypted mesh" : "Waiting for a room member…"
                    if self.connected { self.joinTimeout?.cancel() }
                }
            }, mediaCommandHandler: { _, _, _ in false }, resyncRequestHandler: { _, _, _ in false },
            roomStatePersistenceHandler: { [weak self] data in
                do { try store.saveDocument(data, roomID: choice.id) }
                catch {
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.errorMessage = "Room history could not be saved on this device."
                    }
                }
            }, installationIdentity: identity, peerPins: pins, secureCapabilities: [.chat],
            secureStateHandler: { [weak self] _, state in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    switch state {
                    case .authenticated:
                        do { try store.saveSelectedRoom(choice) }
                        catch { self.errorMessage = "Connected, but this room could not be saved for automatic rejoin." }
                    case .failed(let failure):
                        guard !self.connected else { return }
                        self.status = failure == .admissionFailed
                            ? "Room admission failed. Check the invite secret and peer identity."
                            : "Connection interrupted. Retrying securely…"
                    default: break
                    }
                }
            }, listenerStateHandler: { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if case .failed(let error) = state {
                        self.status = "The nearby listener could not start."
                        if case .dns(let code) = error, code == -65570 {
                            self.errorMessage = "Allow Local Network access in Settings to join nearby rooms."
                        }
                    }
                }
            })
        mesh = runtime
        do {
            try runtime.start()
            if let selected { runtime.connect(to: selected.endpoint, expectedPeerID: selected.peerID) }
        } catch {
            status = "Could not start the secure room connection."
            disconnectRuntime()
            return
        }
        joinTimeout?.cancel()
        joinTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token, !self.connected else { return }
            self.status = "No room member is connected. Check your network or retry."
        }
    }

    private func disconnectRuntime() {
        generation &+= 1
        joinTimeout?.cancel(); joinTimeout = nil
        if let runtime = mesh {
            let pendingShutdown = shutdownTask
            shutdownTask = Task {
                await pendingShutdown?.value
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    runtime.stop { continuation.resume() }
                }
            }
        }
        mesh = nil
        connected = false
        audio.stop()
    }
}
