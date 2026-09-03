import CoreGraphics
import Foundation
import ScreenCaptureKit
import WERAICore

enum BroadcasterPlaybackMode: Equatable {
    case directSource
    case synchronizedReceiver

    static func resolve(sourceMuteTapActive: Bool) -> Self {
        sourceMuteTapActive ? .synchronizedReceiver : .directSource
    }

    static func shouldAttemptSourceMuteTap(
        alreadyAttempted: Bool,
        setupInFlight: Bool,
        tapActive: Bool
    ) -> Bool {
        !alreadyAttempted && !setupInFlight && !tapActive
    }

    static func canAdoptSuccessfulTap(
        belongsToOriginalSession: Bool,
        currentReceiverIsPlaying: Bool
    ) -> Bool {
        belongsToOriginalSession || currentReceiverIsPlaying
    }

    var mutesSynchronizedReceiver: Bool {
        self == .directSource
    }

    var activeStatus: String {
        switch self {
        case .directSource:
            return "Broadcasting this Mac · local playback is not delayed"
        case .synchronizedReceiver:
            return "This Mac is playing in sync"
        }
    }
}

@MainActor
final class HostSession {
    private var host: HostServer?
    private var localReceiver: Receiver?
    private var audioSource: AudioSource?
    private var videoPicker: ScreenContentPicker?
    private var videoCapture: ScreenVideoCapture?
    private var videoEncoder: VideoEncoder?
    private var nowPlayingMonitor: NowPlayingMonitor?
    private var playbackController: SystemPlaybackController?
    private var shouldPauseSourceOnStop = false
    private var sourceMuteTap: AnyObject?
    private var sourceMuteTapTask: Task<Void, Never>?
    private var sourceMuteTapAttempted = false
    private var playbackSessionID: UUID?
    private var playbackMode = BroadcasterPlaybackMode.directSource
    private var localReceiverIsPlaying = false
    private var playbackStatusHandler: ((String) -> Void)?
    private var videoStoppedHandler: (Error) -> Void = { _ in }
    func start(
        roomName: String,
        participantID: String = UUID().uuidString,
        statusHandler: @escaping (String) -> Void,
        receiverCountHandler: @escaping (Int) -> Void,
        initialVideoEnabled: Bool,
        identityHandler: @escaping (_ id: String, _ name: String) -> Void,
        participantsHandler: @escaping ([RoomParticipant]) -> Void,
        mediaStateHandler: @escaping (Bool) -> Void,
        nowPlayingHandler: @escaping (NowPlayingMedia) -> Void,
        chatHandler: @escaping (_ sender: String, _ text: String, _ sentNanos: UInt64) -> Void,
        queueHandler: @escaping ([RoomQueueItem]) -> Void,
        videoHandler: @escaping (CGImage) -> Void,
        audioStoppedHandler: @escaping (Error) -> Void = { _ in },
        videoStoppedHandler: @escaping (Error) -> Void = { _ in }
    ) async throws {
        do {
            self.videoStoppedHandler = videoStoppedHandler
            try Task.checkCancellation()
            statusHandler("Opening your room")
            statusHandler("Preparing system audio capture")
            let source: AudioSource = SystemAudioCapture(unexpectedStopHandler: audioStoppedHandler)
            audioSource = source
            let playbackController = SystemPlaybackController()
            self.playbackController = playbackController
            let host = HostServer(
                roomName: roomName,
                statusHandler: statusHandler,
                receiverCountHandler: receiverCountHandler,
                playbackRequestHandler: { [weak playbackController] command in
                    playbackController?.perform(command) ?? false
                },
                localParticipantID: participantID
            )
            try host.start()
            self.host = host
            try Task.checkCancellation()

            let nowPlayingMonitor = NowPlayingMonitor { [weak host] media in
                host?.setNowPlaying(media)
            }
            nowPlayingMonitor.start()
            self.nowPlayingMonitor = nowPlayingMonitor

            statusHandler("Starting synchronized audio")
            try await source.start { samples, captureTimeNanos in
                host.acceptAudio(samples: samples, captureTimeNanos: captureTimeNanos)
            }
            shouldPauseSourceOnStop = true
            try Task.checkCancellation()

            statusHandler("Broadcasting this Mac · waiting for audio")
            let playbackSessionID = UUID()
            self.playbackSessionID = playbackSessionID
            playbackStatusHandler = statusHandler
            let localReceiver = try Receiver(
                requestedRoom: roomName,
                participantID: participantID,
                capturesSystemMediaCommands: false,
                statusHandler: { [weak self] status in
                    Task { @MainActor [weak self] in
                        self?.handleLocalReceiverStatus(
                            status,
                            playbackSessionID: playbackSessionID,
                            statusHandler: statusHandler
                        )
                    }
                },
                identityHandler: identityHandler,
                participantsHandler: participantsHandler,
                mediaStateHandler: mediaStateHandler,
                nowPlayingHandler: nowPlayingHandler,
                chatHandler: chatHandler,
                queueHandler: queueHandler,
                videoHandler: videoHandler
            )
            self.localReceiver = localReceiver
            applyPlaybackMode(
                .resolve(sourceMuteTapActive: false),
                to: localReceiver
            )
            try localReceiver.start()
            try Task.checkCancellation()

            if initialVideoEnabled {
                try await setVideoEnabled(true)
            }
            statusHandler("Sharing system audio")
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        // Releasing broadcaster ownership must also stop the source application;
        // otherwise a takeover leaves the old Mac playing locally after its
        // capture and room route have been removed.
        if shouldPauseSourceOnStop { _ = playbackController?.perform(.pause) }
        shouldPauseSourceOnStop = false
        stopLocalPlayback()
        try? await audioSource?.stop()
        audioSource = nil
        videoPicker?.deactivate()
        videoPicker = nil
        await videoCapture?.stop()
        videoCapture = nil
        videoEncoder?.stop()
        videoEncoder = nil
        nowPlayingMonitor?.stop()
        nowPlayingMonitor = nil
        playbackController = nil
        host?.stop()
        host = nil
    }

    func sendChat(_ text: String) {
        localReceiver?.sendChat(text)
    }

    func addQueueItem(_ item: RoomQueueItem) {
        localReceiver?.addQueueItem(item)
    }

    func removeQueueItem(id: String) {
        host?.removeQueueItem(id: id)
    }

    func setParticipantLevel(id: String, volume: Double, muted: Bool) {
        host?.setParticipantLevel(id: id, volume: volume, muted: muted)
    }

    /// Applies voice ducking to the broadcaster's own synchronized receiver.
    func setVoiceDuckingActive(_ active: Bool) {
        localReceiver?.setVoiceDuckingActive(active)
    }

    private func handleLocalReceiverStatus(
        _ status: ReceiverStatus,
        playbackSessionID: UUID,
        statusHandler: @escaping (String) -> Void
    ) {
        guard self.playbackSessionID == playbackSessionID else { return }
        switch status {
        case .playing:
            localReceiverIsPlaying = true
            statusHandler(playbackMode.activeStatus)
            startOptionalSourceMuteTap(
                playbackSessionID: playbackSessionID,
                statusHandler: statusHandler
            )
        case .silent:
            localReceiverIsPlaying = false
            statusHandler("Broadcasting this Mac · waiting for audio")
        default:
            break
        }
    }

    /// Starts the optional tap only after the synchronized Receiver has audio
    /// scheduled. The Core Audio permission prompt and tap setup run away from
    /// the main actor, so a pending or denied prompt cannot block screen share.
    private func startOptionalSourceMuteTap(
        playbackSessionID: UUID,
        statusHandler: @escaping (String) -> Void
    ) {
        guard BroadcasterPlaybackMode.shouldAttemptSourceMuteTap(
            alreadyAttempted: sourceMuteTapAttempted,
            setupInFlight: sourceMuteTapTask != nil,
            tapActive: sourceMuteTap != nil
        ),
              let expectedReceiver = localReceiver
        else { return }
        sourceMuteTapAttempted = true

        guard #available(macOS 14.2, *) else { return }
        statusHandler("Broadcasting this Mac · setting up local sync")
        let tap = SourceMuteTap()
        sourceMuteTapTask = Task { @MainActor [weak self, weak expectedReceiver] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try tap.start() }
            }.value
            let cancelled = Task.isCancelled

            guard let self else {
                if case .success = result { tap.stop() }
                return
            }
            self.sourceMuteTapTask = nil
            let belongsToOriginalSession = !cancelled
                && self.playbackSessionID == playbackSessionID
                && expectedReceiver != nil
                && self.localReceiver === expectedReceiver

            switch result {
            case .success:
                // A consent request can outlive a quick stop/start. The tap is
                // process-wide, so hand a successful result to the new Receiver
                // when it is already playing instead of prompting a second time.
                guard let currentReceiver = self.localReceiver,
                      BroadcasterPlaybackMode.canAdoptSuccessfulTap(
                        belongsToOriginalSession: belongsToOriginalSession,
                        currentReceiverIsPlaying: self.localReceiverIsPlaying
                      )
                else {
                    tap.stop()
                    return
                }
                self.sourceMuteTap = tap
                self.sourceMuteTapAttempted = true
                self.applyPlaybackMode(
                    .resolve(sourceMuteTapActive: true),
                    to: currentReceiver
                )
                (self.playbackStatusHandler ?? statusHandler)(self.playbackMode.activeStatus)
            case .failure(let error):
                guard belongsToOriginalSession, let expectedReceiver else { return }
                // This optimization has its own macOS Audio Capture consent.
                // Denial or setup failure is intentionally nonfatal: the source
                // application remains audible and room/screen sharing continues.
                fputs("Optional synchronized local playback is unavailable: \(error.localizedDescription)\n", stderr)
                self.applyPlaybackMode(
                    .resolve(sourceMuteTapActive: false),
                    to: expectedReceiver
                )
                statusHandler(self.playbackMode.activeStatus)
            }
        }
    }

    private func applyPlaybackMode(_ mode: BroadcasterPlaybackMode, to receiver: Receiver) {
        playbackMode = mode
        receiver.setLocalPlaybackMuted(mode.mutesSynchronizedReceiver)
    }

    private func stopLocalPlayback() {
        playbackSessionID = nil
        sourceMuteTapAttempted = false
        localReceiverIsPlaying = false
        playbackStatusHandler = nil
        sourceMuteTapTask?.cancel()
        // Keep an in-flight permission/setup task retained until it returns.
        // A quick stop/start must not launch a second Core Audio consent request.

        // Stop the delayed return before removing source suppression, avoiding
        // even a short duplicate render during teardown.
        localReceiver?.stop()
        localReceiver = nil
        if #available(macOS 14.2, *), let tap = sourceMuteTap as? SourceMuteTap {
            tap.stop()
        }
        sourceMuteTap = nil
        playbackMode = .directSource
    }

    @discardableResult
    func sendRoomMediaCommand(_ command: RoomMediaCommand) -> Bool {
        host?.sendRoomMediaCommand(command) ?? false
    }

    func requestResync(participantID: String? = nil) -> Bool {
        guard let host else { return false }
        return host.requestResync(participantID: participantID)
    }

    func diagnosticsSnapshot() -> SessionTimingDiagnostics {
        SessionTimingDiagnostics(
            receiver: localReceiver?.diagnosticsSnapshot(),
            host: host?.diagnosticsSnapshot()
        )
    }

    func setVideoEnabled(_ enabled: Bool) async throws {
        if enabled {
            guard videoPicker == nil, videoCapture == nil else {
                throw WERAIError("A display or window selection is already active.")
            }
            guard let host else { throw CancellationError() }
            let picker = ScreenContentPicker()
            videoPicker = picker
            let filter: SCContentFilter
            do {
                filter = try await picker.selectDisplayOrWindow()
                try Task.checkCancellation()
                guard self.host === host else { throw CancellationError() }
            } catch {
                picker.deactivate()
                if videoPicker === picker { videoPicker = nil }
                throw error
            }
            let encoder = VideoEncoder { frame in host.acceptVideo(frame) }
            let capture = ScreenVideoCapture()
            videoEncoder = encoder
            videoCapture = capture
            do {
                try await capture.start(filter: filter) { pixelBuffer, captureTimeNanos in
                    encoder.encode(pixelBuffer, captureTimeNanos: captureTimeNanos)
                } stopped: { [weak self, weak capture] error in
                    Task { @MainActor in
                        guard let self, let capture else { return }
                        let handled = await self.handleVideoCaptureStopped(capture, error: error)
                        if handled { self.videoStoppedHandler(error) }
                    }
                }
                try Task.checkCancellation()
                guard self.host === host, videoCapture === capture else {
                    throw CancellationError()
                }
                host.setVideoEnabled(true)
            } catch {
                picker.deactivate()
                if videoPicker === picker { videoPicker = nil }
                if videoCapture === capture { videoCapture = nil }
                if videoEncoder === encoder { videoEncoder = nil }
                await capture.stop()
                encoder.stop()
                throw error
            }
        } else {
            videoPicker?.deactivate()
            videoPicker = nil
            host?.setVideoEnabled(false)
            await videoCapture?.stop()
            videoCapture = nil
            videoEncoder?.stop()
            videoEncoder = nil
        }
    }

    @MainActor
    private func handleVideoCaptureStopped(_ capture: ScreenVideoCapture, error: Error) async -> Bool {
        guard videoCapture === capture else { return false }
        videoPicker?.deactivate()
        videoPicker = nil
        videoCapture = nil
        let encoder = videoEncoder
        videoEncoder = nil
        host?.setVideoEnabled(false)
        await capture.stop()
        encoder?.stop()
        fputs("Video sharing was disabled after capture stopped: \(error.localizedDescription)\n", stderr)
        return true
    }

    func stopImmediately() {
        if shouldPauseSourceOnStop { _ = playbackController?.perform(.pause) }
        shouldPauseSourceOnStop = false
        stopLocalPlayback()
        if let audioSource { Task { try? await audioSource.stop() } }
        videoPicker?.deactivate()
        videoPicker = nil
        nowPlayingMonitor?.stop()
        host?.setVideoEnabled(false)
        let activeVideoCapture = videoCapture
        self.videoCapture = nil
        let activeVideoEncoder = videoEncoder
        videoEncoder = nil
        if let activeVideoCapture {
            Task {
                await activeVideoCapture.stop()
                activeVideoEncoder?.stop()
            }
        } else {
            activeVideoEncoder?.stop()
        }
        host?.stop()
    }
}
