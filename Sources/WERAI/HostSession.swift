import CoreGraphics
import Foundation
import WERAICore

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
    private var muteTap: AnyObject?
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

            guard #available(macOS 14.2, *) else {
                throw WERAIError("ALO requires macOS 14.2 or newer.")
            }
            statusHandler("Synchronizing this Mac")
            let muteTap = SourceMuteTap()
            try await Task.detached(priority: .userInitiated) {
                try muteTap.start()
            }.value
            self.muteTap = muteTap
            try Task.checkCancellation()

            statusHandler("Broadcasting this Mac · waiting for audio")
            let localReceiver = try Receiver(
                requestedRoom: roomName,
                participantID: participantID,
                capturesSystemMediaCommands: false,
                statusHandler: { status in
                    if status == .playing {
                        statusHandler("This Mac is playing in sync")
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

    func stop() async {
        // Releasing broadcaster ownership must also stop the source application;
        // otherwise a takeover leaves the old Mac playing locally after its
        // capture and room route have been removed.
        if shouldPauseSourceOnStop { _ = playbackController?.perform(.pause) }
        shouldPauseSourceOnStop = false
        if #available(macOS 14.2, *), let muteTap = muteTap as? SourceMuteTap {
            muteTap.stop()
        }
        muteTap = nil
        try? await audioSource?.stop()
        audioSource = nil
        videoPicker?.cancel()
        videoPicker = nil
        await videoCapture?.stop()
        videoCapture = nil
        videoEncoder?.stop()
        videoEncoder = nil
        nowPlayingMonitor?.stop()
        nowPlayingMonitor = nil
        playbackController = nil
        localReceiver?.stop()
        localReceiver = nil
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

    @discardableResult
    func sendRoomMediaCommand(_ command: RoomMediaCommand) -> Bool {
        host?.sendRoomMediaCommand(command) ?? false
    }

    func requestResync(participantID: String? = nil) -> Bool {
        guard let host else { return false }
        return host.requestResync(participantID: participantID)
    }

    func setVideoEnabled(_ enabled: Bool) async throws {
        if enabled {
            guard videoPicker == nil, videoCapture == nil, let host else { return }
            let picker = ScreenContentPicker()
            videoPicker = picker
            defer {
                if videoPicker === picker { videoPicker = nil }
            }
            let filter = try await picker.selectDisplayOrWindow()
            try Task.checkCancellation()
            guard self.host === host else { throw CancellationError() }
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
                if videoCapture === capture { videoCapture = nil }
                if videoEncoder === encoder { videoEncoder = nil }
                await capture.stop()
                encoder.stop()
                throw error
            }
        } else {
            videoPicker?.cancel()
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
        if #available(macOS 14.2, *), let muteTap = muteTap as? SourceMuteTap {
            muteTap.stop()
        }
        if let audioSource { Task { try? await audioSource.stop() } }
        videoPicker?.cancel()
        videoPicker = nil
        localReceiver?.stop()
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
