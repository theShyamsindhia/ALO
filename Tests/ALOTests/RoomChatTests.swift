import Foundation
import Testing
@testable import ALOCore

struct RoomChatTests {
    private func apply(_ op: RoomChatOperation, by sender: String = "alice", to doc: inout RoomChatDocument) {
        _ = doc.receive(senderID: sender, sender: sender.capitalized, text: op.encoded!, sentNanos: op.timestamp, version: .init(counter: op.timestamp, nodeID: sender))
    }

    @Test func mutationsConvergeWhenDeliveredOutOfOrder() {
        let message = RoomChatOperation(kind: .message, text: "Hello", timestamp: 1)
        let edit = RoomChatOperation(kind: .edit, target: message.id, text: "Hello room", timestamp: 2)
        let reaction = RoomChatOperation(kind: .reaction, target: message.id, text: "🔥", enabled: true, timestamp: 3)
        let pin = RoomChatOperation(kind: .pin, target: message.id, enabled: true, timestamp: 4)
        var forward = RoomChatDocument(), reverse = RoomChatDocument()
        for op in [message, edit, reaction, pin] { apply(op, to: &forward) }
        for op in [pin, reaction, edit, message] { apply(op, to: &reverse) }
        #expect(forward.messages == reverse.messages)
        #expect(forward.messages.first?.text == "Hello room")
        #expect(forward.messages.first?.pinned == true)
        #expect(forward.messages.first?.reactions["🔥"] == ["alice"])
    }

    @Test func authorOnlyEditsAndPermanentDeletion() {
        let message = RoomChatOperation(kind: .message, text: "Mine", timestamp: 1)
        var doc = RoomChatDocument()
        apply(message, to: &doc)
        apply(.init(kind: .edit, target: message.id, text: "Spoof", timestamp: 2), by: "bob", to: &doc)
        apply(.init(kind: .delete, target: message.id, timestamp: 3), by: "bob", to: &doc)
        #expect(doc.messages.first?.text == "Mine")
        apply(.init(kind: .delete, target: message.id, timestamp: 4), to: &doc)
        apply(.init(kind: .edit, target: message.id, text: "Revived", timestamp: 5), to: &doc)
        #expect(doc.messages.first?.deleted == true)
        #expect(doc.messages.first?.text == "Message deleted")
    }

    @Test func reactionsAreIdempotentAndOwnedBySender() {
        let message = RoomChatOperation(kind: .message, text: "Hello", timestamp: 1)
        let reaction = RoomChatOperation(kind: .reaction, target: message.id, text: "👍", enabled: true, timestamp: 2)
        var doc = RoomChatDocument()
        apply(message, to: &doc); apply(reaction, to: &doc); apply(reaction, to: &doc)
        apply(.init(kind: .reaction, target: message.id, text: "👍", enabled: false, timestamp: 3), by: "bob", to: &doc)
        #expect(doc.messages.first?.reactions["👍"] == ["alice"])
        apply(.init(kind: .reaction, target: message.id, text: "👍", enabled: false, timestamp: 4), to: &doc)
        #expect(doc.messages.first?.reactions["👍"]?.isEmpty == true)
    }

    @Test func legacyIdentityAndReplyAreStable() {
        var a = RoomChatDocument(), b = RoomChatDocument()
        _ = a.receive(senderID: "alice", sender: "Alice", text: "Legacy", sentNanos: 22, version: .init(counter: 22, nodeID: "alice"))
        _ = b.receive(senderID: "alice", sender: "Alice", text: "Legacy", sentNanos: 22, version: .init(counter: 22, nodeID: "alice"))
        #expect(a.messages.first?.id == b.messages.first?.id)
        apply(.init(kind: .message, target: a.messages.first!.id, text: "A reply", timestamp: 23), to: &a)
        #expect(a.messages.last?.replyTo == b.messages.first?.id)
    }

    @Test func wireBudgetAndMalformedOperations() {
        #expect(RoomChatOperation(kind: .message, text: String(repeating: "a", count: 701)).encoded == nil)
        #expect(RoomChatOperation(kind: .reaction, target: UUID(), text: "invalid", enabled: true).encoded == nil)
        let op = RoomChatOperation(kind: .message, text: String(repeating: "\n", count: 699) + "x")
        #expect(op.encoded!.count <= 2000)
        var doc = RoomChatDocument()
        let accepted = doc.receive(senderID: "a", sender: "a", text: RoomChatOperation.prefix + "broken", sentNanos: 0, version: .init(counter: 0, nodeID: "a"))
        #expect(!accepted)
        #expect(doc.messages.isEmpty)
    }

