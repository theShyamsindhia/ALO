import CoreGraphics
import Foundation
import Network
import WERAICore

final class Receiver {
    private let queue = DispatchQueue(label: "in.werai.receiver.network", qos: .userInteractive)
    private let requestedRoom: String?
    private let displayName: String
    private let participantID = UUID().uuidString
    private let statusHandler: ((ReceiverStatus) -> Void)?
    private let identityHandler: ((_ id: String, _ name: String) -> Void)?
    private let participantsHandler: (([RoomParticipant]) -> Void)?
    private let mediaStateHandler: ((Bool) -> Void)?
    private let nowPlayingHandler: ((NowPlayingMedia) -> Void)?
    private let chatHandler: ((_ sender: String, _ text: String, _ sentNanos: UInt64) -> Void)?
    private let queueHandler: (([RoomQueueItem]) -> Void)?
    private let clock = ClockSynchronizer()
    private let player: SynchronizedPlayer
    private let videoDecoder: VideoDecoder
    private var udpListener: NWListener?
    private var videoListener: NWListener?
    private var browser: NWBrowser?
    private var control: NWConnection?
    private var controlDecoder = ControlLineDecoder()
    private var pingTimer: DispatchSourceTimer?
    private var maintenanceTimer: DispatchSourceTimer?
    private var hasChosenRoom = false
    private var audioListenerReady = false
    private var videoListenerReady = false
    private var audioConnections = [NWConnection]()
    private var videoConnections = [NWConnection]()

    init(
        requestedRoom: String?,
        displayName: String? = nil,
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
        self.displayName = displayName ?? Host.current().localizedName ?? "Mac"
        self.statusHandler = statusHandler
        self.identityHandler = identityHandler
        self.participantsHandler = participantsHandler
        self.mediaStateHandler = mediaStateHandler
        self.nowPlayingHandler = nowPlayingHandler
        self.chatHandler = chatHandler
        self.queueHandler = queueHandler
        self.player = try SynchronizedPlayer {
            statusHandler?(.playing)
        }
        self.videoDecoder = VideoDecoder(imageHandler: videoHandler ?? { _ in })
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
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.player.maintainSync() }
        timer.resume()
        maintenanceTimer = timer

        print("Looking for WERAI rooms…")
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
                self.statusHandler?(.connected)
                self.sendJoin()
                self.startPinging()
            case .failed(let error):
                fputs("Room connection failed: \(error)\n", stderr)
                self.statusHandler?(.failed(error.localizedDescription))
                self.hasChosenRoom = false
                self.startBrowsing()
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
                timer.schedule(deadline: .now() + 2, repeating: 2)
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
                            self.player.clockOffsetNanos = self.clock.offsetNanos
                            self.videoDecoder.clockOffsetNanos = self.clock.offsetNanos
                        }
                    case "presence":
                        self.participantsHandler?(message.participantDetails ?? [])
                    case "welcome":
                        if let id = message.participantID, let name = message.displayName {
                            self.identityHandler?(id, name)
                        }
                    case "media_state":
                        self.mediaStateHandler?(message.videoEnabled ?? false)
                    case "now_playing":
                        self.nowPlayingHandler?(message.nowPlaying ?? NowPlayingMedia())
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
                    default:
                        break
                    }
                }
            }
            if !isComplete, error == nil {
                self.receiveControl()
            }
        }
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
                    self?.player.accept(packet)
                }
                if error == nil {
                    receiveNext()
                }
            }
        }
        receiveNext()
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
    case failed(String)
}
