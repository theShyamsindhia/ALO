import Foundation
import Network
import ALOCore

final class HostServer {
    static let serviceType = "_werai-audio._tcp"
    /// Gives the reliable TCP control command time to reach every receiver before
    /// the UDP audio packet that becomes the shared restart point.
    static let coordinatedResyncLeadNanos: UInt64 = 500_000_000
    enum AudioBackpressurePolicy {
        case unbounded
        case boundedLatest(maxInFlight: Int)
    }
    // Preserve short capture/completion bursts without letting a slow peer
    // accumulate a growing timeline. This is separate from the socket limit.
    private static let maximumPendingAudioPackets = 16
    private static let maximumPendingAudioWaitNanos: UInt64 = 80_000_000
    private static let maximumPendingAudioSpanNanos: UInt64 = 80_000_000
    private static let maximumAudioCompletionSamples = 8
    private struct PendingAudio {
        let data: Data
        let captureTimeNanos: UInt64
        let enqueuedAtNanos: UInt64
    }
    struct AudioSenderSnapshot {
        let participantID: String
        let udpPort: UInt16
        let inFlight: Int
        let pending: Int
        let enqueued: UInt64
        let sent: UInt64
        let expiredWait: UInt64
        let expiredAge: UInt64
        let admissionRejected: UInt64
        let replaced: UInt64
        let discardedBoundary: UInt64
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
        var mediaSessionID: UUID?
        var audioSealer: DatagramSealer?
        var audio: NWConnection?
        var video: NWConnection?
        var videoQueue = VideoSendQueue()
        var videoSendToken: UUID?
        var id: String?
        var name: String?
        var volume: Double = 1
        var isMuted = false
        var recommendedPlayoutDelayNanos = RoomTiming.defaultPlayoutDelayNanos
        var outputLatencyPlayoutFloorNanos = RoomTiming.defaultPlayoutDelayNanos
        var lastSyncReportNanos: UInt64?
        var audioSendsInFlight = 0
        var pendingAudio: [PendingAudio] = []
        var audioBacklogCongested = false
        var audioEnqueued: UInt64 = 0
        var audioSent: UInt64 = 0
        var audioExpiredWait: UInt64 = 0
        var audioExpiredAge: UInt64 = 0
        var audioAdmissionRejected: UInt64 = 0
        // Local contentProcessed durations, not receiver acknowledgments or
        // measured network delivery. A bounded recent maximum is a conservative
        // admission estimate; it cannot guarantee a remote playback deadline.
        var audioCompletionDurations: [UInt64] = []
        var audioCompletionIntervals: [UInt64] = []
        var lastAudioCompletionNanos: UInt64?
        var audioReplaced: UInt64 = 0
        var audioDiscardedBoundary: UInt64 = 0
        var lastAudioAgeWarningNanos: UInt64?
        var syncReport: PlaybackSyncReport?
        var lastPlaybackReportNanos: UInt64?
        var lastResyncCommandNanos: UInt64 = 0
        var lastManualResyncRequestNanos: UInt64 = 0

        init(control: NWConnection) {
            self.control = control
        }
    }

    private let queue = DispatchQueue(label: "in.werai.host.network", qos: .userInteractive)
    private let mediaSecurity: RoomMediaSecurity?
    private let roomName: String
    private let statusHandler: ((String) -> Void)?
    private let receiverCountHandler: ((Int) -> Void)?
    private let advertise: Bool
    private let listenerReadyHandler: ((NWEndpoint.Port) -> Void)?
    private let outboundSend: OutboundSend?
    private let audioSendNowNanos: () -> UInt64
    private let audioBackpressurePolicy: AudioBackpressurePolicy
    private let playbackRequestHandler: ((RoomMediaCommand) -> Bool)?
    private let localParticipantID: String?
    private let packetizer = AudioPacketizer()
    private var listener: NWListener?
    private var clients = [ObjectIdentifier: Client]()
    private var videoEnabled = false
    private var nowPlaying = NowPlayingMedia()
    private var roomPlaybackIsPlaying = true
    private var requestedPlaybackState: Bool?
    private var requestedPlaybackStateSetNanos: UInt64?
    private var lastAudioCaptureNanos: UInt64?
    private var mediaQueue = [RoomQueueItem]()
    private var groupPlayoutDelayNanos = RoomTiming.defaultPlayoutDelayNanos
    // Nil until an audio packet sees at least one identified audible output.
    // The set contains only remote outputs that were already present at that
    // first playback boundary. It may intentionally be empty when the
    // broadcaster's local Receiver starts alone: a later listener must inherit
    // that established timeline instead of retiming and resetting it.
    private var timingEligibleClients: Set<ObjectIdentifier>?
    private var roomTimingChangeCount: UInt64 = 0
    private var videoKeyframeHandler: (() -> Void)?
    private var lastVideoKeyframeRequestNanos: UInt64 = 0

