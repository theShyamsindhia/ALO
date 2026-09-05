import CryptoKit
import Foundation
import Network
import ALOCore

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

final class MeshControlPlane: @unchecked Sendable {
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
        var arenaSendQueue = ArenaSendQueue()
        var arenaReceiveWindow: UInt64 = 0
        var arenaReceiveCount = 0
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

    let room: RoomConfiguration
    let nodeID: String
    private var roomIcon: RoomIcon?
    private let roomIconHandler: (RoomIcon) -> Void
    private var advertisedRecord = [String: String]()
    private var displayName: String
    private var deviceIcon: String
    private var deviceColorHex: String
    private var profileImageData: Data?
    private let queue = DispatchQueue(label: "in.werai.mesh.control", qos: .userInteractive)
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
    private var replica: MeshRoomReplica
    private let roomStateSync: any RoomStateSync
    private let roomStatePersistenceHandler: (Data) -> Void
    private let roomStateReceiveCompletedHandler: ([MeshRoomEvent]) -> Void
    private let arenaHandler: (String, Data) -> Void
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

    init(
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
        roomStatePersistenceHandler: @escaping (Data) -> Void = { _ in },
        roomStateSyncOverride: (any RoomStateSync)? = nil,
        roomStateReceiveCompletedHandler: @escaping ([MeshRoomEvent]) -> Void = { _ in },
        roomStateDowngradeHandler: @escaping (String?) -> Void = { _ in },
        disableRoomStateSyncDuringAuthenticationForTesting: Bool = false,
        connectionAttemptHandler: @escaping () -> Void = {}
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
        self.arenaHandler = arenaHandler
        let durableState: any RoomStateSync = roomStateSyncOverride
            ?? AutomergeRoomStateSync.recovering(
                roomID: room.id,
                savedDocument: initialRoomStateDocument,
                legacyEvents: initialEvents
            )
        self.roomStateSync = durableState
        self.roomStateSyncDisabled = false
        let durableEvents = (try? durableState.snapshot().events) ?? []
        self.replica = MeshRoomReplica(events: initialEvents + durableEvents)
        self.roomStatePersistenceHandler = roomStatePersistenceHandler
        self.roomStateReceiveCompletedHandler = roomStateReceiveCompletedHandler
        self.roomStateDowngradeHandler = roomStateDowngradeHandler
        self.disableRoomStateSyncDuringAuthenticationForTesting =
            disableRoomStateSyncDuringAuthenticationForTesting
        self.listenerReadyHandler = listenerReadyHandler
        self.connectionAttemptHandler = connectionAttemptHandler
        self.replicaHandler = replicaHandler
        self.participantsHandler = participantsHandler
    }

