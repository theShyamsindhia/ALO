import Foundation
import SwiftUI

public struct RoomPlaybackSnapshot: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var artworkData: Data?
    public var isPlaying: Bool
    public var elapsed: TimeInterval
    public var duration: TimeInterval
    public var canTogglePlayback: Bool
    public var canSkipNext: Bool
    public var canSkipPrevious: Bool
    public var canSeek: Bool
    public var receivedAt: Date

    public init(title: String, artist: String = "", album: String = "", artworkData: Data? = nil,
                isPlaying: Bool, elapsed: TimeInterval = 0, duration: TimeInterval = 0,
                canTogglePlayback: Bool = false, canSkipNext: Bool = false,
                canSkipPrevious: Bool = false, canSeek: Bool = false, receivedAt: Date = .now) {
        self.title = title; self.artist = artist; self.album = album; self.artworkData = artworkData
        self.isPlaying = isPlaying; self.elapsed = elapsed; self.duration = duration
        self.canTogglePlayback = canTogglePlayback; self.canSkipNext = canSkipNext
        self.canSkipPrevious = canSkipPrevious; self.canSeek = canSeek; self.receivedAt = receivedAt
    }
}

public enum RoomPlaybackCommand: Equatable, Sendable {
    case togglePlayback, next, previous, openSource
    case seek(TimeInterval)
}

/// Only adapts ALO data and commands. Rendering remains the upstream player.
@MainActor
final class RoomPlaybackService: NowPlayingMonitoring, NowPlayingCommandAvailabilityProviding, PlaybackSourceOpening {
    var onSnapshotChange: ((NowPlayingSnapshot?) -> Void)?
    var onCommand: @MainActor (RoomPlaybackCommand) -> Void = { _ in }
    private(set) var roomSnapshot: RoomPlaybackSnapshot?
    private(set) var isMonitoring = false

    func update(_ snapshot: RoomPlaybackSnapshot?) {
        roomSnapshot = snapshot
        if isMonitoring { publish() }
    }
    func startMonitoring() { isMonitoring = true; publish() }
    func stopMonitoring() { isMonitoring = false }
    func canSend(_ command: NowPlayingCommand) -> Bool {
        guard isMonitoring, let snapshot = roomSnapshot else { return false }
        switch command {
        case .play, .pause, .togglePlayPause: return snapshot.canTogglePlayback
        case .nextTrack: return snapshot.canSkipNext
        case .previousTrack: return snapshot.canSkipPrevious
        case .seek: return snapshot.canSeek && snapshot.duration > 0
        default: return false
        }
    }
    func send(_ command: NowPlayingCommand) {
        guard canSend(command) else { return }
        switch command {
        case .play, .pause, .togglePlayPause: onCommand(.togglePlayback)
        case .nextTrack: onCommand(.next)
        case .previousTrack: onCommand(.previous)
        case .seek(let position): onCommand(.seek(min(max(0, position), roomSnapshot?.duration ?? 0)))
        default: break
        }
    }
    func openPlaybackSource(_ source: NowPlayingPlaybackSource) {
        guard isMonitoring else { return }
        onCommand(.openSource)
    }
    private func publish() {
        onSnapshotChange?(roomSnapshot.map { snapshot in
            NowPlayingSnapshot(title: snapshot.title, artist: snapshot.artist, album: snapshot.album,
                duration: snapshot.duration, elapsedTime: snapshot.elapsed,
                playbackRate: snapshot.isPlaying ? 1 : 0, artworkData: snapshot.artworkData,
                playbackSource: NowPlayingPlaybackSource(bundleIdentifier: "in.werai.audio", parentBundleIdentifier: nil, processIdentifier: nil),
                contentItemIdentifier: "alo-room:" + snapshot.title + ":" + snapshot.artist,
                supportsFavorite: false, supportsVolumeControl: false, refreshedAt: snapshot.receivedAt)
        })
    }
}

/// Separate identity prevents system-player hide events from hiding room media.
/// Every visual, size and corner is delegated to the original content.
struct RoomNowPlayingNotchContent: NotchContentProtocol, DynamicIslandCustomizable {
    static let activityID = "alo.room.nowPlaying"
    let original: NowPlayingNotchContent
    var id: String { Self.activityID }
    var priority: Int { original.priority + 1 }
    var strokeColor: Color { original.strokeColor }
    var isExpandable: Bool { original.isExpandable }
    var windowLink: (@MainActor () -> Void)? { original.windowLink }
    func size(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize { original.size(baseWidth: baseWidth, baseHeight: baseHeight) }
    func expandedSize(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize { original.expandedSize(baseWidth: baseWidth, baseHeight: baseHeight) }
    func cornerRadius(baseRadius: CGFloat) -> (top: CGFloat, bottom: CGFloat) { original.cornerRadius(baseRadius: baseRadius) }
    func expandedCornerRadius(baseRadius: CGFloat) -> (top: CGFloat, bottom: CGFloat) { original.expandedCornerRadius(baseRadius: baseRadius) }
    func dynamicIslandSize(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize { original.dynamicIslandSize(baseWidth: baseWidth, baseHeight: baseHeight) }
    func expandedDynamicIslandSize(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize { original.expandedDynamicIslandSize(baseWidth: baseWidth, baseHeight: baseHeight) }
    func dynamicIslandCornerRadius(baseHeight: CGFloat) -> CGFloat { original.dynamicIslandCornerRadius(baseHeight: baseHeight) }
    func expandedDynamicIslandCornerRadius(baseHeight: CGFloat) -> CGFloat { original.expandedDynamicIslandCornerRadius(baseHeight: baseHeight) }
    func makeView() -> AnyView { original.makeView() }
    func makeExpandedView() -> AnyView { original.makeExpandedView() }
}