    func setVideoKeyframeHandler(_ handler: (() -> Void)?) {
        queue.async { [weak self] in self?.videoKeyframeHandler = handler }
    }

    init(
        roomName: String,
        mediaSecurity: RoomMediaSecurity? = nil,
        statusHandler: ((String) -> Void)? = nil,
        receiverCountHandler: ((Int) -> Void)? = nil,
        advertise: Bool = true,
        listenerReadyHandler: ((NWEndpoint.Port) -> Void)? = nil,
        outboundSend: OutboundSend? = nil,
        // Must be thread-safe: read on the owning queue and at send-callback entry.
        audioSendNowNanos: @escaping () -> UInt64 = MonotonicClock.nowNanos,
        audioBackpressurePolicy: AudioBackpressurePolicy = .boundedLatest(maxInFlight: 8),
        playbackRequestHandler: ((RoomMediaCommand) -> Bool)? = nil,
        localParticipantID: String? = nil
    ) {
        self.mediaSecurity = mediaSecurity
        self.roomName = roomName
        self.statusHandler = statusHandler
        self.receiverCountHandler = receiverCountHandler
        self.advertise = advertise
        self.listenerReadyHandler = listenerReadyHandler
        self.outboundSend = outboundSend
        self.audioSendNowNanos = audioSendNowNanos
        self.audioBackpressurePolicy = audioBackpressurePolicy
        self.playbackRequestHandler = playbackRequestHandler
        self.localParticipantID = localParticipantID
    }

