import Foundation

public enum RoomMediaCommand: String, Codable, Sendable, Equatable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
}

public struct RoomParticipant: Codable, Sendable, Equatable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id, name, volume, isMuted, icon, colorHex, profileImageData
    }

    public let id: String
    public let name: String
    public let volume: Double
    public let isMuted: Bool
    public let icon: String?
    public let colorHex: String?
    public let profileImageData: Data?
    /// Ephemeral display data, never persisted or encoded in participant identity.
    public var playbackTiming: PeerPlaybackTiming? = nil
    /// Learned from the authenticated room handshake and kept out of durable room state.
    public var appVersion: String? = nil

    public init(
        id: String,
        name: String,
        volume: Double = 1,
        isMuted: Bool = false,
        icon: String? = nil,
        colorHex: String? = nil,
        profileImageData: Data? = nil,
        appVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.volume = volume
        self.isMuted = isMuted
        self.icon = icon
        self.colorHex = colorHex
        self.profileImageData = DeviceAppearance.sanitizedProfileImageData(profileImageData)
        self.appVersion = appVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        volume = try values.decode(Double.self, forKey: .volume)
        isMuted = try values.decode(Bool.self, forKey: .isMuted)
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        colorHex = try values.decodeIfPresent(String.self, forKey: .colorHex)
        profileImageData = DeviceAppearance.sanitizedProfileImageData(
            try values.decodeIfPresent(Data.self, forKey: .profileImageData)
        )
    }
}

public struct NowPlayingMedia: Codable, Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let artworkData: Data?
    public let sourceURL: String?
    public let isPlaying: Bool?
    public let elapsedTime: TimeInterval?
    public let duration: TimeInterval?
    /// Nil keeps compatibility with older peers and means the broadcaster has
    /// not restricted global playback controls. False is used for app-scoped
    /// capture, where a global media command could control the wrong app.
    public let playbackControlsAvailable: Bool?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        artworkData: Data? = nil,
        sourceURL: String? = nil,
        isPlaying: Bool? = nil,
        elapsedTime: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        playbackControlsAvailable: Bool? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
        self.sourceURL = sourceURL
        self.isPlaying = isPlaying
        self.elapsedTime = elapsedTime
        self.duration = duration
        self.playbackControlsAvailable = playbackControlsAvailable
    }

    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && artworkData == nil
    }

    public func playbackProgress(elapsedSinceReceipt: TimeInterval = 0) -> Double? {
        guard let duration, duration.isFinite, duration > 0,
              let elapsedTime, elapsedTime.isFinite, elapsedTime >= 0
        else { return nil }
        let advancement = isPlaying == true && elapsedSinceReceipt.isFinite
            ? max(0, elapsedSinceReceipt)
            : 0
        return min(1, max(0, (elapsedTime + advancement) / duration))
    }
}

public struct RoomQueueItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let url: String
    public let addedBy: String
    public let addedByID: String
    public let addedNanos: UInt64

    public init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        url: String,
        addedBy: String = "",
        addedByID: String = "",
        addedNanos: UInt64 = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.addedBy = addedBy
        self.addedByID = addedByID
        self.addedNanos = addedNanos
    }
}

/// Relative observations at the receiver's UI handoff, not physical display or
/// lip-sync measurements. No receiver monotonic timestamp crosses this boundary.
public struct PlaybackScreenTimingReport: Codable, Sendable, Equatable {
    public let latestHandoffAgeNanos: UInt64?
    public let latestDeadlineMissNanos: UInt64?
    public let oldestPendingDeadlineMissNanos: UInt64?

    public init(latestHandoffAgeNanos: UInt64? = nil, latestDeadlineMissNanos: UInt64? = nil,
                oldestPendingDeadlineMissNanos: UInt64? = nil) {
        self.latestHandoffAgeNanos = latestHandoffAgeNanos
        self.latestDeadlineMissNanos = latestDeadlineMissNanos
        self.oldestPendingDeadlineMissNanos = oldestPendingDeadlineMissNanos
    }
}

public struct PlaybackSyncReport: Codable, Sendable, Equatable {
    public let measuredAtNanos: UInt64
    public let latenessNanos: UInt64
    public let latePacketCount: UInt64
    public let resyncCount: UInt64
    /// Current render-timeline error, independent of packet underflow history.
    /// Optional so older peers can still decode and send the original report.
    public let driftNanos: UInt64?
    public let driftSampleAgeNanos: UInt64?
    public let screenTiming: PlaybackScreenTimingReport?
    /// Present means this receiver owns drift realignment; the host must not run a duplicate loop.
    public let automaticSyncEnabled: Bool?

