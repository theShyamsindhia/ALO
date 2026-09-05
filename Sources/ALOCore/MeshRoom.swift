import Foundation

public struct RoomConfiguration: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let creatorPeerID: String
    public let isPrivate: Bool
    public let accessKey: String?
    public let joinedAt: Date
    public var icon: RoomIcon?

    public init(
        id: String = UUID().uuidString,
        name: String,
        creatorPeerID: String = "",
        isPrivate: Bool = false,
        accessKey: String? = nil,
        joinedAt: Date = Date(),
        icon: RoomIcon? = nil
    ) {
        self.id = id
        self.name = name
        self.creatorPeerID = creatorPeerID
        self.isPrivate = isPrivate
        self.accessKey = isPrivate ? accessKey : nil
        self.joinedAt = joinedAt
        self.icon = icon?.isValid == true ? icon : nil
    }
}

public struct MeshVersion: Codable, Sendable, Equatable, Hashable, Comparable {
    public let counter: UInt64
    public let nodeID: String
    public let wallTimeMillis: UInt64

    public init(counter: UInt64, nodeID: String, wallTimeMillis: UInt64 = 0) {
        self.counter = counter
        self.nodeID = nodeID
        self.wallTimeMillis = wallTimeMillis
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        if lhs.nodeID != rhs.nodeID { return lhs.nodeID < rhs.nodeID }
        return lhs.wallTimeMillis < rhs.wallTimeMillis
    }
}

public enum MeshRoomEventKind: String, Codable, Sendable {
    case chat
    case queueAdd
    case queueRemove
    case broadcaster
    case playback
    case video
}

public struct MeshRoomEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let roomID: String
    public let version: MeshVersion
    public let kind: MeshRoomEventKind
    public let senderID: String?
    public let sender: String?
    public let text: String?
    public let sentNanos: UInt64?
    public let queueItem: RoomQueueItem?
    public let queueItemID: String?
    public let broadcasterID: String?
    public let broadcasterEpoch: UInt64?
    public let mediaServiceName: String?
    public let isBroadcasting: Bool?
    public let nowPlaying: NowPlayingMedia?
    public let videoEnabled: Bool?

    public init(
        id: String = UUID().uuidString,
        roomID: String,
        version: MeshVersion,
        kind: MeshRoomEventKind,
        senderID: String? = nil,
        sender: String? = nil,
        text: String? = nil,
        sentNanos: UInt64? = nil,
        queueItem: RoomQueueItem? = nil,
        queueItemID: String? = nil,
        broadcasterID: String? = nil,
        broadcasterEpoch: UInt64? = nil,
        mediaServiceName: String? = nil,
        isBroadcasting: Bool? = nil,
        nowPlaying: NowPlayingMedia? = nil,
        videoEnabled: Bool? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.version = version
        self.kind = kind
        self.senderID = senderID
        self.sender = sender
        self.text = text
        self.sentNanos = sentNanos
        self.queueItem = queueItem
        self.queueItemID = queueItemID
        self.broadcasterID = broadcasterID
        self.broadcasterEpoch = broadcasterEpoch
        self.mediaServiceName = mediaServiceName
        self.isBroadcasting = isBroadcasting
        self.nowPlaying = nowPlaying
        self.videoEnabled = videoEnabled
    }
}

public struct MeshBroadcaster: Sendable, Equatable {
    public let nodeID: String
    public let mediaServiceName: String
    public let version: MeshVersion
    public let epoch: UInt64

    public init(nodeID: String, mediaServiceName: String, version: MeshVersion, epoch: UInt64 = 0) {
        self.nodeID = nodeID
        self.mediaServiceName = mediaServiceName
        self.version = version
        self.epoch = epoch
    }
}

public struct MeshRoomReplica: Sendable, Equatable {
    public static let maximumChatEvents = 500
    public static let maximumQueueEvents = 5_000