    @Test func attachmentMessagesRoundTripAndReassembleBoundedChunks() throws {
        let bytes = Data((0..<(RoomChatAttachmentPacket.chunkBytes * 2 + 17)).map { UInt8($0 % 251) })
        let metadata = RoomChatAttachment(fileName: "../photo.bin", contentType: "application/octet-stream", byteCount: bytes.count)
        let operation = RoomChatOperation(kind: .message, text: "", timestamp: 1, attachment: metadata)
        let wire = try #require(operation.encoded)
        let decoded = try #require(RoomChatOperation.decode(wire))
        #expect(decoded.attachment?.fileName == "photo.bin")

        var document = RoomChatDocument()
        apply(operation, to: &document)
        #expect(document.messages.first?.attachment == metadata)
        #expect(document.messages.first?.previewText == "Sent a file · photo.bin")

        let payload = try #require(RoomChatAttachmentPayload(attachment: metadata, data: bytes))
        let packets = RoomChatAttachmentPacket.packets(for: payload)
        #expect(packets.count == 3)
        #expect(try packets.allSatisfy {
            try MeshEnvelope(type: "chat_attachment", nodeID: "alice", chatAttachmentPacket: $0)
                .encodedLine().count <= MeshEnvelopeDecoder.maximumLineBytes
        })
        var assembler = RoomChatAttachmentAssembler()
        var result: RoomChatAttachmentPayload?
        for packet in packets { result = assembler.receive(senderID: "alice", packet: packet) ?? result }
        #expect(result == payload)
    }

    @Test func attachmentAssemblerRejectsMissingOrCorruptChunks() throws {
        let bytes = Data(repeating: 0x2A, count: RoomChatAttachmentPacket.chunkBytes + 1)
        let metadata = RoomChatAttachment(fileName: "archive.zip", byteCount: bytes.count)
        let payload = try #require(RoomChatAttachmentPayload(attachment: metadata, data: bytes))
        let packets = RoomChatAttachmentPacket.packets(for: payload)
        var assembler = RoomChatAttachmentAssembler()
        #expect(assembler.receive(senderID: "alice", packet: packets[1]) == nil)
        #expect(assembler.receive(senderID: "alice", packet: packets[0]) == nil)
        var corrupt = packets[1]
        corrupt = RoomChatAttachmentPacket(attachment: corrupt.attachment, digest: corrupt.digest,
                                           chunkIndex: corrupt.chunkIndex, chunkCount: corrupt.chunkCount,
                                           bytes: Data([0]))
        #expect(assembler.receive(senderID: "alice", packet: corrupt) == nil)
        #expect(!RoomChatAttachment(id: "../escape", fileName: "file.txt", byteCount: 1).isValid)
    }
    @Test func mentionsRespectNamesAndNotificationPreferences() {
        #expect(RoomChatPresentation.containsMention(of: "jolly-walrus-715", in: "Hi @Jolly-Walrus-715!"))
        #expect(!RoomChatPresentation.containsMention(of: "alice", in: "name@alice.example.com"))
        #expect(!RoomChatPresentation.containsMention(of: "alice", in: "Hi @alice-two"))
        #expect(ChatNotificationMode.mentions.shouldPreview(text: "@alice play?", displayName: "Alice"))
        #expect(!ChatNotificationMode.mentions.shouldPreview(text: "Hello", displayName: "Alice"))
        #expect(!ChatNotificationMode.muted.shouldPreview(text: "@Alice", displayName: "Alice"))
    }

    @Test func linksAreBoundedWebURLsWithoutCredentials() {
        let links = RoomChatPresentation.links(in: "https://example.com/hello https://example.com/hello ftp://example.com/file file:///tmp/a mailto:a@example.com https://user:password@example.com")
        #expect(links == [URL(string: "https://example.com/hello")!])
        #expect(!RoomChatPresentation.isWebURL(URL(string: "javascript:alert(1)")!))
        #expect(RoomChatPresentation.links(in: "https://a.com https://b.com https://c.com https://d.com").count == 3)
    }

    @Test func mixedLegacyAndRichMessagesFollowReplicaVersionDespiteOppositeUptime() {
        let early = RoomChatOperation(kind: .message, text: "Rich first", timestamp: 9_999_999)
        let later = RoomChatOperation(kind: .message, text: "Rich last", timestamp: 1)
        let records: [(String, String, String, UInt64)] = [
            ("alice", "Alice", early.encoded!, 10),
            ("bob", "Bob", "Legacy middle", 20),
            ("alice", "Alice", later.encoded!, 30)
        ]
        var forward = RoomChatDocument(), reverse = RoomChatDocument()
        for row in records { forward.receive(senderID: row.0, sender: row.1, text: row.2, sentNanos: 1000 - row.3, version: .init(counter: row.3, nodeID: row.0)) }
        for row in records.reversed() { reverse.receive(senderID: row.0, sender: row.1, text: row.2, sentNanos: 1000 - row.3, version: .init(counter: row.3, nodeID: row.0)) }
        #expect(forward.messages == reverse.messages)
        #expect(forward.messages.map(\.text) == ["Rich first", "Legacy middle", "Rich last"])
        #expect(forward.messages.map(\.sender) == ["Alice", "Bob", "Alice"])
        #expect(forward.messages.map(\.senderID) == ["alice", "bob", "alice"])
        var legacyOnly = RoomChatDocument()
        legacyOnly.receive(senderID: "bob", sender: "Bob", text: "Legacy middle", sentNanos: 980, version: .init(counter: 20, nodeID: "bob"))
        #expect(forward.messages[1].id == legacyOnly.messages[0].id)
    }

    @Test func freshLegacyMessageRemainsVisibleAfterFiveHundredRichMessages() {
        var doc = RoomChatDocument()
        for index in 1...500 {
            apply(.init(kind: .message, text: "Rich \(index)", timestamp: UInt64(index)), to: &doc)
        }
        doc.receive(senderID: "bob", sender: "Bob", text: "Latest legacy", sentNanos: 1, version: .init(counter: 501, nodeID: "bob"))
        #expect(doc.messages.count == 500)
        #expect(doc.messages.last?.text == "Latest legacy")
        #expect(doc.messages.last?.sender == "Bob")
        #expect(doc.messages.first?.text == "Rich 2")
    }

}
