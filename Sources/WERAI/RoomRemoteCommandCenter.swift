import Foundation
import MediaPlayer
import WERAICore

final class RoomRemoteCommandCenter {
    private let handler: (RoomMediaCommand) -> Bool
    private let lock = NSLock()
    private var targets = [(command: MPRemoteCommand, token: Any)]()
    private var roomName = "ALO Room"
    private var media = NowPlayingMedia()
    private var isRunning = false

    init(handler: @escaping (RoomMediaCommand) -> Bool) {
        self.handler = handler
    }

    func start(roomName: String) {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        self.roomName = roomName
        lock.unlock()

        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand, command: .play)
        register(center.pauseCommand, command: .pause)
        register(center.togglePlayPauseCommand, command: .togglePlayPause)
        register(center.nextTrackCommand, command: .nextTrack)
        register(center.previousTrackCommand, command: .previousTrack)
        publishNowPlaying()
    }

    func update(_ media: NowPlayingMedia) {
        lock.lock()
        self.media = media
        lock.unlock()
        publishNowPlaying()
    }

    func stop() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        isRunning = false
        let registeredTargets = targets
        targets.removeAll()
        lock.unlock()

        for target in registeredTargets {
            target.command.removeTarget(target.token)
            target.command.isEnabled = false
        }
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    private func register(_ remoteCommand: MPRemoteCommand, command: RoomMediaCommand) {
        remoteCommand.isEnabled = true
        let token = remoteCommand.addTarget { [weak self] _ in
            self?.handle(command) ?? .commandFailed
        }
        lock.lock()
        targets.append((remoteCommand, token))
        lock.unlock()
    }

    private func handle(_ command: RoomMediaCommand) -> MPRemoteCommandHandlerStatus {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return .noSuchContent
        }
        lock.unlock()
        // Keep the current macOS Now Playing state until the broadcaster confirms
        // the command by publishing authoritative metadata. This avoids showing a
        // pause/play that never reached the room during a reconnect.
        return handler(command) ? .success : .commandFailed
    }

    static func playbackState(after command: RoomMediaCommand, current: Bool) -> Bool? {
        switch command {
        case .play: true
        case .pause: false
        case .togglePlayPause: !current
        case .nextTrack, .previousTrack: nil
        }
    }

    private func publishNowPlaying() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        let media = media
        let roomName = roomName
        lock.unlock()

        let isPlaying = media.isPlaying ?? true
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: media.title ?? roomName,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let artist = media.artist { information[MPMediaItemPropertyArtist] = artist }
        if let album = media.album { information[MPMediaItemPropertyAlbumTitle] = album }

        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = information
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }

}
