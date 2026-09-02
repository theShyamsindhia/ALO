import Foundation

public struct RoomParticipant: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let volume: Double
    public let isMuted: Bool

    public init(id: String, name: String, volume: Double = 1, isMuted: Bool = false) {
        self.id = id
        self.name = name
        self.volume = volume
        self.isMuted = isMuted
    }
}

public struct NowPlayingMedia: Codable, Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let artworkData: Data?
    public let sourceURL: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        artworkData: Data? = nil,
        sourceURL: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
        self.sourceURL = sourceURL
    }

    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && artworkData == nil
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

public struct ControlMessage: Codable, Sendable {
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
    public let sender: String?
    public let text: String?
    public let sentNanos: UInt64?
    public let participants: [String]?
    public let participantDetails: [RoomParticipant]?
    public let nowPlaying: NowPlayingMedia?
    public let mediaQueue: [RoomQueueItem]?
    public let queueItem: RoomQueueItem?
    public let queueItemID: String?

    public init(
        type: String,
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
        sender: String? = nil,
        text: String? = nil,
        sentNanos: UInt64? = nil,
        participants: [String]? = nil,
        participantDetails: [RoomParticipant]? = nil,
        nowPlaying: NowPlayingMedia? = nil,
        mediaQueue: [RoomQueueItem]? = nil,
        queueItem: RoomQueueItem? = nil,
        queueItemID: String? = nil
    ) {
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
        self.sender = sender
        self.text = text
        self.sentNanos = sentNanos
        self.participants = participants
        self.participantDetails = participantDetails
        self.nowPlaying = nowPlaying
        self.mediaQueue = mediaQueue
        self.queueItem = queueItem
        self.queueItemID = queueItemID
    }

    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}

public final class ControlLineDecoder {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) -> [ControlMessage] {
        buffer.append(data)
        var messages = [ControlMessage]()

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let message = try? JSONDecoder().decode(ControlMessage.self, from: line) {
                messages.append(message)
            }
        }
        return messages
    }
}
