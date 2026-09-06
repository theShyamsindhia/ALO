import CryptoKit
import Foundation
import Network
import ALOCore

struct ChatAttachmentReceiveAdmission {
    static let windowNanos: UInt64 = 60_000_000_000
    static let maximumBytes = 32 * 1_024 * 1_024
    static let maximumTransfers = 8

    private(set) var windowStartedAt: UInt64 = 0
    private(set) var bytes = 0
    private(set) var transfers = 0

    mutating func permits(packetBytes: Int, now: UInt64) -> Bool {
        if windowStartedAt == 0 || now < windowStartedAt || now - windowStartedAt >= Self.windowNanos {
            windowStartedAt = now
            bytes = 0
            transfers = 0
        }
        guard packetBytes > 0, packetBytes <= RoomChatAttachmentPacket.chunkBytes,
              transfers < Self.maximumTransfers,
              bytes <= Self.maximumBytes - packetBytes else { return false }
        bytes += packetBytes
        return true
    }

    mutating func completedTransfer() { transfers += 1 }
}

struct RealtimeVoiceSendQueue {
    struct Item {
        let kind: WalkieTalkieKind
        let sessionID: String
        let data: Data
    }

    let maximumPendingAudioPackets: Int
    private(set) var pending = [Item]()

    init(maximumPendingAudioPackets: Int = 8) {
        self.maximumPendingAudioPackets = max(1, maximumPendingAudioPackets)
    }

    mutating func enqueue(_ item: Item) {
        switch item.kind {
        case .began:
            pending.removeAll { $0.sessionID == item.sessionID }
        case .audio:
            while pending.lazy.filter({ $0.kind == .audio }).count >= maximumPendingAudioPackets,
                  let stale = pending.firstIndex(where: { $0.kind == .audio }) {
                pending.remove(at: stale)
            }
        case .ended:
            // Speech that is still waiting for the socket is already stale by
            // the time Talk ends. Deliver the end marker promptly instead.
            pending.removeAll { $0.sessionID == item.sessionID }
        }
        pending.append(item)
    }

    mutating func popFirst() -> Item? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

/// Stateful low-pass decimator used only for peers that predate full-band voice.
/// Keeping the filter history per connection/session avoids a click at every
/// 20 ms packet boundary while suppressing frequencies above the 16 kHz
/// stream's Nyquist limit before decimation.
struct LegacyVoiceDownsampler {
    private static let tapCount = 31
    private static let decimationFactor = 3
    private static let coefficients: [Double] = {
        let cutoff = 7_000.0 / 48_000.0
        let midpoint = Double(tapCount - 1) / 2
        var values = (0..<tapCount).map { index -> Double in
            let distance = Double(index) - midpoint
            let sinc = distance == 0
                ? 2 * cutoff
                : sin(2 * Double.pi * cutoff * distance) / (Double.pi * distance)
            let window = 0.54 - 0.46 * cos(2 * Double.pi * Double(index) / Double(tapCount - 1))
            return sinc * window
        }
        let total = values.reduce(0, +)
        guard total != 0 else { return values }
        for index in values.indices { values[index] /= total }
        return values
    }()

    private var history = [Double](repeating: 0, count: tapCount)
    private var writeIndex = 0
    private var phase = 0

    mutating func process(_ data: Data) -> Data? {
        guard !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<Int16>.size)
        else { return nil }

        var output = Data()
        output.reserveCapacity(data.count / Self.decimationFactor)
        data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: data.count, by: MemoryLayout<Int16>.size) {
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                history[writeIndex] = Double(Int16(bitPattern: bits))
                writeIndex = (writeIndex + 1) % Self.tapCount
                phase += 1
                guard phase == Self.decimationFactor else { continue }
                phase = 0

                var filtered = 0.0
                for tap in 0..<Self.tapCount {
                    let historyIndex = (writeIndex - 1 - tap + Self.tapCount) % Self.tapCount
                    filtered += history[historyIndex] * Self.coefficients[tap]
                }
                let sample = Int16(clamping: Int(filtered.rounded()))
                let outputBits = UInt16(bitPattern: sample)
                output.append(UInt8(truncatingIfNeeded: outputBits))
                output.append(UInt8(truncatingIfNeeded: outputBits >> 8))
            }
        }
        return output
    }
}

/// The shared room, chat, durable-state, and voice-signaling runtime. This
/// extraction preserves the legacy wire; v2 admission is a separate integration.
public final class MeshControlPlane: @unchecked Sendable {
    static let identityEnvelopeType = "display_name"
    private struct WalkieMessageKey: Hashable {
        let senderID: String
        let sessionID: String
        let kind: String
        let sequence: UInt64
        let targetIDs: [String]?
    }
    private struct OpenLineMessageKey: Hashable {
        let invitationID: String
        let kind: String
        let senderID: String
        let targetID: String
    }
    private struct PendingRoomAction {
        let envelope: MeshEnvelope
        let broadcasterID: String
        let broadcasterEpoch: UInt64
        var attempts: Int
    }
    private final class Link {
        let connection: NWConnection
        let initiated: Bool
        let decoder = MeshEnvelopeDecoder()
        var nodeID: String?
        var displayName: String?
        var deviceIcon: String?
        var deviceColorHex: String?
        var profileImageData: Data?
        var appVersion: String?
        var roomStateSyncVersion: UInt8?
        var realtimeVoiceQueue = RealtimeVoiceSendQueue()
        var realtimeVoiceSendInFlight = false
        var arenaSendInFlight = false
        var arenaSendQueue = GameSendQueue()
        var chatAttachmentSendInFlight = false
        var chatAttachmentSendQueue = [Data]()
        var chatAttachmentQueuedBytes = 0
        var arenaReceiveWindow: UInt64 = 0
        var arenaReceiveCount = 0
        var chatAttachmentReceiveAdmission = ChatAttachmentReceiveAdmission()
        var roomTrayRequestWindow: UInt64 = 0
        var roomTrayRequestCount = 0
        var legacyVoiceDownsamplers = [String: LegacyVoiceDownsampler]()
        var remoteVersionVector: [String: UInt64]?
        let roomStateSyncSession: RoomStateSyncSession
        var roomStateSyncID: String?
        var roomStateSyncChunkCount: UInt16 = 0
        var roomStateSyncNextChunk: UInt16 = 0
        var roomStateSyncBuffer = Data()
        var snapshotSendQueue = [MeshEnvelope]()
        var snapshotSendInFlight = false
        var snapshotResendRequested = false
        var roomStateSyncSendQueue = [Data]()
        var roomStateSyncSendInFlight = false
        var roomStateSyncReceiveInFlight = false
        var roomStateSyncReceiveQueue = [Data]()
        var roomStateSyncReceiveQueuedBytes = 0
        let localNonce = UUID().uuidString
        var authenticated = false
        var secureChannel: SecurePeerChannel?
        var authenticatedPeer: AuthenticatedPeer?
        var receivedHello = false
        var remoteReady = false
        var commitSent = false
        var lastPayloadNanos: UInt64 = 0
        var listeningPort: UInt16?
        var hintExpiresAtNanos: UInt64?

        init(
            connection: NWConnection,
            initiated: Bool,
            roomStateSyncSession: RoomStateSyncSession
        ) {
            self.connection = connection
            self.initiated = initiated
            self.roomStateSyncSession = roomStateSyncSession
        }
    }

    public let room: RoomConfiguration
    public let nodeID: String
    private var roomIcon: RoomIcon?
    private let roomIconHandler: (RoomIcon) -> Void
    private var advertisedRecord = [String: String]()
    private var displayName: String
    private var deviceIcon: String
    private var deviceColorHex: String
    private var profileImageData: Data?
    private let queue = DispatchQueue(label: "in.werai.mesh.control", qos: .userInteractive)
    private let mediaExecutorKey = DispatchSpecificKey<UInt8>()
    private let roomStateWorkerQueue = DispatchQueue(label: "in.werai.mesh.room-state", qos: .utility)
    private let replicaHandler: (MeshRoomReplica) -> Void
    private let participantsHandler: ([RoomParticipant]) -> Void
    private let peerVersionHandler: (String) -> Void
    private let mediaCommandHandler: (RoomMediaCommand, String, UInt64) -> Bool
    private let resyncRequestHandler: (String?, String, UInt64) -> Bool
    private let walkieTalkieHandler: (WalkieTalkieMessage) -> Void
    private let openLineHandler: (OpenLineMessage) -> Void
    private let appVersion: String
    private let listenerReadyHandler: ((NWEndpoint.Port) -> Void)?
    private let connectionAttemptHandler: () -> Void
    private let installationIdentity: InstallationIdentity?
    private let peerPins: (any PeerPinStore)?
    private let incomingMediaChannelHandler: ((SecurePeerChannel, AuthenticatedPeer) -> Void)?
    private let eventPolicy: SecureRoomEventPolicy?
    private let secureCapabilities: PeerCapabilities
    private let incarnationID = UUID()
    private var advertises = false
    private var scanDeadline: DispatchWorkItem?
    private var scanGeneration: UInt64 = 0
    private var scanWindowExpiresAtNanos: UInt64?
    private var secureAdmissions: [UInt64] = []
    private var pendingCommits: [String: UUID] = [:]
    private var pendingMediaChannels: [UUID: SecurePeerChannel] = [:]
    private struct DirectoryEntry {
        let hint: MeshPeerDirectoryHint
        let expiresAtNanos: UInt64
        var lastAttemptNanos: UInt64 = 0
    }
    private var peerDirectory: [String: DirectoryEntry] = [:]
    private var lastDirectoryPublishNanos: UInt64 = 0
    private let secureStateHandler: (String?, SecurePeerChannelState) -> Void
    private let listenerStateHandler: (NWListener.State) -> Void
    private var replica: MeshRoomReplica
    private let roomStateSync: any RoomStateSync
    private let roomStatePersistenceHandler: (Data) -> Void
    private let roomStateReceiveCompletedHandler: ([MeshRoomEvent]) -> Void
    private let arenaHandler: (String, Data) -> Void
    private let chatAttachmentHandler: (String, RoomChatAttachmentPayload) -> Void
    private let roomTrayFileRequestHandler: (String, RoomTrayFileRequest) -> Void
    private var chatAttachmentAssembler = RoomChatAttachmentAssembler()
    private let roomStateDowngradeHandler: (String?) -> Void
    private let disableRoomStateSyncDuringAuthenticationForTesting: Bool
    private var roomStatePersistenceWorkItem: DispatchWorkItem?
    private var roomStateSyncDisabled = false
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links = [ObjectIdentifier: Link]()
    private var peers = [String: Link]()
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatSequence: UInt64 = 0
    private let heartbeatGeneration = UUID().uuidString
    private var latestHeartbeatSequence = [String: UInt64]()
    private var latestHeartbeatGeneration = [String: String]()
    private var lastSeenNanos = [String: UInt64]()
    private var remoteParticipants = [String: RoomParticipant]()
    private var lastPublishedParticipants = [RoomParticipant]()
    private var playbackReports: [String: (timing: PeerPlaybackTiming, received: UInt64, broadcaster: String, epoch: UInt64)] = [:]
    private var lastPlaybackReportSend: UInt64 = 0
    private var reconnectAttempts = [String: Int]()
    private var reconnectWorkItems = [String: DispatchWorkItem]()
    private var seenRoomActionIDs = Set<String>()
    private var roomActionIDOrder = [String]()
    private var acceptedRoomActionIDs = Set<String>()
    private var seenWalkieMessages = Set<WalkieMessageKey>()
    private var seenWalkieMessageOrder = [WalkieMessageKey]()
    private var seenOpenLineMessages = Set<OpenLineMessageKey>()
    private var seenOpenLineMessageOrder = [OpenLineMessageKey]()
    private var pendingRoomActions = [String: PendingRoomAction]()
    private var isStopped = true
    private let heartbeatIntervalNanos: UInt64 = 400_000_000
    private let broadcasterLeaseNanos: UInt64 = 2_400_000_000
    private let participantLeaseNanos: UInt64 = 2_400_000_000
    private let maximumSyncEvents = 2_000
    private static let synchronizationEnvelopeTargetBytes = 196_608
    static let roomStateSyncChunkBytes = 96 * 1_024
    static let maximumRoomStateSyncBytes = 5 * 1_024 * 1_024
    static let maximumRoomStateSyncChunks: UInt16 = 96
    private let maximumRememberedWalkieMessages = 8_192
    private let maximumWalkieTalkieHopCount: UInt8 = 8
    private static let fullBandVoiceVersion = AppVersion("0.13.31")!
    private static let maximumPendingRoomStateSyncMessages = 32
    private static let maximumPendingRoomStateSyncBytes = 16 * 1_024 * 1_024

