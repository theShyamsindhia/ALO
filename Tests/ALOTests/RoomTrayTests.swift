import CryptoKit
import Foundation
import Testing
@testable import ALOCore

struct RoomTrayTests {
    private func metadata(
        id: UUID = UUID(),
        name: String = "notes.txt",
        bytes: Int = 3,
        digestByte: UInt8 = 1
    ) -> RoomTrayItemMetadata {
        RoomTrayItemMetadata(
            attachment: RoomChatAttachment(
                id: id.uuidString,
                fileName: name,
                contentType: "text/plain",
                byteCount: bytes
            ),
            digest: Data(repeating: digestByte, count: SHA256.Digest.byteCount)
        )
    }

    private func apply(
        _ operation: RoomTrayOperation,
        sender: String,
        counter: UInt64,
        to document: inout RoomTrayDocument
    ) {
        let accepted = document.receive(
            senderID: sender,
            sender: sender.capitalized,
            text: operation.encoded!,
            version: MeshVersion(counter: counter, nodeID: sender)
        )
        #expect(accepted)
    }

    @Test func operationsRoundTripAndMetadataUsesAStableDigest() throws {
        let bytes = Data("hello".utf8)
        let attachment = RoomChatAttachment(fileName: "../hello.txt", contentType: "text/plain", byteCount: bytes.count)
        let item = try #require(RoomTrayItemMetadata(attachment: attachment, data: bytes))
        #expect(item.attachment.fileName == "hello.txt")
        #expect(item.digest == Data(SHA256.hash(data: bytes)))

        let add = RoomTrayOperation.add(item, timestamp: 1)
        #expect(RoomTrayOperation.decode(try #require(add.encoded)) == add)
        #expect(add.encoded?.hasPrefix(RoomChatOperation.prefix) == true)
        let remove = RoomTrayOperation.remove(itemID: item.id, timestamp: 2)
        #expect(RoomTrayOperation.decode(try #require(remove.encoded)) == remove)
        #expect(add.encoded!.utf8.count <= RoomTrayOperation.maximumWireBytes)
    }

    @Test func removesAreCollaborativePermanentAndConvergent() {
        let item = metadata()
        let add = RoomTrayOperation.add(item, timestamp: 1)
        let remove = RoomTrayOperation.remove(itemID: item.id, timestamp: 2)
        var forward = RoomTrayDocument()
        apply(add, sender: "alice", counter: 1, to: &forward)
        apply(remove, sender: "bob", counter: 2, to: &forward)
        var reverse = RoomTrayDocument()
        apply(remove, sender: "bob", counter: 2, to: &reverse)
        apply(add, sender: "alice", counter: 1, to: &reverse)
        #expect(forward.items.isEmpty)
        #expect(reverse.items == forward.items)

        var caseInsensitive = RoomTrayDocument()
        apply(add, sender: "alice", counter: 1, to: &caseInsensitive)
        apply(.remove(itemID: item.id.lowercased(), timestamp: 3), sender: "bob", counter: 3, to: &caseInsensitive)
        #expect(caseInsensitive.items.isEmpty)
    }

    @Test func activeItemsAndBytesAreBoundedDeterministically() {
        let itemBytes = 3 * 1_024 * 1_024
        let fixtures = (0..<40).map { index in
            metadata(name: "file-\(index).bin", bytes: itemBytes, digestByte: UInt8(index))
        }
        var forward = RoomTrayDocument()
        for (index, item) in fixtures.enumerated() {
            apply(.add(item, timestamp: UInt64(index)), sender: "alice", counter: UInt64(index + 1), to: &forward)
        }
        var reverse = RoomTrayDocument()
        for (index, item) in fixtures.enumerated().reversed() {
            apply(.add(item, timestamp: UInt64(index)), sender: "alice", counter: UInt64(index + 1), to: &reverse)
        }
        #expect(forward.items == reverse.items)
        #expect(forward.items.count == 21)
        #expect(forward.items.reduce(0) { $0 + $1.attachment.byteCount } <= RoomTrayDocument.maximumActiveBytes)
        #expect(forward.items.count <= RoomTrayDocument.maximumActiveItems)
        #expect(forward.items.last?.attachment.fileName == "file-39.bin")

        var countBounded = RoomTrayDocument()
        for index in 0..<40 {
            apply(.add(metadata(name: "tiny-\(index).txt", bytes: 1, digestByte: UInt8(index)),
                       timestamp: UInt64(index)), sender: "bob", counter: UInt64(index + 1), to: &countBounded)
        }
        #expect(countBounded.items.count == RoomTrayDocument.maximumActiveItems)
        #expect(countBounded.items.first?.attachment.fileName == "tiny-8.txt")
    }

