import Foundation
import CryptoKit
import Testing
@testable import ALONetworking

struct RoomCanvasWireTests {
    @Test func canvasAvailabilityIsBoundedAndNotPersistedInsideParticipantIdentity() throws {
        let advertisement = RoomCanvasAdvertisement(canvasID: UUID(), imageName: "Shared idea.png")
        #expect(advertisement.isValid)
        for name in ["", "   ", ".", "..", "folder/file", "folder\\file", "a\nb", String(repeating: "💬", count: 61)] {
            #expect(!RoomCanvasAdvertisement(canvasID: UUID(), imageName: name).isValid)
        }
        let envelope = MeshEnvelope(type: "room_canvas", nodeID: UUID().uuidString, roomCanvas: advertisement)
        let decoded = try JSONDecoder().decode(MeshEnvelope.self, from: JSONEncoder().encode(envelope))
        #expect(decoded.roomCanvas == advertisement)
        let withdrawn = try JSONDecoder().decode(MeshEnvelope.self, from: JSONEncoder().encode(MeshEnvelope(type: "room_canvas")))
        #expect(withdrawn.roomCanvas == nil)
        var participant = RoomParticipant(id: UUID().uuidString, name: "Peer")
        participant.canvas = advertisement
        let encoded = try JSONEncoder().encode(participant)
        let restored = try JSONDecoder().decode(RoomParticipant.self, from: encoded)
        #expect(restored.canvas == nil && restored.id == participant.id)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(advertisement.canvasID.uuidString))
    }

