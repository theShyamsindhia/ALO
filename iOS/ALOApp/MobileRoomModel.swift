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
    @Published private(set) var videoImage: CGImage?
    @Published private(set) var videoStatus = "No screen is being shared"
    @Published private(set) var audioConnected = false
    @Published private(set) var status = "Ready to find a nearby room"
    @Published var errorMessage: String?
    @Published var displayName = MobileRoomStore.usesTemporarySimulatorIdentity
        ? "ALO Simulator Test" : UserDefaults.standard.string(forKey: "displayName") ?? "iPhone"
    @Published var levels = AudioMixLevels() { didSet { audio.levels = levels } }
    let audio: iOSAudioSessionCoordinator
    let voice: MobileVoiceController
    @Published private(set) var chatMessages: [RoomChatMessage] = []
    private var chatDocument = RoomChatDocument()
    private var seenChatEvents: Set<String> = []
    @Published private(set) var mediaAvailability = "Waiting for a secure broadcaster."
    let isTemporarySimulatorSession = MobileRoomStore.usesTemporarySimulatorIdentity
    private(set) var localID = ""
    private var identity: InstallationIdentity?
    private var pins: (any PeerPinStore)?
    private var store: MobileRoomStore?
    private var discovery: DiscoveryCoordinator?
    private var mesh: MeshControlPlane?
    private var generation: UInt64 = 0
    private var foreground = false
    private var backgroundPlayback = false
    private var backgroundMonitor: Task<Void, Never>?
    private var lastMediaPacketNanos: UInt64?
    private var mediaRunning = false
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
    private var committedBroadcasterEpoch: UInt64?
    private var missedCutoverRepair: (epoch: UInt64, delay: UInt64)?
    private var startingAudio = false
    private var videoStarted = false
    private var currentVideoToken: UUID?
    private let mediaJitter = NetworkJitterEstimator()
    private var mediaClock: MediaReceiverSession.ClockSnapshot?
    @Published private(set) var annotationScene: AnnotationSceneModel?

    init() {
        let audio = iOSAudioSessionCoordinator()
        self.audio = audio
        voice = MobileVoiceController(audio: audio)
    }

    private enum MediaEvent: Sendable {
        case attached(Result<MediaReceiverSession, Error>)
        case prepare(MediaReceiverSession.Preparation)
        case commit(MediaReceiverSession.Preparation)
        case audio(AudioPacket, UInt64, UInt64)
        case state(MediaReceiverSession.State)
        case clock(MediaReceiverSession.ClockSnapshot)
        case paused
        case videoState(VideoReceiverState, UUID)
    }

    /// Attachment ownership cannot live only in the bounded UI event queue: an
    /// overflow can discard its attached-success event before MainActor sees it.
    private final class MediaTransportOwner: @unchecked Sendable {
        private let lock = NSLock()
        private var receiver: MediaReceiverSession?
        private var decoder: VideoDecoder?
        private var videoEnabled = false
        private var videoGeneration = UUID()
        private var annotations: SecureMacAnnotationViewer?
        private var closed = false
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return !closed }
        func setAnnotations(_ annotations: SecureMacAnnotationViewer) {
            lock.lock(); self.annotations = annotations; lock.unlock()
        }
        func receiveAnnotation(_ bytes: Data) -> Bool {
            lock.lock(); let annotations = closed ? nil : self.annotations; lock.unlock()
            return annotations?.receiveAnnotation(bytes) ?? true
        }
        func receiveMetadata(_ bytes: Data) -> Bool {
            lock.lock(); let annotations = closed ? nil : self.annotations; lock.unlock()
            return annotations?.receiveMetadata(bytes) ?? true
        }
        func attachAnnotations(channel: SecurePeerChannel, receiver: MediaReceiverSession) {
            lock.lock(); let annotations = closed ? nil : self.annotations; lock.unlock()
            annotations?.attach(channel: channel, receiver: receiver)
        }
        @MainActor func updateParticipants(_ names: [String: String]) {
            lock.lock(); let annotations = closed ? nil : self.annotations; lock.unlock()
            annotations?.updateParticipants(names)
        }
        func setDecoder(_ decoder: VideoDecoder) {
            lock.lock(); self.decoder = decoder; lock.unlock()
        }
        @discardableResult func setVideoEnabled(_ enabled: Bool) -> UUID {
            lock.lock(); videoEnabled = enabled
            videoGeneration = UUID()
            if !enabled { decoder?.forceResync() }
            let generation = videoGeneration
            lock.unlock()
            return generation
        }
        func acceptVideo(_ frame: VideoFrame, generation: UUID) {
            lock.lock(); defer { lock.unlock() }
            guard !closed, videoEnabled, videoGeneration == generation else { return }
            decoder?.accept(frame)
        }
        func updateVideoClock(_ offset: Int64) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            decoder?.updateClockOffsetNanos(offset)
        }
        func commitVideoAnchor(_ anchor: MediaStreamAnchor) {
            lock.lock(); defer { lock.unlock() }
            guard !closed, anchor.hostPlaybackTimeNanos >= anchor.captureTimeNanos else { return }
            decoder?.stagePlayoutAnchor(captureTimeNanos: anchor.captureTimeNanos,
                delayNanos: anchor.hostPlaybackTimeNanos - anchor.captureTimeNanos)
        }
        func install(_ receiver: MediaReceiverSession) -> Bool {
            lock.lock()
            guard !closed else { lock.unlock(); receiver.stop(); return false }
            self.receiver = receiver; lock.unlock(); return true
        }
        func stop() {
            lock.lock(); closed = true
            let receiver = self.receiver; self.receiver = nil
            let decoder = self.decoder; self.decoder = nil
            let annotations = self.annotations; self.annotations = nil
            decoder?.resetTiming()
            lock.unlock(); annotations?.stop(); receiver?.stop()
            // Decoder teardown may wait for VideoToolbox. Never block the
            // admitted network executor or MainActor on that wait.
            if let decoder { DispatchQueue.global(qos: .userInitiated).async { decoder.stop() } }
        }
        deinit {
            annotations?.stop()
            receiver?.stop()
            if let decoder {
                decoder.resetTiming()
                DispatchQueue.global(qos: .userInitiated).async { decoder.stop() }
            }
        }
    }

    deinit {
        voice.relay.stop()
        backgroundMonitor?.cancel()
        mediaOwner?.stop()
        mediaRetry?.cancel(); joinTimeout?.cancel()
        mesh?.stop()
        let audio = audio
        Task { @MainActor in audio.close() }
    }

    func activate() {
        foreground = true
        backgroundPlayback = false; backgroundMonitor?.cancel(); backgroundMonitor = nil
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
                    self?.voice.audioLifecycleChanged(lifecycle)
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
        if mesh != nil { synchronizeVideo() }
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
        // A foreground Talk/Invite is never permission to keep the microphone
        // open in the background. Stopping it may require a new output anchor.
        voice.endOpenLine()
        let canContinue = canContinueBackgroundPlayback
        foreground = false
        discovery?.stop()
        backgroundPlayback = canContinue
        synchronizeVideo()
        if canContinue {
            status = "Playing room audio in the background"
            let token = generation
            backgroundMonitor?.cancel()
            backgroundMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self, self.generation == token,
                          !self.foreground, self.backgroundPlayback else { return }
                    if !self.canContinueBackgroundPlayback { self.finishBackgroundPlayback(); return }
                }
            }
            return
        }
        finishBackgroundPlayback()
    }

    private var canContinueBackgroundPlayback: Bool {
        BackgroundAudioEligibility.allows(connected: connected, running: mediaRunning,
            hasScheduledAudio: audio.hasScheduledMediaPlayback,
            microphoneActive: audio.lifecycle.isMicrophoneActive,
            lastPacketNanos: lastMediaPacketNanos, nowNanos: MonotonicClock.nowNanos())
    }

    private func finishBackgroundPlayback() {
        backgroundPlayback = false; backgroundMonitor?.cancel(); backgroundMonitor = nil
        disconnectRuntime()
        audio.suspend()
        if room != nil { status = "Paused while the app is in the background" }
    }

    func sendChat(_ text: String) -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, let encoded = RoomChatOperation(kind: .message, text: message).encoded,
              encoded.utf8.count <= 4_096 else { return false }
        mesh?.publishChat(encoded)
        return true
    }

    func sendChatOperation(_ operation: RoomChatOperation) -> Bool {
        guard connected, let encoded = operation.encoded, encoded.utf8.count <= 4_096 else { return false }
        mesh?.publishChat(encoded); return true
    }

    private func updateChat(_ value: MeshRoomReplica) {
        let events = value.chatEvents
        // Seen IDs follow the bounded retained room history. The shared reducer
        // handles rich operations, legacy text and authorship—not UI string parsing.
        seenChatEvents.formIntersection(Set(events.map(\.id)))
        for event in events where !seenChatEvents.contains(event.id) {
            seenChatEvents.insert(event.id)
            _ = chatDocument.receive(senderID: event.senderID ?? event.version.nodeID,
                sender: event.sender ?? "Room member", text: event.text ?? "",
                sentNanos: event.sentNanos ?? 0, version: event.version)
        }
        chatMessages = chatDocument.messages
    }

    private func connect(_ choice: RoomConfiguration, selected: NearbyPeerHint?) {
        guard foreground, identity != nil, pins != nil, store != nil else { return }
        discovery?.stop()
        generation &+= 1
        let token = generation
        connected = false; participants = []; status = "Connecting securely…"
        chatDocument = RoomChatDocument(); seenChatEvents.removeAll(); chatMessages = []
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
        let voiceToken = UUID(), voiceRelay = voice.relay
        let document: Data?
        do { document = try store.document(roomID: choice.id) }
        catch { errorMessage = "Saved room history could not be read. It will resynchronize from peers."; document = nil }
        let runtime = MeshControlPlane(room: choice, nodeID: localID, displayName: displayName,
            deviceIcon: "iphone", initialRoomStateDocument: document,
            replicaHandler: { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.replica = value
                    self.updateChat(value)
                    self.synchronizeMediaSelection()
                    self.synchronizeVideo()
                }
            }, participantsHandler: { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.participants = value
                    self.voice.updateParticipants(value)
                    self.mediaOwner?.updateParticipants(Dictionary(uniqueKeysWithValues: value.map { ($0.id, $0.name) }))
                    self.connected = value.contains { $0.id != self.localID }
                    self.status = self.connected ? "Connected · encrypted mesh" : "Waiting for a room member…"
                    if self.connected { self.joinTimeout?.cancel() }
                    self.synchronizeMediaSelection()
                }
            }, mediaCommandHandler: { _, _, _ in false }, resyncRequestHandler: { _, _, _ in false },
            walkieTalkieHandler: { voiceRelay.receive($0, generation: voiceToken) },
            openLineHandler: { voiceRelay.receive($0, generation: voiceToken) },
            roomStatePersistenceHandler: { [weak self] data in
                do { try store.saveDocument(data, roomID: choice.id) }
                catch {
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.errorMessage = "Room history could not be saved on this device."
                    }
                }
            }, installationIdentity: identity, peerPins: pins, secureCapabilities: [.chat, .receiveAudio, .receiveVideo, .voice],
            incomingMediaChannelHandler: { channel, peer in
                voiceRelay.admit(channel, peer: peer, generation: voiceToken)
            },
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
            voice.start(mesh: runtime, localID: identity.publicIdentity.nodeID, name: displayName, generation: voiceToken)
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
        connected = false
        voice.stop()
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
        guard foreground || backgroundPlayback, connected, let mesh, let roomID = room.flatMap({ UUID(uuidString: $0.id) }),
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
        let annotations = SecureMacAnnotationViewer(localID: localPeerID, presenterID: peerID) { [weak self] scene in
            guard let self, self.mediaToken == token else { return }
            self.annotationScene = scene
        }
        annotations.updateParticipants(Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.name) }))
        owner.setAnnotations(annotations)
        let decoder = VideoDecoder { [weak self] image in
            MainActor.assumeIsolated {
                guard let self, self.mediaToken == token, self.videoStarted, self.replica.videoEnabled else { return }
                self.videoImage = image
                self.videoStatus = "Screen connected"
            }
        }
        owner.setDecoder(decoder)
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
        mediaAvailability = "Synchronizing encrypted audio…"
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
                    audio: { packet, _, generation in
                        submit(.audio(packet, generation, MonotonicClock.nowNanos()), packet.samples.count * 2)
                    },
                    state: { submit(.state($0), 0) }, clock: { submit(.clock($0), 0) },
                    paused: { _, _ in submit(.paused, 0) },
                    annotation: { owner.receiveAnnotation($0) },
                    metadata: { owner.receiveMetadata($0) })) { result in
                        if case .success(let receiver) = result, !owner.install(receiver) { return }
                        if case .success(let receiver) = result {
                            owner.attachAnnotations(channel: channel, receiver: receiver)
                        }
                        submit(.attached(result), 0)
                    }
            }
        }
    }

    private func consumeMedia(_ event: MediaEvent) {
        switch event {
        case .attached(.success(let receiver)):
            mediaReceiver = receiver
            publishMediaTiming()
            synchronizeVideo()
        case .attached(.failure): scheduleMediaRetry(message: "Secure audio is unavailable. Retrying…")
        case .prepare(let preparation):
            let renderGeneration = audio.lifecycle.generation
            mediaClock = preparation.clock
            // Emit the real hardware floor before accepting OR rejecting the
            // first anchor, so a Bluetooth route is not trapped in renew/reject.
            publishMediaTiming()
            do {
                guard audio.lifecycle.canRender else { throw AppleMediaError.invalidState }
                guard preparation.anchor.hostPlaybackTimeNanos >= preparation.anchor.captureTimeNanos else {
                    throw AppleMediaError.invalidAnchor
                }
                mediaOwner?.updateVideoClock(preparation.clock.offsetNanos)
                if preparation.anchor.state == .running {
                    try audio.prepareMediaAnchor(id: preparation.id,
                        anchor: .init(captureTimeNanos: preparation.anchor.captureTimeNanos,
                                      hostPlaybackTimeNanos: preparation.anchor.hostPlaybackTimeNanos),
                        clockOffsetNanos: preparation.clock.offsetNanos, generation: renderGeneration,
                        preserveCurrentTimeline: committedBroadcasterEpoch == preparation.anchor.stream.broadcasterEpoch
                            && !audio.lifecycle.needsResynchronization)
                }
                // Keep this app/render generation separate from the receiver's
                // transport lifecycle generation (which starts at one per session).
                renderPreparations = [preparation.id: renderGeneration]
                receiverGeneration = preparation.lifecycleGeneration
                mediaReceiver?.completePreparation(id: preparation.id, ready: true)
            } catch AppleMediaError.missedCutover {
                mediaReceiver?.completePreparation(id: preparation.id, ready: false)
                let key = (epoch: preparation.anchor.stream.broadcasterEpoch,
                           delay: preparation.anchor.hostPlaybackTimeNanos - preparation.anchor.captureTimeNanos)
                if missedCutoverRepair?.epoch != key.epoch || missedCutoverRepair?.delay != key.delay {
                    missedCutoverRepair = key
                    // This peer missed an already-authoritative room cutover.
                    // Do not retime the room or destroy healthy peer playback.
                    audio.pauseMedia(generation: renderGeneration)
                    committedBroadcasterEpoch = nil; renderPreparations.removeAll()
                    mediaReceiver?.resynchronize()
                }
            } catch { mediaReceiver?.completePreparation(id: preparation.id, ready: false) }
        case .commit(let preparation):
            guard let renderGeneration = renderPreparations.removeValue(forKey: preparation.id),
                  renderGeneration == audio.lifecycle.generation else { mediaReceiver?.resynchronize(); return }
            guard preparation.anchor.state == .running else {
                mediaOwner?.commitVideoAnchor(preparation.anchor); return
            }
            do {
                try audio.commitMediaAnchor(id: preparation.id, generation: renderGeneration)
                committedBroadcasterEpoch = preparation.anchor.stream.broadcasterEpoch
                missedCutoverRepair = nil
                mediaOwner?.commitVideoAnchor(preparation.anchor)
            }
            catch { mediaReceiver?.resynchronize() }
        case .audio(let packet, let transportGeneration, let arrivedAt):
            guard receiverGeneration == transportGeneration else { return }
            guard !audio.lifecycle.needsResynchronization else { return }
            if let mediaClock {
                mediaJitter.observe(captureTimeNanos: packet.captureTimeNanos,
                    receivedAt: arrivedAt, clockOffsetNanos: mediaClock.offsetNanos)
            }
            do {
                try audio.enqueueMedia(packet, generation: audio.lifecycle.generation)
                lastMediaPacketNanos = arrivedAt
            }
            catch AppleMediaError.duplicate { }
            catch AppleMediaError.late { }
            catch { mediaReceiver?.resynchronize() }
        case .clock(let clock):
            mediaClock = clock
            audio.updateMediaClockOffset(clock.offsetNanos)
            mediaOwner?.updateVideoClock(clock.offsetNanos)
            publishMediaTiming()
        case .paused:
            mediaRunning = false
            missedCutoverRepair = nil
            committedBroadcasterEpoch = nil
            audio.pauseMedia(generation: audio.lifecycle.generation)
        case .state(let state):
            switch state {
            case .failed, .stopped: scheduleMediaRetry(message: "Audio connection interrupted. Retrying…")
            case .active:
                mediaRunning = true
                audioConnected = true
                mediaAvailability = "Encrypted audio connected."
            case .paused:
                mediaRunning = false; mediaAvailability = "Broadcaster audio is paused."
                if backgroundPlayback { finishBackgroundPlayback() }
            default: mediaAvailability = "Synchronizing encrypted audio…"
            }
        case .videoState(let state, let generation):
            guard videoStarted, currentVideoToken == generation else { return }
            switch state {
            case .active: videoStatus = videoImage == nil ? "Waiting for the first screen frame…" : "Screen connected"
            case .connecting: videoStatus = "Connecting encrypted screen…"
            case .recovering: videoStatus = "Screen interrupted. Reconnecting…"
            case .stopped: videoStatus = "Waiting for the broadcaster’s screen…"
            }
        }
    }

    private func publishMediaTiming() {
        let latency = audio.outputLatencyNanos
        let floor = RoomTiming.outputLatencyFloor(latency)
        let rtt = mediaClock.flatMap { $0.roundTripNanos <= MediaReceiverTimingReport.maximumAgeNanos ? $0.roundTripNanos : nil }
        let recommendation = mediaJitter.recommendedPlayoutDelayNanos(roundTripNanos: rtt, outputLatencyNanos: latency)
        if let report = try? MediaReceiverTimingReport(hardwareOutputFloorNanos: floor,
            networkRecommendedDelayNanos: max(floor, recommendation), roundTripNanos: rtt) {
            mediaReceiver?.updateTiming(report)
        }
    }

    private func synchronizeVideo() {
        guard foreground, replica.videoEnabled, let receiver = mediaReceiver, let owner = mediaOwner,
              let mesh, let selection = mediaSelection, let bridge = mediaBridge else {
            if videoStarted { mediaReceiver?.stopVideo(); mediaOwner?.setVideoEnabled(false) }
            videoStarted = false; currentVideoToken = nil; videoImage = nil; videoStatus = "No screen is being shared"
            return
        }
        guard !videoStarted else { return }
        videoStarted = true
        let generation = owner.setVideoEnabled(true)
        currentVideoToken = generation
        videoStatus = "Connecting encrypted screen…"
        receiver.startVideo(openChannel: { reply in
            guard owner.isOpen else { reply(.failure(SecurePeerChannelError.cancelled)); return }
            mesh.openMediaChannel(to: selection.broadcasterPeerID, role: .video) { result in
                switch result {
                case .success(let (channel, _)):
                    guard owner.isOpen else { channel.cancel(); reply(.failure(SecurePeerChannelError.cancelled)); return }
                    reply(.success(channel)) // Inline: install handlers before coalesced payloads.
                case .failure(let error): reply(.failure(error))
                }
            }
        }, callbacks: .init(frame: { frame, _, _ in owner.acceptVideo(frame, generation: generation) }, state: { state in
            if !bridge.submit(.videoState(state, generation)) { owner.stop() }
        }))
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
        annotationScene = nil
        mediaReceiver?.stop(); mediaReceiver = nil
        mediaSelection = nil; receiverGeneration = nil; committedBroadcasterEpoch = nil; missedCutoverRepair = nil; renderPreparations.removeAll()
        mediaClock = nil; mediaJitter.reset()
        lastMediaPacketNanos = nil; mediaRunning = false
        videoStarted = false; currentVideoToken = nil; videoImage = nil; videoStatus = "No screen is being shared"; audioConnected = false
        audio.pauseMedia(generation: audio.lifecycle.generation)
        mediaAvailability = "Waiting for a secure broadcaster."
    }
}