    @Test func duplicateOperationsAndSpoofedSenderContextAreRejected() {
        let operation = RoomTrayOperation.add(metadata(), timestamp: 1)
        var document = RoomTrayDocument()
        let version = MeshVersion(counter: 1, nodeID: "alice")
        let first = document.receive(operation, senderID: "alice", sender: "Alice", version: version)
        let duplicate = document.receive(operation, senderID: "alice", sender: "Alice", version: version)
        let spoofed = document.receive(
            RoomTrayOperation.add(metadata()),
            senderID: "mallory",
            sender: "Mallory",
            version: version
        )
        #expect(first)
        #expect(!duplicate)
        #expect(!spoofed)
    }

    @Test func trayWireNeverAppearsAsChatEvenWhenMalformed() {
        let operation = RoomTrayOperation.add(metadata(), timestamp: 1)
        var chat = RoomChatDocument()
        let validAccepted = chat.receive(
            senderID: "alice", sender: "Alice", text: operation.encoded!, sentNanos: 1,
            version: MeshVersion(counter: 1, nodeID: "alice")
        )
        let malformedAccepted = chat.receive(
            senderID: "alice", sender: "Alice", text: RoomTrayOperation.prefix + "broken", sentNanos: 2,
            version: MeshVersion(counter: 2, nodeID: "alice")
        )
        #expect(!validAccepted)
        #expect(!malformedAccepted)
        #expect(chat.messages.isEmpty)
    }

    @Test func fileRequestsValidateIdentityAndDigest() {
        let valid = RoomTrayFileRequest(itemID: UUID().uuidString, digest: Data(repeating: 7, count: SHA256.Digest.byteCount))
        #expect(valid.isValid)
        #expect(RoomTrayFileRequest(itemID: valid.itemID.lowercased(), digest: valid.digest).isValid)
        #expect(!RoomTrayFileRequest(itemID: "../escape", digest: valid.digest).isValid)
        #expect(!RoomTrayFileRequest(itemID: valid.itemID, digest: Data([1])).isValid)
    }

    @Test func durableChatEventsBuildTheSameTraySnapshot() {
        let item = metadata()
        let operation = RoomTrayOperation.add(item, timestamp: 1)
        let event = MeshRoomEvent(
            roomID: "room",
            version: MeshVersion(counter: 1, nodeID: "alice"),
            kind: .chat,
            senderID: "alice",
            sender: "Alice",
            text: operation.encoded,
            sentNanos: 1
        )
        let document = RoomTrayDocument(events: [event])
        #expect(document.items.map(\.id) == [item.id])
        #expect(document.items.first?.addedBy == "Alice")
        #expect(document.contains(itemID: item.id, digest: item.digest))
    }

    @Test func operationHistoryIsBoundedAndKeepsTheNewestActiveItems() {
        var document = RoomTrayDocument()
        for index in 0..<600 {
            apply(
                .add(metadata(name: "history-\(index).txt", bytes: 1, digestByte: UInt8(index % 255)),
                     timestamp: UInt64(index)),
                sender: "alice",
                counter: UInt64(index + 1),
                to: &document
            )
        }
        #expect(document.retainedOperationCount == RoomTrayDocument.maximumHistory)
        #expect(document.items.count == RoomTrayDocument.maximumActiveItems)
        #expect(document.items.first?.attachment.fileName == "history-568.txt")
        #expect(document.items.last?.attachment.fileName == "history-599.txt")
    }
}