    /// A moving ceiling rejects remote integer poisoning while leaving room for
    /// the next local event and broadcaster takeover.
    public static func hasPlausibleCounters(_ event: MeshRoomEvent, now: Date = Date()) -> Bool {
        let ceiling = UInt64(max(0, min(now.timeIntervalSince1970 * 1_000_000, Double(UInt64.max / 2))))
        return event.version.counter <= ceiling && (event.broadcasterEpoch ?? 0) <= ceiling
    }

    public private(set) var eventsByID = [String: MeshRoomEvent]()
    public private(set) var logicalClock: UInt64 = 0

    public init(events: [MeshRoomEvent] = []) {
        _ = merge(events)
    }

    @discardableResult
    public mutating func merge(_ events: [MeshRoomEvent]) -> [MeshRoomEvent] {
        var inserted = [MeshRoomEvent]()
        for event in events where eventsByID[event.id] == nil && Self.hasPlausibleCounters(event) {
            eventsByID[event.id] = event
            logicalClock = max(logicalClock, event.version.counter)
            inserted.append(event)
        }
        compactRetainedEvents()
        return inserted.filter { eventsByID[$0.id] != nil }
    }

    private mutating func compactRetainedEvents() {
        let ordered = events
        var retained = Array(ordered.filter { $0.kind == .chat }.suffix(Self.maximumChatEvents))
        var queueByItem = [String: MeshRoomEvent]()
        for event in ordered where event.kind == .queueAdd || event.kind == .queueRemove {
            guard let id = event.queueItem?.id ?? event.queueItemID else { continue }
            if queueByItem[id]?.kind != .queueRemove || event.kind == .queueRemove { queueByItem[id] = event }
        }
        retained += queueByItem.values.sorted { $0.version == $1.version ? $0.id < $1.id : $0.version < $1.version }
            .suffix(Self.maximumQueueEvents)
        if let playback = ordered.last(where: { $0.kind == .playback }) { retained.append(playback) }
        // A claim can race its video state. Keep the latest state for recent scopes.
        var videoByScope = [String: MeshRoomEvent]()
        for event in ordered where event.kind == .video {
            videoByScope["\(event.broadcasterID ?? "")/\(event.broadcasterEpoch ?? 0)"] = event
        }
        retained += videoByScope.values.sorted { $0.version == $1.version ? $0.id < $1.id : $0.version < $1.version }.suffix(128)
        let claims = ordered.filter { $0.kind == .broadcaster }
        if let claim = claims.filter({ $0.isBroadcasting == true }).max(by: broadcasterPrecedes) {
            retained.append(claim)
            if let stop = claims.last(where: { $0.isBroadcasting == false && $0.broadcasterID == claim.broadcasterID && $0.broadcasterEpoch == claim.broadcasterEpoch }) {
                retained.append(stop)
            }
        }
        // Preserve the epoch high-water mark even when it belongs to a stop.
        if let highest = claims.max(by: broadcasterPrecedes) { retained.append(highest) }
        eventsByID = Dictionary(retained.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public mutating func nextVersion(nodeID: String) -> MeshVersion {
        logicalClock += 1
        return MeshVersion(
            counter: logicalClock,
            nodeID: nodeID,
            wallTimeMillis: UInt64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    public var versionVector: [String: UInt64] {
        eventsByID.values.reduce(into: [:]) { vector, event in
            vector[event.version.nodeID] = max(vector[event.version.nodeID] ?? 0, event.version.counter)
        }
    }

    public func missingEvents(comparedWith vector: [String: UInt64]) -> [MeshRoomEvent] {
        events.filter { $0.version.counter > (vector[$0.version.nodeID] ?? 0) }
    }

    public var events: [MeshRoomEvent] {
        eventsByID.values.sorted {
            $0.version == $1.version ? $0.id < $1.id : $0.version < $1.version
        }
    }

    public var chatEvents: [MeshRoomEvent] {
        events.filter { $0.kind == .chat }
    }

    public var queue: [RoomQueueItem] {
        let removed = Set(events.lazy.filter { $0.kind == .queueRemove }.compactMap(\.queueItemID))
        return events.compactMap { event in
            guard event.kind == .queueAdd, let item = event.queueItem, !removed.contains(item.id) else {
                return nil
            }
            return item
        }
    }

    public var broadcaster: MeshBroadcaster? {
        let broadcasterEvents = eventsByID.values.filter { $0.kind == .broadcaster }
        let claims = broadcasterEvents.filter {
            $0.isBroadcasting == true && $0.broadcasterID != nil && $0.mediaServiceName != nil
        }
        guard let claim = claims.max(by: broadcasterPrecedes),
              let nodeID = claim.broadcasterID,
              let serviceName = claim.mediaServiceName
        else { return nil }
        let epoch = claim.broadcasterEpoch ?? 0
        let hasMatchingStop = broadcasterEvents.contains {
            $0.isBroadcasting == false &&
                $0.broadcasterID == nodeID &&
                ($0.broadcasterEpoch ?? 0) == epoch
        }
        guard !hasMatchingStop else { return nil }
        return MeshBroadcaster(nodeID: nodeID, mediaServiceName: serviceName, version: claim.version, epoch: epoch)
    }

    public var highestBroadcasterEpoch: UInt64 {
        eventsByID.values.lazy
            .filter { $0.kind == .broadcaster }
            .compactMap(\.broadcasterEpoch)
            .max() ?? 0
    }

    public var nowPlaying: NowPlayingMedia {
        latest(.playback)?.nowPlaying ?? NowPlayingMedia()
    }

    public var videoEnabled: Bool {
        guard let broadcaster else { return false }
        return eventsByID.values
            .filter {
                $0.kind == .video &&
                    $0.broadcasterID == broadcaster.nodeID &&
                    ($0.broadcasterEpoch ?? 0) == broadcaster.epoch
            }
            .max {
                $0.version == $1.version ? $0.id < $1.id : $0.version < $1.version
            }?
            .videoEnabled ?? false
    }

    private func latest(_ kind: MeshRoomEventKind) -> MeshRoomEvent? {
        eventsByID.values.filter { $0.kind == kind }.max {
            $0.version == $1.version ? $0.id < $1.id : $0.version < $1.version
        }
    }

    private func broadcasterPrecedes(_ lhs: MeshRoomEvent, _ rhs: MeshRoomEvent) -> Bool {
        let lhsEpoch = lhs.broadcasterEpoch ?? 0
        let rhsEpoch = rhs.broadcasterEpoch ?? 0
        if lhsEpoch != rhsEpoch { return lhsEpoch < rhsEpoch }
        let lhsNode = lhs.broadcasterID ?? ""
        let rhsNode = rhs.broadcasterID ?? ""
        if lhsNode != rhsNode { return lhsNode < rhsNode }
        return lhs.version == rhs.version ? lhs.id < rhs.id : lhs.version < rhs.version
    }
}

public struct MeshEnvelope: Codable, Sendable {
    public let type: String
    public let roomIcon: RoomIcon?
    public let room: RoomConfiguration?
    public let nodeID: String?
    public let displayName: String?
    public let deviceIcon: String?
    public let deviceColorHex: String?
    public private(set) var profileImageData: Data?
    public let appVersion: String?
    public let events: [MeshRoomEvent]?
    public let event: MeshRoomEvent?
    public let versionVector: [String: UInt64]?
    public let roomStateSyncVersion: UInt8?
    public let roomStateSyncID: String?
    public let roomStateSyncChunkIndex: UInt16?
    public let roomStateSyncChunkCount: UInt16?
    public let roomStateSyncMessage: Data?
    public let accessProof: String?
    public let heartbeatSequence: UInt64?
    public let heartbeatGeneration: String?
    public let authNonce: String?
    public let authResponse: String?
    public let requestID: String?
    public let broadcasterID: String?
    public let broadcasterEpoch: UInt64?
    public let mediaCommand: RoomMediaCommand?
    public let targetID: String?
    public let actionAttempt: UInt64?
    public let walkieTalkieHopCount: UInt8?
    /// Explicit recipients that still need routing after this hop. An empty
    /// array makes a direct-recipient envelope terminal.
    public let walkieTalkieRelayTargetIDs: [String]?
    public let walkieTalkie: WalkieTalkieMessage?
    public let openLine: OpenLineMessage?

    public init(
        type: String,
        roomIcon: RoomIcon? = nil,
        room: RoomConfiguration? = nil,
        nodeID: String? = nil,
        displayName: String? = nil,
        deviceIcon: String? = nil,
        deviceColorHex: String? = nil,
        profileImageData: Data? = nil,
        appVersion: String? = nil,
        events: [MeshRoomEvent]? = nil,
        event: MeshRoomEvent? = nil,
        versionVector: [String: UInt64]? = nil,
        roomStateSyncVersion: UInt8? = nil,
        roomStateSyncID: String? = nil,
        roomStateSyncChunkIndex: UInt16? = nil,
        roomStateSyncChunkCount: UInt16? = nil,
        roomStateSyncMessage: Data? = nil,
        accessProof: String? = nil,
        heartbeatSequence: UInt64? = nil,
        heartbeatGeneration: String? = nil,
        authNonce: String? = nil,
        authResponse: String? = nil,
        requestID: String? = nil,
        broadcasterID: String? = nil,
        broadcasterEpoch: UInt64? = nil,
        mediaCommand: RoomMediaCommand? = nil,
        targetID: String? = nil,
        actionAttempt: UInt64? = nil,
        walkieTalkieHopCount: UInt8? = nil,
        walkieTalkieRelayTargetIDs: [String]? = nil,
        walkieTalkie: WalkieTalkieMessage? = nil,
        openLine: OpenLineMessage? = nil
    ) {
        self.type = type
        self.roomIcon = roomIcon
        self.room = room
        self.nodeID = nodeID
        self.displayName = displayName
        self.deviceIcon = deviceIcon
        self.deviceColorHex = deviceColorHex
        self.profileImageData = DeviceAppearance.sanitizedProfileImageData(profileImageData)
        self.appVersion = appVersion
        self.events = events
        self.event = event
        self.versionVector = versionVector
        self.roomStateSyncVersion = roomStateSyncVersion
        self.roomStateSyncID = roomStateSyncID
        self.roomStateSyncChunkIndex = roomStateSyncChunkIndex
        self.roomStateSyncChunkCount = roomStateSyncChunkCount
        self.roomStateSyncMessage = roomStateSyncMessage
        self.accessProof = accessProof
        self.heartbeatSequence = heartbeatSequence
        self.heartbeatGeneration = heartbeatGeneration
        self.authNonce = authNonce
        self.authResponse = authResponse
        self.requestID = requestID
        self.broadcasterID = broadcasterID
        self.broadcasterEpoch = broadcasterEpoch
        self.mediaCommand = mediaCommand
        self.targetID = targetID
        self.actionAttempt = actionAttempt
        self.walkieTalkieHopCount = walkieTalkieHopCount
        self.walkieTalkieRelayTargetIDs = walkieTalkieRelayTargetIDs
        self.walkieTalkie = walkieTalkie
        self.openLine = openLine
    }

    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    fileprivate mutating func sanitizeProfileImageData() {
        profileImageData = DeviceAppearance.sanitizedProfileImageData(profileImageData)
    }
}

public final class MeshEnvelopeDecoder {
    public static let maximumLineBytes = 262_144
    private var buffer = Data()
    public private(set) var isOverflowed = false

    public init() {}

    public func append(_ data: Data) -> [MeshEnvelope] {
        guard !isOverflowed else { return [] }
        buffer.append(data)
        if buffer.count > Self.maximumLineBytes && !buffer.contains(0x0A) {
            buffer.removeAll(keepingCapacity: false)
            isOverflowed = true
            return []
        }
        var messages = [MeshEnvelope]()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard line.count <= Self.maximumLineBytes else {
                isOverflowed = true
                buffer.removeAll()
                return messages
            }
            if var message = try? JSONDecoder().decode(MeshEnvelope.self, from: line) {
                message.sanitizeProfileImageData()
                messages.append(message)
            }
        }
        return messages
    }
}
