import CoreGraphics
import Foundation
import WERAICore

final class HostSession {
    private var host: HostServer?
    private var localReceiver: Receiver?
    private var audioSource: AudioSource?
    private var videoCapture: ScreenVideoCapture?
    private var videoEncoder: VideoEncoder?
    private let virtualDisplayOwner: VirtualDisplayOwner
    private var nowPlayingMonitor: NowPlayingMonitor?
    private var playbackController: SystemPlaybackController?
    private var muteTap: AnyObject?
    private var videoStoppedHandler: (Error) -> Void = { _ in }
    init(virtualDisplayFactory: @escaping () throws -> VirtualDisplayManaging = { try VirtualDisplayManager() }) {
        self.virtualDisplayOwner = VirtualDisplayOwner(factory: virtualDisplayFactory)
    }

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
        if #available(macOS 14.2, *), let muteTap = muteTap as? SourceMuteTap {
            muteTap.stop()
        }
        muteTap = nil
        try? await audioSource?.stop()
        audioSource = nil
        await videoCapture?.stop()
        videoCapture = nil
        videoEncoder?.stop()
        videoEncoder = nil
        virtualDisplayOwner.stop()
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

    func sendRoomMediaCommand(_ command: RoomMediaCommand) {
        localReceiver?.sendRoomMediaCommand(command)
    }

    func setVideoEnabled(_ enabled: Bool) async throws {
        if enabled {
            guard videoCapture == nil, let host else { return }
            let displayID = try virtualDisplayOwner.create()
            let encoder = VideoEncoder { frame in host.acceptVideo(frame) }
            let capture = ScreenVideoCapture()
            videoEncoder = encoder
            videoCapture = capture
            do {
                try await capture.start(displayID: displayID) { pixelBuffer, captureTimeNanos in
                    encoder.encode(pixelBuffer, captureTimeNanos: captureTimeNanos)
                } stopped: { [weak self, weak capture] error in
                    Task { @MainActor in
                        guard let self, let capture else { return }
                        let handled = await self.handleVideoCaptureStopped(capture, error: error)
                        if handled { self.videoStoppedHandler(error) }
                    }
                }
                host.setVideoEnabled(true)
            } catch {
                if videoCapture === capture { videoCapture = nil }
                if videoEncoder === encoder { videoEncoder = nil }
                await capture.stop()
                encoder.stop()
                virtualDisplayOwner.stop()
                throw error
            }
        } else {
            host?.setVideoEnabled(false)
            await videoCapture?.stop()
            videoCapture = nil
            videoEncoder?.stop()
            videoEncoder = nil
            virtualDisplayOwner.stop()
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
        virtualDisplayOwner.stop()
        fputs("Video sharing was disabled after capture stopped: \(error.localizedDescription)\n", stderr)
        return true
    }

    func stopImmediately() {
        if #available(macOS 14.2, *), let muteTap = muteTap as? SourceMuteTap {
            muteTap.stop()
        }
        if let audioSource { Task { try? await audioSource.stop() } }
        localReceiver?.stop()
        nowPlayingMonitor?.stop()
        host?.setVideoEnabled(false)
        let activeVideoCapture = videoCapture
        self.videoCapture = nil
        let activeVideoEncoder = videoEncoder
        videoEncoder = nil
        let displayOwner = virtualDisplayOwner
        if let activeVideoCapture {
            Task {
                await activeVideoCapture.stop()
                activeVideoEncoder?.stop()
                displayOwner.stop()
            }
        } else {
            activeVideoEncoder?.stop()
            displayOwner.stop()
        }
        host?.stop()
    }
}