    func start(advertise: Bool = true) throws {
        isStopped = false
        advertisedRecord = [:]
        let listener = try NWListener(using: LocalNetworkParameters.tcp(), on: .any)
        self.listener = listener
        if advertise {
            refreshAdvertisement()
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = listener.port { self?.listenerReadyHandler?(port) }
        }
        listener.start(queue: queue)
        self.listener = listener

        if advertise {
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

    func updateRoomIcon(_ icon: RoomIcon) {
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
            type: MeshRoomBrowser.serviceType, txtRecord: NWTXTRecord(record)
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

    func stop(completion: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in
            isStopped = true
            browser?.cancel()
            listener?.cancel()
            heartbeatTimer?.cancel()
            reconnectWorkItems.values.forEach { $0.cancel() }
            roomStatePersistenceWorkItem?.cancel()
            roomStatePersistenceWorkItem = nil
            let durableState = roomStateSync
            let persist = roomStatePersistenceHandler
            roomStateWorkerQueue.async {
                _ = try? durableState.compactIfNeeded()
                persist(durableState.save())
                completion()
            }
            links.values.forEach { $0.connection.cancel() }
            browser = nil
            listener = nil
            heartbeatTimer = nil
            links.removeAll()
            peers.removeAll()
            remoteParticipants.removeAll()
            lastPublishedParticipants.removeAll()
            reconnectWorkItems.removeAll()
            reconnectAttempts.removeAll()
            pendingRoomActions.removeAll()
            seenWalkieMessages.removeAll()
            seenWalkieMessageOrder.removeAll()
        }
    }

    /// Direct authenticated links only. One in-flight packet, bounded priority lifecycle queue, and one latest frame per peer.
    func publishArena(_ data: Data, targetID: String?) {
        guard data.count <= 8192, let packet = try? JSONDecoder().decode(ArenaPacket.self, from: data), packet.isValid else { return }
        queue.async { [weak self] in
            guard let self, !self.isStopped,
                  let wire = try? MeshEnvelope(type: "arena", nodeID: self.nodeID, arenaData: data).encodedLine()
            else { return }
            let destinations = targetID.map { id in self.peers[id].map { [$0] } ?? [] } ?? Array(self.peers.values)
            for link in destinations where link.authenticated {
                link.arenaSendQueue.enqueue(kind: packet.kind.rawValue, data: wire)
                self.drainArena(to: link)
            }
        }
    }

    private func drainArena(to link: Link) {
        guard !link.arenaSendInFlight, let data = link.arenaSendQueue.popFirst() else { return }
        link.arenaSendInFlight = true
        link.connection.send(content: data, completion: .contentProcessed { [weak self, weak link] error in
            guard let self, let link else { return }
            self.queue.async {
                link.arenaSendInFlight = false
                if error != nil { link.arenaSendQueue = ArenaSendQueue(); link.connection.cancel() }
                else if !self.isStopped { self.drainArena(to: link) }
            }
        })
    }

    func publishChat(_ text: String) {
        publish(
            kind: .chat,
            senderID: nodeID,
            sender: displayName,
            text: String(text.prefix(2_000)),
            sentNanos: MonotonicClock.nowNanos()
        )
    }

    func publishQueueAdd(_ item: RoomQueueItem) { publish(kind: .queueAdd, queueItem: item) }
    func publishQueueRemove(_ id: String) { publish(kind: .queueRemove, queueItemID: id) }
    func publishQueueReorder(_ ids: [String]) {
        publish(kind: .queueReorder, senderID: nodeID, queueOrder: ids)
    }

    func updateIdentity(name: String, icon: String, colorHex: String) {
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

    func updateIdentity(name: String, icon: String, colorHex: String, profileImageData: Data?) {
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

    func publishWalkieTalkie(_ message: WalkieTalkieMessage) {
        queue.async { [weak self] in
            guard let self,
                  message.senderID == nodeID,
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

    func publishOpenLine(_ message: OpenLineMessage) {
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
    func publishMediaCommand(
        _ command: RoomMediaCommand,
        broadcasterID: String,
        broadcasterEpoch: UInt64
    ) -> Bool {
        queue.sync {
            guard let current = replica.broadcaster,
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
    func publishResyncRequest(
        targetID: String?,
        broadcasterID: String,
        broadcasterEpoch: UInt64
    ) -> Bool {
        queue.sync {
            guard let current = replica.broadcaster,
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

    func publishBroadcaster(active: Bool, mediaServiceName: String? = nil) {
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

    func publishPlayback(_ media: NowPlayingMedia) { publish(kind: .playback, nowPlaying: media) }
    func publishVideo(_ enabled: Bool, broadcasterID: String, broadcasterEpoch: UInt64) {
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
            if kind == .queueReorder {
                guard replica.broadcaster?.nodeID == nodeID,
                      let queueOrder, queueOrder.count <= 2_000,
                      Set(queueOrder).count == queueOrder.count,
                      Set(queueOrder) == Set(replica.queue.map(\.id)) else { return }
            }
            let event = MeshRoomEvent(
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
            _ = replica.merge([event])
            ingestDurableRoomState([event], excluding: nil)
            replicaHandler(replica)
            broadcast(MeshEnvelope(type: "event", event: event))
        }
    }

    private func consider(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .bonjour(let record) = result.metadata,
                  record["roomID"] == room.id,
                  let remoteID = record["nodeID"],
                  remoteID != nodeID,
                  nodeID < remoteID,
                  peers[remoteID] == nil,
                  !links.values.contains(where: { $0.nodeID == remoteID })
            else { continue }
            connect(to: result.endpoint, expectedNodeID: remoteID)
        }
    }

    private func connect(to endpoint: NWEndpoint, expectedNodeID: String?) {
        connectionAttemptHandler()
        let connection = NWConnection(to: endpoint, using: LocalNetworkParameters.tcp())
        let link = Link(
            connection: connection,
            initiated: true,
            roomStateSyncSession: roomStateSync.makeSession()
        )
        link.nodeID = expectedNodeID
        register(link)
    }

    private func accept(_ connection: NWConnection) {
        register(Link(
            connection: connection,
            initiated: false,
            roomStateSyncSession: roomStateSync.makeSession()
        ))
    }

    private func register(_ link: Link) {
        let identifier = ObjectIdentifier(link.connection)
        links[identifier] = link
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

    private func hello(for link: Link, advertiseRoomStateSync: Bool = true) -> MeshEnvelope {
        let publicRoom = RoomConfiguration(
            id: room.id,
            name: room.name,
            creatorPeerID: room.creatorPeerID,
            isPrivate: room.isPrivate,
            accessKey: nil,
            joinedAt: room.joinedAt
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
            authNonce: room.isPrivate ? link.localNonce : nil
        )
    }

    private var accessProof: String? {
        guard room.isPrivate, let key = room.accessKey else { return nil }
        return Self.makeAccessProof(roomID: room.id, accessKey: key)
    }

    static func makeAccessProof(roomID: String, accessKey: String) -> String {
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
        if envelope.type == "hello" {
            guard envelope.room?.id == room.id,
                  envelope.room?.isPrivate == room.isPrivate,
                  let remoteID = envelope.nodeID,
                  remoteID.utf8.count <= 128,
                  (envelope.displayName?.utf8.count ?? 0) <= 160,
                  (envelope.appVersion?.utf8.count ?? 0) <= 64,
                  remoteID != nodeID
            else {
                link.connection.cancel()
                return
            }
            guard link.nodeID == nil || link.nodeID == remoteID else {
                // The discovered service no longer belongs to the advertised
                // peer. Do not reconnect forever to the same stale endpoint.
                link.nodeID = nil
                link.connection.cancel()
                return
            }
            let shouldBeInitiated = nodeID < remoteID
            guard link.initiated == shouldBeInitiated else {
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
            if room.isPrivate {
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
        case "arena":
            guard envelope.nodeID == remoteID, let data = envelope.arenaData, data.count <= 8192 else { return }
            let now = MonotonicClock.nowNanos()
            if now - min(now, link.arenaReceiveWindow) >= 1_000_000_000 {
                link.arenaReceiveWindow = now; link.arenaReceiveCount = 0
            }
            guard link.arenaReceiveCount < 90 else { return }
            link.arenaReceiveCount += 1
            arenaHandler(remoteID, data)
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
            let hopCount = envelope.walkieTalkieHopCount ?? 0
            guard let message = envelope.walkieTalkie,
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

    private func validRoomEvents(_ events: [MeshRoomEvent]) -> [MeshRoomEvent] {
        events.filter {
            $0.roomID == room.id && MeshRoomReplica.hasPlausibleCounters($0) && ($0.text?.utf8.count ?? 0) <= 8_192 &&
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

    private func publishParticipants() {
        let now = MonotonicClock.nowNanos()
        let local = RoomParticipant(
            id: nodeID,
            name: displayName,
            icon: deviceIcon,
            colorHex: deviceColorHex,
            profileImageData: profileImageData
        )
        let remote: [RoomParticipant] = remoteParticipants.compactMap { id, participant in
            guard peers[id] != nil || lastSeenNanos[id].map({ seen in
                now < seen || now - seen < participantLeaseNanos
            }) == true else { return nil }
            return participant
        }
        let participants = ([local] + remote).sorted { $0.name < $1.name }
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

    private func scheduleReconnect(to endpoint: NWEndpoint, peerID: String) {
        guard !isStopped, peers[peerID] == nil else { return }
        reconnectWorkItems.removeValue(forKey: peerID)?.cancel()
        let attempt = min((reconnectAttempts[peerID] ?? 0) + 1, 4)
        reconnectAttempts[peerID] = attempt
        let delayMillis = min(400 * (1 << (attempt - 1)), 3_200)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isStopped, peers[peerID] == nil else { return }
            reconnectWorkItems.removeValue(forKey: peerID)
            connect(to: endpoint, expectedNodeID: peerID)
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
        let event = MeshRoomEvent(
            roomID: room.id,
            version: replica.nextVersion(nodeID: nodeID),
            kind: .broadcaster,
            broadcasterID: broadcasterID,
            broadcasterEpoch: epoch,
            mediaServiceName: mediaServiceName,
            isBroadcasting: active
        )
        _ = replica.merge([event])
        replicaHandler(replica)
        broadcast(MeshEnvelope(type: "event", event: event))
    }

    private func retireExpiredBroadcasterIfNeeded(nowNanos: UInt64) {
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
        for id in expired { remoteParticipants.removeValue(forKey: id) }
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
            existing.connection.cancel()
        }
        link.authenticated = true
        peers[remoteID] = link
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
        guard let data = try? envelope.encodedLine() else { link.connection.cancel(); return }
        link.snapshotSendInFlight = true
        link.connection.send(content: data, completion: .contentProcessed { [weak self, weak link] error in
            guard let self, let link else { return }
            self.queue.async {
                link.snapshotSendInFlight = false
                guard error == nil else { link.connection.cancel(); return }
                self.drainSnapshot(to: link)
            }
        })
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
        link.connection.send(content: data, completion: .contentProcessed { [weak self, weak link] error in
            guard let self, let link else { return }
            self.queue.async {
                link.roomStateSyncSendInFlight = false
                guard error == nil else {
                    link.connection.cancel()
                    return
                }
                self.drainRoomStateSync(to: link)
            }
        })
    }

    private func scheduleRoomStatePersistence(delay: DispatchTimeInterval = .milliseconds(250)) {
        guard !isStopped else { return }
        roomStatePersistenceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isStopped else { return }
            roomStatePersistenceWorkItem = nil
            roomStateWorkerQueue.async { [weak self] in
                guard let self else { return }
                let document = roomStateSync.save()
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
            profileImageData: link.profileImageData
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
        link.connection.send(content: data, completion: .contentProcessed { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.queue.async {
                guard self.links[ObjectIdentifier(link.connection)] === link,
                      !link.authenticated
                else { return }
                link.connection.cancel()
            }
        })
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
        link.connection.send(content: item.data, completion: .contentProcessed { [weak self, weak link] error in
            guard let self, let link else { return }
            self.queue.async {
                guard self.links[ObjectIdentifier(link.connection)] === link else { return }
                link.realtimeVoiceSendInFlight = false
                if error != nil {
                    link.connection.cancel()
                } else {
                    self.drainRealtimeVoice(to: link)
                }
            }
        })
    }

    private func send(_ data: Data, to link: Link) {
        link.connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
