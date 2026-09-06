import Foundation
import Combine
import ALOCore

@MainActor
final class LyricsController: ObservableObject {
    enum State: Equatable {
        case disabled, missingTrack, loading
        case ready(LyricsResult)
        case unavailable(String)
        case failed(String)
    }
    @Published var enabled: Bool {
        didSet { preferences.set(enabled, forKey: Self.preferenceKey); refresh() }
    }
    @Published private(set) var state: State = .disabled
    static let preferenceKey = "lyricsEnabled"
    static let privacyNotice = "When enabled, track title, artist, album and duration are sent to LRCLIB to find lyrics. Channel details and audio are not sent."
    private let preferences: UserDefaults
    private let provider: LyricsProvider
    private(set) var track: LyricsTrack?
    private var externalDemand = false
    private var needsLyrics: Bool { enabled || externalDemand }
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(preferences: UserDefaults = .standard, provider: LyricsProvider = LyricsProvider()) {
        self.preferences = preferences; self.provider = provider
        enabled = preferences.bool(forKey: Self.preferenceKey)
        state = enabled ? .missingTrack : .disabled
    }
    deinit { task?.cancel() }

    func update(media: NowPlayingMedia) {
        let next = LyricsTrack(media: media)
        guard next != track else { return }
        track = next; refresh()
    }
    func setExternalDemand(_ requested: Bool) {
        let previouslyNeeded = needsLyrics
        externalDemand = requested
        if previouslyNeeded != needsLyrics {
            refresh()
        } else if requested {
            // Opening the Notch or lock-screen presentation is an explicit retry.
            // This lets a transient lookup failure recover without requiring a
            // track change or changing the user's persistent lyrics preference.
            switch state {
            case .unavailable, .failed: refresh()
            default: break
            }
        }
    }
    func retry() { refresh() }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; track = nil; state = enabled ? .missingTrack : .disabled }

    private func refresh() {
        generation = UUID(); task?.cancel(); task = nil
        guard needsLyrics else { state = .disabled; return }
        guard let track else { state = .missingTrack; return }
        state = .loading
        let token = generation
        let provider = provider
        task = Task { [weak self] in
            do {
                let result = try await provider.fetch(track)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.state = .ready(result)
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                switch error {
                case LyricsError.unavailable: self.state = .unavailable("No lyrics found for this track.")
                case LyricsError.ambiguous: self.state = .unavailable("Multiple versions found. Lyrics need a more specific track match.")
                case LyricsError.rateLimited(let date):
                    self.state = .failed("Lyrics service is busy. Retry after \(date.formatted(date: .omitted, time: .shortened)).")
                default: self.state = .failed("Lyrics could not load. Check your connection and try again.")
                }
            }
        }
    }
}
