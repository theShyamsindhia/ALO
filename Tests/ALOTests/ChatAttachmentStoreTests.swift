import Foundation
import Testing
import ALOCore
@testable import ALO

@MainActor
struct ChatAttachmentStoreTests {
    @Test func payloadMustMatchAuthenticatedSendersPublishedMessage() throws {
        let attachment = RoomChatAttachment(fileName: "notes.txt", byteCount: 3)
        let payload = try #require(RoomChatAttachmentPayload(
            attachment: attachment,
            data: Data("alo".utf8)
        ))
        var document = RoomChatDocument()
        let operation = RoomChatOperation(kind: .message, text: "", timestamp: 1,
                                          attachment: attachment)
        _ = document.receive(senderID: "alice", sender: "Alice",
                             text: try #require(operation.encoded), sentNanos: 1,
                             version: .init(counter: 1, nodeID: "alice"))

        #expect(ALOViewModel.shouldAcceptChatAttachment(payload, senderID: "alice",
                                                       messages: document.messages))
        #expect(!ALOViewModel.shouldAcceptChatAttachment(payload, senderID: "mallory",
                                                        messages: document.messages))

        let reused = RoomChatAttachment(id: attachment.id, fileName: "notes.txt", byteCount: 4)
        let replacement = try #require(RoomChatAttachmentPayload(
            attachment: reused,
            data: Data("evil".utf8)
        ))
        #expect(!ALOViewModel.shouldAcceptChatAttachment(replacement, senderID: "alice",
                                                        messages: document.messages))
    }
}
