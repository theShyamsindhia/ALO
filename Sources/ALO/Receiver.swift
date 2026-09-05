import CoreGraphics
import CoreAudio
import Foundation
import Network
import ALOCore

struct ReceiverTransportEpoch {
    private(set) var token: UInt64 = 0

    mutating func advance() {
        token &+= 1
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == token
    }
}

struct ReceiverLevelPreference {
    private(set) var volume = 1.0
    private(set) var muted = false

    mutating func updateLocally(volume: Double, muted: Bool) {
        self.volume = min(max(volume, 0), 1)
        self.muted = muted
    }

    mutating func updateFromAuthoritativeLevel(volume: Double, muted: Bool) {
        updateLocally(volume: volume, muted: muted)
    }

    func controlMessage(participantID: String) -> ControlMessage {
        ControlMessage(
            type: "set_level",
            targetID: participantID,
            volume: volume,
            muted: muted
        )
    }
}

/// Queue-confined screen-session observations, independent of media delivery.
struct ReceiverScreenTiming {
    private(set) var videoEnabled = false
    private var hasEnabledBefore = false
    private var requireHandoffAfterNanos: UInt64?

    mutating func update(enabled: Bool, at now: UInt64) {
        if enabled, !videoEnabled {
            // The initial video can beat its control notification. After a
            // restart, however, a retained/disabled-period image is not proof of
            // new delivery: require another handoff after this local boundary.
            // A restarted static frame that beats control remains unverified,
            // rather than guessing its stream generation across transports.
            if hasEnabledBefore { requireHandoffAfterNanos = now }
            hasEnabledBefore = true
        }
        videoEnabled = enabled
    }

    func presentationSnapshot(_ snapshot: VideoPresentationTimingSnapshot) -> VideoPresentationTimingSnapshot {
        guard let boundary = requireHandoffAfterNanos,
              let handoff = snapshot.latestHandoffAtNanos, handoff <= boundary else { return snapshot }
        return VideoPresentationTimingSnapshot(measuredAtNanos: snapshot.measuredAtNanos,
            latestHandoffAtNanos: nil, latestDeadlineMissNanos: nil,
            maximumDeadlineMissNanos: snapshot.maximumDeadlineMissNanos, presentedCount: 0,
            pendingCount: snapshot.pendingCount, oldestPendingDeadlineNanos: snapshot.oldestPendingDeadlineNanos)
    }
}

final class Receiver {
    private final class PlaybackActivityRelay {
        var handler: (Bool) -> Void = { _ in }
    }

    private let queue = DispatchQueue(label: "in.werai.receiver.network", qos: .userInteractive)
    private let requestedRoom: String?
    private let roomDisplayName: String
    private let displayName: String
    private let capturesSystemMediaCommands: Bool
    private let roomMediaCommandHandler: ((RoomMediaCommand) -> Bool)?
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
        guard let self else { return false }
        if let roomMediaCommandHandler { return roomMediaCommandHandler(command) }
        return sendRoomMediaCommand(command)
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
    private var screenTiming = ReceiverScreenTiming()
    private var audioListenerReady = false
    private var videoListenerReady = false
    private var audioConnections = [NWConnection]()
    private var videoConnections = [NWConnection]()
    private var lastSyncReportNanos: UInt64 = 0
    private var locallyForcedPlaybackMuted = false
    private var participantVolume = 1.0
    private var participantMuted = false
    private var levelPreference = ReceiverLevelPreference()
    private let mediaSecurity: RoomMediaSecurity?
    private var audioOpener: DatagramOpener?
    private var transportEpoch = ReceiverTransportEpoch()

