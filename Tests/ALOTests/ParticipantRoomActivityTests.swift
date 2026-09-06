import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite("People details activity")
struct ParticipantRoomActivityTests {
    @Test("Counts visible chat activity for one participant")
    func countsLocallyObservedActivity() {
        let attachment = RoomChatAttachment(fileName: "notes.txt", contentType: "text/plain", byteCount: 12)
        var first = RoomChatMessage(senderID: "peer", sender: "Peer", text: "Hello",
                                    sentNanos: 1, mentionedParticipantIDs: ["local", "other"])
        first.reactions = ["👍": ["peer", "local"]]
        let file = RoomChatMessage(senderID: "peer", sender: "Peer", text: "",
                                   sentNanos: 2, attachment: attachment)
        var deleted = RoomChatMessage(senderID: "peer", sender: "Peer", text: "Removed", sentNanos: 3)
        deleted.deleted = true
        let other = RoomChatMessage(senderID: "local", sender: "Local", text: "Reply", sentNanos: 4)

        let activity = ALOViewModel.roomActivity(for: "peer", messages: [first, file, deleted, other])

        #expect(activity == ParticipantRoomActivity(messagesSent: 2, filesShared: 1,
                                                    mentionsMade: 2, reactionsAdded: 1))
    }
}
