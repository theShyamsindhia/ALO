import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ALOCore

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
    private var lastMediaReceivedAt = Date()
    private var spotifyTrackID: String?
    private var artworkTask: URLSessionDataTask?
    private var artworkRequestID: UUID?
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
            cancelArtworkRequest()
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
        let receivedAt = Date()
        let playbackRate = playbackRate(information["kMRMediaRemoteNowPlayingInfoPlaybackRate"])
        let duration = playbackTime(information["kMRMediaRemoteNowPlayingInfoDuration"])
        let media = NowPlayingMedia(
            title: clean(information["kMRMediaRemoteNowPlayingInfoTitle"] as? String),
            artist: clean(information["kMRMediaRemoteNowPlayingInfoArtist"] as? String),
            album: clean(information["kMRMediaRemoteNowPlayingInfoAlbum"] as? String),
            artworkData: normalizedArtwork(
                information["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
            ),
            sourceURL: firstWebURL(information),
            isPlaying: playbackRate.map { $0 > 0 },
            elapsedTime: Self.currentElapsedTime(
                elapsedTime: playbackTime(information["kMRMediaRemoteNowPlayingInfoElapsedTime"]),
                timestamp: information["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date,
                playbackRate: playbackRate,
                duration: duration,
                at: receivedAt
            ),
            duration: duration
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
        if spotifyTrackID != trackID { cancelArtworkRequest() }
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
            fetchSpotifyArtwork(trackID: trackID)
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

    private func cancelArtworkRequest() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestID = nil
    }

    private func fetchSpotifyArtwork(trackID: String) {
        guard artworkRequestID == nil else { return }
        var components = URLComponents(string: "https://open.spotify.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/track/\(trackID)")]
        guard let url = components?.url else { return }
        let requestID = UUID()
        artworkRequestID = requestID
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            self?.queue.async { [weak self] in
                guard let self, self.isRunning, self.artworkRequestID == requestID else { return }
                guard let data, data.count <= 65_536,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let urlString = object["thumbnail_url"] as? String,
                      let artworkURL = URL(string: urlString), artworkURL.scheme == "https" else {
                    self.cancelArtworkRequest(); return
                }
                self.artworkTask = URLSession.shared.dataTask(with: artworkURL) { [weak self] data, _, _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.isRunning, self.artworkRequestID == requestID else { return }
                        self.cancelArtworkRequest()
                        guard self.spotifyTrackID == trackID, let artwork = self.normalizedArtwork(data) else { return }
                        if self.artworkCache.count >= 24, let oldest = self.artworkCache.keys.first {
                            self.artworkCache.removeValue(forKey: oldest)
                        }
                        self.artworkCache[trackID] = artwork
                        if let updated = Self.applyingSpotifyArtwork(artwork, trackID: trackID, to: self.lastMedia) {
                            self.publish(updated)
                        }
                    }
                }
                self.artworkTask?.resume()
            }
        }
        artworkTask?.resume()
    }

    /// Artwork completion may arrive after a pause or after another player takes over.
    static func applyingSpotifyArtwork(_ artwork: Data, trackID: String, to media: NowPlayingMedia) -> NowPlayingMedia? {
        guard media.sourceURL == "https://open.spotify.com/track/\(trackID)" else { return nil }
        return NowPlayingMedia(title: media.title, artist: media.artist, album: media.album,
            artworkData: artwork, sourceURL: media.sourceURL, isPlaying: media.isPlaying,
            elapsedTime: media.elapsedTime, duration: media.duration,
            playbackControlsAvailable: media.playbackControlsAvailable)
    }

    private func publish(_ media: NowPlayingMedia) {
        let receivedAt = Date()
        let resolved = Self.preservingPlaybackTiming(
            in: media,
            from: lastMedia,
            previousReceivedAt: lastMediaReceivedAt,
            receivedAt: receivedAt
        )
        guard resolved != lastMedia else { return }
        lastMedia = resolved
        lastMediaReceivedAt = receivedAt
        handler(resolved)
    }

    static func preservingPlaybackTiming(
        in media: NowPlayingMedia,
        from previous: NowPlayingMedia,
        previousReceivedAt: Date,
        receivedAt: Date
    ) -> NowPlayingMedia {
        guard sameTrack(media, previous) else { return media }
        let elapsedTime = media.elapsedTime ?? previous.elapsedTime.map {
            $0 + (previous.isPlaying == true ? max(0, receivedAt.timeIntervalSince(previousReceivedAt)) : 0)
        }
        return NowPlayingMedia(
            title: media.title,
            artist: media.artist,
            album: media.album,
            artworkData: media.artworkData,
            sourceURL: media.sourceURL,
            isPlaying: media.isPlaying,
            elapsedTime: elapsedTime,
            duration: media.duration ?? previous.duration,
            playbackControlsAvailable: media.playbackControlsAvailable ?? previous.playbackControlsAvailable
        )
    }

    static func currentElapsedTime(
        elapsedTime: TimeInterval?,
        timestamp: Date?,
        playbackRate: Double?,
        duration: TimeInterval?,
        at date: Date
    ) -> TimeInterval? {
        guard let elapsedTime, elapsedTime.isFinite, elapsedTime >= 0 else { return nil }
        let advancement: TimeInterval
        if let timestamp, let playbackRate, playbackRate.isFinite, playbackRate > 0 {
            advancement = max(0, date.timeIntervalSince(timestamp)) * playbackRate
        } else {
            advancement = 0
        }
        let current = elapsedTime + advancement
        if let duration, duration.isFinite, duration > 0 { return min(current, duration) }
        return current
    }

    private static func sameTrack(_ lhs: NowPlayingMedia, _ rhs: NowPlayingMedia) -> Bool {
        let lhsIdentity = [lhs.title, lhs.artist, lhs.album].map(cleanIdentity)
        let rhsIdentity = [rhs.title, rhs.artist, rhs.album].map(cleanIdentity)
        if lhsIdentity.contains(where: { $0 != nil }) || rhsIdentity.contains(where: { $0 != nil }) {
            return lhsIdentity == rhsIdentity
        }
        return cleanIdentity(lhs.sourceURL) != nil && cleanIdentity(lhs.sourceURL) == cleanIdentity(rhs.sourceURL)
    }

    private static func cleanIdentity(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
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

    private func playbackRate(_ value: Any?) -> Double? {
        let rate: Double?
        if let number = value as? NSNumber { rate = number.doubleValue }
        else if let text = value as? String { rate = Double(text) }
        else { rate = nil }
        guard let rate, rate.isFinite, rate >= 0 else { return nil }
        return rate
    }

    private func playbackTime(_ value: Any?) -> TimeInterval? {
        let result: TimeInterval?
        if let number = value as? NSNumber { result = number.doubleValue }
        else if let text = value as? String { result = Double(text) }
        else { result = nil }
        guard let result, result.isFinite, result >= 0 else { return nil }
        return result
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