    init(
        requestedRoom: String?,
        mediaSecurity: RoomMediaSecurity? = nil,
        roomDisplayName: String? = nil,
        audioOutput: RoomAudioOutputEngine = RoomAudioOutputEngine(),
        outputDeviceUID: String? = nil,
        outputDeviceID: AudioDeviceID? = nil,
        participantID: String = UUID().uuidString,
        displayName: String? = nil,
        roomMediaCommandHandler: ((RoomMediaCommand) -> Bool)? = nil,
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
        self.mediaSecurity = mediaSecurity
        self.requestedRoom = requestedRoom
        self.roomDisplayName = roomDisplayName ?? requestedRoom ?? "ALO Room"
        self.participantID = participantID
        self.displayName = displayName ?? Host.current().localizedName ?? "Mac"
        self.roomMediaCommandHandler = roomMediaCommandHandler
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
            audioOutput: audioOutput,
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
        let audioListener = try NWListener(using: LocalNetworkParameters.udp(), on: .any)
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

        let videoListener = try NWListener(using: mediaSecurity?.tcp(video: true) ?? LocalNetworkParameters.tcp(), on: .any)
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
            transportEpoch.advance()
            audioOpener = nil
            pingTimer?.cancel()
            pingTimer = nil
            maintenanceTimer?.cancel()
            maintenanceTimer = nil
            browser?.cancel()
            browser = nil
            control?.cancel()
            control = nil
            hasAuthenticatedControl = false
            screenTiming = ReceiverScreenTiming()
            udpListener?.cancel()
            udpListener = nil
            videoListener?.cancel()
            videoListener = nil
            audioConnections.forEach { $0.cancel() }
            audioConnections.removeAll()
            videoConnections.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
            videoConnections.removeAll()
            player.stop()
            videoDecoder.stop()
            if capturesSystemMediaCommands { remoteCommandCenter.stop() }
            hasChosenRoom = false
            audioListenerReady = false
            videoListenerReady = false
        }
    }

    func diagnosticsSnapshot() -> ReceiverTimingDiagnostics {
        queue.sync {
            let now = MonotonicClock.nowNanos()
            let report = player.syncReport()
            let outputFormat = player.outputHardwareFormatForDiagnostics
            return ReceiverTimingDiagnostics(
                roundTripMilliseconds: clock.bestRoundTripNanos.map { Double($0) / 1_000_000 },
                clockOffsetMilliseconds: clock.offsetNanos(at: now).map { Double($0) / 1_000_000 },
                jitterMilliseconds: Double(jitter.jitterNanos) / 1_000_000,
                recommendedBufferMilliseconds: Double(
                    jitter.recommendedPlayoutDelayNanos(
                        roundTripNanos: clock.bestRoundTripNanos,
                        outputLatencyNanos: player.outputLatencyForTimingNanos,
                        renderSchedulingHeadroomNanos: player.renderSchedulingHeadroomForTimingNanos
                    )
                ) / 1_000_000,
                outputLatencyMilliseconds: Double(player.outputLatencyForTimingNanos) / 1_000_000,
                renderHeadroomMilliseconds: Double(
                    player.renderSchedulingHeadroomForTimingNanos
                ) / 1_000_000,
                outputSampleRate: outputFormat?.sampleRate,
                outputChannelCount: outputFormat?.channelCount,
                latenessMilliseconds: Double(report.latenessNanos) / 1_000_000,
                latePacketCount: report.latePacketCount,
                resyncCount: report.resyncCount,
                currentDriftMilliseconds: report.driftNanos.map { Double($0) / 1_000_000 },
                driftMeasurementAgeMilliseconds: report.driftSampleAgeNanos.map { Double($0) / 1_000_000 },
                video: screenTiming.presentationSnapshot(videoDecoder.presentationTimingSnapshot),
                videoEnabled: screenTiming.videoEnabled
            )
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
            self.levelPreference.updateLocally(volume: volume, muted: muted)
            self.participantVolume = self.levelPreference.volume
            self.participantMuted = muted
            self.player.setLevel(
                volume: self.participantVolume,
                muted: muted || self.locallyForcedPlaybackMuted
            )
            if self.hasAuthenticatedControl {
                self.sendPreferredLevel()
            }
        }
    }

    /// Changes playback only on this Receiver without publishing participant
    /// mixer state to the room.
    func setLocalPlaybackMuted(_ muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.locallyForcedPlaybackMuted = muted
            self.player.setLevel(
                volume: self.participantVolume,
                muted: self.participantMuted || muted
            )
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
            using: LocalNetworkParameters.tcp()
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
        let connection = NWConnection(to: endpoint, using: mediaSecurity?.tcp() ?? LocalNetworkParameters.tcp())
        let connectionEpoch = transportEpoch.token
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            guard self.transportEpoch.accepts(connectionEpoch),
                  let connection, self.control === connection
            else { return }
            switch state {
            case .ready:
                print("Connected to \(endpoint).")
                self.sendJoin()
                self.startPinging()
            case .failed(let error):
                fputs("Room connection failed: \(error)\n", stderr)
                self.statusHandler?(.failed(error.localizedDescription))
                self.handleControlDisconnect(expectedEpoch: connectionEpoch)
            default:
                break
            }
        }
        connection.start(queue: queue)
        control = connection
        receiveControl(from: connection, epoch: connectionEpoch)
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

    private func sendPreferredLevel() {
        send(levelPreference.controlMessage(participantID: participantID))
    }

    private func receiveControl(from connection: NWConnection, epoch: UInt64) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self else { return }
            guard self.transportEpoch.accepts(epoch),
                  let connection, self.control === connection
            else { return }
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
                        guard !self.hasAuthenticatedControl else { continue }
                        if let security = self.mediaSecurity {
                            guard let sessionID = message.mediaSessionID,
                                  let opener = try? security.audioOpener(sessionID: sessionID) else {
                                self.handleControlDisconnect(expectedEpoch: epoch); return
                            }
                            self.audioOpener = opener
                        }
                        self.hasAuthenticatedControl = true
                        self.statusHandler?(.connected)
                        if self.capturesSystemMediaCommands {
                            self.remoteCommandCenter.start(roomName: self.roomDisplayName)
                        }
                        if let id = message.participantID, let name = message.displayName {
                            self.identityHandler?(id, name)
                        }
                        // A replacement host has no previous Client record to
                        // inherit. Republish the device's chosen level for each
                        // newly authenticated transport epoch.
                        self.sendPreferredLevel()
                    case "media_state":
                        self.screenTiming.update(enabled: message.videoEnabled ?? false, at: MonotonicClock.nowNanos())
                        self.mediaStateHandler?(self.screenTiming.videoEnabled)
                    case "now_playing":
                        let media = message.nowPlaying ?? NowPlayingMedia()
                        if self.capturesSystemMediaCommands {
                            self.remoteCommandCenter.update(media)
                        }
                        self.nowPlayingHandler?(media)
                    case "room_playback":
                        self.player.setRoomPlayback(playing: message.isPlaying ?? true)
                    case "level":
                        self.participantVolume = message.volume ?? 1
                        self.participantMuted = message.muted ?? false
                        self.levelPreference.updateFromAuthoritativeLevel(
                            volume: self.participantVolume,
                            muted: self.participantMuted
                        )
                        self.player.setLevel(
                            volume: self.participantVolume,
                            muted: self.participantMuted || self.locallyForcedPlaybackMuted
                        )
                    case "chat":
                        if let sender = message.sender, let text = message.text {
                            self.chatHandler?(sender, text, message.sentNanos ?? 0)
                        }
                    case "queue_update":
                        self.queueHandler?(message.mediaQueue ?? [])
                    case "resync":
                        let cutoverCaptureNanos = message.hostNanos
                        self.player.forceResync(atOrAfterCaptureNanos: cutoverCaptureNanos)
                        self.videoDecoder.forceResync(atOrAfterCaptureNanos: cutoverCaptureNanos)
                    default:
                        break
                    }
                }
                if self.controlDecoder.isOverflowed {
                    self.handleControlDisconnect(expectedEpoch: epoch)
                    return
                }
            }
            if !isComplete, error == nil {
                self.receiveControl(from: connection, epoch: epoch)
            } else {
                self.handleControlDisconnect(expectedEpoch: epoch)
            }
        }
    }

    private func handleControlDisconnect(expectedEpoch: UInt64) {
        guard transportEpoch.accepts(expectedEpoch) else { return }
        transportEpoch.advance()
        audioOpener = nil
        pingTimer?.cancel()
        pingTimer = nil
        control?.cancel()
        control = nil
        hasAuthenticatedControl = false
        screenTiming = ReceiverScreenTiming()
        controlDecoder = ControlLineDecoder()
        audioConnections.forEach { $0.cancel() }
        audioConnections.removeAll()
        videoConnections.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
        videoConnections.removeAll()
        clock.reset()
        jitter.reset()
        player.clockOffsetNanos = nil
        player.resetStream()
        videoDecoder.resetTiming()
        lastSyncReportNanos = 0
        if capturesSystemMediaCommands { remoteCommandCenter.stop() }
        guard hasChosenRoom else { return }
        hasChosenRoom = false
        statusHandler?(.searching)
        startBrowsing()
    }

    private func receiveAudio(from connection: NWConnection) {
        let connectionEpoch = transportEpoch.token
        audioConnections.append(connection)
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("Audio receive path failed: \(error)\n", stderr)
            }
        }
        connection.start(queue: queue)

        func receiveNext() {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self, self.transportEpoch.accepts(connectionEpoch) else { return }
                let payload = data.flatMap { bytes -> Data? in
                    if self.mediaSecurity != nil { return try? self.audioOpener?.open(bytes) }
                    return bytes
                }
                if let payload, let packet = AudioPacket(data: payload) {
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
                roundTripNanos: clock.bestRoundTripNanos,
                outputLatencyNanos: player.outputLatencyForTimingNanos,
                renderSchedulingHeadroomNanos: player.renderSchedulingHeadroomForTimingNanos
            ),
            outputLatencyPlayoutFloorNanos: RoomTiming.outputLatencyFloor(
                player.outputLatencyForTimingNanos,
                renderSchedulingHeadroomNanos: player.renderSchedulingHeadroomForTimingNanos
            )
        ))
        let audioReport = player.syncReport()
        let playbackReport = PlaybackSyncReport(measuredAtNanos: audioReport.measuredAtNanos,
            latenessNanos: audioReport.latenessNanos, latePacketCount: audioReport.latePacketCount,
            resyncCount: audioReport.resyncCount, driftNanos: audioReport.driftNanos,
            driftSampleAgeNanos: audioReport.driftSampleAgeNanos,
            screenTiming: screenTiming.presentationSnapshot(videoDecoder.presentationTimingSnapshot).relativeTimingReport)
        send(ControlMessage(
            type: "sync_status",
            participantID: participantID,
            syncReport: playbackReport
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
        let connectionEpoch = transportEpoch.token
        videoConnections.append(connection)
        let decoder = VideoFrameStreamDecoder()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed(let error):
                fputs("Video receive path failed: \(error)\n", stderr)
                self.retireVideoConnection(connection)
            case .cancelled:
                self.retireVideoConnection(connection)
            default: break
            }
        }
        connection.start(queue: queue)

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
                guard let self else { connection.cancel(); return }
                guard self.transportEpoch.accepts(connectionEpoch) else {
                    self.retireVideoConnection(connection)
                    return
                }
                if let data {
                    for frame in decoder.append(data) {
                        self.videoDecoder.accept(frame)
                    }
                }
                if !isComplete, error == nil {
                    receiveNext()
                } else {
                    self.retireVideoConnection(connection)
                }
            }
        }
        receiveNext()
    }

    private func retireVideoConnection(_ connection: NWConnection) {
        // Stale-epoch callbacks retire only their own transport, never a newer
        // replacement; they must still release resources after frame admission ends.
        connection.stateUpdateHandler = nil
        videoConnections.removeAll { $0 === connection }
        connection.cancel()
    }

    var videoConnectionCountForTesting: Int { queue.sync { videoConnections.count } }

    func receiveVideoForTesting(from connection: NWConnection) {
        queue.async { [weak self] in self?.receiveVideo(from: connection) }
    }

    func advanceTransportEpochForTesting() {
        queue.sync { transportEpoch.advance() }
    }
}

enum ReceiverStatus: Equatable {
    case searching
    case connected
    case playing
    case silent
    case failed(String)
}
