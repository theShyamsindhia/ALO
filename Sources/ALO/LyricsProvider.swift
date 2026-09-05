import Foundation
import ALOCore

struct LyricsTrack: Hashable, Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
    init?(media: NowPlayingMedia) {
        guard let title = media.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let artist = media.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty,
              title.count <= 300, artist.count <= 300 else { return nil }
        self.title = title; self.artist = artist
        let album = media.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album?.isEmpty == false ? String(album!.prefix(300)) : nil
        self.duration = media.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}

struct LyricsLine: Equatable, Sendable, Identifiable {
    let id: Int
    let seconds: Double
    let text: String
}

struct LyricsResult: Equatable, Sendable {
    let plain: String
    let lines: [LyricsLine]
    let instrumental: Bool
}

enum LyricsError: Error, Equatable {
    case unavailable, ambiguous, rateLimited(Date), invalidResponse, serviceUnavailable
}

struct LyricsRecord: Decodable, Sendable {
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: TimeInterval?
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?

    init(trackName: String, artistName: String, albumName: String? = nil, duration: TimeInterval? = nil,
         instrumental: Bool, plainLyrics: String?, syncedLyrics: String?) {
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }
}

/// Read-only LRCLIB client. No room, identity, source URL or audio data is sent.
/// Endpoint and response schema: https://lrclib.net/docs
actor LyricsProvider {
    private let session: URLSession
    private var nextRequest = Date.distantPast
    private var blockedUntil = Date.distantPast
    private var cache: [LyricsTrack: LyricsResult] = [:]
    private var order: [LyricsTrack] = []

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetch(_ track: LyricsTrack) async throws -> LyricsResult {
        if let cached = cache[track] { return cached }
        guard Date() >= blockedUntil else { throw LyricsError.rateLimited(blockedUntil) }
        let delay = max(0, nextRequest.timeIntervalSinceNow)
        nextRequest = max(Date(), nextRequest).addingTimeInterval(0.5)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        guard Date() >= blockedUntil else { throw LyricsError.rateLimited(blockedUntil) }
        let (bytes, response) = try await session.bytes(for: Self.request(track))
        guard let http = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
        if http.statusCode == 429 {
            blockedUntil = Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"))
            throw LyricsError.rateLimited(blockedUntil)
        }
        guard http.statusCode == 200 else { throw http.statusCode == 404 ? LyricsError.unavailable : LyricsError.serviceUnavailable }
        guard response.expectedContentLength <= 512_000 else { throw LyricsError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 512_000 else { throw LyricsError.invalidResponse }
            data.append(byte)
        }
        let records: [LyricsRecord]
        do { records = try JSONDecoder().decode([LyricsRecord].self, from: data) }
        catch { throw LyricsError.invalidResponse }
        let result = try Self.select(records, for: track)
        cache[track] = result; order.append(track)
        while order.count > 8 { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }

    nonisolated static func request(_ track: LyricsTrack) -> URLRequest {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.artist)]
        if let album = track.album { components.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
        var request = URLRequest(url: components.url!)
        request.setValue("ALO lyrics (https://github.com/theShyamsindhia/WERAI)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    nonisolated static func select(_ records: [LyricsRecord], for track: LyricsTrack) throws -> LyricsResult {
        func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        let matches = records.filter {
            normalized($0.trackName) == normalized(track.title) && normalized($0.artistName) == normalized(track.artist)
                && (track.album == nil || normalized($0.albumName ?? "") == normalized(track.album!))
        }
        guard !matches.isEmpty else { throw LyricsError.unavailable }
        guard matches.count <= 100 else { throw LyricsError.invalidResponse }
        var preferred = matches
        if let duration = track.duration {
            let measured = matches.compactMap { record -> (LyricsRecord, TimeInterval)? in
                guard let candidate = record.duration, candidate.isFinite, candidate > 0 else { return nil }
                return (record, abs(candidate - duration))
            }
            if let closest = measured.map(\.1).min(), closest <= 10 {
                // Duration separates studio, live, remastered and shortened
                // versions without inferring a match from lyric text.
                preferred = measured.filter { $0.1 <= closest + 0.75 }.map(\.0)
            }
        }
        let synchronized = preferred.filter { !($0.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        if synchronized.count == 1 { preferred = synchronized }

        let results = try preferred.map { record in
            guard (record.plainLyrics?.utf8.count ?? 0) <= 128_000,
                  (record.syncedLyrics?.utf8.count ?? 0) <= 128_000 else { throw LyricsError.invalidResponse }
            let lines = parse(record.syncedLyrics ?? "")
            let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return LyricsResult(plain: plain.isEmpty ? lines.map(\.text).joined(separator: "\n") : plain, lines: lines, instrumental: record.instrumental)
        }
        guard let result = results.first, results.allSatisfy({ $0 == result }) else { throw LyricsError.ambiguous }
        guard result.instrumental || !result.plain.isEmpty else { throw LyricsError.unavailable }
        return result
    }

    nonisolated static func parse(_ lrc: String) -> [LyricsLine] {
        guard lrc.utf8.count <= 128_000,
              let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]"#) else { return [] }
        var values: [(Double, String)] = []
        var offset = 0.0
        var retainedTextBytes = 0
        for raw in lrc.components(separatedBy: .newlines).prefix(2000) {
            if raw.hasPrefix("[offset:"), raw.hasSuffix("]"), let millis = Double(raw.dropFirst(8).dropLast()), millis.isFinite {
                offset = max(-60, min(60, millis / 1000)); continue
            }
            let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            guard let last = matches.last, let tail = Range(NSRange(location: last.range.upperBound, length: (raw as NSString).length - last.range.upperBound), in: raw) else { continue }
            let text = String(String(raw[tail]).trimmingCharacters(in: .whitespaces).prefix(2000))
            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: raw), let secondsRange = Range(match.range(at: 2), in: raw),
                      let minutes = Double(raw[minutesRange]), let seconds = Double(raw[secondsRange]), seconds < 60 else { continue }
                guard values.count < 2000, retainedTextBytes + text.utf8.count <= 128_000 else { break }
                retainedTextBytes += text.utf8.count
                values.append((minutes * 60 + seconds, text))
            }
        }
        return values.enumerated().sorted { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
            .enumerated().map { index, value in LyricsLine(id: index, seconds: max(0, value.element.0 - offset), text: value.element.1) }
    }

    nonisolated static func activeLine(in lines: [LyricsLine], seconds: Double?) -> Int? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return lines.last(where: { $0.seconds <= seconds })?.id
    }

    nonisolated static func retryDate(_ header: String?, now: Date = Date()) -> Date {
        if let header, let seconds = Double(header), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let header, let date = formatter.date(from: header), date > now { return date }
        return now.addingTimeInterval(60)
    }
}
