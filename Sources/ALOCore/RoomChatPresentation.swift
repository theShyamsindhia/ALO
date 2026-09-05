import Foundation

public enum ChatNotificationMode: String, CaseIterable, Sendable {
    case all, mentions, muted
    public var label: String {
        switch self { case .all: return "All messages"; case .mentions: return "Mentions only"; case .muted: return "Muted" }
    }
    public func shouldPreview(text: String, displayName: String, participantID: String? = nil, mentionedParticipantIDs: [String]? = nil) -> Bool {
        guard self != .muted else { return false }
        if self == .all { return true }
        if let ids = mentionedParticipantIDs { return participantID.map(ids.contains) == true }
        return RoomChatPresentation.containsMention(of: displayName, in: text)
    }
}

public enum RoomChatPresentation {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    public static func containsMention(of name: String, in text: String) -> Bool {
        guard !name.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}_])@" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}_-])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Previews are derived entirely from message text. No URL is fetched.
    public static func links(in text: String) -> [URL] {
        guard let detector = linkDetector else { return [] }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, isWebURL(url), seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }.prefix(3).map { $0 }
    }

    public static func isWebURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }
}
