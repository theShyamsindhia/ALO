import Foundation

public enum WalkieTalkieKind: String, Codable, Sendable {
    case began
    case audio
    case ended
}

public struct WalkieTalkieMessage: Codable, Sendable, Equatable {
    public let kind: WalkieTalkieKind
    public let senderID: String
    public let senderName: String
    public let targetID: String?
    public let sessionID: String
    public let sequence: UInt64
    public let pcm16Mono: Data?

    public init(
        kind: WalkieTalkieKind,
        senderID: String,
        senderName: String,
        targetID: String?,
        sessionID: String,
        sequence: UInt64 = 0,
        pcm16Mono: Data? = nil
    ) {
        self.kind = kind
        self.senderID = senderID
        self.senderName = senderName
        self.targetID = targetID
        self.sessionID = sessionID
        self.sequence = sequence
        self.pcm16Mono = pcm16Mono
    }
}