    /// Persistence callbacks return opaque local state. Pass it back through
    /// initialRoomStateDocument unchanged; secure rooms include locally signed admission grants.
    public init(
        room: RoomConfiguration,
        nodeID: String,
        displayName: String,
        deviceIcon: String? = nil,
        deviceColorHex: String? = nil,
        profileImageData: Data? = nil,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        initialEvents: [MeshRoomEvent] = [],
        initialRoomStateDocument: Data? = nil,
        listenerReadyHandler: ((NWEndpoint.Port) -> Void)? = nil,
        replicaHandler: @escaping (MeshRoomReplica) -> Void,
        participantsHandler: @escaping ([RoomParticipant]) -> Void,
        roomIconHandler: @escaping (RoomIcon) -> Void = { _ in },
        peerVersionHandler: @escaping (String) -> Void = { _ in },
        mediaCommandHandler: @escaping (RoomMediaCommand, String, UInt64) -> Bool = { _, _, _ in true },
        resyncRequestHandler: @escaping (String?, String, UInt64) -> Bool = { _, _, _ in true },
        walkieTalkieHandler: @escaping (WalkieTalkieMessage) -> Void = { _ in },
        openLineHandler: @escaping (OpenLineMessage) -> Void = { _ in },
        arenaHandler: @escaping (String, Data) -> Void = { _, _ in },
        chatAttachmentHandler: @escaping (String, RoomChatAttachmentPayload) -> Void = { _, _ in },
        roomTrayFileRequestHandler: @escaping (String, RoomTrayFileRequest) -> Void = { _, _ in },
        roomStatePersistenceHandler: @escaping (Data) -> Void = { _ in },
        roomStateSyncOverride: (any RoomStateSync)? = nil,
        roomStateReceiveCompletedHandler: @escaping ([MeshRoomEvent]) -> Void = { _ in },
        roomStateDowngradeHandler: @escaping (String?) -> Void = { _ in },
        disableRoomStateSyncDuringAuthenticationForTesting: Bool = false,
        connectionAttemptHandler: @escaping () -> Void = {},
        installationIdentity: InstallationIdentity? = nil,
        peerPins: (any PeerPinStore)? = nil,
        secureCapabilities: PeerCapabilities = .desktop,
        incomingMediaChannelHandler: ((SecurePeerChannel, AuthenticatedPeer) -> Void)? = nil,
        secureStateHandler: @escaping (String?, SecurePeerChannelState) -> Void = { _, _ in },
        listenerStateHandler: @escaping (NWListener.State) -> Void = { _ in }
    ) {
        self.room = room
        self.nodeID = nodeID
        self.roomIcon = room.icon
        self.roomIconHandler = roomIconHandler
        self.displayName = displayName
        let generatedAppearance = DeviceAppearance.generated(from: nodeID)
        let appearance = DeviceAppearance(
            icon: deviceIcon ?? generatedAppearance.icon,
            colorHex: deviceColorHex ?? generatedAppearance.colorHex
        )
        self.deviceIcon = appearance.icon
        self.deviceColorHex = appearance.colorHex
        self.profileImageData = DeviceAppearance.sanitizedProfileImageData(profileImageData)
        self.appVersion = appVersion
        self.peerVersionHandler = peerVersionHandler
        self.mediaCommandHandler = mediaCommandHandler
        self.resyncRequestHandler = resyncRequestHandler
        self.walkieTalkieHandler = walkieTalkieHandler
        self.openLineHandler = openLineHandler
        let eventPolicy = room.transportPolicy == .secureV2
            ? SecureRoomEventPolicy(roomID: room.id, identity: installationIdentity, capabilities: secureCapabilities) : nil
        self.eventPolicy = eventPolicy
        self.arenaHandler = arenaHandler
        self.chatAttachmentHandler = chatAttachmentHandler
        self.roomTrayFileRequestHandler = roomTrayFileRequestHandler
        let durableState: any RoomStateSync = roomStateSyncOverride
            ?? AutomergeRoomStateSync.recovering(
                roomID: room.id,
                savedDocument: initialRoomStateDocument.flatMap { eventPolicy?.restoreArchive($0) ?? $0 },
                legacyEvents: initialEvents,
                eventValidator: { eventPolicy?.accepts($0) ?? true }
            )
        self.roomStateSync = durableState
        self.roomStateSyncDisabled = false
        let durableEvents = (try? durableState.snapshot().events) ?? []
        self.replica = MeshRoomReplica(events: (initialEvents + durableEvents).filter { eventPolicy?.accepts($0) ?? true })
        self.roomStatePersistenceHandler = roomStatePersistenceHandler
        self.roomStateReceiveCompletedHandler = roomStateReceiveCompletedHandler
        self.roomStateDowngradeHandler = roomStateDowngradeHandler
        self.disableRoomStateSyncDuringAuthenticationForTesting =
            disableRoomStateSyncDuringAuthenticationForTesting
        self.listenerReadyHandler = listenerReadyHandler
        self.connectionAttemptHandler = connectionAttemptHandler
        self.installationIdentity = installationIdentity
        self.peerPins = peerPins
        self.secureCapabilities = secureCapabilities
        self.incomingMediaChannelHandler = incomingMediaChannelHandler
        self.secureStateHandler = secureStateHandler
        self.listenerStateHandler = listenerStateHandler
        self.replicaHandler = replicaHandler
        self.participantsHandler = participantsHandler
        queue.setSpecific(key: mediaExecutorKey, value: 1)
    }

