import CoreGraphics
import Foundation
import ScreenCaptureKit
import ALOCore

enum BroadcasterPlaybackMode: Equatable {
    case directSource
    case synchronizedReceiver

    /// Muting the original render is safe only when the tap itself is also the
    /// room's audio source. Otherwise ScreenCaptureKit is starved and every
    /// remote Receiver falls silent.
    static func resolve(
        sourceMuteTapActive: Bool,
        sourceMuteTapFeedsRoomAudio: Bool
    ) -> Self {
        sourceMuteTapActive && sourceMuteTapFeedsRoomAudio
            ? .synchronizedReceiver
            : .directSource
    }

    static var unifiedTapSource: Self {
        resolve(sourceMuteTapActive: true, sourceMuteTapFeedsRoomAudio: true)
    }

    var mutesSynchronizedReceiver: Bool {
        self == .directSource
    }

}

private final class SourcePlaybackActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func update(_ value: Bool?) {
        guard let value else { return }
        lock.withLock { self.value = value }
    }

    func current() -> Bool? { lock.withLock { value } }
}

@MainActor
final class HostSession {
    nonisolated static var synchronizedPlaybackMode: BroadcasterPlaybackMode {
        .unifiedTapSource
    }

    private var host: HostServer?
    private var localReceiver: Receiver?
    private var audioSource: AudioSource?
    private var videoPicker: ScreenContentPicker?
    private var videoCapture: ScreenVideoCapture?
    private var videoEncoder: VideoEncoder?
    private var nowPlayingMonitor: NowPlayingMonitor?
    private var playbackController: SystemPlaybackController?
    private var shouldPauseSourceOnStop = false
    private var videoStoppedHandler: (Error) -> Void = { _ in }
    func start(
        roomName: String,
        participantID: String = UUID().uuidString,
        audioOutput: RoomAudioOutputEngine = RoomAudioOutputEngine(),
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
        audioStoppedHandler: @escaping @Sendable (Error) -> Void = { _ in },
        videoStoppedHandler: @escaping (Error) -> Void = { _ in }
    ) async throws {
        do {
            self.videoStoppedHandler = videoStoppedHandler
            try Task.checkCancellation()
            statusHandler("Opening your room")
            statusHandler("Preparing system audio capture")
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

            let sourcePlaybackActivity = SourcePlaybackActivity()
            let nowPlayingMonitor = NowPlayingMonitor { [weak host] media in
                sourcePlaybackActivity.update(media.isPlaying)
                host?.setNowPlaying(media)
            }
            nowPlayingMonitor.start()
            self.nowPlayingMonitor = nowPlayingMonitor

            let (source, playbackMode) = try await startAudioSource(
                host: host,
                statusHandler: statusHandler,
                sourcePlaybackIsActive: { sourcePlaybackActivity.current() },
                audioStoppedHandler: audioStoppedHandler
            )
            audioSource = source
            shouldPauseSourceOnStop = true
            try Task.checkCancellation()

            statusHandler("Broadcasting this Mac · waiting for audio")
            let localReceiver = try Receiver(
                requestedRoom: roomName,
                audioOutput: audioOutput,
                participantID: participantID,
                capturesSystemMediaCommands: false,
                statusHandler: { status in
                    if status == .playing {
                        statusHandler(
                            playbackMode == .synchronizedReceiver
                                ? "This Mac is playing in sync"
                                : "Broadcasting this Mac · local playback is not delayed"
                        )
                    } else if status == .silent {
                        statusHandler("Broadcasting this Mac · waiting for audio")
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
            try localReceiver.start()
            localReceiver.setLocalPlaybackMuted(playbackMode.mutesSynchronizedReceiver)
            self.localReceiver = localReceiver
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

    private func startAudioSource(
        host: HostServer,
        statusHandler: @escaping (String) -> Void,
        sourcePlaybackIsActive: @escaping @Sendable () -> Bool?,
        audioStoppedHandler: @escaping @Sendable (Error) -> Void
    ) async throws -> (AudioSource, BroadcasterPlaybackMode) {
        let handler: AudioSource.AudioHandler = { samples, captureTimeNanos in
            host.acceptAudio(samples: samples, captureTimeNanos: captureTimeNanos)
        }

        guard #available(macOS 14.2, *) else {
            throw ALOError("Synchronized broadcasting requires macOS 14.2 or newer.")
        }
        statusHandler("Starting one synchronized audio path")
        let tapSource = SystemAudioTapCapture(
            sourcePlaybackIsActive: sourcePlaybackIsActive,
            unexpectedStopHandler: { [weak self] error in
                Task { @MainActor [weak self] in
                    // A capture failure is not a user media command. Once the
                    // muting tap is detached, let the source app continue at
                    // its real playback state instead of sending Pause.
                    self?.shouldPauseSourceOnStop = false
                    audioStoppedHandler(error)
                }
            }
        )
        do {
            try await tapSource.start(audioHandler: handler)
        } catch {
            if let tapError = error as? SystemAudioTapCaptureError,
               tapError.isPermissionFailure {
                throw ALOError(
                    "System audio access was denied. Enable ALO under Privacy & Security → System Audio Recording Only, then try again."
                )
            }
            throw ALOError(
                "ALO could not start synchronized system audio. Open Diagnostics for capture and permission checks. (\(error.localizedDescription))"
            )
        }
        return (tapSource, Self.synchronizedPlaybackMode)
    }

    func stop() async {
        // Releasing broadcaster ownership must also stop the source application;
        // otherwise a takeover leaves the old Mac playing locally after its
        // capture and room route have been removed.
        if shouldPauseSourceOnStop { _ = playbackController?.perform(.pause) }
        shouldPauseSourceOnStop = false
        localReceiver?.stop()
        localReceiver = nil
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

    func setLocalPlaybackMuted(_ muted: Bool) {
        localReceiver?.setLocalPlaybackMuted(muted)
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
                throw ALOError("A display or window selection is already active.")
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
        localReceiver?.stop()
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
