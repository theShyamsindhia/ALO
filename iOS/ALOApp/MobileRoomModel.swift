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
    @Published private(set) var mediaAvailability = "Waiting for a secure broadcaster. Screen and voice are not connected yet."
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
    private var mediaReceiver: MediaReceiverSession?
    private var mediaSelection: MediaReceiverSession.Selection?
    private var mediaBridge: BoundedMediaEventBridge<MediaEvent>?
    private var mediaOwner: MediaTransportOwner?
    private var mediaToken = UUID()
    private var mediaRetry: Task<Void, Never>?
    private var renderPreparations: [UUID: UInt64] = [:]
    private var receiverGeneration: UInt64?
    private var startingAudio = false

    private enum MediaEvent: Sendable {
        case attached(Result<MediaReceiverSession, Error>)
        case prepare(MediaReceiverSession.Preparation)
        case commit(MediaReceiverSession.Preparation)
        case audio(AudioPacket, UInt64)
        case state(MediaReceiverSession.State)
        case clock(MediaReceiverSession.ClockSnapshot)
        case paused
    }

    /// Attachment ownership cannot live only in the bounded UI event queue: an
    /// overflow can discard its attached-success event before MainActor sees it.
    private final class MediaTransportOwner: @unchecked Sendable {
        private let lock = NSLock()
        private var receiver: MediaReceiverSession?
        private var closed = false
        func install(_ receiver: MediaReceiverSession) -> Bool {
            lock.lock()
            guard !closed else { lock.unlock(); receiver.stop(); return false }
            self.receiver = receiver; lock.unlock(); return true
        }
        func stop() {
            lock.lock(); closed = true
            let receiver = self.receiver; self.receiver = nil
            lock.unlock(); receiver?.stop()
        }
        deinit { receiver?.stop() }
    }

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
                audio.onNeedsResynchronization = { [weak self] _ in
                    guard let self, !self.startingAudio else { return }
                    // Route/engine generation changes invalidate output preparation,
                    // not the mesh connection or the user's room membership.
                    self.stopMedia()
                    self.synchronizeMediaSelection()
                }
                audio.onLifecycleChanged = { [weak self] lifecycle in
                    guard !lifecycle.canRender else { return }
                    self?.stopMedia()
                }
                audio.onError = { [weak self] _ in self?.mediaAvailability = "Audio output needs attention. Retry the room connection." }
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
                    self.synchronizeMediaSelection()
                }
            }, participantsHandler: { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.participants = value
                    self.connected = value.contains { $0.id != self.localID }
                    self.status = self.connected ? "Connected · encrypted mesh" : "Waiting for a room member…"
                    if self.connected { self.joinTimeout?.cancel() }
                    self.synchronizeMediaSelection()
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
            }, installationIdentity: identity, peerPins: pins, secureCapabilities: [.chat, .receiveAudio],
            secureStateHandler: { [weak self] _, state in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    switch state {
                    case .authenticated:
                        do { try store.saveSelectedRoom(choice) }
                        catch { self.errorMessage = "Connected, but this room could not be saved for automatic rejoin." }
                        self.synchronizeMediaSelection()
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
        stopMedia()
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

    private func synchronizeMediaSelection() {
        guard foreground, connected, let mesh, let roomID = room.flatMap({ UUID(uuidString: $0.id) }),
              let localPeerID = UUID(uuidString: localID), let broadcaster = replica.broadcaster,
              let peerID = UUID(uuidString: broadcaster.nodeID), peerID != localPeerID,
              participants.contains(where: { $0.id == broadcaster.nodeID }) else {
            if mediaSelection != nil { stopMedia() }
            return
        }
        let selection = MediaReceiverSession.Selection(roomID: roomID, localPeerID: localPeerID,
            broadcasterPeerID: peerID, broadcasterEpoch: broadcaster.epoch)
        guard selection != mediaSelection else { return }
        stopMedia()
        mediaSelection = selection
        let token = mediaToken
        let owner = MediaTransportOwner()
        mediaOwner = owner
        if !audio.lifecycle.canRender {
            startingAudio = true
            defer { startingAudio = false }
            do { try audio.startListening() }
            catch {
                mediaAvailability = "Audio output could not start. Retry the room connection."
                mediaSelection = nil
                return
            }
        }
        mediaAvailability = "Synchronizing encrypted audio… Screen and voice are not connected yet."
        let bridge = BoundedMediaEventBridge<MediaEvent>(
            schedule: { DispatchQueue.main.async(execute: $0) },
            receive: { [weak self] events in
                MainActor.assumeIsolated {
                    guard let self, self.mediaToken == token else {
                        for event in events { if case .attached(.success(let receiver)) = event { receiver.stop() } }
                        return
                    }
                    for event in events where self.mediaToken == token { self.consumeMedia(event) }
                }
            }, overflow: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.mediaToken == token else { return }
                    self.scheduleMediaRetry(message: "Audio delivery fell behind. Resynchronizing…")
                }
            })
        mediaBridge = bridge
        let submit: @Sendable (MediaEvent, Int) -> Void = { event, bytes in
            if !bridge.submit(event, byteCount: bytes) { owner.stop() }
        }
        mesh.openMediaChannel(to: peerID, role: .mediaControl) { result in
            switch result {
            case .failure(let error): submit(.attached(.failure(error)), 0)
            case .success(let (channel, _)):
                // Attach inline, before hopping to MainActor: reliable frames may
                // already be coalesced behind the authentication response.
                MediaReceiverSession.attach(channel: channel, expected: selection, callbacks: .init(
                    prepareAnchor: { submit(.prepare($0), 0) },
                    anchorCommitted: { submit(.commit($0), 0) },
                    audio: { packet, _, generation in submit(.audio(packet, generation), packet.samples.count * 2) },
                    state: { submit(.state($0), 0) }, clock: { submit(.clock($0), 0) },
                    paused: { _, _ in submit(.paused, 0) })) { result in
                        if case .success(let receiver) = result, !owner.install(receiver) { return }
                        submit(.attached(result), 0)
                    }
            }
        }
    }

    private func consumeMedia(_ event: MediaEvent) {
        switch event {
        case .attached(.success(let receiver)): mediaReceiver = receiver
        case .attached(.failure): scheduleMediaRetry(message: "Secure audio is unavailable. Retrying…")
        case .prepare(let preparation):
            let renderGeneration = audio.lifecycle.generation
            do {
                guard audio.lifecycle.canRender else { throw AppleMediaError.invalidState }
                if preparation.anchor.state == .running {
                    try audio.prepareMediaAnchor(id: preparation.id,
                        anchor: .init(captureTimeNanos: preparation.anchor.captureTimeNanos,
                                      hostPlaybackTimeNanos: preparation.anchor.hostPlaybackTimeNanos),
                        clockOffsetNanos: preparation.clock.offsetNanos, generation: renderGeneration)
                }
                // Keep this app/render generation separate from the receiver's
                // transport lifecycle generation (which starts at one per session).
                renderPreparations = [preparation.id: renderGeneration]
                receiverGeneration = preparation.lifecycleGeneration
                mediaReceiver?.completePreparation(id: preparation.id, ready: true)
            } catch { mediaReceiver?.completePreparation(id: preparation.id, ready: false) }
        case .commit(let preparation):
            guard let renderGeneration = renderPreparations.removeValue(forKey: preparation.id),
                  renderGeneration == audio.lifecycle.generation else { mediaReceiver?.resynchronize(); return }
            guard preparation.anchor.state == .running else { return }
            do { try audio.commitMediaAnchor(id: preparation.id, generation: renderGeneration) }
            catch { mediaReceiver?.resynchronize() }
        case .audio(let packet, let transportGeneration):
            guard receiverGeneration == transportGeneration else { return }
            do { try audio.enqueueMedia(packet, generation: audio.lifecycle.generation) }
            catch AppleMediaError.duplicate { }
            catch AppleMediaError.late { }
            catch { mediaReceiver?.resynchronize() }
        case .clock(let clock): audio.updateMediaClockOffset(clock.offsetNanos)
        case .paused:
            audio.pauseMedia(generation: audio.lifecycle.generation)
        case .state(let state):
            switch state {
            case .failed, .stopped: scheduleMediaRetry(message: "Audio connection interrupted. Retrying…")
            case .active: mediaAvailability = "Encrypted audio connected. Screen and voice are not connected yet."
            case .paused: mediaAvailability = "Broadcaster audio is paused."
            default: mediaAvailability = "Synchronizing encrypted audio…"
            }
        }
    }

    private func scheduleMediaRetry(message: String) {
        stopMedia()
        mediaAvailability = message
        let token = mediaToken
        mediaRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.mediaToken == token else { return }
            self.synchronizeMediaSelection()
        }
    }

    private func stopMedia() {
        mediaToken = UUID()
        mediaRetry?.cancel(); mediaRetry = nil
        mediaBridge?.close(); mediaBridge = nil
        mediaOwner?.stop(); mediaOwner = nil
        mediaReceiver?.stop(); mediaReceiver = nil
        mediaSelection = nil; receiverGeneration = nil; renderPreparations.removeAll()
        audio.pauseMedia(generation: audio.lifecycle.generation)
        mediaAvailability = "Waiting for a secure broadcaster. Screen and voice are not connected yet."
    }
}