    func start() throws {
        let listener = try NWListener(using: mediaSecurity?.tcp() ?? LocalNetworkParameters.tcp(), on: .any)
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
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            for client in clients.values {
                discardPendingAudio(for: client)
                client.audio?.cancel()
                client.video?.cancel()
                client.control.cancel()
            }
            clients.removeAll()
            receiverCountHandler?(0)
        }
    }

    func diagnosticsSnapshot() -> HostTimingDiagnostics {
        queue.sync {
            let now = MonotonicClock.nowNanos()
            let listeners = clients.values.filter { $0.id != nil && $0.id != localParticipantID }
            let reports = listeners.compactMap(\.syncReport)
            return HostTimingDiagnostics(
                listenerCount: listeners.count,
                reportingListenerCount: reports.count,
                groupBufferMilliseconds: Double(groupPlayoutDelayNanos) / 1_000_000,
                maximumLatenessMilliseconds: Double(reports.map(\.latenessNanos).max() ?? 0) / 1_000_000,
                totalResyncCount: reports.reduce(0) { $0 &+ $1.resyncCount },
                roomTimingChangeCount: roomTimingChangeCount,
                videoEnabled: videoEnabled,
                listeners: listeners.sorted { ($0.id ?? "") < ($1.id ?? "") }.prefix(64).map { client in
                    HostListenerTimingDiagnostics(
                        peerID: client.id ?? "unknown",
                        isTimingEligible: timingEligibleClients?.contains(ObjectIdentifier(client.control)) ?? true,
                        reportAgeMilliseconds: client.lastSyncReportNanos.map { Double(now >= $0 ? now - $0 : 0) / 1_000_000 },
                        recommendedBufferMilliseconds: Double(client.recommendedPlayoutDelayNanos) / 1_000_000,
                        hardwareFloorMilliseconds: Double(client.outputLatencyPlayoutFloorNanos) / 1_000_000,
                        audioEnqueued: client.audioEnqueued, audioSent: client.audioSent,
                        audioExpiredWait: client.audioExpiredWait, audioExpiredAge: client.audioExpiredAge,
                        audioAdmissionRejected: client.audioAdmissionRejected,
                        audioReplaced: client.audioReplaced, audioDiscardedBoundary: client.audioDiscardedBoundary,
                        driftMilliseconds: client.syncReport?.driftNanos.map { Double($0) / 1_000_000 },
                        driftSampleAgeMilliseconds: client.syncReport?.driftSampleAgeNanos.map { Double($0) / 1_000_000 },
                        playbackReportAgeMilliseconds: client.lastPlaybackReportNanos.map { Double(now >= $0 ? now - $0 : 0) / 1_000_000 },
                        screenTiming: client.syncReport?.screenTiming
                    )
                }
            )
        }
    }

    /// A queue-barrier snapshot, never a drain request or an expiry sweep.
    func audioSenderSnapshot() -> [AudioSenderSnapshot] {
        queue.sync {
            clients.values.compactMap { client in
                guard let id = client.id, let audio = client.audio,
                      case .hostPort(_, let port) = audio.endpoint else { return nil }
                return AudioSenderSnapshot(participantID: id, udpPort: port.rawValue,
                    inFlight: client.audioSendsInFlight, pending: client.pendingAudio.count,
                    enqueued: client.audioEnqueued, sent: client.audioSent,
                    expiredWait: client.audioExpiredWait, expiredAge: client.audioExpiredAge,
                    admissionRejected: client.audioAdmissionRejected,
                    replaced: client.audioReplaced, discardedBoundary: client.audioDiscardedBoundary)
            }
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
                _ = sendCoordinatedResync(targetID: nil, nowNanos: captureTimeNanos)
            }
            let packets = self.packetizer.append(
                samples: samples,
                captureTimeNanos: captureTimeNanos
            )
            guard !packets.isEmpty else { return }
            let audioClientEntries = self.clients.filter { $0.value.audio != nil }
            if self.timingEligibleClients == nil {
                let identifiedOutputs = audioClientEntries.filter { $0.value.id != nil }
                let initialRemoteListeners = identifiedOutputs.compactMap {
                    identifier, client -> ObjectIdentifier? in
                    guard let id = client.id, id != self.localParticipantID else { return nil }
                    return identifier
                }
                // Capture can start before any Receiver has joined the media
                // server, so an entirely empty transport does not establish a
                // timeline. The broadcaster's identified local output does.
                if !identifiedOutputs.isEmpty {
                    self.timingEligibleClients = Set(initialRemoteListeners)
                }
            }

            let audioClients = audioClientEntries.map(\.value)
            for packet in packets {
                let data = packet.encoded()
                for client in audioClients {
                    if let sealer = client.audioSealer {
                        if let protected = try? sealer.seal(data) {
                            self.sendAudio(protected, captureTimeNanos: packet.captureTimeNanos, to: client)
                        }
                    } else if self.mediaSecurity == nil {
                        self.sendAudio(data, captureTimeNanos: packet.captureTimeNanos, to: client)
                    }
                }
            }
        }
    }

    func acceptVideo(_ frame: VideoFrame) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = MonotonicClock.nowNanos()
            for client in self.clients.values where client.video != nil {
                client.videoQueue.append(frame, nowNanos: now)
                self.drainVideo(for: client)
                if client.videoSendToken == nil, client.videoQueue.requiresKeyframe {
                    self.requestVideoKeyframe(nowNanos: now)
                }
            }
        }
    }

    private func requestVideoKeyframe(nowNanos: UInt64) {
        guard nowNanos >= lastVideoKeyframeRequestNanos,
              nowNanos - lastVideoKeyframeRequestNanos >= 250_000_000 else { return }
        lastVideoKeyframeRequestNanos = nowNanos
        videoKeyframeHandler?()
    }

    private func drainVideo(for client: Client) {
        guard client.videoSendToken == nil, let connection = client.video,
              let entry = client.videoQueue.takeNext(nowNanos: MonotonicClock.nowNanos()) else { return }
        let token = UUID()
        client.videoSendToken = token
        send(entry.frame.encoded(), over: connection, isComplete: true) { [weak self, weak client] error in
            guard let self else { return }
            self.queue.async { [weak self, weak client] in
                guard let self, let client, client.video === connection,
                      client.videoSendToken == token else { return }
                client.videoSendToken = nil
                if error != nil { self.repairVideo(for: client, failedConnection: connection) }
                else { self.drainVideo(for: client) }
            }
        }
        // Healthy TCP backpressure can outlast a second. Keep recovery bounded
        // without repeatedly replacing a connection that is still draining.
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak client] in
            guard let self, let client, client.video === connection,
                  client.videoSendToken == token else { return }
            self.repairVideo(for: client, failedConnection: connection)
        }
    }

    private func repairVideo(for client: Client, failedConnection: NWConnection) {
        guard clients[ObjectIdentifier(client.control)] === client,
              client.video === failedConnection else { return }
        failedConnection.cancel()
        client.videoQueue.reset()
        client.videoSendToken = nil
        // This adapter is only the existing legacy media transport. Secure v2
        // will reopen a receiver-initiated, admitted video subscription instead.
        let replacement = NWConnection(to: failedConnection.endpoint, using: mediaSecurity?.tcp(video: true) ?? LocalNetworkParameters.tcp())
        replacement.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("Video repair path failed: \(error)\n", stderr)
            }
        }
        client.video = replacement
        replacement.start(queue: queue)
        requestVideoKeyframe(nowNanos: MonotonicClock.nowNanos())
    }

    func setVideoEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if enabled, !self.videoEnabled {
                for client in self.clients.values {
                    guard let report = client.syncReport else { continue }
                    // A previous share's static image cannot verify this start.
                    // Keep the independent audio measurements and report age.
                    client.syncReport = PlaybackSyncReport(measuredAtNanos: report.measuredAtNanos,
                        latenessNanos: report.latenessNanos, latePacketCount: report.latePacketCount,
                        resyncCount: report.resyncCount, driftNanos: report.driftNanos,
                        driftSampleAgeNanos: report.driftSampleAgeNanos)
                }
            }
            self.videoEnabled = enabled
            if !enabled {
                for client in self.clients.values { client.videoQueue.reset() }
            }
            self.broadcast(ControlMessage(type: "media_state", videoEnabled: enabled))
        }
    }

    func setNowPlaying(_ media: NowPlayingMedia) {
        queue.async { [weak self] in
            guard let self else { return }
            let sourcePlaybackChanged = media.isPlaying.map {
                $0 != self.roomPlaybackIsPlaying
            } ?? false
            if media.isPlaying != nil {
                self.requestedPlaybackState = nil
                self.requestedPlaybackStateSetNanos = nil
            }
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
                isPlaying: media.isPlaying ?? self.roomPlaybackIsPlaying,
                elapsedTime: media.elapsedTime,
                duration: media.duration
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
                // A confirmed play starts every synchronized output, including
                // the broadcaster's local return, on the same fresh source position.
                _ = self.sendCoordinatedResync(targetID: nil)
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
                if client.decoder.isOverflowed {
                    self.removeClient(identifier)
                    return
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
            // The publisher chooses a fresh nonce domain inside the PSK TLS channel.
            // Repeated joins on one connection must never reset its send sequence.
            guard client.id == nil else { return }
            if let mediaSecurity {
                let sessionID = UUID()
                guard let sealer = try? mediaSecurity.audioSealer(sessionID: sessionID) else {
                    client.control.cancel(); return
                }
                client.mediaSessionID = sessionID
                client.audioSealer = sealer
            }
            guard let udpPort = message.udpPort,
                  let videoPort = message.videoPort,
                  let port = NWEndpoint.Port(rawValue: udpPort),
                  let videoEndpointPort = NWEndpoint.Port(rawValue: videoPort),
                  case .hostPort(let host, _) = client.control.endpoint
            else { return }

            let proposedName = message.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Mac"
            let participantID = message.participantID ?? UUID().uuidString
            replaceStaleClient(for: participantID, with: client)
            client.id = participantID
            client.name = uniqueName(for: proposedName, client: client)
            client.audio?.cancel()
            client.audioSendsInFlight = 0
            client.audioCompletionDurations.removeAll()
            client.audioCompletionIntervals.removeAll()
            client.lastAudioCompletionNanos = nil
            discardPendingAudio(for: client)
            client.audioBacklogCongested = false
            let connection = NWConnection(
                host: host,
                port: port,
                using: LocalNetworkParameters.udp()
            )
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    fputs("Audio path failed: \(error)\n", stderr)
                }
            }
            connection.start(queue: queue)
            client.audio = connection

            client.video?.cancel()
            client.videoQueue.reset()
            client.videoSendToken = nil
            let videoConnection = NWConnection(
                host: host,
                port: videoEndpointPort,
                using: mediaSecurity?.tcp(video: true) ?? LocalNetworkParameters.tcp()
            )
            videoConnection.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    fputs("Video path failed: \(error)\n", stderr)
                }
            }
            videoConnection.start(queue: queue)
            client.video = videoConnection
            if let data = try? ControlMessage(
                type: "welcome",
                mediaSessionID: client.mediaSessionID,
                displayName: client.name,
                participantID: client.id
            ).encodedLine() {
                send(data, over: client.control)
            }
            sendLevel(to: client)
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
            client.outputLatencyPlayoutFloorNanos = RoomTiming.clampedPlayoutDelay(
                message.outputLatencyPlayoutFloorNanos ?? RoomTiming.defaultPlayoutDelayNanos
            )
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
            client.lastPlaybackReportNanos = now
            if client.id != localParticipantID,
               report.latenessNanos > SynchronizedPlayer.hardResyncThresholdNanos,
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

    /// A device keeps the same participant ID across room joins. Network
    /// cancellation is asynchronous, so a fast rejoin can reach the host before
    /// the old control path reports that it closed. Keeping both clients would
    /// fan every media packet out twice and, when UDP reuses the local port,
    /// deliver a duplicate stream to the replacement receiver.
    private func replaceStaleClient(for participantID: String, with replacement: Client) {
        let replacementIdentifier = ObjectIdentifier(replacement.control)
        guard let staleEntry = clients.first(where: { identifier, candidate in
            identifier != replacementIdentifier && candidate.id == participantID
        }) else { return }

        let (staleIdentifier, stale) = staleEntry
        clients.removeValue(forKey: staleIdentifier)

        replacement.volume = stale.volume
        replacement.isMuted = stale.isMuted
        replacement.recommendedPlayoutDelayNanos = stale.recommendedPlayoutDelayNanos
        replacement.outputLatencyPlayoutFloorNanos = stale.outputLatencyPlayoutFloorNanos

        if timingEligibleClients?.remove(staleIdentifier) != nil {
            timingEligibleClients?.insert(replacementIdentifier)
        }
        stale.audio?.cancel()
        discardPendingAudio(for: stale)
        stale.video?.cancel()
        stale.control.cancel()
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
        let now = MonotonicClock.nowNanos()
        if !Self.playbackIntentIsCurrent(
            setAtNanos: requestedPlaybackStateSetNanos,
            nowNanos: now
        ) {
            requestedPlaybackState = nil
            requestedPlaybackStateSetNanos = nil
        }
        let requestedState = RoomRemoteCommandCenter.playbackState(
            after: command,
            current: requestedPlaybackState ?? roomPlaybackIsPlaying
        )
        let sourceCommand = requestedState.map { $0 ? RoomMediaCommand.play : .pause }
            ?? command
        guard playbackRequestHandler?(sourceCommand) == true else { return false }
        if let requestedState {
            requestedPlaybackState = requestedState
            requestedPlaybackStateSetNanos = now
        }
        guard let requestedState, requestedState != roomPlaybackIsPlaying else { return true }

        // An accepted Pause request is not proof that the source obeyed it.
        // Keep forwarding capture until Now Playing confirms the pause so an
        // app that ignores media keys cannot latch the room silent forever.
        // Play is safe to apply optimistically: if the source stays paused no
        // capture arrives, while doing so releases a stale confirmed Pause.
        guard requestedState else { return true }

        // MediaRemote reports command acceptance synchronously, while browser
        // and third-party Now Playing metadata can lag. Apply an accepted Play
        // intent now so a stale confirmed Pause cannot keep dropping resumed
        // capture. A later source update can still correct the room.
        roomPlaybackIsPlaying = requestedState
        packetizer.discardPendingSamples()
        nowPlaying = NowPlayingMedia(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album,
            artworkData: nowPlaying.artworkData,
            sourceURL: nowPlaying.sourceURL,
            isPlaying: requestedState,
            elapsedTime: nowPlaying.elapsedTime,
            duration: nowPlaying.duration
        )
        broadcast(ControlMessage(type: "now_playing", nowPlaying: nowPlaying))
        broadcast(ControlMessage(type: "room_playback", isPlaying: requestedState))
        _ = sendCoordinatedResync(targetID: nil)
        return true
    }

    static func playbackIntentIsCurrent(
        setAtNanos: UInt64?,
        nowNanos: UInt64
    ) -> Bool {
        guard let setAtNanos, nowNanos >= setAtNanos else { return false }
        return nowNanos - setAtNanos < 2_000_000_000
    }

    private func sendCoordinatedResync(
        targetID: String?,
        nowNanos: UInt64 = MonotonicClock.nowNanos()
    ) -> Bool {
        // Flush queued pre-cutover audio so it cannot leak across a new timeline.
        // Under pressure this may omit a still-playable pre-boundary tail; the
        // shared future restart takes priority over draining that old backlog.
        guard let data = try? coordinatedResyncMessage(nowNanos: nowNanos).encodedLine() else { return false }
        if let targetID {
            guard let target = clients.values.first(where: { $0.id == targetID }) else { return false }
            discardPendingAudio(for: target)
            send(data, over: target.control)
            return true
        } else {
            let targets = clients.values.filter { $0.id != nil }
            guard !targets.isEmpty else { return false }
            for target in targets {
                discardPendingAudio(for: target)
                send(data, over: target.control)
            }
            return true
        }
    }

    private func removeClient(_ identifier: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: identifier) else { return }
        timingEligibleClients?.remove(identifier)
        discardPendingAudio(for: client)
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
        let freshReports = clients.compactMap { identifier, client -> (
            isLocal: Bool,
            isEligible: Bool,
            recommendation: UInt64,
            outputLatencyFloor: UInt64
        )? in
            guard let reportedAt = client.lastSyncReportNanos,
                  now >= reportedAt,
                  now - reportedAt <= 5_000_000_000
            else { return nil }
            return (
                isLocal: client.id == localParticipantID,
                isEligible: timingEligibleClients?.contains(identifier) ?? true,
                recommendation: client.recommendedPlayoutDelayNanos,
                outputLatencyFloor: client.outputLatencyPlayoutFloorNanos
            )
        }
        let timingInputs = Self.timingInputs(freshReports)
        let activeRecommendations = timingInputs.recommendations
        // A late joiner's network jitter must not retime an established room,
        // but every current output still needs enough lead time for its hardware.
        let outputLatencyFloors = timingInputs.outputLatencyFloors
        // Once audio has established a timeline, losing the original reporters
        // must not make later joiners indirectly pull that timeline backward.
        if timingEligibleClients != nil,
           activeRecommendations.isEmpty,
           outputLatencyFloors.isEmpty { return }
        let desired = Self.consensusPlayoutDelay(
            activeRecommendations,
            outputLatencyFloors: outputLatencyFloors
        )

        let next: UInt64
        if desired > groupPlayoutDelayNanos {
            next = roomPlaybackIsPlaying && lastAudioCaptureNanos != nil
                ? RoomTiming.liveIncreasePlayoutDelay(required: desired) : desired
        } else if desired < groupPlayoutDelayNanos, !roomPlaybackIsPlaying {
            // Never move a live timeline backward in small steps. Every such
            // change requires a hard future cutover on all listeners, which can
            // turn one transient jitter spike into repeated audible gaps. A
            // paused room may adopt the lower stable delay before playback
            // resumes on its normal coordinated boundary.
            next = RoomTiming.pausedPlayoutDelay(required: desired, current: groupPlayoutDelayNanos)
        } else {
            return
        }
        guard next != groupPlayoutDelayNanos else { return }

        groupPlayoutDelayNanos = next
        roomTimingChangeCount &+= 1
        // Every audible output uses the synchronized Receiver timeline now,
        // including the broadcaster's local return.
        for client in clients.values where client.id != nil {
            sendTiming(to: client)
        }
        if roomPlaybackIsPlaying, lastAudioCaptureNanos != nil {
            // Changing target latency under a running SynchronizedPlayer moves
            // its timeline anchor and can start a self-resync loop. Follow the
            // ordered timing message with one shared future capture boundary.
            _ = sendCoordinatedResync(targetID: nil, nowNanos: now)
        }
        print("Room timing adjusted to \(groupPlayoutDelayNanos / 1_000_000) ms.")
    }

    /// A single CPU-starved listener must not add latency to every healthy Mac.
    /// The lower median requires a majority to agree before the shared buffer grows,
    /// while a one-listener room can still adapt to that listener's network.
    static func consensusPlayoutDelay(
        _ recommendations: [UInt64],
        outputLatencyFloors: [UInt64] = []
    ) -> UInt64 {
        let networkConsensus: UInt64
        if recommendations.isEmpty {
            networkConsensus = RoomTiming.defaultPlayoutDelayNanos
        } else {
            let sorted = recommendations.map(RoomTiming.clampedPlayoutDelay).sorted()
            networkConsensus = sorted[(sorted.count - 1) / 2]
        }
        let hardwareFloor = outputLatencyFloors
            .map(RoomTiming.clampedPlayoutDelay)
            .max() ?? RoomTiming.defaultPlayoutDelayNanos
        return max(networkConsensus, hardwareFloor)
    }

    static func timingInputs(
        _ reports: [(
            isLocal: Bool,
            isEligible: Bool,
            recommendation: UInt64,
            outputLatencyFloor: UInt64
        )]
    ) -> (recommendations: [UInt64], outputLatencyFloors: [UInt64]) {
        (
            recommendations: reports.compactMap { report in
                guard !report.isLocal, report.isEligible else { return nil }
                return report.recommendation
            },
            outputLatencyFloors: reports.map(\.outputLatencyFloor)
        )
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
        sendLevel(to: client)
        broadcastPresence()
    }

    private func sendLevel(to client: Client) {
        guard let id = client.id else { return }
        let message = ControlMessage(
            type: "level",
            targetID: id,
            volume: client.volume,
            muted: client.isMuted
        )
        if let data = try? message.encodedLine() {
            send(data, over: client.control)
        }
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

    private func sendAudio(_ data: Data, captureTimeNanos: UInt64, to client: Client) {
        guard let connection = client.audio else { return }
        client.audioEnqueued &+= 1
        switch audioBackpressurePolicy {
        case .unbounded:
            client.audioSent &+= 1
            send(data, over: connection, isComplete: true)

        case .boundedLatest(let maxInFlight):
            // Expired capture is not evidence that fresh capture is congested.
            // Sweep before comparing the new packet with the pending head.
            expirePendingAudio(for: client, now: audioSendNowNanos())
            client.pendingAudio.append(PendingAudio(data: data, captureTimeNanos: captureTimeNanos,
                enqueuedAtNanos: audioSendNowNanos()))
            if let first = client.pendingAudio.first {
                let exceedsSpan = captureTimeNanos >= first.captureTimeNanos
                    && captureTimeNanos - first.captureTimeNanos >= Self.maximumPendingAudioSpanNanos
                if client.pendingAudio.count > Self.maximumPendingAudioPackets || exceedsSpan {
                    client.audioBacklogCongested = true
                }
            }
            if client.audioBacklogCongested, client.pendingAudio.count > 1 {
                client.audioReplaced &+= UInt64(client.pendingAudio.count - 1)
                client.pendingAudio.removeFirst(client.pendingAudio.count - 1)
            }
            drainAudio(for: client, over: connection, maxInFlight: maxInFlight)
        }
    }

    private func drainAudio(for client: Client, over connection: NWConnection, maxInFlight: Int) {
        guard client.audio === connection,
              clients[ObjectIdentifier(client.control)] === client else { return }
        expirePendingAudio(for: client, now: audioSendNowNanos())
        // Only backlog growth triggers latest-only mode, not delayed callback
        // dispatch on a fast link. Congestion clears only with an empty pending
        // queue and at least half the socket capacity free: an empty pending
        // slot at full capacity is not recovery, but a steady stream need not
        // become completely idle. Queue wait and the shared playout deadline still
        // expire old audio even if capture has stopped.
        while client.audioSendsInFlight < max(1, maxInFlight), !client.pendingAudio.isEmpty {
            let packet = client.pendingAudio.removeFirst()
            let submittedAt = audioSendNowNanos()
            let captureAge = submittedAt >= packet.captureTimeNanos ? submittedAt - packet.captureTimeNanos : 0
            let schedulingHeadroom = RoomTiming.renderSchedulingHeadroomNanos
            let admissionBudget = groupPlayoutDelayNanos > schedulingHeadroom
                ? groupPlayoutDelayNanos - schedulingHeadroom : 0
            let estimatedLocalCompletion = client.audioCompletionDurations.max() ?? 0
            let recentCompletionInterval = client.audioCompletionIntervals.isEmpty ? 0
                : client.audioCompletionIntervals.reduce(0, +) / UInt64(client.audioCompletionIntervals.count)
            // An outstanding interval is already at least this long, even
            // before its completion arrives. Otherwise a slowing path keeps
            // admitting against an obsolete fast rate until the next callback.
            let unfinishedCompletionInterval = client.audioSendsInFlight > 0
                ? client.lastAudioCompletionNanos.map { submittedAt >= $0 ? submittedAt - $0 : 0 } ?? 0
                : 0
            let completionInterval = max(recentCompletionInterval, unfinishedCompletionInterval)
            // Queue wait alone ignores capture acquisition age and work already
            // occupying this path. Preserve fresh FIFO packets, but do not admit
            // one whose observed local service estimate consumes its remaining
            // room budget. Subtraction avoids overflowing unsigned timestamps.
            guard captureAge < admissionBudget,
                  estimatedLocalCompletion < admissionBudget - captureAge,
                  // Early completions understate a growing in-flight backlog.
                  // Budget its recent average service rate too, without multiplying
                  // timestamps or treating local completion as a remote ACK.
                  completionInterval < (admissionBudget - captureAge)
                    / UInt64(client.audioSendsInFlight + 1) else {
                client.audioAdmissionRejected &+= 1
                continue
            }
            client.audioSendsInFlight += 1
            client.audioSent &+= 1
            send(packet.data, over: connection, isComplete: true) { [weak self, weak client] error in
                guard let self, let client else { return }
                // Sample at callback entry, before the additional owning-queue
                // dispatch. The queued admission check separately sees that age.
                let completedAt = self.audioSendNowNanos()
                self.queue.async { [weak self, weak client] in
                    guard let self, let client, client.audio === connection,
                          self.clients[ObjectIdentifier(client.control)] === client else { return }
                    client.audioSendsInFlight = max(0, client.audioSendsInFlight - 1)
                    if let error {
                        fputs("Audio send failed: \(error)\n", stderr)
                        connection.cancel()
                        client.audio = nil
                        self.discardPendingAudio(for: client)
                        return
                    }
                    if completedAt >= submittedAt {
                        client.audioCompletionDurations.append(completedAt - submittedAt)
                        if client.audioCompletionDurations.count > Self.maximumAudioCompletionSamples {
                            client.audioCompletionDurations.removeFirst()
                        }
                    }
                    if let previous = client.lastAudioCompletionNanos, completedAt >= previous {
                        client.audioCompletionIntervals.append(completedAt - previous)
                        if client.audioCompletionIntervals.count > Self.maximumAudioCompletionSamples {
                            client.audioCompletionIntervals.removeFirst()
                        }
                    }
                    client.lastAudioCompletionNanos = completedAt
                    self.drainAudio(for: client, over: connection, maxInFlight: maxInFlight)
                }
            }
        }
        if client.audioSendsInFlight <= max(1, maxInFlight) / 2, client.pendingAudio.isEmpty {
            client.audioBacklogCongested = false
        }
        if client.audioSendsInFlight == 0, client.pendingAudio.isEmpty {
            // A giant stall must not permanently exclude fresh capture after
            // recovery. The next bounded burst probes the now-idle path anew.
            client.audioCompletionDurations.removeAll()
            client.audioCompletionIntervals.removeAll()
            client.lastAudioCompletionNanos = nil
        }
    }

    private func discardPendingAudio(for client: Client) {
        client.audioDiscardedBoundary &+= UInt64(client.pendingAudio.count)
        client.pendingAudio.removeAll()
    }

    private func expirePendingAudio(for client: Client, now: UInt64) {
        let priorAgeDrops = client.audioExpiredAge
        client.pendingAudio.removeAll { packet in
            if now >= packet.enqueuedAtNanos,
               now - packet.enqueuedAtNanos >= Self.maximumPendingAudioWaitNanos {
                client.audioExpiredWait &+= 1
                return true
            }
            if now >= packet.captureTimeNanos,
               now - packet.captureTimeNanos >= groupPlayoutDelayNanos {
                client.audioExpiredAge &+= 1
                return true
            }
            return false
        }
        if client.audioExpiredAge != priorAgeDrops,
           client.lastAudioAgeWarningNanos.map({ now >= $0 && now - $0 >= 5_000_000_000 }) ?? true {
            client.lastAudioAgeWarningNanos = now
            fputs("Audio capture arrived after its room playout deadline; inspect capture-age drop diagnostics.\n", stderr)
        }
    }
}