    /// For bounded/coalesced application work sharing admitted media ownership.
    /// Cleanup remains available after stop; callers guard their own lifecycle.
    public func performMediaWork(_ callback: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: mediaExecutorKey) == 1 { callback() }
        else { queue.async(execute: callback) }
    }

    public func start(advertise: Bool = true) throws {
        try room.validateForJoining()
        if room.transportPolicy == .secureV2 {
            guard let installationIdentity, peerPins != nil,
                  UUID(uuidString: nodeID) == installationIdentity.publicIdentity.nodeID,
                  nodeID == installationIdentity.publicIdentity.nodeID.uuidString,
                  UUID(uuidString: room.id) != nil else { throw SecureTransportError.invalidCredentials }
        }
        let parameters = try transportParameters(expectedPeerID: nil)
        let listener = try NWListener(using: parameters, on: .any)
        isStopped = false
        advertises = advertise
        if room.transportPolicy == .secureV2 { scanWindowExpiresAtNanos = MonotonicClock.nowNanos() + 15_000_000_000 }
        advertisedRecord = [:]
        self.listener = listener
        if advertise {
            refreshAdvertisement()
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            self?.listenerStateHandler(state)
            if case .ready = state, let port = listener.port { self?.listenerReadyHandler?(port) }
        }
        listener.start(queue: queue)
        self.listener = listener

        if advertise, room.transportPolicy == .secureV2 {
            startSecureScan()
        } else if advertise {
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: MeshRoomBrowser.serviceType, domain: nil),
                using: LocalNetworkParameters.tcp()
            )
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.consider(results) }
            browser.start(queue: queue)
            self.browser = browser
        }
        publishParticipants()
        replicaHandler(replica)
        scheduleRoomStatePersistence(delay: .milliseconds(0))
        startHeartbeatTimer()
    }

    func connectForTesting(to endpoint: NWEndpoint, expectedNodeID: String? = nil) {
        queue.async { [weak self] in self?.connect(to: endpoint, expectedNodeID: expectedNodeID) }
    }

    /// Connects a user-selected/discovered endpoint. Its claimed address remains
    /// a hint; v2 TLS verifies the expected installation identity before admission.
    public func connect(to endpoint: NWEndpoint, expectedPeerID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.room.transportPolicy == .secureV2 {
                // A fresh explicit selection owns a new bounded repair window.
                self.scanWindowExpiresAtNanos = MonotonicClock.nowNanos() + 15_000_000_000
            }
            self.connect(to: endpoint, expectedNodeID: expectedPeerID.uuidString)
        }
    }

    /// Opens a separate admitted receiver-initiated connection to a current
    /// direct peer's authenticated listener, never its inbound ephemeral port.
    /// Completion runs on the mesh queue. On success the caller owns the channel,
    /// must install payload/state handlers immediately, and cancel it on leaving.
    public func openMediaChannel(to peerID: UUID, role: ReliableChannelRole,
        completion: @escaping (Result<(SecurePeerChannel, AuthenticatedPeer), Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.isStopped, self.room.transportPolicy == .secureV2,
                  role == .mediaControl || role == .video || role == .voiceControl || role == .fileTransfer,
                  let identity = self.installationIdentity, let pins = self.peerPins,
                  let roomID = UUID(uuidString: self.room.id),
                  let peer = self.peers[peerID.uuidString], peer.authenticated,
                  peer.authenticatedPeer?.nodeID == peerID,
                  let host = self.remoteHost(of: peer), let rawPort = peer.listeningPort,
                  let port = NWEndpoint.Port(rawValue: rawPort) else {
                completion(.failure(SecurePeerChannelError.notAuthenticated)); return
            }
            guard self.pendingMediaChannels.count < 16 else {
                completion(.failure(SecureTransportError.capacity)); return
            }
            do {
                let connection = NWConnection(host: NWEndpoint.Host(host), port: port,
                    using: try self.transportParameters(expectedPeerID: peerID))
                let admission: SecureRoomAdmission = self.room.isPrivate
                    ? .privateRoom(secret: self.room.secureJoinSecret ?? Data()) : .publicRoom
                let configuration = try SecurePeerConfiguration(roomID: roomID, incarnationID: self.incarnationID,
                    admission: admission, offer: ProtocolOffer.current(capabilities: self.secureCapabilities),
                    direction: .initiator(role))
                let channel = SecurePeerChannel(connection: connection, identity: identity, configuration: configuration,
                    pins: pins, queue: self.queue)
                let operation = UUID()
                self.pendingMediaChannels[operation] = channel
                channel.onState = { [weak self] state in
                    guard let self else { return }
                    let error: Error
                    switch state {
                    case .failed(let failure): error = failure
                    case .cancelled: error = SecurePeerChannelError.cancelled
                    default: return
                    }
                    guard self.pendingMediaChannels.removeValue(forKey: operation) != nil else { return }
                    completion(.failure(error))
                }
                channel.onAuthenticated = { [weak self, weak channel] authenticated in
                    guard let self, let channel,
                          self.pendingMediaChannels.removeValue(forKey: operation) != nil else { return }
                    channel.onState = nil; channel.onAuthenticated = nil
                    guard !self.isStopped, authenticated.nodeID == peerID, authenticated.channelRole == role else {
                        channel.cancel(); completion(.failure(SecurePeerChannelError.notAuthenticated)); return
                    }
                    completion(.success((channel, authenticated)))
                }
                channel.start()
            } catch { completion(.failure(error)) }
        }
    }

    /// Creates a host owned by the same executor as admitted channels. Attach
    /// incoming media channels inline in incomingMediaChannelHandler. The caller
    /// owns this host and must stop it on room leave or ownership loss.
    public func makeMediaHost(callbacks: MediaHostSession.Callbacks,
                              completion: @escaping (Result<MediaHostSession, Error>) -> Void) {
        queue.async {
            guard !self.isStopped, self.room.transportPolicy == .secureV2,
                  let roomID = UUID(uuidString: self.room.id),
                  let peerID = UUID(uuidString: self.nodeID), self.localPermits(.broadcast) else {
                completion(.failure(SecureTransportError.invalidState)); return
            }
            do {
                let host = try MediaHostSession(roomID: roomID, localPeerID: peerID, queue: self.queue, callbacks: callbacks)
                host.start(); completion(.success(host))
            } catch { completion(.failure(error)) }
        }
    }

    /// The voice runtime shares the room executor, so beginTransmitting followed
    /// by publishWalkieTalkie(.began) preserves authorization-before-offer order.
    public func makeVoiceSession(callbacks: DirectedVoiceSession.Callbacks,
                                 completion: @escaping (Result<DirectedVoiceSession, Error>) -> Void) {
        queue.async {
            guard !self.isStopped, self.room.transportPolicy == .secureV2, self.localPermits(.voice),
                  let roomID = UUID(uuidString: self.room.id), let peerID = UUID(uuidString: self.nodeID) else {
                completion(.failure(SecureTransportError.invalidState)); return
            }
            do {
                let ownerQueue = self.queue
                let session = try DirectedVoiceSession(roomID: roomID, localPeerID: peerID, queue: ownerQueue,
                    callbacks: callbacks, open: { [weak self] remoteID, reply in
                        guard let self else { reply(.failure(SecureTransportError.invalidState)); return }
                        self.openMediaChannel(to: remoteID, role: .voiceControl) { result in
                            switch result {
                            case .success(let value): VoiceControlConnection.attach(value.0, queue: ownerQueue, completion: reply)
                            case .failure(let error): reply(.failure(error))
                            }
                        }
                    })
                session.start(); completion(.success(session))
            } catch { completion(.failure(error)) }
        }
    }

    func secureConnectionsForTesting() async -> [String: UUID] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.peers.compactMapValues { $0.authenticatedPeer?.connectionID })
            }
        }
    }

    public func updateRoomIcon(_ icon: RoomIcon) {
        queue.async { [weak self] in self?.mergeRoomIcon(icon) }
    }

    private func mergeRoomIcon(_ icon: RoomIcon) {
        guard icon.supersedes(roomIcon) else { return }
        roomIcon = icon
        roomIconHandler(icon)
        broadcast(MeshEnvelope(type: "room_icon", roomIcon: icon))
    }

    private func refreshAdvertisement() {
        let record = RoomDiscovery.record(
            room: room, nodeID: nodeID, displayName: displayName,
            appVersion: appVersion, accessProof: accessProof, icon: roomIcon,
            media: replica.broadcaster?.nodeID == nodeID ? replica.nowPlaying : nil
        )
        guard record != advertisedRecord else { return }
        advertisedRecord = record
        listener?.service = NWListener.Service(
            name: "\(room.id.prefix(8))-\(nodeID.prefix(8))",
            type: room.transportPolicy == .secureV2 ? MeshRoomBrowser.secureServiceType : MeshRoomBrowser.serviceType,
            txtRecord: NWTXTRecord(record)
        )
    }

    func disconnectForTesting(peerID: String) {
        queue.async { [weak self] in self?.peers[peerID]?.connection.cancel() }
    }

    func dropPeerForTesting(peerID: String) {
        queue.async { [weak self] in
            guard let self, let link = peers[peerID] else { return }
            remove(link)
            link.connection.cancel()
        }
    }

    func sendMalformedRoomStateSyncForTesting(peerID: String) {
        queue.async { [weak self] in
            guard let self, let link = peers[peerID] else { return }
            send(MeshEnvelope(type: "room_state_sync"), to: link)
        }
    }

    func sendRoomStateSyncMessagesForTesting(_ messages: [Data], peerID: String) {
        queue.async { [weak self] in
            guard let self, let link = peers[peerID] else { return }
            for (index, message) in messages.enumerated() {
                for envelope in Self.roomStateSyncEnvelopes(
                    message: message,
                    messageID: "test-\(index)-\(UUID().uuidString)"
                ) {
                    send(envelope, to: link)
                }
            }
        }
    }

    func sendRoomStateSyncEnvelopesForTesting(_ envelopes: [MeshEnvelope], peerID: String) {
        queue.async { [weak self] in
            guard let self, let link = peers[peerID] else { return }
            for envelope in envelopes { send(envelope, to: link) }
        }
    }

    public func stop(completion: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in
            isStopped = true
            for channel in Array(pendingMediaChannels.values) { channel.cancel() }
            browser?.cancel()
            scanDeadline?.cancel(); scanDeadline = nil
            scanGeneration &+= 1
            scanWindowExpiresAtNanos = nil
            listener?.cancel()
            heartbeatTimer?.cancel()
            reconnectWorkItems.values.forEach { $0.cancel() }
            roomStatePersistenceWorkItem?.cancel()
            roomStatePersistenceWorkItem = nil
            let durableState = roomStateSync
            let persist = roomStatePersistenceHandler
            let policy = eventPolicy
            roomStateWorkerQueue.async {
                _ = try? durableState.compactIfNeeded()
                let document = durableState.save()
                if let policy {
                    if let archive = try? policy.archive(document: document) { persist(archive) }
                } else { persist(document) }
                completion()
            }
            links.values.forEach { cancel($0) }
            browser = nil
            listener = nil
            heartbeatTimer = nil
            links.removeAll()
            peers.removeAll()
            pendingCommits.removeAll()
            secureAdmissions.removeAll()
            peerDirectory.removeAll()
            remoteParticipants.removeAll()
            playbackReports.removeAll()
            lastPublishedParticipants.removeAll()
            reconnectWorkItems.removeAll()
            reconnectAttempts.removeAll()
            pendingRoomActions.removeAll()
            seenWalkieMessages.removeAll()
            seenWalkieMessageOrder.removeAll()
        }
    }

    /// Direct authenticated links only. One in-flight packet, bounded priority lifecycle queue, and one latest frame per peer.
    public func publishArena(_ data: Data, targetID: String?) {
        guard data.count <= GameRealtimePolicy.maximumPacketBytes else { return }
        let stream: String
        let kind: String
        if let packet = try? JSONDecoder().decode(ArenaPacket.self, from: data), packet.isValid {
            kind = packet.kind.rawValue; stream = "rift/" + packet.session
        } else if let packet = try? JSONDecoder().decode(StickFightPacket.self, from: data), packet.isValid {
            kind = packet.kind.rawValue; stream = "stick/" + packet.session
        } else if let packet = try? JSONDecoder().decode(BreachPacket.self, from: data), packet.isValid {
            kind = packet.kind.rawValue; stream = "breach/" + packet.session
        } else { return }
        queue.async { [weak self] in
            guard let self, !self.isStopped,
                  let wire = try? MeshEnvelope(type: "arena", nodeID: self.nodeID, arenaData: data).encodedLine()
            else { return }
            let destinations = targetID.map { id in self.peers[id].map { [$0] } ?? [] } ?? Array(self.peers.values)
            for link in destinations where link.authenticated {
                link.arenaSendQueue.enqueue(kind: kind, data: wire, stream: stream)
                self.drainArena(to: link)
            }
        }
    }

    private func drainArena(to link: Link) {
        guard !link.arenaSendInFlight, let data = link.arenaSendQueue.popFirst() else { return }
        link.arenaSendInFlight = true
        sendWire(data, to: link) { [weak self, weak link] error in
            guard let self, let link else { return }
            self.queue.async {
                link.arenaSendInFlight = false
                if error != nil { link.arenaSendQueue = GameSendQueue(); self.cancel(link) }
                else if !self.isStopped { self.drainArena(to: link) }
            }
        }
    }

    public func publishChat(_ text: String) {
        publish(
            kind: .chat,
            senderID: nodeID,
            sender: displayName,
            text: String(text.prefix(2_000)),
            sentNanos: MonotonicClock.nowNanos()
        )
    }

    public func publishChatAttachment(_ payload: RoomChatAttachmentPayload, targetID: String? = nil) {
        let packets = RoomChatAttachmentPacket.packets(for: payload)
        guard localPermits(.chat), !packets.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            let wires = packets.compactMap {
                try? MeshEnvelope(type: "chat_attachment", nodeID: self.nodeID, targetID: targetID,
                                  chatAttachmentPacket: $0).encodedLine()
            }
            guard wires.count == packets.count,
                  wires.allSatisfy({ $0.count <= MeshEnvelopeDecoder.maximumLineBytes }) else { return }
            for link in self.peers.values where link.authenticated && (targetID == nil || link.nodeID == targetID) {
                let addedBytes = wires.reduce(0) { $0 + $1.count }
                guard addedBytes <= 12 * 1_024 * 1_024 - link.chatAttachmentQueuedBytes else { continue }
                link.chatAttachmentSendQueue.append(contentsOf: wires)
                link.chatAttachmentQueuedBytes += addedBytes
                self.drainChatAttachments(to: link)
            }
        }
    }

    public func publishRoomTrayFileRequest(_ request: RoomTrayFileRequest) {
        guard localPermits(.chat), request.isValid else { return }
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.broadcast(MeshEnvelope(type: "room_tray_file_request", nodeID: self.nodeID,
                                        roomTrayFileRequest: request))
        }
    }

    private func drainChatAttachments(to link: Link) {
        guard !link.chatAttachmentSendInFlight,
              links[ObjectIdentifier(link.connection)] === link,
              !link.chatAttachmentSendQueue.isEmpty else { return }
        let wire = link.chatAttachmentSendQueue.removeFirst()
        link.chatAttachmentQueuedBytes -= wire.count
        link.chatAttachmentSendInFlight = true
        sendWire(wire, to: link) { [weak self, weak link] error in
            guard let self, let link else { return }
            self.queue.async {
                guard self.links[ObjectIdentifier(link.connection)] === link else { return }
                link.chatAttachmentSendInFlight = false
                if error != nil {
                    link.chatAttachmentSendQueue.removeAll()
                    link.chatAttachmentQueuedBytes = 0
                    self.cancel(link)
                } else {
                    self.drainChatAttachments(to: link)
                }
            }
        }
    }

    public func publishQueueAdd(_ item: RoomQueueItem) { publish(kind: .queueAdd, queueItem: item) }
    public func publishQueueRemove(_ id: String) { publish(kind: .queueRemove, queueItemID: id) }
    public func publishQueueReorder(_ ids: [String]) {
        publish(kind: .queueReorder, senderID: nodeID, queueOrder: ids)
    }

    public func updateIdentity(name: String, icon: String, colorHex: String) {
        queue.async { [weak self] in
            guard let self, !isStopped else { return }
            updateIdentityOnQueue(
                name: name,
                icon: icon,
                colorHex: colorHex,
                profileImageData: profileImageData
            )
        }
    }

    public func updateIdentity(name: String, icon: String, colorHex: String, profileImageData: Data?) {
        queue.async { [weak self] in
            guard let self else { return }
            updateIdentityOnQueue(
                name: name,
                icon: icon,
                colorHex: colorHex,
                profileImageData: profileImageData
            )
        }
    }

    private func updateIdentityOnQueue(
        name: String,
        icon: String,
        colorHex: String,
        profileImageData: Data?
    ) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty else { return }
        let appearance = DeviceAppearance(icon: icon, colorHex: colorHex)
        displayName = trimmed
        deviceIcon = appearance.icon
        deviceColorHex = appearance.colorHex
        self.profileImageData = DeviceAppearance.sanitizedProfileImageData(profileImageData)
        publishParticipants()
        broadcast(MeshEnvelope(
            type: Self.identityEnvelopeType,
            nodeID: nodeID,
            displayName: trimmed,
            deviceIcon: appearance.icon,
            deviceColorHex: appearance.colorHex,
            profileImageData: self.profileImageData
        ))
    }

    public func publishWalkieTalkie(_ message: WalkieTalkieMessage) {
        guard localPermits(.voice) else { return }
        queue.async { [weak self] in
            guard let self,
                  message.senderID == nodeID,
                  room.transportPolicy != .secureV2 || message.kind != .audio,
                  isValidWalkieTalkie(message)
            else { return }
            for wireMessage in Self.legacySafeWalkieTalkieMessages(message) {
                guard rememberWalkieTalkie(wireMessage) else { continue }
                routeWalkieTalkie(
                    MeshEnvelope(
                        type: "walkie_talkie",
                        nodeID: nodeID,
                        walkieTalkieHopCount: 0,
                        walkieTalkieRelayTargetIDs: wireMessage.recipientIDs.map { $0.sorted() },
                        walkieTalkie: wireMessage
                    ),
                    message: wireMessage,
                    excluding: nil
                )
            }
        }
    }

    public func publishOpenLine(_ message: OpenLineMessage) {
        guard localPermits(.voice) else { return }
        queue.async { [weak self] in
            guard let self,
                  message.senderID == nodeID,
                  isValidOpenLine(message),
                  rememberOpenLine(message)
            else { return }
            routeOpenLine(
                MeshEnvelope(
                    type: "open_line",
                    nodeID: nodeID,
                    walkieTalkieHopCount: 0,
                    openLine: message
                ),
                message: message,
                excluding: nil
            )
        }
    }

    @discardableResult
    public func publishMediaCommand(
        _ command: RoomMediaCommand,
        broadcasterID: String,
        broadcasterEpoch: UInt64
    ) -> Bool {
        queue.sync {
            guard localPermits(.playbackControl), let current = replica.broadcaster,
                  current.nodeID == broadcasterID,
                  current.epoch == broadcasterEpoch,
                  broadcasterID == nodeID || !peers.isEmpty
            else { return false }
            let requestID = UUID().uuidString
            _ = rememberRoomAction(roomActionKey(requestID, attempt: 1))
            let envelope = MeshEnvelope(
                type: "media_command",
                nodeID: nodeID,
                requestID: requestID,
                broadcasterID: broadcasterID,
                broadcasterEpoch: broadcasterEpoch,
                mediaCommand: command,
                actionAttempt: 1
            )
            if broadcasterID == nodeID {
                return mediaCommandHandler(command, broadcasterID, broadcasterEpoch)
            }
            beginReliableRoomAction(
                envelope,
                requestID: requestID,
                broadcasterID: broadcasterID,
                broadcasterEpoch: broadcasterEpoch
            )
            broadcast(envelope)
            return true
        }
    }

    @discardableResult
    public func publishResyncRequest(
        targetID: String?,
        broadcasterID: String,
        broadcasterEpoch: UInt64
    ) -> Bool {
        queue.sync {
            guard localPermits(.receiveAudio), let current = replica.broadcaster,
                  current.nodeID == broadcasterID,
                  current.epoch == broadcasterEpoch,
                  broadcasterID == nodeID || !peers.isEmpty
            else { return false }
            let requestID = UUID().uuidString
            _ = rememberRoomAction(roomActionKey(requestID, attempt: 1))
            let envelope = MeshEnvelope(
                type: "resync_request",
                nodeID: nodeID,
                requestID: requestID,
                broadcasterID: broadcasterID,
                broadcasterEpoch: broadcasterEpoch,
                targetID: targetID,
                actionAttempt: 1
            )
            if broadcasterID == nodeID {
                return resyncRequestHandler(targetID, broadcasterID, broadcasterEpoch)
            }
            beginReliableRoomAction(
                envelope,
                requestID: requestID,
                broadcasterID: broadcasterID,
                broadcasterEpoch: broadcasterEpoch
            )
            broadcast(envelope)
            return true
        }
    }

    public func publishBroadcaster(active: Bool, mediaServiceName: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if active {
                publishBroadcasterEvent(
                    broadcasterID: nodeID,
                    epoch: replica.highestBroadcasterEpoch + 1,
                    active: true,
                    mediaServiceName: mediaServiceName
                )
            } else if let current = replica.broadcaster, current.nodeID == nodeID {
                publishBroadcasterEvent(
                    broadcasterID: current.nodeID,
                    epoch: current.epoch,
                    active: false,
                    mediaServiceName: nil
                )
            }
        }
    }

    public func publishPlaybackTiming(_ timing: PeerPlaybackTiming) {
        queue.async { [self] in
            guard timing.isValid, let current = replica.broadcaster else { return }
            let now = MonotonicClock.nowNanos()
            // Bound diagnostic traffic independently of render/timer frequency.
            guard now >= lastPlaybackReportSend, now - lastPlaybackReportSend >= 500_000_000 else { return }
            lastPlaybackReportSend = now
            playbackReports[nodeID] = (timing, now, current.nodeID, current.epoch)
            broadcast(MeshEnvelope(type: "playback_timing", nodeID: nodeID,
                broadcasterID: current.nodeID, broadcasterEpoch: current.epoch, playbackTiming: timing))
            publishParticipants()
        }
    }

    public func publishPlayback(_ media: NowPlayingMedia) { publish(kind: .playback, nowPlaying: media) }
    public func publishVideo(_ enabled: Bool, broadcasterID: String, broadcasterEpoch: UInt64) {
        publish(
            kind: .video,
            broadcasterID: broadcasterID,
            broadcasterEpoch: broadcasterEpoch,
            videoEnabled: enabled
        )
    }

    private func publish(
        kind: MeshRoomEventKind,
        senderID: String? = nil,
        sender: String? = nil,
        text: String? = nil,
        sentNanos: UInt64? = nil,
        queueItem: RoomQueueItem? = nil,
        queueItemID: String? = nil,
        queueOrder: [String]? = nil,
        broadcasterID: String? = nil,
        broadcasterEpoch: UInt64? = nil,
        mediaServiceName: String? = nil,
        isBroadcasting: Bool? = nil,
        nowPlaying: NowPlayingMedia? = nil,
        videoEnabled: Bool? = nil
    ) {
        queue.async { [weak self] in
            guard let self, !isStopped else { return }
            guard localPermits(SecureRoomEventPolicy.capability(for: kind)) else { return }
            if kind == .queueReorder {
                guard replica.broadcaster?.nodeID == nodeID,
                      let queueOrder, queueOrder.count <= 2_000,
                      Set(queueOrder).count == queueOrder.count,
                      Set(queueOrder) == Set(replica.queue.map(\.id)) else { return }
            }
            var event = MeshRoomEvent(
                roomID: room.id,
                version: replica.nextVersion(nodeID: nodeID),
                kind: kind,
                senderID: senderID,
                sender: sender,
                text: text,
                sentNanos: sentNanos,
                queueItem: queueItem,
                queueItemID: queueItemID,
                queueOrder: queueOrder,
                broadcasterID: broadcasterID,
                broadcasterEpoch: broadcasterEpoch,
                mediaServiceName: mediaServiceName,
                isBroadcasting: isBroadcasting,
                nowPlaying: nowPlaying,
                videoEnabled: videoEnabled
            )
            guard MeshRoomReplica.hasValidQueueOrder(event) else { return }
            if let eventPolicy {
                guard let signed = eventPolicy.sign(event) else { return }
                event = signed
            }
            _ = replica.merge([event])
            ingestDurableRoomState([event], excluding: nil)
            replicaHandler(replica)
            broadcast(MeshEnvelope(type: "event", event: event))
        }
    }

    private func consider(_ results: Set<NWBrowser.Result>) {
        for result in results.prefix(256) {
            guard case .bonjour(let record) = result.metadata,
                  record["roomID"] == room.id,
                  room.transportPolicy != .secureV2 || record["roomGeneration"] == String(ProtocolOffer.currentRoomGeneration),
                  let remoteID = record["nodeID"],
                  remoteID != nodeID,
                  (room.transportPolicy == .secureV2 || nodeID < remoteID),
                  peers[remoteID] == nil,
                  !links.values.contains(where: { $0.nodeID == remoteID })
            else { continue }
            connect(to: result.endpoint, expectedNodeID: remoteID)
            if room.transportPolicy == .secureV2 { break }
        }
    }

    private func connect(to endpoint: NWEndpoint, expectedNodeID: String?, hintExpiresAtNanos: UInt64? = nil) {
        guard !isStopped else { return }
        if let hintExpiresAtNanos, MonotonicClock.nowNanos() >= hintExpiresAtNanos { return }
        if room.transportPolicy == .secureV2 {
            guard expectedNodeID.map({ UUID(uuidString: $0) != nil }) ?? true,
                  admitSecureAttempt() else { return }
            stopSecureScan()
        }
        connectionAttemptHandler()
        let parameters: NWParameters
        do { parameters = try transportParameters(expectedPeerID: expectedNodeID.flatMap(UUID.init(uuidString:))) }
        catch { return }
        let connection = NWConnection(to: endpoint, using: parameters)
        let link = Link(
            connection: connection,
            initiated: true,
            roomStateSyncSession: roomStateSync.makeSession()
        )
        link.nodeID = expectedNodeID
        link.hintExpiresAtNanos = hintExpiresAtNanos
        register(link)
    }

    private func accept(_ connection: NWConnection) {
        guard !isStopped else { connection.cancel(); return }
        if room.transportPolicy == .secureV2, !admitSecureAttempt() { connection.cancel(); return }
        register(Link(
            connection: connection,
            initiated: false,
            roomStateSyncSession: roomStateSync.makeSession()
        ))
    }

    private func register(_ link: Link) {
        let identifier = ObjectIdentifier(link.connection)
        links[identifier] = link
        if room.transportPolicy == .secureV2 {
            registerSecure(link)
            return
        }
        link.connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .ready:
                send(hello(for: link), to: link)
            case .failed, .cancelled:
                remove(link)
            default:
                break
            }
        }
        link.connection.start(queue: queue)
        receive(from: link)
        queue.asyncAfter(deadline: .now() + .seconds(3)) { [weak link] in
            guard let link, !link.authenticated else { return }
            link.connection.cancel()
        }
    }

    private func transportParameters(expectedPeerID: UUID?) throws -> NWParameters {
        guard room.transportPolicy != .migrationRequired else { throw RoomSecurityPolicyError.migrationRequired }
        guard room.transportPolicy == .secureV2 else { return LocalNetworkParameters.tcp() }
        guard let installationIdentity, let peerPins else { throw SecureTransportError.invalidCredentials }
        return try SecureNetworkParameters.tcp(identity: installationIdentity, expectedPeerID: expectedPeerID,
            pins: peerPins, firstContact: .explicitRoomJoin, verificationQueue: queue)
    }

    private func admitSecureAttempt() -> Bool {
        let now = MonotonicClock.nowNanos()
        secureAdmissions.removeAll { now >= $0 && now - $0 >= 1_000_000_000 }
        guard secureAdmissions.count < 16, links.count < 128,
              links.values.filter({ !$0.authenticated }).count < 16 else { return false }
        secureAdmissions.append(now)
        return true
    }

    private func registerSecure(_ link: Link) {
        guard let installationIdentity, let peerPins, let roomID = UUID(uuidString: room.id) else { cancel(link); return }
        do {
            let admission: SecureRoomAdmission = room.isPrivate ? .privateRoom(secret: room.secureJoinSecret ?? Data()) : .publicRoom
            let roles: Set<ReliableChannelRole> = incomingMediaChannelHandler == nil ? [.roomControl] : [.roomControl, .mediaControl, .video, .voiceControl, .fileTransfer]
            let configuration = try SecurePeerConfiguration(roomID: roomID, incarnationID: incarnationID, admission: admission,
                offer: ProtocolOffer.current(capabilities: secureCapabilities),
                direction: link.initiated ? .initiator(.roomControl) : .responder(allowedChannelRoles: roles))
            let channel = SecurePeerChannel(connection: link.connection, identity: installationIdentity,
                                             configuration: configuration, pins: peerPins, queue: queue)
            link.secureChannel = channel
            channel.onState = { [weak self, weak link] state in
                guard let self, let link else { return }
                self.secureStateHandler(link.nodeID, state)
                switch state { case .failed, .cancelled: self.remove(link); default: break }
            }
            channel.onAuthenticated = { [weak self, weak link, weak channel] peer in
                guard let self, let link, let channel, !self.isStopped,
                      self.links[ObjectIdentifier(link.connection)] === link else { return }
                let peerID = peer.nodeID.uuidString
                guard peerID != self.nodeID, link.nodeID == nil || link.nodeID == peerID else { self.cancel(link); return }
                link.authenticatedPeer = peer
                link.nodeID = peerID
                link.lastPayloadNanos = MonotonicClock.nowNanos()
                if peer.channelRole != .roomControl {
                    guard let handler = self.incomingMediaChannelHandler else { self.cancel(link); return }
                    self.links.removeValue(forKey: ObjectIdentifier(link.connection))
                    channel.onState = nil; channel.onPayload = nil
                    handler(channel, peer)
                    return
                }
                guard self.eventPolicy?.admit(peer, initiated: link.initiated) ?? true else { self.cancel(link); return }
                // Saved or relayed events wait for independent admission of their author.
                self.roomStateWorkerQueue.async { [weak self] in
                    guard let self, let events = try? self.roomStateSync.snapshot().events else { return }
                    self.queue.async {
                        guard !self.isStopped else { return }
                        if !self.replica.merge(self.validRoomEvents(events)).isEmpty { self.replicaHandler(self.replica) }
                    }
                }
                self.send(self.hello(for: link), to: link)
                self.queue.asyncAfter(deadline: .now() + 6) { [weak self, weak link] in
                    guard let self, let link, !link.authenticated,
                          self.links[ObjectIdentifier(link.connection)] === link else { return }
                    self.cancel(link)
                }
            }
            channel.onPayload = { [weak self, weak link] payload in
                guard let self, let link, link.authenticatedPeer?.channelRole == .roomControl,
                      self.links[ObjectIdentifier(link.connection)] === link,
                      payload.count <= SecurePeerChannel.maximumPayloadBytes else { return }
                link.lastPayloadNanos = MonotonicClock.nowNanos()
                for envelope in link.decoder.append(payload) { self.handle(envelope, from: link) }
                if link.decoder.isOverflowed { self.cancel(link) }
            }
            channel.start()
        } catch { cancel(link); remove(link) }
    }

    private func cancel(_ link: Link) {
        if let channel = link.secureChannel { channel.cancel() } else { link.connection.cancel() }
    }

    private func startSecureScan() {
        guard advertises, !isStopped, browser == nil, peers.isEmpty,
              !links.values.contains(where: { !$0.authenticated }),
              let windowDeadline = scanWindowExpiresAtNanos else { return }
        let now = MonotonicClock.nowNanos()
        guard now < windowDeadline else { return }
        scanGeneration &+= 1
        let generation = scanGeneration
        let parameters = NWParameters(); parameters.includePeerToPeer = true
        let next = NWBrowser(for: .bonjourWithTXTRecord(type: MeshRoomBrowser.secureServiceType, domain: nil), using: parameters)
        next.browseResultsChangedHandler = { [weak self, weak next] results, _ in
            guard let self, let next, self.browser === next, self.scanGeneration == generation else { return }
            self.consider(results)
        }
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next, self.browser === next else { return }
            if case .failed = state { self.stopSecureScan() }
        }
        browser = next
        next.start(queue: queue)
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.scanGeneration == generation else { return }
            self.stopSecureScan()
        }
        scanDeadline = deadline
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(windowDeadline - now)), execute: deadline)
    }

    private func stopSecureScan() {
        guard room.transportPolicy == .secureV2 else { return }
        scanGeneration &+= 1
        scanDeadline?.cancel(); scanDeadline = nil
        browser?.cancel(); browser = nil
    }

    private func remoteHost(of link: Link) -> String? {
        let endpoints = [link.connection.currentPath?.remoteEndpoint, link.connection.endpoint].compactMap { $0 }
        for endpoint in endpoints {
            if case .hostPort(let host, _) = endpoint { return String(describing: host) }
        }
        return nil
    }

    private func directoryHint(for link: Link) -> MeshPeerDirectoryHint? {
        guard let peer = link.authenticatedPeer, peer.channelRole == .roomControl else { return nil }
        return MeshPeerDirectoryHint(peerID: peer.nodeID.uuidString, incarnationID: peer.incarnationID.uuidString,
                                     host: remoteHost(of: link), port: link.listeningPort)
    }

    private func rememberDirectPeer(_ link: Link) {
        guard let hint = directoryHint(for: link) else { return }
        peerDirectory[hint.peerID] = DirectoryEntry(hint: hint, expiresAtNanos: MonotonicClock.nowNanos() + 30_000_000_000)
    }

    private func publishSecureDirectory(to recipient: Link? = nil) {
        guard room.transportPolicy == .secureV2 else { return }
        let now = MonotonicClock.nowNanos()
        var hints = [MeshPeerDirectoryHint(peerID: nodeID, incarnationID: incarnationID.uuidString,
                                          host: nil, port: listener?.port?.rawValue)]
        // Only advertise direct, live authenticated peers. Re-advertising cached
        // hints would let a forwarding cycle indefinitely extend a dead peer's TTL.
        for link in peers.values.sorted(by: { ($0.nodeID ?? "") < ($1.nodeID ?? "") }) {
            guard now < link.lastPayloadNanos || now - link.lastPayloadNanos < broadcasterLeaseNanos,
                  let hint = directoryHint(for: link) else { continue }
            hints.append(hint)
            rememberDirectPeer(link)
        }
        let envelope = MeshEnvelope(type: "mesh_peer_directory", meshPeerDirectory: Array(hints.prefix(128)))
        if let recipient { send(envelope, to: recipient) } else { broadcast(envelope) }
    }

    private func receiveSecureDirectory(_ hints: [MeshPeerDirectoryHint], from source: Link) {
        guard hints.count <= 128, let sourcePeer = source.authenticatedPeer else { cancel(source); return }
        let now = MonotonicClock.nowNanos()
        expireSecureDirectory(nowNanos: now)
        for hint in hints {
            guard let peerID = UUID(uuidString: hint.peerID), peerID.uuidString == hint.peerID, hint.peerID != nodeID,
                  let incarnation = UUID(uuidString: hint.incarnationID), incarnation.uuidString == hint.incarnationID,
                  (1...30).contains(hint.validForSeconds), hint.port != 0,
                  hint.host.map({ !$0.isEmpty && $0.utf8.count <= 255 && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil }) ?? true,
                  peerDirectory[hint.peerID] != nil || peerDirectory.count < 128 else { continue }
            if peers[hint.peerID] != nil {
                if let direct = peers[hint.peerID] { rememberDirectPeer(direct) }
                continue
            }
            let host: String?
            if hint.peerID == sourcePeer.nodeID.uuidString {
                guard incarnation == sourcePeer.incarnationID else { continue }
                host = remoteHost(of: source)
            } else { host = hint.host }
            let resolved = MeshPeerDirectoryHint(peerID: hint.peerID, incarnationID: hint.incarnationID,
                                                 host: host, port: hint.port, validForSeconds: hint.validForSeconds)
            let previous = peerDirectory[hint.peerID]
            let changed = previous?.hint.incarnationID != resolved.incarnationID || previous?.hint.host != host || previous?.hint.port != hint.port
            if changed { reconnectAttempts[hint.peerID] = 0 }
            peerDirectory[hint.peerID] = DirectoryEntry(hint: resolved,
                expiresAtNanos: now + UInt64(hint.validForSeconds) * 1_000_000_000,
                lastAttemptNanos: changed ? 0 : previous?.lastAttemptNanos ?? 0)
        }
        repairSecureDirectory(nowNanos: now)
    }

    private func directoryEndpoint(_ hint: MeshPeerDirectoryHint) -> NWEndpoint {
        if let host = hint.host, let rawPort = hint.port, let port = NWEndpoint.Port(rawValue: rawPort) {
            return .hostPort(host: NWEndpoint.Host(host), port: port)
        }
        return .service(name: "\(room.id.prefix(8))-\(hint.peerID.prefix(8))", type: MeshRoomBrowser.secureServiceType,
                        domain: "local.", interface: nil)
    }

    private func repairSecureDirectory(nowNanos now: UInt64) {
        guard room.transportPolicy == .secureV2, !isStopped else { return }
        expireSecureDirectory(nowNanos: now)
        var attempts = 0
        for id in peerDirectory.keys.sorted() {
            guard attempts < 2, peers[id] == nil, reconnectWorkItems[id] == nil,
                  (reconnectAttempts[id] ?? 0) < 4,
                  !links.values.contains(where: { $0.nodeID == id }),
                  var entry = peerDirectory[id],
                  entry.lastAttemptNanos == 0 || (now >= entry.lastAttemptNanos && now - entry.lastAttemptNanos >= 5_000_000_000)
            else { continue }
            entry.lastAttemptNanos = now; peerDirectory[id] = entry
            attempts += 1
            connect(to: directoryEndpoint(entry.hint), expectedNodeID: id, hintExpiresAtNanos: entry.expiresAtNanos)
        }
    }

    private func expireSecureDirectory(nowNanos: UInt64) {
        for id in peerDirectory.keys where peerDirectory[id]!.expiresAtNanos <= nowNanos {
            peerDirectory.removeValue(forKey: id)
            if peers[id] == nil {
                reconnectWorkItems.removeValue(forKey: id)?.cancel()
                reconnectAttempts.removeValue(forKey: id)
            }
        }
    }

    private func hello(for link: Link, advertiseRoomStateSync: Bool = true) -> MeshEnvelope {
        let publicRoom = RoomConfiguration(
            id: room.id,
            name: room.name,
            creatorPeerID: room.creatorPeerID,
            isPrivate: room.isPrivate,
            accessKey: nil,
            joinedAt: room.joinedAt,
            transportPolicy: room.transportPolicy
        )
        return MeshEnvelope(
            type: "hello",
            room: publicRoom,
            nodeID: nodeID,
            displayName: displayName,
            deviceIcon: deviceIcon,
            deviceColorHex: deviceColorHex,
            profileImageData: profileImageData,
            appVersion: appVersion,
            versionVector: replica.versionVector,
            roomStateSyncVersion: advertiseRoomStateSync && !roomStateSyncDisabled ? 1 : nil,
            authNonce: room.isPrivate && room.transportPolicy == .legacyOnly ? link.localNonce : nil,
            meshListeningPort: room.transportPolicy == .secureV2 ? listener?.port?.rawValue : nil
        )
    }

    private var accessProof: String? {
        guard room.isPrivate, let key = room.accessKey else { return nil }
        return Self.makeAccessProof(roomID: room.id, accessKey: key)
    }

    public static func makeAccessProof(roomID: String, accessKey: String) -> String {
        SHA256.hash(data: Data("\(roomID):\(accessKey)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func makeChallengeResponse(roomID: String, accessKey: String, nonce: String, nodeID: String) -> String {
        let key = SymmetricKey(data: Data(accessKey.utf8))
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data("\(roomID):\(nonce):\(nodeID)".utf8),
            using: key
        )
        return Data(authentication).base64EncodedString()
    }

    static func verifyChallengeResponse(
        _ response: String,
        roomID: String,
        accessKey: String,
        nonce: String,
        nodeID: String
    ) -> Bool {
        guard let code = Data(base64Encoded: response) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            code,
            authenticating: Data("\(roomID):\(nonce):\(nodeID)".utf8),
            using: SymmetricKey(data: Data(accessKey.utf8))
        )
    }

    private func receive(from link: Link) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak link] data, _, complete, error in
            guard let self, let link else { return }
            if let data {
                for envelope in link.decoder.append(data) { self.handle(envelope, from: link) }
                if link.decoder.isOverflowed { link.connection.cancel(); return }
            }
            if complete || error != nil { self.remove(link) } else { self.receive(from: link) }
        }
    }

    private func handle(_ envelope: MeshEnvelope, from link: Link) {
        if room.transportPolicy == .secureV2 {
            guard let peer = link.authenticatedPeer, peer.channelRole == .roomControl else { cancel(link); return }
            switch envelope.type {
            case "mesh_ready":
                guard link.receivedHello, envelope.requestID == peer.connectionID.uuidString else { cancel(link); return }
                link.remoteReady = true
                scheduleSecureSelection(peerID: peer.nodeID.uuidString)
                return
            case "mesh_commit":
                guard peer.nodeID.uuidString < nodeID, link.receivedHello, link.remoteReady,
                      envelope.requestID == peer.connectionID.uuidString else { cancel(link); return }
                send(MeshEnvelope(type: "mesh_commit_ack", requestID: peer.connectionID.uuidString), to: link)
                completeAuthentication(link, remoteID: peer.nodeID.uuidString)
                return
            case "mesh_commit_ack":
                guard nodeID < peer.nodeID.uuidString, link.commitSent,
                      pendingCommits[peer.nodeID.uuidString] == peer.connectionID,
                      envelope.requestID == peer.connectionID.uuidString else { cancel(link); return }
                completeAuthentication(link, remoteID: peer.nodeID.uuidString)
                return
            case "auth": cancel(link); return
            default: break
            }
        }
        if envelope.type == "hello" {
            guard envelope.room?.id == room.id,
                  envelope.room?.isPrivate == room.isPrivate,
                  envelope.room?.transportPolicy == room.transportPolicy,
                  let remoteID = envelope.nodeID,
                  remoteID.utf8.count <= 128,
                  (envelope.displayName?.utf8.count ?? 0) <= 160,
                  (envelope.appVersion?.utf8.count ?? 0) <= 64,
                  remoteID != nodeID
            else {
                link.connection.cancel()
                return
            }
            if room.transportPolicy == .secureV2, remoteID != link.authenticatedPeer?.nodeID.uuidString {
                cancel(link); return
            }
            guard link.nodeID == nil || link.nodeID == remoteID else {
                // The discovered service no longer belongs to the advertised
                // peer. Do not reconnect forever to the same stale endpoint.
                link.nodeID = nil
                link.connection.cancel()
                return
            }
            let shouldBeInitiated = nodeID < remoteID
            guard room.transportPolicy == .secureV2 || link.initiated == shouldBeInitiated else {
                if link.initiated {
                    link.connection.cancel()
                } else {
                    // Give the initiator a deterministic chance to read our
                    // identity before closing a connection in the wrong
                    // canonical direction. This lets it invalidate a stale
                    // Bonjour endpoint instead of retrying that endpoint.
                    sendThenCancel(hello(for: link), to: link)
                }
                return
            }
            link.nodeID = remoteID
            link.remoteVersionVector = envelope.versionVector
            link.displayName = envelope.displayName
            link.listeningPort = envelope.meshListeningPort
            let remoteAppearance = DeviceAppearance.generated(from: remoteID)
            let sanitizedAppearance = DeviceAppearance(
                icon: envelope.deviceIcon ?? remoteAppearance.icon,
                colorHex: envelope.deviceColorHex ?? remoteAppearance.colorHex
            )
            link.deviceIcon = sanitizedAppearance.icon
            link.deviceColorHex = sanitizedAppearance.colorHex
            link.profileImageData = DeviceAppearance.sanitizedProfileImageData(envelope.profileImageData)
            link.appVersion = envelope.appVersion
            let previousRoomStateSyncVersion = link.roomStateSyncVersion
            let nextRoomStateSyncVersion: UInt8? = envelope.roomStateSyncVersion == 1 ? 1 : nil
            if previousRoomStateSyncVersion == 1, nextRoomStateSyncVersion == nil {
                disableRoomStateSync(
                    for: link,
                    reason: "the peer switched to legacy durable sync",
                    notifyPeer: false
                )
            } else {
                link.roomStateSyncVersion = nextRoomStateSyncVersion
            }
            if disableRoomStateSyncDuringAuthenticationForTesting {
                roomStateSyncDisabled = true
            }
            if room.transportPolicy == .secureV2 {
                link.receivedHello = true
                if !link.authenticated, let peer = link.authenticatedPeer {
                    send(MeshEnvelope(type: "mesh_ready", requestID: peer.connectionID.uuidString), to: link)
                    scheduleSecureSelection(peerID: remoteID)
                }
            } else if room.isPrivate {
                guard let nonce = envelope.authNonce, nonce.count <= 128,
                      let key = room.accessKey else { link.connection.cancel(); return }
                send(MeshEnvelope(
                    type: "auth",
                    nodeID: nodeID,
                    authResponse: Self.makeChallengeResponse(
                        roomID: room.id, accessKey: key, nonce: nonce, nodeID: nodeID
                    )
                ), to: link)
            } else {
                completeAuthentication(link, remoteID: remoteID)
            }
            return
        }


        if envelope.type == "auth" {
            guard room.isPrivate, let remoteID = link.nodeID,
                  envelope.nodeID == remoteID,
                  let key = room.accessKey,
                  remoteID.utf8.count <= 128,
                  let response = envelope.authResponse,
                  Self.verifyChallengeResponse(
                    response, roomID: room.id, accessKey: key,
                    nonce: link.localNonce, nodeID: remoteID
                  )
            else { link.connection.cancel(); return }
            completeAuthentication(link, remoteID: remoteID)
            return
        }

        guard link.authenticated, let remoteID = link.nodeID, peers[remoteID] === link else { return }
        switch envelope.type {
        case "playback_timing":
            guard envelope.nodeID == remoteID, let timing = envelope.playbackTiming, timing.isValid,
                  let current = replica.broadcaster, envelope.broadcasterID == current.nodeID,
                  envelope.broadcasterEpoch == current.epoch else { return }
            let now = MonotonicClock.nowNanos()
            if let prior = playbackReports[remoteID], now >= prior.received,
               now - prior.received < 500_000_000 { return }
            // Only accept reports directly from the authenticated reporting device.
            playbackReports[remoteID] = (timing, now, current.nodeID, current.epoch)
            publishParticipants()
        case "mesh_peer_directory":
            guard room.transportPolicy == .secureV2 else { return }
            receiveSecureDirectory(envelope.meshPeerDirectory ?? [], from: link)
        case "arena":
            guard envelope.nodeID == remoteID, let data = envelope.arenaData, data.count <= GameRealtimePolicy.maximumPacketBytes else { return }
            let now = MonotonicClock.nowNanos()
            if now - min(now, link.arenaReceiveWindow) >= 1_000_000_000 {
                link.arenaReceiveWindow = now; link.arenaReceiveCount = 0
            }
            guard link.arenaReceiveCount < 90 else { return }
            link.arenaReceiveCount += 1
            arenaHandler(remoteID, data)
        case "chat_attachment":
            guard envelope.nodeID == remoteID, envelope.targetID == nil || envelope.targetID == nodeID,
                  let packet = envelope.chatAttachmentPacket,
                  permitsTransient(envelope, from: link, capability: .chat),
                  link.chatAttachmentReceiveAdmission.permits(
                    packetBytes: packet.bytes.count,
                    now: MonotonicClock.nowNanos()
                  ),
                  let payload = chatAttachmentAssembler.receive(senderID: remoteID, packet: packet) else { return }
            link.chatAttachmentReceiveAdmission.completedTransfer()
            chatAttachmentHandler(remoteID, payload)
        case "room_tray_file_request":
            guard envelope.nodeID == remoteID, let request = envelope.roomTrayFileRequest,
                  request.isValid, permitsTransient(envelope, from: link, capability: .chat) else { return }
            let now = MonotonicClock.nowNanos()
            if link.roomTrayRequestWindow == 0 || now < link.roomTrayRequestWindow
                || now - link.roomTrayRequestWindow >= 60_000_000_000 {
                link.roomTrayRequestWindow = now
                link.roomTrayRequestCount = 0
            }
            guard link.roomTrayRequestCount < 32 else { return }
            link.roomTrayRequestCount += 1
            roomTrayFileRequestHandler(remoteID, request)
        case "room_icon":
            if let icon = envelope.roomIcon { mergeRoomIcon(icon) }
        case "sync":
            merge(Array((envelope.events ?? []).prefix(maximumSyncEvents)), excluding: link)
            if let vector = envelope.versionVector {
                let missing = replica.missingEvents(comparedWith: vector)
                if !missing.isEmpty {
                    sendSync(
                        events: Array(missing.prefix(maximumSyncEvents)),
                        versionVector: nil,
                        to: link
                    )
                }
            }
        case "event":
            if let event = envelope.event { merge([event], excluding: link) }
        case "room_state_sync":
            guard !roomStateSyncDisabled, link.roomStateSyncVersion == 1 else { return }
            receiveRoomStateSync(envelope, from: link)
        case "heartbeat":
            if let originID = envelope.nodeID, let sequence = envelope.heartbeatSequence,
               let generation = envelope.heartbeatGeneration {
                acceptHeartbeat(originID: originID, generation: generation, sequence: sequence, excluding: link)
            }
        case "media_command":
            guard permitsTransient(envelope, from: link, capability: .playbackControl) else { return }
            guard let originID = envelope.nodeID,
                  !originID.isEmpty,
                  originID.utf8.count <= 128,
                  let requestID = envelope.requestID,
                  requestID.utf8.count <= 128,
                  let attempt = envelope.actionAttempt,
                  (1...20).contains(attempt),
                  let broadcasterID = envelope.broadcasterID,
                  let broadcasterEpoch = envelope.broadcasterEpoch,
                  let command = envelope.mediaCommand,
                  let current = replica.broadcaster,
                  current.nodeID == broadcasterID,
                  current.epoch == broadcasterEpoch
            else { return }
            let isNew = rememberRoomAction(roomActionKey(requestID, attempt: attempt))
            if broadcasterID == nodeID {
                let accepted = acceptedRoomActionIDs.contains(requestID)
                    || mediaCommandHandler(command, broadcasterID, broadcasterEpoch)
                if accepted {
                    rememberAcceptedRoomAction(requestID)
                    acknowledgeRoomAction(
                        requestID: requestID,
                        originID: originID,
                        broadcasterID: broadcasterID,
                        broadcasterEpoch: broadcasterEpoch
                    )
                }
            }
            // Normally every room member has a direct link. Forwarding also
            // keeps controls working briefly while the mesh reconnects.
            if isNew { broadcast(envelope, excluding: link) }
        case "resync_request":
            guard permitsTransient(envelope, from: link, capability: .receiveAudio) else { return }
            guard let originID = envelope.nodeID,
                  !originID.isEmpty,
                  originID.utf8.count <= 128,
                  let requestID = envelope.requestID,
                  requestID.utf8.count <= 128,
                  let attempt = envelope.actionAttempt,
                  (1...20).contains(attempt),
                  let broadcasterID = envelope.broadcasterID,
                  let broadcasterEpoch = envelope.broadcasterEpoch,
                  let current = replica.broadcaster,
                  current.nodeID == broadcasterID,
                  current.epoch == broadcasterEpoch
            else { return }
            let isNew = rememberRoomAction(roomActionKey(requestID, attempt: attempt))
            if broadcasterID == nodeID {
                let accepted = acceptedRoomActionIDs.contains(requestID)
                    || resyncRequestHandler(envelope.targetID, broadcasterID, broadcasterEpoch)
                if accepted {
                    rememberAcceptedRoomAction(requestID)
                    acknowledgeRoomAction(
                        requestID: requestID,
                        originID: originID,
                        broadcasterID: broadcasterID,
                        broadcasterEpoch: broadcasterEpoch
                    )
                }
            }
            if isNew { broadcast(envelope, excluding: link) }
        case "room_action_ack":
            guard permitsTransient(envelope, from: link, capability: .broadcast) else { return }
            guard let ackOriginID = envelope.nodeID,
                  !ackOriginID.isEmpty,
                  ackOriginID.utf8.count <= 128,
                  let requestID = envelope.requestID,
                  requestID.utf8.count <= 128,
                  let recipientID = envelope.targetID,
                  let broadcasterID = envelope.broadcasterID,
                  let broadcasterEpoch = envelope.broadcasterEpoch
            else { return }
            guard ackOriginID == broadcasterID else { return }
            let isNew = rememberRoomAction("ack:\(requestID)")
            if recipientID == nodeID,
               let pending = pendingRoomActions[requestID],
               pending.broadcasterID == broadcasterID,
               pending.broadcasterEpoch == broadcasterEpoch {
                pendingRoomActions.removeValue(forKey: requestID)
            }
            if isNew { broadcast(envelope, excluding: link) }
        case "device_identity", "display_name":
            guard envelope.nodeID == remoteID,
                  let name = envelope.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  name.utf8.count <= 160
            else { return }
            let appearance = DeviceAppearance(
                icon: envelope.deviceIcon ?? DeviceAppearance.generated(from: remoteID).icon,
                colorHex: envelope.deviceColorHex ?? DeviceAppearance.generated(from: remoteID).colorHex
            )
            link.displayName = name
            link.deviceIcon = appearance.icon
            link.deviceColorHex = appearance.colorHex
            link.profileImageData = DeviceAppearance.sanitizedProfileImageData(envelope.profileImageData)
            cacheParticipant(from: link, id: remoteID)
            publishParticipants()
        case "walkie_talkie":
            guard permitsTransient(envelope, from: link, capability: .voice) else { return }
            let hopCount = envelope.walkieTalkieHopCount ?? 0
            guard let message = envelope.walkieTalkie,
                  room.transportPolicy != .secureV2 || message.kind != .audio,
                  isValidWalkieTalkie(message),
                  Self.isValidWalkieTalkieOrigin(
                      senderID: message.senderID,
                      remoteID: remoteID,
                      envelopeOriginID: envelope.nodeID,
                      hopCount: hopCount
                  ),
                  hopCount <= maximumWalkieTalkieHopCount,
                  rememberWalkieTalkie(message)
            else { return }
            if message.recipientIDs == nil || message.recipientIDs?.contains(nodeID) == true {
                walkieTalkieHandler(message)
            }
            guard hopCount < maximumWalkieTalkieHopCount else { return }
            let relayRecipients = envelope.walkieTalkieRelayTargetIDs.map(Set.init)
                ?? message.recipientIDs
            routeWalkieTalkie(
                MeshEnvelope(
                    type: "walkie_talkie",
                    nodeID: message.senderID,
                    walkieTalkieHopCount: hopCount + 1,
                    walkieTalkieRelayTargetIDs: relayRecipients.map { $0.sorted() },
                    walkieTalkie: message
                ),
                message: message,
                relayRecipients: relayRecipients,
                excluding: link
            )
        case "open_line":
            guard permitsTransient(envelope, from: link, capability: .voice) else { return }
            let hopCount = envelope.walkieTalkieHopCount ?? 0
            guard let message = envelope.openLine,
                  isValidOpenLine(message),
                  Self.isValidWalkieTalkieOrigin(
                      senderID: message.senderID,
                      remoteID: remoteID,
                      envelopeOriginID: envelope.nodeID,
                      hopCount: hopCount
                  ),
                  hopCount <= maximumWalkieTalkieHopCount,
                  rememberOpenLine(message)
            else { return }
            if message.targetID == nodeID { openLineHandler(message) }
            guard message.targetID != nodeID, hopCount < maximumWalkieTalkieHopCount else { return }
            routeOpenLine(
                MeshEnvelope(
                    type: "open_line",
                    nodeID: message.senderID,
                    walkieTalkieHopCount: hopCount + 1,
                    openLine: message
                ),
                message: message,
                excluding: link
            )
        default:
            break
        }
    }

    private func scheduleSecureSelection(peerID: String) {
        guard nodeID < peerID else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in self?.selectSecureLink(peerID: peerID) }
    }

    private func selectSecureLink(peerID: String) {
        guard !isStopped, pendingCommits[peerID] == nil else { return }
        let candidates = links.values.filter {
            !$0.authenticated && $0.receivedHello && $0.remoteReady && $0.authenticatedPeer?.nodeID.uuidString == peerID
        }.sorted { ($0.authenticatedPeer?.connectionID.uuidString ?? "") < ($1.authenticatedPeer?.connectionID.uuidString ?? "") }
        guard let selected = candidates.first, let connectionID = selected.authenticatedPeer?.connectionID else { return }
        if let existing = peers[peerID] {
            let now = MonotonicClock.nowNanos()
            if now < existing.lastPayloadNanos || now - existing.lastPayloadNanos < broadcasterLeaseNanos {
                // A failed candidate must never displace an active channel. A
                // half-open channel can be replaced after application liveness expires.
                queue.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in self?.selectSecureLink(peerID: peerID) }
                return
            }
        }
        pendingCommits[peerID] = connectionID
        selected.commitSent = true
        send(MeshEnvelope(type: "mesh_commit", requestID: connectionID.uuidString), to: selected)
    }

    private func merge(_ events: [MeshRoomEvent], excluding source: Link) {
        let valid = validRoomEvents(Array(events.prefix(maximumSyncEvents)))
        let inserted = replica.merge(valid)
        guard !inserted.isEmpty else { return }
        if source.roomStateSyncVersion == nil {
            ingestDurableRoomState(inserted, excluding: source)
        }
        if let broadcaster = replica.broadcaster, broadcaster.nodeID != nodeID,
           lastSeenNanos[broadcaster.nodeID] == nil {
            lastSeenNanos[broadcaster.nodeID] = MonotonicClock.nowNanos()
        }
        replicaHandler(replica)
        for event in inserted { broadcast(MeshEnvelope(type: "event", event: event), excluding: source) }
    }

    private func localPermits(_ capability: PeerCapabilities) -> Bool {
        room.transportPolicy != .secureV2 || secureCapabilities.contains(capability)
    }

    private func permitsTransient(_ envelope: MeshEnvelope, from link: Link, capability: PeerCapabilities) -> Bool {
        guard room.transportPolicy == .secureV2 else { return true }
        // Transient commands have no durable signature. Only their admitted
        // origin may send them; the v2 directory repairs missing direct links.
        guard let origin = envelope.nodeID, origin == link.nodeID else { return false }
        return eventPolicy?.permits(author: origin, capability: capability) == true
    }

    private func validRoomEvents(_ events: [MeshRoomEvent]) -> [MeshRoomEvent] {
        events.filter {
            (eventPolicy?.accepts($0) ?? true) && $0.roomID == room.id && MeshRoomReplica.hasPlausibleCounters($0) && ($0.text?.utf8.count ?? 0) <= 8_192 &&
                (try? MeshEnvelope(type: "event", event: $0).encodedLine().count).map {
                    $0 <= MeshEnvelopeDecoder.maximumLineBytes
                } == true
        }
    }

    private func isValidWalkieTalkie(_ message: WalkieTalkieMessage) -> Bool {
        guard !message.senderID.isEmpty,
              message.senderID.utf8.count <= 128,
              !message.senderName.isEmpty,
              message.senderName.utf8.count <= 160,
              !message.sessionID.isEmpty,
              message.sessionID.utf8.count <= 128,
              (message.targetID?.utf8.count ?? 0) <= 128
        else { return false }
        if let targetIDs = message.targetIDs {
            guard targetIDs.count <= 256,
                  targetIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
                  Set(targetIDs).count == targetIDs.count
            else { return false }
            if let targetID = message.targetID {
                guard targetIDs == [targetID] else { return false }
            }
        }
        guard (8_000...96_000).contains(message.resolvedSampleRate) else { return false }
        guard message.kind == .audio else { return message.pcm16Mono == nil }
        guard let data = message.pcm16Mono else { return false }
        return !data.isEmpty && data.count <= 8_192 && data.count.isMultiple(of: MemoryLayout<Int16>.size)
    }

    /// Explicit recipient snapshots are split into one targeted message per
    /// peer. Older clients ignore `targetIDs`, so retaining a non-nil
    /// `targetID` prevents a private Talk/Open Line stream from becoming their
    /// legacy `targetID == nil` broadcast sentinel.
    static func legacySafeWalkieTalkieMessages(
        _ message: WalkieTalkieMessage
    ) -> [WalkieTalkieMessage] {
        guard let recipients = message.recipientIDs else { return [message] }
        return recipients.sorted().map { recipientID in
            WalkieTalkieMessage(
                kind: message.kind,
                senderID: message.senderID,
                senderName: message.senderName,
                targetID: recipientID,
                targetIDs: [recipientID],
                sessionID: message.sessionID,
                sequence: message.sequence,
                sampleRate: message.sampleRate,
                pcm16Mono: message.pcm16Mono
            )
        }
    }

    static func supportsFullBandVoice(appVersion: String?) -> Bool {
        guard let appVersion, let parsed = AppVersion(appVersion) else { return false }
        return parsed >= fullBandVoiceVersion
    }

    static func legacyCompatibleWalkieTalkieMessage(
        _ message: WalkieTalkieMessage
    ) -> WalkieTalkieMessage {
        var downsampler = LegacyVoiceDownsampler()
        return legacyCompatibleWalkieTalkieMessage(message, downsampler: &downsampler)
    }

    static func legacyCompatibleWalkieTalkieMessage(
        _ message: WalkieTalkieMessage,
        downsampler: inout LegacyVoiceDownsampler
    ) -> WalkieTalkieMessage {
        guard message.resolvedSampleRate == 48_000 else { return message }
        let legacyPCM: Data?
        if let pcm = message.pcm16Mono {
            legacyPCM = downsampler.process(pcm)
        } else {
            legacyPCM = nil
        }
        return WalkieTalkieMessage(
            kind: message.kind,
            senderID: message.senderID,
            senderName: message.senderName,
            targetID: message.targetID,
            targetIDs: message.recipientIDs,
            sessionID: message.sessionID,
            sequence: message.sequence,
            sampleRate: 16_000,
            pcm16Mono: legacyPCM
        )
    }

    private func isValidOpenLine(_ message: OpenLineMessage) -> Bool {
        !message.invitationID.isEmpty && message.invitationID.utf8.count <= 128 &&
            !message.senderID.isEmpty && message.senderID.utf8.count <= 128 &&
            !message.senderName.isEmpty && message.senderName.utf8.count <= 160 &&
            !message.targetID.isEmpty && message.targetID.utf8.count <= 128 &&
            message.senderID != message.targetID
    }

    static func isValidWalkieTalkieOrigin(
        senderID: String,
        remoteID: String,
        envelopeOriginID: String?,
        hopCount: UInt8
    ) -> Bool {
        if hopCount == 0 {
            return senderID == remoteID && (envelopeOriginID == nil || envelopeOriginID == senderID)
        }
        return envelopeOriginID == senderID
    }

    private func rememberWalkieTalkie(_ message: WalkieTalkieMessage) -> Bool {
        let key = WalkieMessageKey(
            senderID: message.senderID,
            sessionID: message.sessionID,
            kind: message.kind.rawValue,
            sequence: message.sequence,
            targetIDs: message.recipientIDs.map { $0.sorted() }
        )
        guard seenWalkieMessages.insert(key).inserted else { return false }
        seenWalkieMessageOrder.append(key)
        if seenWalkieMessageOrder.count > maximumRememberedWalkieMessages {
            let expired = Array(seenWalkieMessageOrder.prefix(1_024))
            seenWalkieMessageOrder.removeFirst(expired.count)
            for key in expired { seenWalkieMessages.remove(key) }
        }
        return true
    }

    private func rememberOpenLine(_ message: OpenLineMessage) -> Bool {
        let key = OpenLineMessageKey(
            invitationID: message.invitationID,
            kind: message.kind.rawValue,
            senderID: message.senderID,
            targetID: message.targetID
        )
        guard seenOpenLineMessages.insert(key).inserted else { return false }
        seenOpenLineMessageOrder.append(key)
        if seenOpenLineMessageOrder.count > maximumRememberedWalkieMessages {
            let expired = Array(seenOpenLineMessageOrder.prefix(1_024))
            seenOpenLineMessageOrder.removeFirst(expired.count)
            for key in expired { seenOpenLineMessages.remove(key) }
        }
        return true
    }

    private func routeWalkieTalkie(
        _ envelope: MeshEnvelope,
        message: WalkieTalkieMessage,
        relayRecipients: Set<String>? = nil,
        excluding source: Link?
    ) {
        let recipientsToRoute = relayRecipients ?? message.recipientIDs
        guard let recipients = recipientsToRoute else {
            broadcast(envelope, excluding: source)
            return
        }
        let remaining = recipients.subtracting([nodeID])
        guard !remaining.isEmpty else { return }
        let plan = Self.walkieTalkieRoutePlan(
            recipientIDs: remaining,
            directlyConnectedIDs: Set(peers.keys)
        )
        // With unresolved peers, the plan uses every direct branch once because
        // this node does not know which sparse branch contains each peer.
        let links: [Link] = plan.destinationIDs.compactMap { peers[$0] }.filter { $0 !== source }
        let routed = MeshEnvelope(
            type: "walkie_talkie",
            nodeID: envelope.nodeID,
            walkieTalkieHopCount: envelope.walkieTalkieHopCount,
            walkieTalkieRelayTargetIDs: plan.unresolvedIDs.sorted(),
            walkieTalkie: message
        )
        // With no unresolved recipients this is a terminal copy, so a direct
        // recipient cannot relay it to the other direct recipients.
        send(routed, to: links)
    }

    static func walkieTalkieRoutePlan(
        recipientIDs: Set<String>,
        directlyConnectedIDs: Set<String>
    ) -> (destinationIDs: Set<String>, unresolvedIDs: Set<String>) {
        let unresolved = recipientIDs.subtracting(directlyConnectedIDs)
        return (
            destinationIDs: unresolved.isEmpty
                ? recipientIDs.intersection(directlyConnectedIDs)
                : directlyConnectedIDs,
            unresolvedIDs: unresolved
        )
    }

    private func routeOpenLine(
        _ envelope: MeshEnvelope,
        message: OpenLineMessage,
        excluding source: Link?
    ) {
        if let target = peers[message.targetID], target !== source {
            send(envelope, to: [target])
        } else {
            broadcast(envelope, excluding: source)
        }
    }

    private func freshPlaybackTiming(for id: String, now: UInt64) -> PeerPlaybackTiming? {
        guard let report = playbackReports[id],
              report.timing.isFresh(receivedAt: report.received, now: now),
              let broadcaster = replica.broadcaster,
              broadcaster.nodeID == report.broadcaster,
              broadcaster.epoch == report.epoch,
              replica.nowPlaying.isPlaying != false else { return nil }
        return report.timing
    }

    private func publishParticipants() {
        let now = MonotonicClock.nowNanos()
        let local = RoomParticipant(
            id: nodeID,
            name: displayName,
            icon: deviceIcon,
            colorHex: deviceColorHex,
            profileImageData: profileImageData,
            appVersion: appVersion
        )
        let remote: [RoomParticipant] = remoteParticipants.compactMap { id, participant in
            guard peers[id] != nil || lastSeenNanos[id].map({ seen in
                now < seen || now - seen < participantLeaseNanos
            }) == true else { return nil }
            return participant
        }
        var participants: [RoomParticipant] = []
        for identity in [local] + remote {
            var participant = identity
            // Identity caches are never a source of timing truth.
            participant.playbackTiming = freshPlaybackTiming(for: identity.id, now: now)
            participants.append(participant)
        }
        participants.sort { $0.name < $1.name }
        guard participants != lastPublishedParticipants else { return }
        lastPublishedParticipants = participants
        participantsHandler(participants)
    }

    private func remove(_ link: Link) {
        guard links.removeValue(forKey: ObjectIdentifier(link.connection)) != nil else { return }
        let disconnectedID = link.nodeID
        let wasCanonical = disconnectedID.map { peers[$0] === link } ?? false
        if let id = disconnectedID, wasCanonical {
            peers.removeValue(forKey: id)
            playbackReports.removeValue(forKey: id)
            chatAttachmentAssembler.discard(senderID: id)
        }
        if room.transportPolicy == .secureV2 {
            if wasCanonical, peers.isEmpty, scanWindowExpiresAtNanos == nil {
                scanWindowExpiresAtNanos = MonotonicClock.nowNanos() + 15_000_000_000
            }
            if let id = disconnectedID, let connectionID = link.authenticatedPeer?.connectionID,
               pendingCommits[id] == connectionID { pendingCommits.removeValue(forKey: id) }
            guard !isStopped else { return }
            if let id = disconnectedID { scheduleSecureSelection(peerID: id) }
            if let id = disconnectedID, peers[id] == nil, link.initiated {
                scheduleReconnect(to: link.connection.endpoint, peerID: id, hintExpiresAtNanos: link.hintExpiresAtNanos)
            } else if peers.isEmpty { startSecureScan() }
            return
        }
        let canonicalPeerExists = disconnectedID.map { peers[$0] != nil } ?? false
        if Self.shouldReconnectAfterRemoval(
            initiated: link.initiated,
            localID: nodeID,
            remoteID: disconnectedID,
            canonicalPeerExists: canonicalPeerExists
        ), let disconnectedID {
            scheduleReconnect(to: link.connection.endpoint, peerID: disconnectedID)
        }
    }

    static func shouldReconnectAfterRemoval(
        initiated: Bool,
        localID: String,
        remoteID: String?,
        canonicalPeerExists: Bool
    ) -> Bool {
        initiated && !canonicalPeerExists && remoteID.map { localID < $0 } == true
    }

    private func scheduleReconnect(to endpoint: NWEndpoint, peerID: String, hintExpiresAtNanos: UInt64? = nil) {
        guard !isStopped, peers[peerID] == nil else { return }
        if let hintExpiresAtNanos, MonotonicClock.nowNanos() >= hintExpiresAtNanos {
            reconnectWorkItems.removeValue(forKey: peerID)?.cancel()
            reconnectAttempts.removeValue(forKey: peerID)
            return
        }
        if room.transportPolicy == .secureV2, (reconnectAttempts[peerID] ?? 0) >= 4 {
            startSecureScan(); return
        }
        reconnectWorkItems.removeValue(forKey: peerID)?.cancel()
        let attempt = min((reconnectAttempts[peerID] ?? 0) + 1, 4)
        reconnectAttempts[peerID] = attempt
        let delayMillis = min(400 * (1 << (attempt - 1)), 3_200)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isStopped, peers[peerID] == nil else { return }
            reconnectWorkItems.removeValue(forKey: peerID)
            connect(to: endpoint, expectedNodeID: peerID, hintExpiresAtNanos: hintExpiresAtNanos)
        }
        reconnectWorkItems[peerID] = work
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMillis), execute: work)
    }

    private func publishBroadcasterEvent(
        broadcasterID: String,
        epoch: UInt64,
        active: Bool,
        mediaServiceName: String?
    ) {
        guard localPermits(.broadcast) else { return }
        var event = MeshRoomEvent(
            roomID: room.id,
            version: replica.nextVersion(nodeID: nodeID),
            kind: .broadcaster,
            broadcasterID: broadcasterID,
            broadcasterEpoch: epoch,
            mediaServiceName: mediaServiceName,
            isBroadcasting: active
        )
        if let eventPolicy {
            guard let signed = eventPolicy.sign(event) else { return }
            event = signed
        }
        _ = replica.merge([event])
        replicaHandler(replica)
        broadcast(MeshEnvelope(type: "event", event: event))
    }

    private func retireExpiredBroadcasterIfNeeded(nowNanos: UInt64) {
        // v2 liveness is an observation. A timeout cannot author a durable
        // broadcaster-stop event on somebody else's behalf.
        guard room.transportPolicy == .legacyOnly else { return }
        guard let current = replica.broadcaster, current.nodeID != nodeID else { return }
        guard let lastSeen = lastSeenNanos[current.nodeID] else {
            lastSeenNanos[current.nodeID] = nowNanos
            return
        }
        guard nowNanos &- lastSeen >= broadcasterLeaseNanos else { return }
        let liveNodeIDs = [nodeID] + lastSeenNanos.compactMap { id, seen in
            nowNanos &- seen < broadcasterLeaseNanos ? id : nil
        }
        guard liveNodeIDs.min() == nodeID else { return }
        publishBroadcasterEvent(
            broadcasterID: current.nodeID,
            epoch: current.epoch,
            active: false,
            mediaServiceName: nil
        )
    }

    private func startHeartbeatTimer() {
        lastSeenNanos[nodeID] = MonotonicClock.nowNanos()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(Int(heartbeatIntervalNanos)),
            leeway: .milliseconds(80)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = MonotonicClock.nowNanos()
            heartbeatSequence &+= 1
            latestHeartbeatSequence[nodeID] = heartbeatSequence
            lastSeenNanos[nodeID] = now
            broadcast(MeshEnvelope(type: "heartbeat", nodeID: nodeID, heartbeatSequence: heartbeatSequence, heartbeatGeneration: heartbeatGeneration))
            retireExpiredBroadcasterIfNeeded(nowNanos: now)
            expireDisconnectedParticipantsIfNeeded(nowNanos: now)
            publishParticipants() // Expire stale playback telemetry even on an otherwise quiet room.
            if room.transportPolicy == .secureV2 {
                repairSecureDirectory(nowNanos: now)
                if now >= lastDirectoryPublishNanos, now - lastDirectoryPublishNanos >= 5_000_000_000 {
                    lastDirectoryPublishNanos = now
                    publishSecureDirectory()
                }
            }
            if !advertisedRecord.isEmpty { refreshAdvertisement() }
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func acceptHeartbeat(originID: String, generation: String, sequence: UInt64, excluding source: Link) {
        guard originID != nodeID, originID.utf8.count <= 128, generation.utf8.count <= 128,
              originID == source.nodeID || lastSeenNanos[originID] != nil else { return }
        if latestHeartbeatGeneration[originID] != generation {
            latestHeartbeatGeneration[originID] = generation
            latestHeartbeatSequence[originID] = 0
        }
        guard sequence > (latestHeartbeatSequence[originID] ?? 0) else { return }
        latestHeartbeatSequence[originID] = sequence
        lastSeenNanos[originID] = MonotonicClock.nowNanos()
        broadcast(
            MeshEnvelope(type: "heartbeat", nodeID: originID, heartbeatSequence: sequence, heartbeatGeneration: generation),
            excluding: source
        )
    }

    private func expireDisconnectedParticipantsIfNeeded(nowNanos: UInt64) {
        let expired = remoteParticipants.keys.filter { id in
            if peers[id] != nil { return false }
            guard let lastSeen = lastSeenNanos[id] else { return true }
            return nowNanos >= lastSeen && nowNanos - lastSeen >= participantLeaseNanos
        }
        guard !expired.isEmpty else { return }
        for id in expired {
            remoteParticipants.removeValue(forKey: id)
            if room.transportPolicy == .secureV2 {
                lastSeenNanos.removeValue(forKey: id)
                latestHeartbeatSequence.removeValue(forKey: id)
                latestHeartbeatGeneration.removeValue(forKey: id)
            }
        }
        publishParticipants()
    }

    private func rememberRoomAction(_ requestID: String) -> Bool {
        guard seenRoomActionIDs.insert(requestID).inserted else { return false }
        roomActionIDOrder.append(requestID)
        if roomActionIDOrder.count > 1_024 {
            let expiredIDs = Array(roomActionIDOrder.prefix(256))
            roomActionIDOrder.removeFirst(expiredIDs.count)
            for expired in expiredIDs {
                seenRoomActionIDs.remove(expired)
            }
        }
        return true
    }

    private func roomActionKey(_ requestID: String, attempt: UInt64) -> String {
        "action:\(requestID):\(attempt)"
    }

    private func rememberAcceptedRoomAction(_ requestID: String) {
        if acceptedRoomActionIDs.count >= 2_048 {
            acceptedRoomActionIDs.removeAll(keepingCapacity: true)
        }
        acceptedRoomActionIDs.insert(requestID)
    }

    private func beginReliableRoomAction(
        _ envelope: MeshEnvelope,
        requestID: String,
        broadcasterID: String,
        broadcasterEpoch: UInt64
    ) {
        pendingRoomActions[requestID] = PendingRoomAction(
            envelope: envelope,
            broadcasterID: broadcasterID,
            broadcasterEpoch: broadcasterEpoch,
            attempts: 1
        )
        scheduleRoomActionRetry(requestID)
    }

    private func scheduleRoomActionRetry(_ requestID: String) {
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self, !isStopped, var pending = pendingRoomActions[requestID] else { return }
            guard let current = replica.broadcaster,
                  current.nodeID == pending.broadcasterID,
                  current.epoch == pending.broadcasterEpoch,
                  pending.attempts < 20
            else {
                pendingRoomActions.removeValue(forKey: requestID)
                return
            }
            pending.attempts += 1
            pending = PendingRoomAction(
                envelope: roomActionEnvelope(
                    from: pending.envelope,
                    attempt: UInt64(pending.attempts)
                ),
                broadcasterID: pending.broadcasterID,
                broadcasterEpoch: pending.broadcasterEpoch,
                attempts: pending.attempts
            )
            pendingRoomActions[requestID] = pending
            _ = rememberRoomAction(
                roomActionKey(requestID, attempt: UInt64(pending.attempts))
            )
            broadcast(pending.envelope)
            scheduleRoomActionRetry(requestID)
        }
    }

    private func roomActionEnvelope(from envelope: MeshEnvelope, attempt: UInt64) -> MeshEnvelope {
        MeshEnvelope(
            type: envelope.type,
            nodeID: envelope.nodeID,
            requestID: envelope.requestID,
            broadcasterID: envelope.broadcasterID,
            broadcasterEpoch: envelope.broadcasterEpoch,
            mediaCommand: envelope.mediaCommand,
            targetID: envelope.targetID,
            actionAttempt: attempt
        )
    }

    private func acknowledgeRoomAction(
        requestID: String,
        originID: String,
        broadcasterID: String,
        broadcasterEpoch: UInt64
    ) {
        let acknowledgement = MeshEnvelope(
            type: "room_action_ack",
            nodeID: nodeID,
            requestID: requestID,
            broadcasterID: broadcasterID,
            broadcasterEpoch: broadcasterEpoch,
            targetID: originID
        )
        _ = rememberRoomAction("ack:\(requestID)")
        broadcast(acknowledgement)
    }

    private func completeAuthentication(_ link: Link, remoteID: String) {
        guard !link.authenticated else { return }
        if let existing = peers[remoteID], existing !== link {
            // A fresh authenticated link may be replacing an AWDL socket that
            // died only on the initiator's side. Adopt it so a half-open
            // canonical connection cannot reject every recovery attempt.
            cancel(existing)
        }
        link.authenticated = true
        link.hintExpiresAtNanos = nil
        peers[remoteID] = link
        if room.transportPolicy == .secureV2 {
            pendingCommits.removeValue(forKey: remoteID)
            stopSecureScan()
            scanWindowExpiresAtNanos = nil
            for candidate in links.values where candidate !== link && candidate.nodeID == remoteID {
                cancel(candidate)
            }
            rememberDirectPeer(link)
            publishSecureDirectory(to: link)
            if let hint = directoryHint(for: link) {
                broadcast(MeshEnvelope(type: "mesh_peer_directory", meshPeerDirectory: [hint]), excluding: link)
            }
        }
        if let roomIcon { send(MeshEnvelope(type: "room_icon", roomIcon: roomIcon), to: link) }
        if roomStateSyncDisabled, link.roomStateSyncVersion == 1 {
            disableRoomStateSync(
                for: link,
                reason: "local durable sync had already switched to legacy"
            )
        }
        reconnectAttempts[remoteID] = 0
        reconnectWorkItems.removeValue(forKey: remoteID)?.cancel()
        lastSeenNanos[remoteID] = MonotonicClock.nowNanos()
        cacheParticipant(from: link, id: remoteID)
        if let version = link.appVersion { peerVersionHandler(version) }
        publishParticipants()
        let missing = link.remoteVersionVector.map(replica.missingEvents(comparedWith:))
            ?? Array(replica.events.suffix(maximumSyncEvents))
        var eventsByID = Dictionary(uniqueKeysWithValues: missing.map { ($0.id, $0) })
        // Persisted replicas intentionally omit transient broadcaster claims,
        // so their version vector can be ahead of an event they do not hold.
        // Always include broadcaster lifecycle events to restore the live room
        // after a peer relaunches and to retain stop events against resurrection.
        for event in replica.events where event.kind == .broadcaster {
            eventsByID[event.id] = event
        }
        let events = MeshRoomReplica(events: Array(eventsByID.values)).events
        sendSync(
            events: events,
            versionVector: replica.versionVector,
            to: link
        )
        if link.roomStateSyncVersion == 1 { sendRoomStateSync(to: link) }
    }

    /// A room can retain many artwork-bearing playback events. Sending them as
    /// one JSON line exceeds `MeshEnvelopeDecoder.maximumLineBytes`, so the peer
    /// cancels before merging anything and reconnects into the same snapshot.
    /// Keep batches comfortably below that hard framing limit and send the
    /// version vector only after all event batches have arrived.
    static func synchronizationEnvelopes(
        events: [MeshRoomEvent],
        versionVector: [String: UInt64]?
    ) -> [MeshEnvelope] {
        let encoder = JSONEncoder()
        var envelopes = [MeshEnvelope]()
        var batch = [MeshRoomEvent]()
        var estimatedBytes = 64

        func envelopeFits(_ envelope: MeshEnvelope) -> Bool {
            (try? envelope.encodedLine().count).map {
                $0 <= MeshEnvelopeDecoder.maximumLineBytes
            } == true
        }

        func appendBatch(_ events: [MeshRoomEvent], to envelopes: inout [MeshEnvelope]) {
            guard !events.isEmpty else { return }
            let envelope = MeshEnvelope(type: "sync", events: events)
            if envelopeFits(envelope) { envelopes.append(envelope) }
        }

        // Apply lifecycle stops before claims, and the winning claim before
        // older claims. That keeps every intermediate batch semantically safe:
        // a stopped broadcaster never appears live while its stop is still in
        // flight, and a lower-priority claim cannot briefly replace the winner.
        let orderedEvents = events.sorted(by: synchronizationEventPrecedes)
        for event in orderedEvents {
            guard let encodedEvent = try? encoder.encode(event) else { continue }
            let eventBytes = encodedEvent.count
            if !batch.isEmpty,
               estimatedBytes + eventBytes + 1 > synchronizationEnvelopeTargetBytes {
                appendBatch(batch, to: &envelopes)
                batch.removeAll(keepingCapacity: true)
                estimatedBytes = 64
            }
            let single = MeshEnvelope(type: "sync", events: [event])
            guard envelopeFits(single) else { continue }
            batch.append(event)
            estimatedBytes += eventBytes + 1
        }
        appendBatch(batch, to: &envelopes)

        if let versionVector {
            let completion = MeshEnvelope(type: "sync", events: [], versionVector: versionVector)
            if envelopeFits(completion) { envelopes.append(completion) }
        }
        return envelopes
    }

    private static func synchronizationEventPrecedes(
        _ lhs: MeshRoomEvent,
        _ rhs: MeshRoomEvent
    ) -> Bool {
        let lhsIsBroadcaster = lhs.kind == .broadcaster
        let rhsIsBroadcaster = rhs.kind == .broadcaster
        if lhsIsBroadcaster != rhsIsBroadcaster { return lhsIsBroadcaster }
        guard lhsIsBroadcaster else {
            return lhs.version == rhs.version ? lhs.id < rhs.id : lhs.version < rhs.version
        }

        let lhsIsClaim = lhs.isBroadcasting == true
        let rhsIsClaim = rhs.isBroadcasting == true
        if lhsIsClaim != rhsIsClaim { return !lhsIsClaim }
        guard lhsIsClaim else {
            return lhs.version == rhs.version ? lhs.id < rhs.id : lhs.version < rhs.version
        }

        let lhsEpoch = lhs.broadcasterEpoch ?? 0
        let rhsEpoch = rhs.broadcasterEpoch ?? 0
        if lhsEpoch != rhsEpoch { return lhsEpoch > rhsEpoch }
        let lhsNode = lhs.broadcasterID ?? ""
        let rhsNode = rhs.broadcasterID ?? ""
        if lhsNode != rhsNode { return lhsNode > rhsNode }
        return lhs.version == rhs.version ? lhs.id > rhs.id : lhs.version > rhs.version
    }

    private func sendSync(
        events: [MeshRoomEvent],
        versionVector: [String: UInt64]?,
        to link: Link
    ) {
        guard !link.snapshotSendInFlight, link.snapshotSendQueue.isEmpty else {
            link.snapshotResendRequested = true
            return
        }
        link.snapshotSendQueue = Self.synchronizationEnvelopes(events: events, versionVector: versionVector)
        drainSnapshot(to: link)
    }

    private func drainSnapshot(to link: Link) {
        guard !link.snapshotSendInFlight, links[ObjectIdentifier(link.connection)] === link else { return }
        guard !link.snapshotSendQueue.isEmpty else {
            if link.snapshotResendRequested {
                link.snapshotResendRequested = false
                sendSync(events: replica.events, versionVector: replica.versionVector, to: link)
            }
            return
        }
        let envelope = link.snapshotSendQueue.removeFirst()
        guard let data = try? envelope.encodedLine() else { cancel(link); return }
        link.snapshotSendInFlight = true
        sendWire(data, to: link) { [weak self, weak link] error in
            guard let self, let link else { return }
            self.queue.async {
                link.snapshotSendInFlight = false
                guard error == nil else { self.cancel(link); return }
                self.drainSnapshot(to: link)
            }
        }
    }

    static func roomStateSyncEnvelopes(
        message: Data,
        messageID: String = UUID().uuidString
    ) -> [MeshEnvelope] {
        guard !message.isEmpty,
              message.count <= maximumRoomStateSyncBytes,
              !messageID.isEmpty,
              messageID.utf8.count <= 128
        else { return [] }
        let count = (message.count + roomStateSyncChunkBytes - 1) / roomStateSyncChunkBytes
        guard count <= Int(maximumRoomStateSyncChunks) else { return [] }
        return (0..<count).map { index in
            let start = index * roomStateSyncChunkBytes
            let end = min(start + roomStateSyncChunkBytes, message.count)
            return MeshEnvelope(
                type: "room_state_sync",
                roomStateSyncID: messageID,
                roomStateSyncChunkIndex: UInt16(index),
                roomStateSyncChunkCount: UInt16(count),
                roomStateSyncMessage: message.subdata(in: start..<end)
            )
        }
    }

    private func sendRoomStateSync(to link: Link) {
        guard !roomStateSyncDisabled, link.roomStateSyncVersion == 1 else { return }
        roomStateWorkerQueue.async { [weak self, weak link] in
            guard let self, let link,
                  let message = roomStateSync.generateSyncMessage(for: link.roomStateSyncSession)
            else { return }
            let encoded = Self.roomStateSyncEnvelopes(message: message).compactMap {
                try? $0.encodedLine()
            }
            queue.async { [weak self, weak link] in
                guard let self, let link,
                      links[ObjectIdentifier(link.connection)] === link,
                      link.roomStateSyncVersion == 1
                else { return }
                guard !encoded.isEmpty else {
                    disableRoomStateSync(for: link, reason: "sync message exceeded the wire budget")
                    return
                }
                link.roomStateSyncSendQueue.append(contentsOf: encoded)
                drainRoomStateSync(to: link)
            }
        }
    }

    private func ingestDurableRoomState(_ events: [MeshRoomEvent], excluding source: Link?) {
        let durable = events.filter {
            $0.kind == .chat || $0.kind == .queueAdd || $0.kind == .queueRemove || $0.kind == .queueReorder
        }
        guard !roomStateSyncDisabled, !durable.isEmpty else { return }
        roomStateWorkerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let inserted = try roomStateSync.ingest(durable)
                guard !inserted.isEmpty else { return }
                let shouldFallback = roomStateSync.requiresLifecycleCompaction()
                queue.async { [weak self] in
                    guard let self, !isStopped, !roomStateSyncDisabled else { return }
                    scheduleRoomStatePersistence()
                    if shouldFallback {
                        handleRoomStateSyncFailure(RoomStateSyncError.documentTooLarge, from: nil)
                        return
                    }
                    for link in peers.values where link !== source && link.roomStateSyncVersion == 1 {
                        sendRoomStateSync(to: link)
                    }
                }
            } catch {
                queue.async { [weak self] in
                    guard let self, !isStopped else { return }
                    handleRoomStateSyncFailure(error, from: nil)
                }
            }
        }
    }

    private func receiveRoomStateSync(_ envelope: MeshEnvelope, from link: Link) {
        guard let messageID = envelope.roomStateSyncID,
              !messageID.isEmpty,
              messageID.utf8.count <= 128,
              let index = envelope.roomStateSyncChunkIndex,
              let count = envelope.roomStateSyncChunkCount,
              count > 0,
              count <= Self.maximumRoomStateSyncChunks,
              index < count,
              let chunk = envelope.roomStateSyncMessage,
              !chunk.isEmpty,
              chunk.count <= Self.roomStateSyncChunkBytes
        else {
            disableRoomStateSync(for: link, reason: "peer sent malformed durable-sync framing")
            return
        }

        if index == 0 {
            link.roomStateSyncID = messageID
            link.roomStateSyncChunkCount = count
            link.roomStateSyncNextChunk = 0
            link.roomStateSyncBuffer.removeAll(keepingCapacity: true)
        }
        guard link.roomStateSyncID == messageID,
              link.roomStateSyncChunkCount == count,
              link.roomStateSyncNextChunk == index,
              link.roomStateSyncBuffer.count + chunk.count <= Self.maximumRoomStateSyncBytes
        else {
            resetRoomStateSyncAssembly(link)
            disableRoomStateSync(for: link, reason: "peer exceeded durable-sync assembly bounds")
            return
        }
        link.roomStateSyncBuffer.append(chunk)
        link.roomStateSyncNextChunk &+= 1
        guard link.roomStateSyncNextChunk == count else { return }

        let message = link.roomStateSyncBuffer
        resetRoomStateSyncAssembly(link)
        enqueueRoomStateSyncMessage(message, from: link)
    }

    private func enqueueRoomStateSyncMessage(_ message: Data, from link: Link) {
        guard !link.roomStateSyncReceiveInFlight else {
            guard link.roomStateSyncReceiveQueue.count
                    < Self.maximumPendingRoomStateSyncMessages,
                  link.roomStateSyncReceiveQueuedBytes + message.count
                    <= Self.maximumPendingRoomStateSyncBytes else {
                disableRoomStateSync(for: link, reason: "peer exceeded durable-sync work backlog")
                return
            }
            link.roomStateSyncReceiveQueue.append(message)
            link.roomStateSyncReceiveQueuedBytes += message.count
            return
        }
        link.roomStateSyncReceiveInFlight = true
        processRoomStateSyncMessage(message, from: link)
    }

    private func processRoomStateSyncMessage(_ message: Data, from link: Link) {
        roomStateWorkerQueue.async { [weak self, weak link] in
            guard let self, let link else { return }
            do {
                let inserted = try roomStateSync.receiveSyncMessage(
                    message,
                    from: link.roomStateSyncSession
                )
                let shouldFallback = roomStateSync.requiresLifecycleCompaction()
                roomStateReceiveCompletedHandler(inserted)
                queue.async { [weak self] in
                    guard let self, !isStopped else { return }
                    let linkIsLive = links[ObjectIdentifier(link.connection)] === link
                        && link.authenticated
                    if !inserted.isEmpty {
                        let merged = replica.merge(validRoomEvents(inserted))
                        if !merged.isEmpty {
                            replicaHandler(replica)
                            // Legacy peers still converge during the rolling upgrade.
                            for event in merged {
                                broadcast(MeshEnvelope(type: "event", event: event), excluding: link)
                            }
                        }
                        scheduleRoomStatePersistence()
                        for peer in peers.values
                            where peer !== link && peer.roomStateSyncVersion == 1 {
                            sendRoomStateSync(to: peer)
                        }
                    }
                    if shouldFallback {
                        handleRoomStateSyncFailure(RoomStateSyncError.documentTooLarge, from: nil)
                    }
                    if linkIsLive { sendRoomStateSync(to: link) }
                    finishRoomStateSyncReceive(from: link)
                }
            } catch {
                queue.async { [weak self] in
                    guard let self, !isStopped else { return }
                    handleRoomStateSyncFailure(error, from: link)
                    finishRoomStateSyncReceive(from: link)
                }
            }
        }
    }

    private func finishRoomStateSyncReceive(from link: Link) {
        link.roomStateSyncReceiveInFlight = false
        guard !roomStateSyncDisabled,
              link.roomStateSyncVersion == 1,
              links[ObjectIdentifier(link.connection)] === link,
              !link.roomStateSyncReceiveQueue.isEmpty
        else {
            link.roomStateSyncReceiveQueue.removeAll(keepingCapacity: false)
            return
        }
        let next = link.roomStateSyncReceiveQueue.removeFirst()
        link.roomStateSyncReceiveQueuedBytes -= next.count
        link.roomStateSyncReceiveInFlight = true
        processRoomStateSyncMessage(next, from: link)
    }

    private func drainRoomStateSync(to link: Link) {
        guard !link.roomStateSyncSendInFlight,
              !link.roomStateSyncSendQueue.isEmpty,
              links[ObjectIdentifier(link.connection)] === link
        else { return }
        let data = link.roomStateSyncSendQueue.removeFirst()
        link.roomStateSyncSendInFlight = true
        sendWire(data, to: link) { [weak self, weak link] error in
            guard let self, let link else { return }
            self.queue.async {
                link.roomStateSyncSendInFlight = false
                guard error == nil else {
                    self.cancel(link)
                    return
                }
                self.drainRoomStateSync(to: link)
            }
        }
    }

    private func scheduleRoomStatePersistence(delay: DispatchTimeInterval = .milliseconds(250)) {
        guard !isStopped else { return }
        roomStatePersistenceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isStopped else { return }
            roomStatePersistenceWorkItem = nil
            roomStateWorkerQueue.async { [weak self] in
                guard let self else { return }
                let document: Data
                if let eventPolicy {
                    guard let archive = try? eventPolicy.archive(document: roomStateSync.save()) else { return }
                    document = archive
                } else { document = roomStateSync.save() }
                queue.async { [weak self] in
                    guard let self, !isStopped else { return }
                    roomStatePersistenceHandler(document)
                }
            }
        }
        roomStatePersistenceWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resetRoomStateSyncAssembly(_ link: Link) {
        link.roomStateSyncID = nil
        link.roomStateSyncChunkCount = 0
        link.roomStateSyncNextChunk = 0
        link.roomStateSyncBuffer.removeAll(keepingCapacity: false)
    }

    private func handleRoomStateSyncFailure(_ error: Error, from link: Link?) {
        if let link {
            disableRoomStateSync(
                for: link,
                reason: "peer state could not be merged (\(type(of: error)))"
            )
        } else {
            roomStateSyncDisabled = true
            for peer in peers.values {
                disableRoomStateSync(
                    for: peer,
                    reason: "local state could not be updated (\(type(of: error)))"
                )
            }
        }
    }

    private func disableRoomStateSync(for link: Link, reason: String, notifyPeer: Bool = true) {
        let transitionedFromAutomerge = link.roomStateSyncVersion == 1
        let shouldNotify = notifyPeer && link.authenticated && transitionedFromAutomerge
        link.roomStateSyncVersion = nil
        link.roomStateSyncSendQueue.removeAll(keepingCapacity: false)
        link.roomStateSyncReceiveQueue.removeAll(keepingCapacity: false)
        link.roomStateSyncReceiveQueuedBytes = 0
        resetRoomStateSyncAssembly(link)
        if shouldNotify {
            // A repeated hello is accepted before or after authentication, so
            // this downgrade cannot be lost in the handshake race.
            send(hello(for: link, advertiseRoomStateSync: false), to: link)
        }
        if transitionedFromAutomerge, !roomStateSyncDisabled {
            ingestDurableRoomState(replica.events, excluding: nil)
        }
        roomStateDowngradeHandler(link.nodeID)
        fputs("Durable room sync disabled for this link: \(reason). Legacy sync remains active.\n", stderr)
    }

    private func cacheParticipant(from link: Link, id: String) {
        guard let name = link.displayName else { return }
        let appearance = DeviceAppearance.generated(from: id)
        remoteParticipants[id] = RoomParticipant(
            id: id,
            name: name,
            icon: link.deviceIcon ?? appearance.icon,
            colorHex: link.deviceColorHex ?? appearance.colorHex,
            profileImageData: link.profileImageData,
            appVersion: link.appVersion
        )
    }

    private func broadcast(_ envelope: MeshEnvelope, excluding source: Link? = nil) {
        send(envelope, to: peers.values.filter { $0 !== source })
    }

    private func send(_ envelope: MeshEnvelope, to link: Link) {
        send(envelope, to: [link])
    }

    private func sendThenCancel(_ envelope: MeshEnvelope, to link: Link) {
        guard let data = try? envelope.encodedLine() else {
            link.connection.cancel()
            return
        }
        sendWire(data, to: link) { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.queue.async {
                guard self.links[ObjectIdentifier(link.connection)] === link,
                      !link.authenticated
                else { return }
                self.cancel(link)
            }
        }
    }

    private func send(_ envelope: MeshEnvelope, to links: [Link]) {
        if envelope.type == "walkie_talkie", let message = envelope.walkieTalkie {
            for link in links {
                let wireMessage: WalkieTalkieMessage
                if Self.supportsFullBandVoice(appVersion: link.appVersion) {
                    wireMessage = message
                } else {
                    if message.kind == .began {
                        link.legacyVoiceDownsamplers[message.sessionID] = LegacyVoiceDownsampler()
                    }
                    var downsampler = link.legacyVoiceDownsamplers[message.sessionID]
                        ?? LegacyVoiceDownsampler()
                    wireMessage = Self.legacyCompatibleWalkieTalkieMessage(
                        message,
                        downsampler: &downsampler
                    )
                    if message.kind == .ended {
                        link.legacyVoiceDownsamplers.removeValue(forKey: message.sessionID)
                    } else {
                        link.legacyVoiceDownsamplers[message.sessionID] = downsampler
                    }
                }
                let wireEnvelope = MeshEnvelope(
                    type: envelope.type,
                    nodeID: envelope.nodeID,
                    walkieTalkieHopCount: envelope.walkieTalkieHopCount,
                    walkieTalkieRelayTargetIDs: envelope.walkieTalkieRelayTargetIDs,
                    walkieTalkie: wireMessage
                )
                guard let data = try? wireEnvelope.encodedLine() else { continue }
                enqueueRealtimeVoice(
                    .init(kind: wireMessage.kind, sessionID: wireMessage.sessionID, data: data),
                    to: link
                )
            }
            return
        }
        guard let data = try? envelope.encodedLine() else { return }
        for link in links { send(data, to: link) }
    }

    private func enqueueRealtimeVoice(_ item: RealtimeVoiceSendQueue.Item, to link: Link) {
        link.realtimeVoiceQueue.enqueue(item)
        drainRealtimeVoice(to: link)
    }

    private func drainRealtimeVoice(to link: Link) {
        guard !link.realtimeVoiceSendInFlight,
              let item = link.realtimeVoiceQueue.popFirst()
        else { return }
        link.realtimeVoiceSendInFlight = true
        sendWire(item.data, to: link) { [weak self, weak link] error in
            guard let self, let link else { return }
            self.queue.async {
                guard self.links[ObjectIdentifier(link.connection)] === link else { return }
                link.realtimeVoiceSendInFlight = false
                if error != nil {
                    self.cancel(link)
                } else {
                    self.drainRealtimeVoice(to: link)
                }
            }
        }
    }

    private func send(_ data: Data, to link: Link) {
        sendWire(data, to: link)
    }

    private func sendWire(_ data: Data, to link: Link, completion: ((Error?) -> Void)? = nil) {
        if let channel = link.secureChannel {
            guard data.count <= SecurePeerChannel.maximumPayloadBytes else {
                completion?(SecurePeerChannelError.oversized); cancel(link); return
            }
            channel.send(payload: data) { result in
                switch result { case .success: completion?(nil); case .failure(let error): completion?(error) }
            }
        } else {
            // A secure room must never reach an unwrapped connection write.
            guard room.transportPolicy == .legacyOnly else { completion?(SecurePeerChannelError.notAuthenticated); cancel(link); return }
            link.connection.send(content: data, completion: .contentProcessed { completion?($0) })
        }
    }
}