    public init(
        measuredAtNanos: UInt64,
        latenessNanos: UInt64,
        latePacketCount: UInt64,
        resyncCount: UInt64,
        driftNanos: UInt64? = nil,
        driftSampleAgeNanos: UInt64? = nil,
        screenTiming: PlaybackScreenTimingReport? = nil,
        automaticSyncEnabled: Bool? = nil
    ) {
        self.measuredAtNanos = measuredAtNanos
        self.latenessNanos = latenessNanos
        self.latePacketCount = latePacketCount
        self.resyncCount = resyncCount
        self.driftNanos = driftNanos
        self.driftSampleAgeNanos = driftSampleAgeNanos
        self.screenTiming = screenTiming
        self.automaticSyncEnabled = automaticSyncEnabled
    }
}

public struct ControlMessage: Codable, Sendable {
    public let mediaSessionID: UUID?
    public let type: String
    public let udpPort: UInt16?
    public let videoPort: UInt16?
    public let displayName: String?
    public let participantID: String?
    public let targetID: String?
    public let volume: Double?
    public let muted: Bool?
    public let videoEnabled: Bool?
    public let id: UInt64?
    public let clientNanos: UInt64?
    public let hostNanos: UInt64?
    public let playoutDelayNanos: UInt64?
    public let outputLatencyPlayoutFloorNanos: UInt64?
    public let sender: String?
    public let text: String?
    public let sentNanos: UInt64?
    public let participants: [String]?
    public let participantDetails: [RoomParticipant]?
    public let nowPlaying: NowPlayingMedia?
    public let mediaQueue: [RoomQueueItem]?
    public let queueItem: RoomQueueItem?
    public let queueItemID: String?
    public let syncReport: PlaybackSyncReport?
    public let isPlaying: Bool?
    public let mediaCommand: RoomMediaCommand?

    public init(
        type: String,
        mediaSessionID: UUID? = nil,
        udpPort: UInt16? = nil,
        videoPort: UInt16? = nil,
        displayName: String? = nil,
        participantID: String? = nil,
        targetID: String? = nil,
        volume: Double? = nil,
        muted: Bool? = nil,
        videoEnabled: Bool? = nil,
        id: UInt64? = nil,
        clientNanos: UInt64? = nil,
        hostNanos: UInt64? = nil,
        playoutDelayNanos: UInt64? = nil,
        outputLatencyPlayoutFloorNanos: UInt64? = nil,
        sender: String? = nil,
        text: String? = nil,
        sentNanos: UInt64? = nil,
        participants: [String]? = nil,
        participantDetails: [RoomParticipant]? = nil,
        nowPlaying: NowPlayingMedia? = nil,
        mediaQueue: [RoomQueueItem]? = nil,
        queueItem: RoomQueueItem? = nil,
        queueItemID: String? = nil,
        syncReport: PlaybackSyncReport? = nil,
        isPlaying: Bool? = nil,
        mediaCommand: RoomMediaCommand? = nil
    ) {
        self.mediaSessionID = mediaSessionID
        self.type = type
        self.udpPort = udpPort
        self.videoPort = videoPort
        self.displayName = displayName
        self.participantID = participantID
        self.targetID = targetID
        self.volume = volume
        self.muted = muted
        self.videoEnabled = videoEnabled
        self.id = id
        self.clientNanos = clientNanos
        self.hostNanos = hostNanos
        self.playoutDelayNanos = playoutDelayNanos
        self.outputLatencyPlayoutFloorNanos = outputLatencyPlayoutFloorNanos
        self.sender = sender
        self.text = text
        self.sentNanos = sentNanos
        self.participants = participants
        self.participantDetails = participantDetails
        self.nowPlaying = nowPlaying
        self.mediaQueue = mediaQueue
        self.queueItem = queueItem
        self.queueItemID = queueItemID
        self.syncReport = syncReport
        self.isPlaying = isPlaying
        self.mediaCommand = mediaCommand
    }

    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}

public final class ControlLineDecoder {
    public static let defaultMaximumLineBytes = 1_048_576
    private var buffer = Data()
    private let maximumLineBytes: Int
    public private(set) var isOverflowed = false
    public var bufferedByteCount: Int { buffer.count }

    public init(maximumLineBytes: Int = defaultMaximumLineBytes) {
        precondition(maximumLineBytes > 0)
        self.maximumLineBytes = maximumLineBytes
    }

    public func append(_ data: Data) -> [ControlMessage] {
        guard !isOverflowed else { return [] }
        var messages = [ControlMessage]()
        // Never copy an unbounded network read into retained storage. The cap
        // applies to each line, including an unterminated tail after valid lines.
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let newline = data[cursor...].firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            guard end - cursor <= maximumLineBytes - buffer.count else {
                isOverflowed = true
                buffer = Data()
                return messages
            }
            buffer.append(data[cursor..<end])
            guard let newline else { break }
            if let message = try? JSONDecoder().decode(ControlMessage.self, from: buffer) {
                messages.append(message)
            }
            buffer.removeAll(keepingCapacity: true)
            cursor = data.index(after: newline)
        }
        return messages
    }
}
