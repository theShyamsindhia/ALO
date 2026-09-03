import CryptoKit
import Foundation
import Network
import WERAICore

final class MeshControlPlane: @unchecked Sendable {
    static let identityEnvelopeType = "display_name"
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
        let localNonce = UUID().uuidString
        var authenticated = false

        init(connection: NWConnection, initiated: Bool) {
            self.connection = connection
            self.initiated = initiated
        }
    }

    let room: RoomConfiguration
    let nodeID: String
    private var displayName: String
    private var deviceIcon: String
    private var deviceColorHex: String
    private var profileImageData: Data?
    private let queue = DispatchQueue(label: "in.werai.mesh.control", qos: .userInteractive)
    private let replicaHandler: (MeshRoomReplica) -> Void
    private let participantsHandler: ([RoomParticipant]) -> Void
    private let peerVersionHandler: (String) -> Void
    private let mediaCommandHandler: (RoomMediaCommand, String, UInt64) -> Bool
    private let resyncRequestHandler: (String?, String, UInt64) -> Bool
    private let walkieTalkieHandler: (WalkieTalkieMessage) -> Void
    private let appVersion: String
    private let listenerReadyHandler: ((NWEndpoint.Port) -> Void)?
    private var replica: MeshRoomReplica
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
    private var reconnectAttempts = [String: Int]()
    private var reconnectWorkItems = [String: DispatchWorkItem]()
    private var seenRoomActionIDs = Set<String>()
    private var roomActionIDOrder = [String]()
    private var acceptedRoomActionIDs = Set<String>()
    private var pendingRoomActions = [String: PendingRoomAction]()
    private var isStopped = true
    private let heartbeatIntervalNanos: UInt64 = 400_000_000
    private let broadcasterLeaseNanos: UInt64 = 2_400_000_000
    private let maximumSyncEvents = 2_000

    init(
        room: RoomConfiguration,
        nodeID: String,
        displayName: String,
        deviceIcon: String? = nil,
        deviceColorHex: String? = nil,
        profileImageData: Data? = nil,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        initialEvents: [MeshRoomEvent] = [],
        listenerReadyHandler: ((NWEndpoint.Port) -> Void)? = nil,
        replicaHandler: @escaping (MeshRoomReplica) -> Void,
        participantsHandler: @escaping ([RoomParticipant]) -> Void,
        peerVersionHandler: @escaping (String) -> Void = { _ in },
        mediaCommandHandler: @escaping (RoomMediaCommand, String, UInt64) -> Bool = { _, _, _ in true },
        resyncRequestHandler: @escaping (String?, String, UInt64) -> Bool = { _, _, _ in true },
        walkieTalkieHandler: @escaping (WalkieTalkieMessage) -> Void = { _ in }
    ) {
        self.room = room
        self.nodeID = nodeID
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
        self.replica = MeshRoomReplica(events: initialEvents)
        self.listenerReadyHandler = listenerReadyHandler
        self.replicaHandler = replicaHandler
        self.participantsHandler = participantsHandler
    }

    func start(advertise: Bool = true) throws {
        isStopped = false
        let listener = try NWListener(using: .tcp, on: .any)
        if advertise {
            var txtRecord = [
                "roomID": room.id,
                "roomName": String(room.name.prefix(40)),
                "nodeID": nodeID,
                "private": room.isPrivate ? "1" : "0",
                "version": "1",
                "appVersion": appVersion,
            ]
            if let accessProof { txtRecord["accessProof"] = accessProof }
            listener.service = NWListener.Service(
                name: "\(room.id.prefix(8))-\(nodeID.prefix(8))",
                type: MeshRoomBrowser.serviceType,
                txtRecord: NWTXTRecord(txtRecord)
            )
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
                using: .tcp
            )
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.consider(results) }
            browser.start(queue: queue)
            self.browser = browser
        }
        publishParticipants()
        replicaHandler(replica)
        startHeartbeatTimer()
    }

    func connectForTesting(to endpoint: NWEndpoint) {
        queue.async { [weak self] in self?.connect(to: endpoint, expectedNodeID: nil) }
    }

    func disconnectForTesting(peerID: String) {
        queue.async { [weak self] in self?.peers[peerID]?.connection.cancel() }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            browser?.cancel()
            listener?.cancel()
            heartbeatTimer?.cancel()
            reconnectWorkItems.values.forEach { $0.cancel() }
            links.values.forEach { $0.connection.cancel() }
            browser = nil
            listener = nil
            heartbeatTimer = nil
            links.removeAll()
            peers.removeAll()
            reconnectWorkItems.removeAll()
            reconnectAttempts.removeAll()
            pendingRoomActions.removeAll()
        }
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

    func updateIdentity(name: String, icon: String, colorHex: String) {
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
                  message.senderName.utf8.count <= 160,
                  message.sessionID.utf8.count <= 128,
                  (message.pcm16Mono?.count ?? 0) <= 8_192
            else { return }
            let envelope = MeshEnvelope(type: "walkie_talkie", walkieTalkie: message)
            if let targetID = message.targetID {
                if let link = peers[targetID] { send(envelope, to: link) }
            } else {
                broadcast(envelope)
            }
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
                    epoch: replica.highestBroadcasterEpoch &+ 1,
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
        broadcasterID: String? = nil,
        broadcasterEpoch: UInt64? = nil,
        mediaServiceName: String? = nil,
        isBroadcasting: Bool? = nil,
        nowPlaying: NowPlayingMedia? = nil,
        videoEnabled: Bool? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
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
                broadcasterID: broadcasterID,
                broadcasterEpoch: broadcasterEpoch,
                mediaServiceName: mediaServiceName,
                isBroadcasting: isBroadcasting,
                nowPlaying: nowPlaying,
                videoEnabled: videoEnabled
            )
            _ = replica.merge([event])
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
        let connection = NWConnection(to: endpoint, using: .tcp)
        let link = Link(connection: connection, initiated: true)
        link.nodeID = expectedNodeID
        register(link)
    }

    private func accept(_ connection: NWConnection) {
        register(Link(connection: connection, initiated: false))
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

    private func hello(for link: Link) -> MeshEnvelope {
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
            let shouldBeInitiated = nodeID < remoteID
            guard link.initiated == shouldBeInitiated else {
                link.connection.cancel()
                return
            }
            link.nodeID = remoteID
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
        case "sync":
            merge(Array((envelope.events ?? []).prefix(maximumSyncEvents)), excluding: link)
            if let vector = envelope.versionVector {
                let missing = replica.missingEvents(comparedWith: vector)
                if !missing.isEmpty {
                    send(MeshEnvelope(type: "sync", events: Array(missing.prefix(maximumSyncEvents))), to: link)
                }
            }
        case "event":
            if let event = envelope.event { merge([event], excluding: link) }
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
            publishParticipants()
        case "walkie_talkie":
            guard let message = envelope.walkieTalkie,
                  message.senderID == remoteID,
                  message.senderName.utf8.count <= 160,
                  message.sessionID.utf8.count <= 128,
                  message.targetID == nil || message.targetID == nodeID,
                  (message.pcm16Mono?.count ?? 0) <= 8_192
            else { return }
            walkieTalkieHandler(message)
        default:
            break
        }
    }

    private func merge(_ events: [MeshRoomEvent], excluding source: Link) {
        let valid = events.prefix(maximumSyncEvents).filter {
            $0.roomID == room.id && ($0.text?.utf8.count ?? 0) <= 8_192 &&
                (try? JSONEncoder().encode($0).count).map { $0 <= 32_768 } == true
        }
        let inserted = replica.merge(valid)
        guard !inserted.isEmpty else { return }
        if let broadcaster = replica.broadcaster, broadcaster.nodeID != nodeID,
           lastSeenNanos[broadcaster.nodeID] == nil {
            lastSeenNanos[broadcaster.nodeID] = MonotonicClock.nowNanos()
        }
        replicaHandler(replica)
        for event in inserted { broadcast(MeshEnvelope(type: "event", event: event), excluding: source) }
    }

    private func publishParticipants() {
        let local = RoomParticipant(
            id: nodeID,
            name: displayName,
            icon: deviceIcon,
            colorHex: deviceColorHex,
            profileImageData: profileImageData
        )
        let remote = peers.compactMap { id, link in
            link.displayName.map {
                let appearance = DeviceAppearance.generated(from: id)
                return RoomParticipant(
                    id: id,
                    name: $0,
                    icon: link.deviceIcon ?? appearance.icon,
                    colorHex: link.deviceColorHex ?? appearance.colorHex,
                    profileImageData: link.profileImageData
                )
            }
        }
        participantsHandler(([local] + remote).sorted { $0.name < $1.name })
    }

    private func remove(_ link: Link) {
        guard links.removeValue(forKey: ObjectIdentifier(link.connection)) != nil else { return }
        let disconnectedID = link.nodeID
        if let id = link.nodeID, peers[id] === link {
            peers.removeValue(forKey: id)
        }
        publishParticipants()
        if link.initiated, let disconnectedID, nodeID < disconnectedID {
            scheduleReconnect(to: link.connection.endpoint, peerID: disconnectedID)
        }
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
        if let existing = peers[remoteID], existing !== link { existing.connection.cancel() }
        link.authenticated = true
        peers[remoteID] = link
        reconnectAttempts[remoteID] = 0
        reconnectWorkItems.removeValue(forKey: remoteID)?.cancel()
        lastSeenNanos[remoteID] = MonotonicClock.nowNanos()
        if let version = link.appVersion { peerVersionHandler(version) }
        publishParticipants()
        send(MeshEnvelope(
            type: "sync",
            events: Array(replica.events.suffix(maximumSyncEvents)),
            versionVector: replica.versionVector
        ), to: link)
    }

    private func broadcast(_ envelope: MeshEnvelope, excluding source: Link? = nil) {
        for link in peers.values where link !== source { send(envelope, to: link) }
    }

    private func send(_ envelope: MeshEnvelope, to link: Link) {
        guard let data = try? envelope.encodedLine() else { return }
        link.connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
