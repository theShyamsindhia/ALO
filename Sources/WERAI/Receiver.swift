import CoreGraphics
import CoreAudio
import Foundation
import Network
import WERAICore

final class Receiver {
    private final class PlaybackActivityRelay {
        var handler: (Bool) -> Void = { _ in }
    }

    private let queue = DispatchQueue(label: "in.werai.receiver.network", qos: .userInteractive)
    private let requestedRoom: String?
    private let roomDisplayName: String
    private let displayName: String
    private let capturesSystemMediaCommands: Bool
    private let participantID: String
    private let statusHandler: ((ReceiverStatus) -> Void)?
    private let identityHandler: ((_ id: String, _ name: String) -> Void)?
    private let participantsHandler: (([RoomParticipant]) -> Void)?
    private let mediaStateHandler: ((Bool) -> Void)?
    private let nowPlayingHandler: ((NowPlayingMedia) -> Void)?
    private let chatHandler: ((_ sender: String, _ text: String, _ sentNanos: UInt64) -> Void)?
    private let queueHandler: (([RoomQueueItem]) -> Void)?
    private let clock = ClockSynchronizer()
    private let jitter = NetworkJitterEstimator()
    private let player: SynchronizedPlayer
    private let videoDecoder: VideoDecoder
    private let playbackActivityRelay: PlaybackActivityRelay
    private lazy var remoteCommandCenter = RoomRemoteCommandCenter { [weak self] command in
        self?.sendRoomMediaCommand(command) ?? false
    }
    private var udpListener: NWListener?
    private var videoListener: NWListener?
    private var browser: NWBrowser?
    private var control: NWConnection?
    private var controlDecoder = ControlLineDecoder()
    private var pingTimer: DispatchSourceTimer?
    private var maintenanceTimer: DispatchSourceTimer?
    private var hasChosenRoom = false
    private var hasAuthenticatedControl = false
    private var audioListenerReady = false
    private var videoListenerReady = false
    private var audioConnections = [NWConnection]()
    private var videoConnections = [NWConnection]()
    private var lastSyncReportNanos: UInt64 = 0

    init(
        requestedRoom: String?,
        roomDisplayName: String? = nil,
        outputDeviceUID: String? = nil,
        outputDeviceID: AudioDeviceID? = nil,
        participantID: String = UUID().uuidString,
        displayName: String? = nil,
        capturesSystemMediaCommands: Bool = true,
        statusHandler: ((ReceiverStatus) -> Void)? = nil,
        identityHandler: ((_ id: String, _ name: String) -> Void)? = nil,
        participantsHandler: (([RoomParticipant]) -> Void)? = nil,
        mediaStateHandler: ((Bool) -> Void)? = nil,
        nowPlayingHandler: ((NowPlayingMedia) -> Void)? = nil,
        chatHandler: ((_ sender: String, _ text: String, _ sentNanos: UInt64) -> Void)? = nil,
        queueHandler: (([RoomQueueItem]) -> Void)? = nil,
        videoHandler: ((CGImage) -> Void)? = nil
    ) throws {
        self.requestedRoom = requestedRoom
        self.roomDisplayName = roomDisplayName ?? requestedRoom ?? "WERAI Room"
        self.participantID = participantID
        self.displayName = displayName ?? Host.current().localizedName ?? "Mac"
        self.capturesSystemMediaCommands = capturesSystemMediaCommands
        self.statusHandler = statusHandler
        self.identityHandler = identityHandler
        self.participantsHandler = participantsHandler
        self.mediaStateHandler = mediaStateHandler
        self.nowPlayingHandler = nowPlayingHandler
        self.chatHandler = chatHandler
        self.queueHandler = queueHandler
        let playbackActivityRelay = PlaybackActivityRelay()
        self.playbackActivityRelay = playbackActivityRelay
        self.player = try SynchronizedPlayer(
            outputDeviceUID: outputDeviceUID,
            outputDeviceID: outputDeviceID
        ) { active in
            playbackActivityRelay.handler(active)
        }
        self.videoDecoder = VideoDecoder(imageHandler: videoHandler ?? { _ in })
        playbackActivityRelay.handler = { [weak self] active in
            guard let self else { return }
            self.statusHandler?(active ? .playing : .silent)
            if self.capturesSystemMediaCommands {
                self.remoteCommandCenter.updatePlaybackActivity(active)
            }
        }
    }

