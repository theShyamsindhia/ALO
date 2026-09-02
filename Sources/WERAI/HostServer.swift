import Foundation
import Network
import WERAICore

final class HostServer {
    static let serviceType = "_werai-audio._tcp"
    /// Gives the reliable TCP control command time to reach every receiver before
    /// the UDP audio packet that becomes the shared restart point.
    static let coordinatedResyncLeadNanos: UInt64 = 500_000_000
    enum AudioBackpressurePolicy {
        case unbounded
        case boundedLatest(maxInFlight: Int)
    }
    typealias OutboundSend = (
        _ connection: NWConnection,
        _ data: Data,
        _ isComplete: Bool,
        _ completion: @escaping (NWError?) -> Void
    ) -> Void

    private final class Client {
        let control: NWConnection
        let decoder = ControlLineDecoder()
        var audio: NWConnection?
        var video: NWConnection?
        var id: String?
        var name: String?
        var volume: Double = 1
        var isMuted = false
        var recommendedPlayoutDelayNanos = RoomTiming.defaultPlayoutDelayNanos
        var lastSyncReportNanos: UInt64?
        var audioSendsInFlight = 0
        var pendingAudio: Data?
        var syncReport: PlaybackSyncReport?
        var lastResyncCommandNanos: UInt64 = 0
        var lastManualResyncRequestNanos: UInt64 = 0

        init(control: NWConnection) {
            self.control = control
        }
    }

    private let queue = DispatchQueue(label: "in.werai.host.network", qos: .userInteractive)
    private let roomName: String
    private let statusHandler: ((String) -> Void)?
    private let receiverCountHandler: ((Int) -> Void)?
    private let advertise: Bool
    private let listenerReadyHandler: ((NWEndpoint.Port) -> Void)?
    private let outboundSend: OutboundSend?
    private let audioBackpressurePolicy: AudioBackpressurePolicy
    private let playbackRequestHandler: ((RoomMediaCommand) -> Bool)?
    private let localParticipantID: String?
    private let packetizer = AudioPacketizer()
    private var listener: NWListener?
    private var clients = [ObjectIdentifier: Client]()
    private var videoEnabled = false
    private var nowPlaying = NowPlayingMedia()
    private var roomPlaybackIsPlaying = true
    private var lastAudioCaptureNanos: UInt64?
    private var mediaQueue = [RoomQueueItem]()
    private var groupPlayoutDelayNanos = RoomTiming.defaultPlayoutDelayNanos
    private var lastGroupDelayAdjustmentNanos: UInt64 = 0
    // Nil until the first audio packet. Once the timeline is active, only clients
    // already joined at that instant may influence its adaptive shared delay.
    private var timingEligibleClients: Set<ObjectIdentifier>?

