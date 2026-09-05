import Foundation
import Testing
@testable import ALOCore

struct RoomMentionTests {
    @Test func typedAtFiltersRealMembersAndReplacesOnlyTheToken() throws {
        let draft = "Let's play @lu"
        let token = try #require(RoomMentionCompletion.token(in: draft, selection: .init(location: draft.utf16.count, length: 0)))
        let members = [RoomMentionMember(id: "actual-luna", name: "Luna"), .init(id: "actual-alex", name: "Alex")]
        let suggestions = RoomMentionCompletion.suggestions(for: token, members: members)
        #expect(suggestions.map(\.id) == ["actual-luna"])
        let inserted = try #require(RoomMentionCompletion.inserting(suggestions[0], at: token, in: draft))
        #expect(inserted.text == "Let's play @Luna ")
        #expect(inserted.caret.location == inserted.text.utf16.count)
        #expect(RoomMentionCompletion.token(in: "email@lu", selection: .init(location: 8, length: 0)) == nil)
    }

    @Test func unicodeAndSelectionBoundsAreSafe() throws {
        let draft = "🎮 @Zo"
        let token = try #require(RoomMentionCompletion.token(in: draft, selection: .init(location: draft.utf16.count, length: 0)))
        let inserted = try #require(RoomMentionCompletion.inserting(.init(id: "z", name: "Zoë"), at: token, in: draft))
        #expect(inserted.text == "🎮 @Zoë ")
        #expect(RoomMentionCompletion.token(in: draft, selection: .init(location: draft.utf16.count + 1, length: 0)) == nil)
        #expect(RoomMentionCompletion.token(in: draft, selection: .init(location: 0, length: 2)) == nil)
    }

    @Test func duplicateDisplayNamesOnlyNotifyTheSelectedIdentity() throws {
        let members = [RoomMentionMember(id: "alice-one", name: "Alice"), .init(id: "alice-two", name: "Alice")]
        let token = try #require(RoomMentionCompletion.token(in: "@Ali", selection: .init(location: 4, length: 0)))
        #expect(RoomMentionCompletion.suggestions(for: token, members: members).count == 2)
        let operation = RoomChatOperation(kind: .message, text: "Hi @Alice", mentionedParticipantIDs: ["alice-two"])
        let encoded = try #require(operation.encoded)
        let decoded = try #require(RoomChatOperation.decode(encoded))
        var document = RoomChatDocument()
        _ = document.receive(senderID: "sender", sender: "Sender", text: try #require(decoded.encoded), sentNanos: 1, version: .init(counter: 1, nodeID: "sender"))
        let message = try #require(document.messages.first)
        #expect(message.mentionedParticipantIDs == ["alice-two"])
        #expect(ChatNotificationMode.mentions.shouldPreview(text: message.text, displayName: "Alice", participantID: "alice-two", mentionedParticipantIDs: message.mentionedParticipantIDs))
        #expect(!ChatNotificationMode.mentions.shouldPreview(text: message.text, displayName: "Alice", participantID: "alice-one", mentionedParticipantIDs: message.mentionedParticipantIDs))
        #expect(ChatNotificationMode.mentions.shouldPreview(text: "Hi @Alice", displayName: "Alice"))
    }

    @Test func mentionMetadataIsOptionalAndBounded() throws {
        let old = RoomChatOperation(kind: .message, text: "Legacy rich chat")
        let oldEncoded = try #require(old.encoded)
        let oldDecoded = try #require(RoomChatOperation.decode(oldEncoded))
        #expect(oldDecoded.mentionedParticipantIDs == nil)
        #expect(RoomChatOperation(kind: .message, text: "Too many", mentionedParticipantIDs: (0..<9).map(String.init)).encoded == nil)
        #expect(RoomChatOperation(kind: .message, text: "Repeated", mentionedParticipantIDs: ["same", "same"]).encoded == nil)
        #expect(!ChatNotificationMode.mentions.shouldPreview(text: "@Alice", displayName: "Alice", participantID: "alice", mentionedParticipantIDs: []))
    }
}