    func start() throws {
        let audioListener = try NWListener(using: .udp, on: .any)
        audioListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.audioListenerReady = true
                self.startBrowsingWhenReady()
            case .failed(let error):
                fputs("Receiver failed: \(error)\n", stderr)
            default:
                break
            }
        }
        audioListener.newConnectionHandler = { [weak self] connection in
            self?.receiveAudio(from: connection)
        }
        audioListener.start(queue: queue)
        udpListener = audioListener

        let videoListener = try NWListener(using: .tcp, on: .any)
        videoListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.videoListenerReady = true
                self.startBrowsingWhenReady()
            case .failed(let error):
                fputs("Video receiver failed: \(error)\n", stderr)
            default:
                break
            }
        }
        videoListener.newConnectionHandler = { [weak self] connection in
            self?.receiveVideo(from: connection)
        }
        videoListener.start(queue: queue)
        self.videoListener = videoListener

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(50),
            repeating: .milliseconds(50),
            leeway: .milliseconds(10)
        )
        timer.setEventHandler { [weak self] in self?.maintainTiming() }
        timer.resume()
        maintenanceTimer = timer

        print("Looking for ALO rooms…")
        statusHandler?(.searching)
    }

    func stop() {
        queue.sync {
            pingTimer?.cancel()
            pingTimer = nil
            maintenanceTimer?.cancel()
            maintenanceTimer = nil
            browser?.cancel()
            browser = nil
            control?.cancel()
            control = nil
            hasAuthenticatedControl = false
            udpListener?.cancel()
            udpListener = nil
            videoListener?.cancel()
            videoListener = nil
            audioConnections.forEach { $0.cancel() }
            audioConnections.removeAll()
            videoConnections.forEach { $0.cancel() }
            videoConnections.removeAll()
            player.stop()
            videoDecoder.stop()
            if capturesSystemMediaCommands { remoteCommandCenter.stop() }
            hasChosenRoom = false
            audioListenerReady = false
            videoListenerReady = false
        }
    }

    func sendChat(_ text: String) {
        queue.async { [weak self] in
            self?.send(ControlMessage(type: "chat", text: text))
        }
    }

    func addQueueItem(_ item: RoomQueueItem) {
        queue.async { [weak self] in
            self?.send(ControlMessage(type: "queue_add", queueItem: item))
        }
    }

    func removeQueueItem(id: String) {
        queue.async { [weak self] in
            self?.send(ControlMessage(type: "queue_remove", queueItemID: id))
        }
    }

    func setLocalLevel(volume: Double, muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.send(ControlMessage(
                type: "set_level",
                targetID: self.participantID,
                volume: volume,
                muted: muted
            ))
        }
    }

    func setRoomPlayback(playing: Bool) {
        sendRoomMediaCommand(playing ? .play : .pause)
    }

    @discardableResult
    func sendRoomMediaCommand(_ command: RoomMediaCommand) -> Bool {
        queue.sync {
            guard control != nil, hasAuthenticatedControl else { return false }
            send(ControlMessage(type: "media_command", mediaCommand: command))
            return true
        }
    }

    @discardableResult
    func requestResync(participantID: String? = nil) -> Bool {
        queue.sync {
            guard control != nil, hasAuthenticatedControl else { return false }
            send(ControlMessage(type: "resync_request", targetID: participantID))
            return true
        }
    }

    func updateNowPlaying(_ media: NowPlayingMedia) {
        guard capturesSystemMediaCommands else { return }
        queue.async { [weak self] in self?.remoteCommandCenter.update(media) }
    }

    private func startBrowsingWhenReady() {
        guard audioListenerReady, videoListenerReady, browser == nil else { return }
        startBrowsing()
    }

    private func startBrowsing() {
        let browser = NWBrowser(
            for: .bonjour(type: HostServer.serviceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.consider(results)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("Room discovery failed: \(error)\n", stderr)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func consider(_ results: Set<NWBrowser.Result>) {
        guard !hasChosenRoom else { return }
        let matching = results.first { result in
            guard let requestedRoom else { return true }
            guard case .service(let name, _, _, _) = result.endpoint else { return false }
            return name.caseInsensitiveCompare(requestedRoom) == .orderedSame
        }
        guard let result = matching else { return }

        hasChosenRoom = true
        browser?.cancel()
        connect(to: result.endpoint)
    }

    private func connect(to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("Connected to \(endpoint).")
                self.sendJoin()
                self.startPinging()
            case .failed(let error):
                fputs("Room connection failed: \(error)\n", stderr)
                self.statusHandler?(.failed(error.localizedDescription))
                self.handleControlDisconnect()
            default:
                break
            }
        }
        connection.start(queue: queue)
        control = connection
        receiveControl()
    }

    private func sendJoin() {
        guard let audioPort = udpListener?.port, let videoPort = videoListener?.port else { return }
        send(ControlMessage(
            type: "join",
            udpPort: audioPort.rawValue,
            videoPort: videoPort.rawValue,
            displayName: displayName,
            participantID: participantID
        ))
    }

    private func startPinging() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var burstCount = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.send(self.clock.makePing(at: MonotonicClock.nowNanos()))
            burstCount += 1
            if burstCount == 8 {
                timer.schedule(deadline: .now() + 1, repeating: 1)
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func send(_ message: ControlMessage) {
        guard let data = try? message.encodedLine() else { return }
        control?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveControl() {
        control?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                for message in self.controlDecoder.append(data) {
                    switch message.type {
                    case "pong":
                        if self.clock.acceptPong(message, receivedAt: MonotonicClock.nowNanos()), self.clock.isReady {
                            self.updateClockEstimate()
                        }
                    case "sync_timing":
                        if let delay = message.playoutDelayNanos {
                            let clamped = RoomTiming.clampedPlayoutDelay(delay)
                            self.player.setTargetLatencyNanos(clamped)
                            self.videoDecoder.setTargetLatencyNanos(clamped)
                        }
                    case "presence":
                        self.participantsHandler?(message.participantDetails ?? [])
                    case "welcome":
                        self.hasAuthenticatedControl = true
                        self.statusHandler?(.connected)
                        if self.capturesSystemMediaCommands {
                            self.remoteCommandCenter.start(roomName: self.roomDisplayName)
                        }
                        if let id = message.participantID, let name = message.displayName {
                            self.identityHandler?(id, name)
                        }
                    case "media_state":
                        self.mediaStateHandler?(message.videoEnabled ?? false)
                    case "now_playing":
                        let media = message.nowPlaying ?? NowPlayingMedia()
                        if self.capturesSystemMediaCommands {
                            self.remoteCommandCenter.update(media)
                        }
                        self.nowPlayingHandler?(media)
                    case "room_playback":
                        self.player.setRoomPlayback(playing: message.isPlaying ?? true)
                    case "level":
                        self.player.setLevel(
                            volume: message.volume ?? 1,
                            muted: message.muted ?? false
                        )
                    case "chat":
                        if let sender = message.sender, let text = message.text {
                            self.chatHandler?(sender, text, message.sentNanos ?? 0)
                        }
                    case "queue_update":
                        self.queueHandler?(message.mediaQueue ?? [])
                    case "resync":
                        self.player.forceResync()
                    default:
                        break
                    }
                }
            }
            if !isComplete, error == nil {
                self.receiveControl()
            } else {
                self.handleControlDisconnect()
            }
        }
    }

    private func handleControlDisconnect() {
        pingTimer?.cancel()
        pingTimer = nil
        control?.cancel()
        control = nil
        hasAuthenticatedControl = false
        controlDecoder = ControlLineDecoder()
        if capturesSystemMediaCommands { remoteCommandCenter.stop() }
        guard hasChosenRoom else { return }
        hasChosenRoom = false
        statusHandler?(.searching)
        startBrowsing()
    }

    private func receiveAudio(from connection: NWConnection) {
        audioConnections.append(connection)
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("Audio receive path failed: \(error)\n", stderr)
            }
        }
        connection.start(queue: queue)

        func receiveNext() {
            connection.receiveMessage { [weak self] data, _, _, error in
                if let data, let packet = AudioPacket(data: data) {
                    if let self {
                        let now = MonotonicClock.nowNanos()
                        if let offset = self.clock.offsetNanos(at: now), self.clock.isReady {
                            self.jitter.observe(
                                captureTimeNanos: packet.captureTimeNanos,
                                receivedAt: now,
                                clockOffsetNanos: offset
                            )
                        }
                        self.player.accept(packet)
                    }
                }
                if error == nil {
                    receiveNext()
                }
            }
        }
        receiveNext()
    }

    private func maintainTiming() {
        updateClockEstimate()
        player.maintainSync()

        let now = MonotonicClock.nowNanos()
        guard clock.isReady, now - lastSyncReportNanos >= 1_000_000_000 else { return }
        lastSyncReportNanos = now
        send(ControlMessage(
            type: "sync_report",
            playoutDelayNanos: jitter.recommendedPlayoutDelayNanos(
                roundTripNanos: clock.bestRoundTripNanos
            )
        ))
        send(ControlMessage(
            type: "sync_status",
            participantID: participantID,
            syncReport: player.syncReport()
        ))
    }

    private func updateClockEstimate() {
        guard clock.isReady,
              let offset = clock.offsetNanos(at: MonotonicClock.nowNanos())
        else { return }
        player.clockOffsetNanos = offset
        videoDecoder.updateClockOffsetNanos(offset)
    }

    private func receiveVideo(from connection: NWConnection) {
        videoConnections.append(connection)
        let decoder = VideoFrameStreamDecoder()
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("Video receive path failed: \(error)\n", stderr)
            }
        }
        connection.start(queue: queue)

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
                if let data {
                    for frame in decoder.append(data) {
                        self?.videoDecoder.accept(frame)
                    }
                }
                if !isComplete, error == nil {
                    receiveNext()
                }
            }
        }
        receiveNext()
    }
}

enum ReceiverStatus: Equatable {
    case searching
    case connected
    case playing
    case silent
    case failed(String)
}