    @Test func messagesCannotCrossRoomsCanvasesOrAnnotationProtocols() throws {
        let room = UUID(), canvas = UUID()
        let bytes = try RoomCanvasMessage.join.encoded(roomID: room, canvasID: canvas)
        if case .join = try RoomCanvasMessage(encoded: bytes, roomID: room, canvasID: canvas) {} else {
            Issue.record("Expected canvas join")
        }
        #expect(throws: SecureTransportError.wrongContext) { try RoomCanvasMessage(encoded: bytes, roomID: UUID(), canvasID: canvas) }
        #expect(throws: SecureTransportError.wrongContext) { try RoomCanvasMessage(encoded: bytes, roomID: room, canvasID: UUID()) }
        #expect(throws: (any Error).self) { try AnnotationWireMessage(encoded: bytes) }
        let annotations = try AnnotationWireMessage.requestSnapshot.encoded()
        #expect(throws: (any Error).self) { try RoomCanvasMessage(encoded: annotations, roomID: room, canvasID: canvas) }
        #expect(throws: SecureTransportError.oversized) {
            try RoomCanvasMessage(encoded: Data(repeating: 0, count: RoomCanvasMessage.maximumWireBytes + 1), roomID: room, canvasID: canvas)
        }
    }

    @Test func checkpointRoundTripRecoversCanonicalCanvasState() throws {
        let image = RoomCanvasImage(name: "image.png", byteCount: 3, sha256: Data(repeating: 1, count: 32), pixelWidth: 2, pixelHeight: 2)
        let host = try RoomCanvasAuthority(roomID: UUID(), ownerID: UUID(), image: image, isPublicRoom: false)
        let snapshot = try #require(host.snapshot(nowNanos: 1))
        var assembler = RoomCanvasPayloadAssembler()
        var result: Data?
        for chunk in try RoomCanvasChunk.checkpoint(snapshot) {
            let bytes = try RoomCanvasMessage.checkpointChunk(chunk).encoded(roomID: snapshot.roomID, canvasID: snapshot.canvasID)
            if case .checkpointChunk(let received) = try RoomCanvasMessage(encoded: bytes, roomID: snapshot.roomID, canvasID: snapshot.canvasID) {
                result = try assembler.append(received, nowNanos: 2)
            } else { Issue.record("Expected checkpoint chunk") }
        }
        let restored = try JSONDecoder().decode(RoomCanvasSnapshot.self, from: #require(result))
        #expect(restored == snapshot)
        #expect(restored.isValid)
        #expect(assembler.bufferedByteCount == 0)
    }

    @Test func imageChunksRoundTripAndBindToTheChosenImage() throws {
        let data = Data(repeating: 19, count: RoomCanvasChunk.chunkBytes * 2 + 13)
        let chunks = try RoomCanvasChunk.split(data)
        let image = RoomCanvasImage(name: "image.png", byteCount: data.count, sha256: Data(SHA256.hash(data: data)), pixelWidth: 800, pixelHeight: 600)
        var assembler = RoomCanvasPayloadAssembler(image: image)
        #expect(try assembler.append(chunks[0], nowNanos: 0) == nil)
        #expect(try assembler.append(chunks[1], nowNanos: 1) == nil)
        #expect(try assembler.append(chunks[2], nowNanos: 2) == data)
        #expect(assembler.bufferedByteCount == 0)
        var wrong = RoomCanvasPayloadAssembler(image: .init(name: image.name, byteCount: data.count,
            sha256: Data(repeating: 0, count: 32), pixelWidth: 800, pixelHeight: 600))
        #expect(throws: SecureTransportError.wrongContext) { try wrong.append(chunks[0], nowNanos: 0) }
        #expect(wrong.bufferedByteCount == 0)
        wrong = RoomCanvasPayloadAssembler(image: .init(name: image.name, byteCount: data.count - 1,
            sha256: image.sha256, pixelWidth: 800, pixelHeight: 600))
        #expect(throws: SecureTransportError.wrongContext) { try wrong.append(chunks[0], nowNanos: 0) }
        #expect(wrong.bufferedByteCount == 0)
    }

    @Test func interruptedOutOfOrderDuplicateAndCorruptPayloadsResetWithoutDelivering() throws {
        let chunks = try RoomCanvasChunk.split(Data(repeating: 4, count: RoomCanvasChunk.chunkBytes + 7))
        var assembler = RoomCanvasPayloadAssembler()
        #expect(throws: (any Error).self) { try assembler.append(chunks[1], nowNanos: 0) }
        #expect(try assembler.append(chunks[0], nowNanos: 0) == nil)
        #expect(throws: (any Error).self) { try assembler.append(chunks[0], nowNanos: 1) }
        #expect(assembler.bufferedByteCount == 0)
        _ = try assembler.append(chunks[0], nowNanos: 0)
        #expect(throws: (any Error).self) { try assembler.append(chunks[1], nowNanos: 10_000_000_000) }
        #expect(assembler.bufferedByteCount == 0)
        _ = try assembler.append(chunks[0], nowNanos: 0)
        let last = chunks[1]
        let corrupt = RoomCanvasChunk(transferID: last.transferID, offset: last.offset, totalBytes: last.totalBytes,
            sha256: last.sha256, bytes: Data(repeating: 9, count: last.bytes.count))
        #expect(throws: (any Error).self) { try assembler.append(corrupt, nowNanos: 1) }
        #expect(assembler.bufferedByteCount == 0)
        let retry = try RoomCanvasChunk.split(Data(repeating: 5, count: 3))
        #expect(try assembler.append(retry[0], nowNanos: 2) == Data(repeating: 5, count: 3))
    }

    @Test func sizeAndOffsetLimitsAreCheckedBeforeBuffering() throws {
        for (offset, total, count) in [(-1, 10, 10), (0, Int.max, 1), (Int.max, 10, 1), (0, 10, 9), (1, 10, 9)] {
            let chunk = RoomCanvasChunk(transferID: UUID(), offset: offset, totalBytes: total,
                sha256: Data(repeating: 0, count: 32), bytes: Data(repeating: 0, count: count))
            var assembler = RoomCanvasPayloadAssembler()
            #expect(throws: SecureTransportError.malformed) { try assembler.append(chunk, nowNanos: 0) }
            #expect(assembler.bufferedByteCount == 0)
            #expect(throws: SecureTransportError.malformed) {
                try RoomCanvasMessage.imageChunk(chunk).encoded(roomID: UUID(), canvasID: UUID())
            }
        }
    }

    @Test func silentInterruptedTransferExpiresAndCanBeRetried() throws {
        let chunks = try RoomCanvasChunk.split(Data(repeating: 4, count: RoomCanvasChunk.chunkBytes + 7))
        var assembler = RoomCanvasPayloadAssembler()
        _ = try assembler.append(chunks[0], nowNanos: 10)
        #expect(assembler.bufferedByteCount == RoomCanvasChunk.chunkBytes)
        #expect(assembler.expire(nowNanos: 10_000_000_009) == false)
        #expect(assembler.expire(nowNanos: 10_000_000_010) == true)
        #expect(assembler.bufferedByteCount == 0)
        #expect(assembler.expire(nowNanos: 10_000_000_011) == false)
        #expect(try assembler.append(chunks[0], nowNanos: 11_000_000_000) == nil)
        #expect(try assembler.append(chunks[1], nowNanos: 11_000_000_001) != nil)
    }
}