    init(
        roomName: String,
        statusHandler: ((String) -> Void)? = nil,
        receiverCountHandler: ((Int) -> Void)? = nil,
        advertise: Bool = true,
        listenerReadyHandler: ((NWEndpoint.Port) -> Void)? = nil,
        outboundSend: OutboundSend? = nil,
        audioBackpressurePolicy: AudioBackpressurePolicy = .boundedLatest(maxInFlight: 8),
        playbackRequestHandler: ((RoomMediaCommand) -> Bool)? = nil,
        localParticipantID: String? = nil
    ) {
        self.roomName = roomName
        self.statusHandler = statusHandler
        self.receiverCountHandler = receiverCountHandler
        self.advertise = advertise
        self.listenerReadyHandler = listenerReadyHandler
        self.outboundSend = outboundSend
        self.audioBackpressurePolicy = audioBackpressurePolicy
        self.playbackRequestHandler = playbackRequestHandler
        self.localParticipantID = localParticipantID
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        if advertise {
            listener.service = NWListener.Service(name: roomName, type: Self.serviceType)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Room \"\(self.roomName)\" is visible on the local network.")
                self.statusHandler?("Room is visible on your local network")
                if let port = listener.port {
                    self.listenerReadyHandler?(port)
                }
            case .failed(let error):
                fputs("Host listener failed: \(error)\n", stderr)
                self.statusHandler?("Could not open the room: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for client in clients.values {
                client.audio?.cancel()
                client.video?.cancel()
                client.control.cancel()
            }
            clients.removeAll()
            receiverCountHandler?(0)
        }
    }

    func acceptAudio(samples: [Int16], captureTimeNanos: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            let captureGap = lastAudioCaptureNanos.map {
                captureTimeNanos > $0 ? captureTimeNanos - $0 : 0
            }
            lastAudioCaptureNanos = captureTimeNanos
            guard roomPlaybackIsPlaying else { return }
            if let captureGap, captureGap > 500_000_000 {
                // System media keys can pause the source app directly on the
                // broadcaster. When capture resumes, make it a fresh stream
                // boundary instead of appending to the pre-pause timeline.
                packetizer.discardPendingSamples()
                broadcast(coordinatedResyncMessage(nowNanos: captureTimeNanos))
            }
            let packets = self.packetizer.append(
                samples: samples,
                captureTimeNanos: captureTimeNanos
            )
            guard !packets.isEmpty else { return }
            let audioClientEntries = self.clients.filter { $0.value.audio != nil }
            if self.timingEligibleClients == nil {
                self.timingEligibleClients = Set(audioClientEntries.compactMap { identifier, client in
                    client.id != nil ? identifier : nil
                })
            }

            let audioClients = audioClientEntries.map(\.value)
            for packet in packets {
                let data = packet.encoded()
                for client in audioClients {
                    self.sendAudio(data, to: client)
                }
            }
        }
    }

    func acceptVideo(_ frame: VideoFrame) {
        let data = frame.encoded()
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.clients.values.compactMap(\.video) {
                self.send(data, over: connection, isComplete: true) { error in
                    if let error {
                        fputs("Video send failed: \(error)\n", stderr)
                    }
                }
            }
        }
    }

    func setVideoEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.videoEnabled = enabled
            self.broadcast(ControlMessage(type: "media_state", videoEnabled: enabled))
        }
    }

    func setNowPlaying(_ media: NowPlayingMedia) {
        queue.async { [weak self] in
            guard let self else { return }
            let sourcePlaybackChanged = media.isPlaying.map {
                $0 != self.roomPlaybackIsPlaying
            } ?? false
            if let sourceIsPlaying = media.isPlaying, sourcePlaybackChanged {
                // The broadcaster's real macOS media session is the sole source
                // of truth. ALO and listener controls only request a change; the
                // room changes after Now Playing confirms what the source did.
                self.roomPlaybackIsPlaying = sourceIsPlaying
                self.packetizer.discardPendingSamples()
            }
            let presentedMedia = NowPlayingMedia(
                title: media.title,
                artist: media.artist,
                album: media.album,
                artworkData: media.artworkData,
                sourceURL: media.sourceURL,
                isPlaying: media.isPlaying ?? self.roomPlaybackIsPlaying
            )
            if presentedMedia != self.nowPlaying {
                self.nowPlaying = presentedMedia
                self.broadcast(ControlMessage(type: "now_playing", nowPlaying: presentedMedia))
            }
            if sourcePlaybackChanged {
                self.broadcast(ControlMessage(
                    type: "room_playback",
                    isPlaying: self.roomPlaybackIsPlaying
                ))
                // A confirmed play always starts all receivers on the same fresh
                // source position. Pause clears anything already scheduled.
                self.broadcast(self.coordinatedResyncMessage())
            }
        }
    }

    func setParticipantLevel(id: String, volume: Double, muted: Bool) {
        queue.async { [weak self] in
            guard let self,
                  let client = self.clients.values.first(where: { $0.id == id })
            else { return }
            self.applyLevel(to: client, volume: volume, muted: muted)
        }
    }

    /// Used by the broadcaster's own UI. This deliberately bypasses its
    /// loopback receiver so controls cannot disappear during media reconnects.
    @discardableResult
    func sendRoomMediaCommand(_ command: RoomMediaCommand) -> Bool {
        queue.sync { applyRoomMediaCommand(command) }
    }

    func requestResync(participantID: String? = nil) -> Bool {
        queue.sync { sendCoordinatedResync(targetID: participantID) }
    }

    func removeQueueItem(id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.removeQueueItem(id: id, requestedBy: nil)
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(control: connection)
        let identifier = ObjectIdentifier(connection)
        clients[identifier] = client

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                print("Receiver connected from \(connection.endpoint).")
            case .failed, .cancelled:
                self.removeClient(identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveControl(for: client, identifier: identifier)
    }

    private func receiveControl(for client: Client, identifier: ObjectIdentifier) {
        client.control.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                for message in client.decoder.append(data) {
                    self.handle(message, for: client)
                }
            }
            if isComplete || error != nil {
                self.removeClient(identifier)
                return
            }
            self.receiveControl(for: client, identifier: identifier)
        }
    }

    private func handle(_ message: ControlMessage, for client: Client) {
        switch message.type {
        case "join":
            guard let udpPort = message.udpPort,
                  let videoPort = message.videoPort,
                  let port = NWEndpoint.Port(rawValue: udpPort),
                  let videoEndpointPort = NWEndpoint.Port(rawValue: videoPort),
                  case .hostPort(let host, _) = client.control.endpoint
            else { return }

            let proposedName = message.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Mac"
            client.id = message.participantID ?? UUID().uuidString
            client.name = uniqueName(for: proposedName, client: client)
            client.audio?.cancel()
            client.audioSendsInFlight = 0
            client.pendingAudio = nil
            let connection = NWConnection(host: host, port: port, using: .udp)
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    fputs("Audio path failed: \(error)\n", stderr)
                }
            }
            connection.start(queue: queue)
            client.audio = connection

            client.video?.cancel()
            let videoConnection = NWConnection(host: host, port: videoEndpointPort, using: .tcp)
            videoConnection.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    fputs("Video path failed: \(error)\n", stderr)
                }
            }
            videoConnection.start(queue: queue)
            client.video = videoConnection
            if let data = try? ControlMessage(
                type: "welcome",
                displayName: client.name,
                participantID: client.id
            ).encodedLine() {
                send(data, over: client.control)
            }
            broadcastPresence()
            if let data = try? ControlMessage(type: "media_state", videoEnabled: videoEnabled).encodedLine() {
                send(data, over: client.control)
            }
            if let data = try? ControlMessage(
                type: "now_playing",
                nowPlaying: nowPlaying
            ).encodedLine() {
                send(data, over: client.control)
            }
            if let data = try? ControlMessage(
                type: "room_playback",
                isPlaying: roomPlaybackIsPlaying
            ).encodedLine() {
                send(data, over: client.control)
            }
            sendQueue(to: client)
            sendTiming(to: client)

        case "ping":
            guard let id = message.id, let clientNanos = message.clientNanos else { return }
            let pong = ControlMessage(
                type: "pong",
                id: id,
                clientNanos: clientNanos,
                hostNanos: MonotonicClock.nowNanos()
            )
            if let data = try? pong.encodedLine() {
                send(data, over: client.control)
            }

        case "sync_report":
            guard client.id != nil, let recommendation = message.playoutDelayNanos else { return }
            client.recommendedPlayoutDelayNanos = RoomTiming.clampedPlayoutDelay(recommendation)
            client.lastSyncReportNanos = MonotonicClock.nowNanos()
            updateGroupTiming()

        case "chat":
            let trimmed = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let sender = client.name, !trimmed.isEmpty else { return }
            broadcast(ControlMessage(
                type: "chat",
                sender: sender,
                text: String(trimmed.prefix(2_000)),
                sentNanos: MonotonicClock.nowNanos()
            ))

        case "queue_add":
            guard let sender = client.name,
                  let senderID = client.id,
                  let proposed = message.queueItem,
                  mediaQueue.count < 100,
                  let url = validMediaURL(String(proposed.url.prefix(2_048)))
            else { return }
            let title = String(proposed.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
            guard !title.isEmpty else { return }
            let subtitle = proposed.subtitle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(180)
                .description
            mediaQueue.append(RoomQueueItem(
                title: title,
                subtitle: subtitle?.isEmpty == false ? subtitle : nil,
                url: url.absoluteString,
                addedBy: sender,
                addedByID: senderID,
                addedNanos: MonotonicClock.nowNanos()
            ))
            broadcastQueue()

        case "queue_remove":
            guard let id = message.queueItemID else { return }
            removeQueueItem(id: id, requestedBy: client.id)

        case "set_level":
            guard message.targetID == client.id else { return }
            applyLevel(
                to: client,
                volume: message.volume ?? client.volume,
                muted: message.muted ?? client.isMuted
            )

        case "set_playback", "media_command":
            guard client.id != nil,
                  let command = message.mediaCommand
                    ?? message.isPlaying.map({ $0 ? .play : .pause })
            else { return }
            _ = applyRoomMediaCommand(command)

        case "sync_status":
            guard message.participantID == client.id, let report = message.syncReport else { return }
            let previousResyncCount = client.syncReport?.resyncCount ?? 0
            let receiverAlreadyResynced = report.resyncCount > previousResyncCount
            client.syncReport = report
            let now = MonotonicClock.nowNanos()
            if report.latenessNanos > SynchronizedPlayer.hardResyncThresholdNanos,
               !receiverAlreadyResynced,
               now - client.lastResyncCommandNanos > 2_000_000_000 {
                client.lastResyncCommandNanos = now
                if let data = try? coordinatedResyncMessage(nowNanos: now).encodedLine() {
                    send(data, over: client.control)
                }
            }

        case "resync_request":
            guard client.id != nil else { return }
            let now = MonotonicClock.nowNanos()
            guard now - client.lastManualResyncRequestNanos >= 750_000_000 else { return }
            client.lastManualResyncRequestNanos = now
            // A plain stop/start on each receiver races the TCP command against
            // the UDP stream. Give every selected receiver one future capture
            // timestamp so they all discard the same old audio and restart on
            // the same packet, just as a new broadcast would.
            _ = sendCoordinatedResync(targetID: message.targetID, nowNanos: now)

        default:
            break
        }
    }

    private func coordinatedResyncMessage(
        nowNanos: UInt64 = MonotonicClock.nowNanos()
    ) -> ControlMessage {
        ControlMessage(
            type: "resync",
            hostNanos: nowNanos &+ Self.coordinatedResyncLeadNanos
        )
    }

    private func applyRoomMediaCommand(_ command: RoomMediaCommand) -> Bool {
        // Do not maintain a second, synthetic room state here. macOS may accept
        // a media command without the player changing state. NowPlayingMonitor
        // will call setNowPlaying only when the broadcaster's source actually
        // pauses or plays, and that confirmed state is what listeners receive.
        playbackRequestHandler?(command) == true
    }

    private func sendCoordinatedResync(
        targetID: String?,
        nowNanos: UInt64 = MonotonicClock.nowNanos()
    ) -> Bool {
        guard let data = try? coordinatedResyncMessage(nowNanos: nowNanos).encodedLine() else { return false }
        if let targetID {
            guard let target = clients.values.first(where: { $0.id == targetID }) else { return false }
            send(data, over: target.control)
            return true
        } else {
            let targets = clients.values.filter { $0.id != nil }
            guard !targets.isEmpty else { return false }
            for target in targets {
                send(data, over: target.control)
            }
            return true
        }
    }

    private func removeClient(_ identifier: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: identifier) else { return }
        timingEligibleClients?.remove(identifier)
        client.audio?.cancel()
        client.video?.cancel()
        receiverCountHandler?(participantNames.count)
        broadcastPresence()
        updateGroupTiming()
    }

    private var participantNames: [String] {
        clients.values.compactMap(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var participantDetails: [RoomParticipant] {
        clients.values.compactMap { client in
            guard let id = client.id, let name = client.name else { return nil }
            return RoomParticipant(id: id, name: name, volume: client.volume, isMuted: client.isMuted)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniqueName(for proposedName: String, client: Client) -> String {
        let shortened = String(proposedName.prefix(40))
        let base = shortened.isEmpty ? "Mac" : shortened
        let existing = clients.values
            .filter { $0 !== client }
            .compactMap(\.name)
        var candidate = base
        var suffix = 2
        while existing.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(base) (\(suffix))"
            suffix += 1
        }
        return candidate
    }

    private func broadcastPresence() {
        let names = participantNames
        receiverCountHandler?(names.count)
        broadcast(ControlMessage(
            type: "presence",
            participants: names,
            participantDetails: participantDetails
        ))
    }

    private func sendQueue(to client: Client) {
        guard let data = try? ControlMessage(
            type: "queue_update",
            mediaQueue: mediaQueue
        ).encodedLine() else { return }
        send(data, over: client.control)
    }

    private func sendTiming(to client: Client) {
        guard let data = try? ControlMessage(
            type: "sync_timing",
            playoutDelayNanos: groupPlayoutDelayNanos
        ).encodedLine() else { return }
        send(data, over: client.control)
    }

    private func updateGroupTiming() {
        let now = MonotonicClock.nowNanos()
        let activeRecommendations = clients.compactMap { identifier, client -> UInt64? in
            if let timingEligibleClients, !timingEligibleClients.contains(identifier) { return nil }
            if client.id == localParticipantID { return nil }
            guard let reportedAt = client.lastSyncReportNanos,
                  now >= reportedAt,
                  now - reportedAt <= 5_000_000_000
            else { return nil }
            return client.recommendedPlayoutDelayNanos
        }
        // Once audio has established a timeline, losing the original reporters
        // must not make later joiners indirectly pull that timeline backward.
        if timingEligibleClients != nil, activeRecommendations.isEmpty { return }
        let desired = Self.consensusPlayoutDelay(activeRecommendations)

        let next: UInt64
        if desired > groupPlayoutDelayNanos {
            next = desired
        } else if desired < groupPlayoutDelayNanos,
                  now - lastGroupDelayAdjustmentNanos >= 2_000_000_000 {
            next = max(desired, groupPlayoutDelayNanos - 10_000_000)
        } else {
            return
        }
        guard next != groupPlayoutDelayNanos else { return }

        groupPlayoutDelayNanos = next
        lastGroupDelayAdjustmentNanos = now
        broadcast(ControlMessage(
            type: "sync_timing",
            playoutDelayNanos: groupPlayoutDelayNanos
        ))
        print("Room timing adjusted to \(groupPlayoutDelayNanos / 1_000_000) ms.")
    }

    /// A single CPU-starved listener must not add latency to every healthy Mac.
    /// The lower median requires a majority to agree before the shared buffer grows,
    /// while a one-listener room can still adapt to that listener's network.
    static func consensusPlayoutDelay(_ recommendations: [UInt64]) -> UInt64 {
        guard !recommendations.isEmpty else { return RoomTiming.defaultPlayoutDelayNanos }
        let sorted = recommendations.map(RoomTiming.clampedPlayoutDelay).sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    private func broadcastQueue() {
        broadcast(ControlMessage(type: "queue_update", mediaQueue: mediaQueue))
    }

    private func removeQueueItem(id: String, requestedBy participantID: String?) {
        guard let index = mediaQueue.firstIndex(where: { item in
            item.id == id && (participantID == nil || item.addedByID == participantID)
        }) else { return }
        mediaQueue.remove(at: index)
        broadcastQueue()
    }

    private func validMediaURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else { return nil }
        return url
    }

    private func applyLevel(to client: Client, volume: Double, muted: Bool) {
        client.volume = min(max(volume, 0), 1)
        client.isMuted = muted
        guard let id = client.id else { return }
        let message = ControlMessage(
            type: "level",
            targetID: id,
            volume: client.volume,
            muted: muted
        )
        if let data = try? message.encodedLine() {
            send(data, over: client.control)
        }
        broadcastPresence()
    }

    private func broadcast(_ message: ControlMessage) {
        guard let data = try? message.encodedLine() else { return }
        for client in clients.values where client.name != nil {
            send(data, over: client.control)
        }
    }

    private func send(
        _ data: Data,
        over connection: NWConnection,
        isComplete: Bool = false,
        completion: @escaping (NWError?) -> Void = { _ in }
    ) {
        if let outboundSend {
            outboundSend(connection, data, isComplete, completion)
        } else {
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed(completion)
            )
        }
    }

    private func sendAudio(_ data: Data, to client: Client) {
        guard let connection = client.audio else { return }
        switch audioBackpressurePolicy {
        case .unbounded:
            send(data, over: connection, isComplete: true)

        case .boundedLatest(let maxInFlight):
            guard client.audioSendsInFlight < max(1, maxInFlight) else {
                // Audio timestamps define the shared timeline, so keeping an old queued
                // packet is worse than replacing it with the newest available packet.
                client.pendingAudio = data
                return
            }
            client.audioSendsInFlight += 1
            send(data, over: connection, isComplete: true) { [weak self, weak client] error in
                guard let self, let client else { return }
                self.queue.async { [weak self, weak client] in
                    guard let self, let client else { return }
                    client.audioSendsInFlight = max(0, client.audioSendsInFlight - 1)
                    if let error {
                        fputs("Audio send failed: \(error)\n", stderr)
                        if client.audio === connection {
                            connection.cancel()
                            client.audio = nil
                            client.pendingAudio = nil
                        }
                        return
                    }
                    guard let pending = client.pendingAudio else { return }
                    client.pendingAudio = nil
                    self.sendAudio(pending, to: client)
                }
            }
        }
    }
}
