import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WERAICore

final class NowPlayingMonitor {
    private typealias InfoCallback = @convention(block) (NSDictionary) -> Void
    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping InfoCallback) -> Void

    private let queue = DispatchQueue(label: "in.werai.now-playing", qos: .utility)
    private let handler: (NowPlayingMedia) -> Void
    private let frameworkHandle: UnsafeMutableRawPointer?
    private let getInfo: GetInfo?
    private var timer: DispatchSourceTimer?
    private var notificationObservers = [NSObjectProtocol]()
    private var lastMedia = NowPlayingMedia()
    private var spotifyTrackID: String?
    private var artworkCache = [String: Data]()
    private var isRunning = false

    init(handler: @escaping (NowPlayingMedia) -> Void) {
        self.handler = handler
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        let handle = dlopen(path, RTLD_LAZY)
        frameworkHandle = handle
        if let handle, let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getInfo = unsafeBitCast(symbol, to: GetInfo.self)
        } else {
            getInfo = nil
        }
    }

    deinit {
        if let frameworkHandle { dlclose(frameworkHandle) }
    }

    func start() {
        guard timer == nil, notificationObservers.isEmpty else { return }
        isRunning = true
        observePlayerNotifications()
        if getInfo != nil {
            requestInfo()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 4, repeating: 4, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.requestUpdate() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        notificationObservers.forEach(center.removeObserver)
        notificationObservers.removeAll()
        queue.sync {
            isRunning = false
            timer?.cancel()
            timer = nil
        }
    }

    private func requestUpdate() {
        guard isRunning else { return }
        DispatchQueue.main.async { [weak self] in
            self?.requestInfo()
        }
    }

    private func requestInfo() {
        guard isRunning, let getInfo else { return }
        getInfo(DispatchQueue.global(qos: .utility)) { [weak self] information in
            self?.queue.async { self?.consume(information) }
        }
    }

    private func consume(_ information: NSDictionary) {
        guard isRunning else { return }
        let media = NowPlayingMedia(
            title: clean(information["kMRMediaRemoteNowPlayingInfoTitle"] as? String),
            artist: clean(information["kMRMediaRemoteNowPlayingInfoArtist"] as? String),
            album: clean(information["kMRMediaRemoteNowPlayingInfoAlbum"] as? String),
            artworkData: normalizedArtwork(
                information["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
            ),
            sourceURL: firstWebURL(information),
            isPlaying: playbackState(information["kMRMediaRemoteNowPlayingInfoPlaybackRate"])
        )
        guard !media.isEmpty else { return }
        publish(media)
    }

    private func observePlayerNotifications() {
        let center = DistributedNotificationCenter.default()
        notificationObservers.append(
            center.addObserver(
                forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
                object: nil,
                queue: nil
            ) { [weak self] notification in
                let userInfo = notification.userInfo ?? [:]
                self?.queue.async { self?.consumeSpotify(userInfo) }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: Notification.Name("com.apple.Music.playerInfo"),
                object: nil,
                queue: nil
            ) { [weak self] notification in
                let userInfo = notification.userInfo ?? [:]
                self?.queue.async { self?.consumeMusic(userInfo) }
            }
        )
    }

    private func consumeSpotify(_ information: [AnyHashable: Any]) {
        guard isRunning else { return }
        let trackID = (information["Track ID"] as? String)?
            .split(separator: ":")
            .last
            .map(String.init)
        spotifyTrackID = trackID
        let media = NowPlayingMedia(
            title: clean(information["Name"] as? String),
            artist: clean(information["Artist"] as? String),
            album: clean(information["Album"] as? String),
            artworkData: trackID.flatMap { artworkCache[$0] },
            sourceURL: trackID.map { "https://open.spotify.com/track/\($0)" },
            isPlaying: playbackState(information["Player State"])
        )
        publish(media)
        if let trackID, media.artworkData == nil {
            fetchSpotifyArtwork(trackID: trackID, media: media)
        }
    }

    private func consumeMusic(_ information: [AnyHashable: Any]) {
        guard isRunning else { return }
        publish(NowPlayingMedia(
            title: clean(information["Name"] as? String),
            artist: clean(information["Artist"] as? String),
            album: clean(information["Album"] as? String),
            sourceURL: firstWebURL(information),
            isPlaying: playbackState(information["Player State"])
        ))
    }

    private func fetchSpotifyArtwork(trackID: String, media: NowPlayingMedia) {
        var components = URLComponents(string: "https://open.spotify.com/oembed")
        components?.queryItems = [
            URLQueryItem(
                name: "url",
                value: "https://open.spotify.com/track/\(trackID)"
            )
        ]
        guard let url = components?.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artworkURLString = object["thumbnail_url"] as? String,
                  let artworkURL = URL(string: artworkURLString)
            else { return }
            URLSession.shared.dataTask(with: artworkURL) { [weak self] data, _, _ in
                guard let self, let artwork = self.normalizedArtwork(data) else { return }
                self.queue.async {
                    guard self.isRunning, self.spotifyTrackID == trackID else { return }
                    if self.artworkCache.count >= 24, let oldest = self.artworkCache.keys.first {
                        self.artworkCache.removeValue(forKey: oldest)
                    }
                    self.artworkCache[trackID] = artwork
                    self.publish(NowPlayingMedia(
                        title: media.title,
                        artist: media.artist,
                        album: media.album,
                        artworkData: artwork,
                        sourceURL: media.sourceURL,
                        isPlaying: media.isPlaying
                    ))
                }
            }.resume()
        }.resume()
    }

    private func publish(_ media: NowPlayingMedia) {
        guard media != lastMedia else { return }
        lastMedia = media
        handler(media)
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(180))
    }

    private func playbackState(_ value: Any?) -> Bool? {
        if let rate = value as? NSNumber { return rate.doubleValue > 0 }
        guard let state = value as? String else { return nil }
        switch state.lowercased() {
        case "playing", "play": return true
        case "paused", "stopped", "pause", "stop": return false
        default: return nil
        }
    }

    private func firstWebURL(_ information: NSDictionary) -> String? {
        let keys = [
            "Store URL",
            "URL",
            "kMRMediaRemoteNowPlayingInfoExternalContentIdentifier",
            "kMRMediaRemoteNowPlayingInfoContentItemIdentifier"
        ]
        for key in keys {
            guard let value = information[key] as? String,
                  let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { continue }
            return url.absoluteString
        }
        return nil
    }

    private func firstWebURL(_ information: [AnyHashable: Any]) -> String? {
        firstWebURL(information as NSDictionary)
    }

    private func normalizedArtwork(_ data: Data?) -> Data? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256
                ] as CFDictionary
              )
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), output.length <= 180_000 else { return nil }
        return output as Data
    }
}

final class SystemPlaybackController {
    private typealias SendCommand = @convention(c) (Int, CFDictionary?) -> Bool
    private let frameworkHandle: UnsafeMutableRawPointer?
    private let sendCommand: SendCommand?

    init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        let handle = dlopen(path, RTLD_LAZY)
        frameworkHandle = handle
        if let handle, let symbol = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(symbol, to: SendCommand.self)
        } else {
            sendCommand = nil
        }
    }

    deinit {
        if let frameworkHandle { dlclose(frameworkHandle) }
    }

    func perform(_ command: RoomMediaCommand) -> Bool {
        let commandValue: Int
        switch command {
        case .play: commandValue = 0
        case .pause: commandValue = 1
        case .togglePlayPause: commandValue = 2
        case .nextTrack: commandValue = 4
        case .previousTrack: commandValue = 5
        }
        return sendCommand?(commandValue, nil) ?? false
    }
}
