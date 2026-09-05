import Foundation

public struct RoomMentionMember: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum RoomMentionCompletion {
    public struct Token: Equatable, Sendable {
        public let range: NSRange
        public let query: String
    }
    /// Works at the actual UTF-16 caret, including edits in the middle of a draft.
    public static func token(in text: String, selection: NSRange) -> Token? {
        guard selection.length == 0, selection.location >= 0,
              let caret = Range(selection, in: text)?.lowerBound else { return nil }
        let prefix = text[..<caret]
        guard let at = prefix.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let previous = text[text.index(before: at)]
            guard previous.isWhitespace || "([{\"'".contains(previous) else { return nil }
        }
        let query = String(text[text.index(after: at)..<caret])
        guard query.count <= 64, !query.contains(where: { "\n\r\t@,;!?".contains($0) }) else { return nil }
        return Token(range: NSRange(at..<caret, in: text), query: query)
    }
    public static func suggestions(for token: Token, members: [RoomMentionMember]) -> [RoomMentionMember] {
        let query = token.query.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        return members.filter { !$0.id.isEmpty && !$0.name.isEmpty && seen.insert($0.id).inserted && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame ? $0.id < $1.id : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    public static func inserting(_ member: RoomMentionMember, at token: Token, in text: String) -> (text: String, caret: NSRange)? {
        guard let range = Range(token.range, in: text) else { return nil }
        let replacement = "@" + member.name + " "
        let updated = text.replacingCharacters(in: range, with: replacement)
        guard updated.count <= RoomChatOperation.maximumTextLength else { return nil }
        return (updated, NSRange(location: token.range.location + replacement.utf16.count, length: 0))
    }
}
