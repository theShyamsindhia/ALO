import Foundation

/// Shared room lyrics, resolved once by the host application.
public struct RoomLyricsPayload: Sendable {
    public enum State: Sendable { case idle, loading, ready, unavailable, failed }
    public struct Line: Sendable {
        public let seconds: Double?
        public let text: String
        public init(seconds: Double?, text: String) { self.seconds = seconds; self.text = text }
    }
    public let title: String
    public let artist: String
    public let state: State
    public let lines: [Line]
    public let hasPlaybackClock: Bool
    public init(title: String, artist: String, state: State, lines: [Line] = [], hasPlaybackClock: Bool) {
        self.title = title; self.artist = artist; self.state = state
        self.lines = lines; self.hasPlaybackClock = hasPlaybackClock
    }
}
