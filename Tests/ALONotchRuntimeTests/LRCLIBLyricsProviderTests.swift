import XCTest
@testable import ALONotchRuntime

@MainActor
final class LRCLIBLyricsProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LRCLIBFixtureProtocol.reset()
    }

    func testExact503FallsBackToBoundedSearch() async throws {
        LRCLIBFixtureProtocol.responses = [
            .init(status: 503, body: [:]),
            .init(status: 200, body: [[
                "id": 1,
                "trackName": "Blinding Lights",
                "artistName": "The Weeknd",
                "albumName": "After Hours",
                "duration": 200,
                "instrumental": false,
                "plainLyrics": "Fixture lyric"
            ]])
        ]
        let provider = LRCLIBLyricsProvider(session: fixtureSession())
        let snapshot = NowPlayingSnapshot(
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "Incorrect Album Metadata",
            duration: 1,
            elapsedTime: 0,
            playbackRate: 1,
            artworkData: nil,
            refreshedAt: .now
        )

        let lyrics = try await provider.lyrics(for: snapshot)

        XCTAssertEqual(lyrics?.lines.map(\.text), ["Fixture lyric"])
        XCTAssertEqual(LRCLIBFixtureProtocol.requestPaths, ["/api/get", "/api/search"])
        XCTAssertEqual(LRCLIBFixtureProtocol.requestCount, 2)
    }

    func testRateLimitDoesNotFallThroughToMoreRequests() async {
        LRCLIBFixtureProtocol.responses = [.init(status: 429, body: [:])]
        let provider = LRCLIBLyricsProvider(session: fixtureSession())
        let snapshot = NowPlayingSnapshot(
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "After Hours",
            duration: 200,
            elapsedTime: 0,
            playbackRate: 1,
            artworkData: nil,
            refreshedAt: .now
        )

        do {
            _ = try await provider.lyrics(for: snapshot)
            XCTFail("Expected the rate-limited request to fail")
        } catch {
            XCTAssertEqual(LRCLIBFixtureProtocol.requestCount, 1)
        }
    }

    func testMissingTrackStopsAfterFourRequests() async throws {
        LRCLIBFixtureProtocol.responses = [
            .init(status: 503, body: [:]),
            .init(status: 200, body: []),
            .init(status: 200, body: []),
            .init(status: 200, body: [])
        ]
        let provider = LRCLIBLyricsProvider(session: fixtureSession())
        let snapshot = NowPlayingSnapshot(
            title: "Missing Fixture Song",
            artist: "Fixture Artist",
            album: "Fixture Album",
            duration: 180,
            elapsedTime: 0,
            playbackRate: 1,
            artworkData: nil,
            refreshedAt: .now
        )

        let lyrics = try await provider.lyrics(for: snapshot)

        XCTAssertNil(lyrics)
        XCTAssertEqual(LRCLIBFixtureProtocol.requestPaths, [
            "/api/get", "/api/search", "/api/search", "/api/search"
        ])
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LRCLIBFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class LRCLIBFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct FixtureResponse {
        let status: Int
        let body: Any
    }

    private static let lock = NSLock()
    private static var storedResponses: [FixtureResponse] = []
    private static var storedRequestPaths: [String] = []

    static var responses: [FixtureResponse] {
        get { lock.withLock { storedResponses } }
        set { lock.withLock { storedResponses = newValue } }
    }

    static var requestPaths: [String] {
        lock.withLock { storedRequestPaths }
    }

    static var requestCount: Int { requestPaths.count }

    static func reset() {
        lock.withLock {
            storedResponses = []
            storedRequestPaths = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "lrclib.net"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture: FixtureResponse? = Self.lock.withLock {
            Self.storedRequestPaths.append(request.url?.path ?? "")
            guard Self.storedResponses.isEmpty == false else { return nil }
            return Self.storedResponses.removeFirst()
        }
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let data = try! JSONSerialization.data(withJSONObject: fixture.body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: fixture.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
