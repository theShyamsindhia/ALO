import CoreGraphics
import Foundation
import WERAICore

final class HostSession {
    private var host: HostServer?
    private var localReceiver: Receiver?
    private var capture: SystemAudioCapture?
    private var videoCapture: ScreenVideoCapture?
    private var videoEncoder: VideoEncoder?
    private var nowPlayingMonitor: NowPlayingMonitor?
    private var playbackController: SystemPlaybackController?
    private var muteTap: AnyObject?

    func start(
        roomName: String,
        statusHandler: @escaping (String) -> Void,
        receiverCountHandler: @escaping (Int) -> Void,
        initialVideoEnabled: Bool,
        identityHandler: @escaping (_ id: String, _ name: String) -> Void,
        participantsHandler: @escaping ([RoomParticipant]) -> Void,
        mediaStateHandler: @escaping (Bool) -> Void,
        nowPlayingHandler: @escaping (NowPlayingMedia) -> Void,
        chatHandler: @escaping (_ sender: String, _ text: String, _ sentNanos: UInt64) -> Void,
        queueHandler: @escaping ([RoomQueueItem]) -> Void,
        videoHandler: @escaping (CGImage) -> Void
    ) async throws {
        do {
            statusHandler("Opening your room")
            let playbackController = SystemPlaybackController()
            self.playbackController = playbackController
            let host = HostServer(
                roomName: roomName,
                statusHandler: statusHandler,
                receiverCountHandler: receiverCountHandler,
                playbackRequestHandler: { [weak playbackController] command in
                    playbackController?.perform(command) ?? false
                }
            )
            try host.start()
            self.host = host

            let localReceiver = try Receiver(
                requestedRoom: roomName,
                capturesSystemMediaCommands: false,
                statusHandler: { status in
                    if status == .playing {
                        statusHandler("This Mac is playing in sync")
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

            let nowPlayingMonitor = NowPlayingMonitor { [weak host] media in
                host?.setNowPlaying(media)
            }
            nowPlayingMonitor.start()
            self.nowPlayingMonitor = nowPlayingMonitor

            statusHandler("Starting synchronized audio")
            let capture = SystemAudioCapture()
            try await capture.start { samples, captureTimeNanos in
                host.acceptAudio(samples: samples, captureTimeNanos: captureTimeNanos)
            }
            self.capture = capture

            if initialVideoEnabled {
                try await setVideoEnabled(true)
            }

            guard #available(macOS 14.2, *) else {
                throw WERAIError("WERAI requires macOS 14.2 or newer.")
            }
            statusHandler("Synchronizing this Mac")
            let muteTap = SourceMuteTap()
            try await Task.detached(priority: .userInitiated) {
                try muteTap.start()
            }.value
            self.muteTap = muteTap
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
        try? await capture?.stop()
        capture = nil
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

    func sendRoomMediaCommand(_ command: RoomMediaCommand) {
        localReceiver?.sendRoomMediaCommand(command)
    }

    func setVideoEnabled(_ enabled: Bool) async throws {
        if enabled {
            guard videoCapture == nil, let host else { return }
            let encoder = VideoEncoder { frame in host.acceptVideo(frame) }
            let capture = ScreenVideoCapture()
            do {
                try await capture.start { pixelBuffer, captureTimeNanos in
                    encoder.encode(pixelBuffer, captureTimeNanos: captureTimeNanos)
                }
                videoEncoder = encoder
                videoCapture = capture
                host.setVideoEnabled(true)
            } catch {
                encoder.stop()
                throw error
            }
        } else {
            host?.setVideoEnabled(false)
            await videoCapture?.stop()
            videoCapture = nil
            videoEncoder?.stop()
            videoEncoder = nil
        }
    }

    func stopImmediately() {
        if #available(macOS 14.2, *), let muteTap = muteTap as? SourceMuteTap {
            muteTap.stop()
        }
        localReceiver?.stop()
        nowPlayingMonitor?.stop()
        host?.stop()
        videoEncoder?.stop()
        if let videoCapture {
            Task { await videoCapture.stop() }
        }
    }
}
