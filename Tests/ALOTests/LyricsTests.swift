import Foundation
import Testing
@testable import ALO
import ALOCore

@Suite(.serialized)
struct LyricsTests {
    @Test func onlyPublicTrackMetadataIsSent() {
        let track = LyricsTrack(media: .init(title: "Track & title", artist: "Artist", album: "Album", sourceURL: "https://private.invalid/secret"))!
        let request = LyricsProvider.request(track)
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        #expect(parts.host == "lrclib.net")
        #expect(parts.path == "/api/search")
        #expect(Set(parts.queryItems!.map(\.name)) == ["track_name", "artist_name", "album_name"])
        #expect(parts.queryItems?.first(where: { $0.name == "track_name" })?.value == "Track & title")
        #expect(!request.url!.absoluteString.contains("private"))
        #expect(LyricsTrack(media: .init(title: "Track")) == nil)
    }

    @Test func matchingDoesNotGuessBetweenVersions() throws {
        let track = LyricsTrack(media: .init(title: "Sample", artist: "Artist"))!
        let one = LyricsRecord(trackName: "Sample", artistName: "Artist", albumName: "A", instrumental: false, plainLyrics: "Synthetic first line", syncedLyrics: nil)
        let two = LyricsRecord(trackName: "Sample", artistName: "Artist", albumName: "B", instrumental: false, plainLyrics: "Synthetic second line", syncedLyrics: nil)
        #expect(throws: LyricsError.ambiguous) { try LyricsProvider.select([one, two], for: track) }
        let exact = LyricsTrack(media: .init(title: "Sample", artist: "Artist", album: "B"))!
        #expect(try LyricsProvider.select([one, two], for: exact).plain == "Synthetic second line")
    }

    @Test func durationSelectsTheMatchingVersionAndPrefersSyncedLyrics() throws {
        let timed = LyricsTrack(media: .init(title: "Sample", artist: "Artist", duration: 181))!
        let live = LyricsRecord(trackName: "Sample", artistName: "Artist", albumName: "Live", duration: 245,
                                instrumental: false, plainLyrics: "Live", syncedLyrics: nil)
        let studio = LyricsRecord(trackName: "Sample", artistName: "Artist", albumName: "Studio", duration: 181.3,
                                  instrumental: false, plainLyrics: "Studio", syncedLyrics: "[00:01.00]Studio")
        #expect(try LyricsProvider.select([live, studio], for: timed).plain == "Studio")

        let untimed = LyricsTrack(media: .init(title: "Other", artist: "Artist"))!
        let plain = LyricsRecord(trackName: "Other", artistName: "Artist", instrumental: false,
                                 plainLyrics: "Plain", syncedLyrics: nil)
        let synced = LyricsRecord(trackName: "Other", artistName: "Artist", instrumental: false,
                                  plainLyrics: "Synced", syncedLyrics: "[00:01.00]Synced")
        #expect(try LyricsProvider.select([plain, synced], for: untimed).plain == "Synced")
    }

    @Test func timestampsRequireTrustworthyPosition() {
        let lines = LyricsProvider.parse("[00:01.00][00:03.50]Sample line\n[00:05.00]Next sample\n[offset:500]\n[00:99.00]Invalid")
        #expect(lines.map(\.seconds) == [0.5, 3, 4.5])
        #expect(LyricsProvider.activeLine(in: lines, seconds: nil) == nil)
        #expect(LyricsProvider.activeLine(in: lines, seconds: 0) == nil)
        #expect(LyricsProvider.activeLine(in: lines, seconds: 3.25) == 1)
        #expect(LyricsProvider.activeLine(in: lines, seconds: .nan) == nil)
    }

    @Test func lyricRowsAndRetainedTextAreBounded() {
        let lrc = (0..<2100).map { "[00:01.00]Synthetic \($0)" }.joined(separator: "\n")
        let lines = LyricsProvider.parse(lrc)
        #expect(lines.count <= 2000)
        #expect(lines.reduce(0) { $0 + $1.text.utf8.count } <= 128_000)
    }

    @Test func honorsRetryAfterInBothForms() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(LyricsProvider.retryDate("120", now: now) == now.addingTimeInterval(120))
        #expect(LyricsProvider.retryDate("Thu, 01 Jan 1970 00:20:00 GMT", now: now) == Date(timeIntervalSince1970: 1200))
        #expect(LyricsProvider.retryDate(nil, now: now) == now.addingTimeInterval(60))
    }

    @MainActor @Test func defaultOffAndLateRequestsCannotReplaceCurrentTrack() async throws {
        let suite = "lyrics-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsFixtureProtocol.self]
        let provider = LyricsProvider(session: URLSession(configuration: configuration))
        let controller = LyricsController(preferences: preferences, provider: provider)
        controller.update(media: .init(title: "Slow", artist: "Fixture"))
        #expect(!controller.enabled)
        #expect(controller.state == .disabled)
        controller.enabled = true
        #expect(controller.state == .loading)
        controller.update(media: .init(title: "Fast", artist: "Fixture"))
        for _ in 0..<100 {
            if case .ready = controller.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .ready(let result) = controller.state else { Issue.record("Expected ready lyrics"); return }
        #expect(result.plain == "Synthetic Fast line")
        controller.enabled = false
        #expect(controller.state == .disabled)
        #expect(!preferences.bool(forKey: LyricsController.preferenceKey))
    }
}

private final class LyricsFixtureProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lrclib.net" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let title = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "track_name" })?.value ?? "Unknown"
        DispatchQueue.global().asyncAfter(deadline: .now() + (title == "Slow" ? 0.2 : 0.01)) { [self] in
            lock.lock(); let cancelled = stopped; lock.unlock()
            guard !cancelled else { return }
            let body: [[String: Any]] = [["trackName": title, "artistName": "Fixture", "instrumental": false, "plainLyrics": "Synthetic \(title) line"]]
            let data = try! JSONSerialization.data(withJSONObject: body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
