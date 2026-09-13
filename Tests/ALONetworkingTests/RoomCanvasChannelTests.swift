import Foundation
import Testing
@testable import ALONetworking

struct RoomCanvasChannelTests {
    @Test func largePayloadIsChunkedLazilyAndCannotInterleaveWithFollowingMessages() throws {
        let room = UUID(), canvas = UUID()
        let payload = Data(repeating: 42, count: RoomCanvasChunk.chunkBytes * 2 + 1)
        var output = RoomCanvasOutbox(), input = RoomCanvasPayloadAssembler()
        try output.enqueue(.join, roomID: room, canvasID: canvas)
        try output.enqueuePayload(payload, isImage: true)
        try output.enqueue(.requestCheckpoint, roomID: room, canvasID: canvas)
        let firstValue = try output.next(roomID: room, canvasID: canvas)
        let first = try #require(firstValue)
        if case .join = try RoomCanvasMessage(encoded: first, roomID: room, canvasID: canvas) {} else {
            Issue.record("Join must remain first")
        }
        var assembled: Data?
        for offset in [0, RoomCanvasChunk.chunkBytes, RoomCanvasChunk.chunkBytes * 2] {
            let nextValue = try output.next(roomID: room, canvasID: canvas)
            let bytes = try #require(nextValue)
            #expect(bytes.count <= RoomCanvasMessage.maximumWireBytes)
            if case .imageChunk(let chunk) = try RoomCanvasMessage(encoded: bytes, roomID: room, canvasID: canvas) {
                #expect(chunk.offset == offset)
                assembled = try input.append(chunk, nowNanos: 1)
            } else { Issue.record("Payload was interleaved or dropped") }
        }
        #expect(assembled == payload)
        let lastValue = try output.next(roomID: room, canvasID: canvas)
        let last = try #require(lastValue)
        if case .requestCheckpoint = try RoomCanvasMessage(encoded: last, roomID: room, canvasID: canvas) {} else {
            Issue.record("Small messages must retain their position after a payload")
        }
        #expect(output.isEmpty && output.bufferedBytes == 0)
        #expect(try output.next(roomID: room, canvasID: canvas) == nil)
    }

    @Test func checkpointUsesItsOwnChunkKind() throws {
        let room = UUID(), canvas = UUID()
        var output = RoomCanvasOutbox()
        try output.enqueuePayload(Data([1, 2, 3]), isImage: false)
        let nextValue = try output.next(roomID: room, canvasID: canvas)
        let data = try #require(nextValue)
        if case .checkpointChunk(let chunk) = try RoomCanvasMessage(encoded: data, roomID: room, canvasID: canvas) {
            #expect(chunk.bytes == Data([1, 2, 3]))
        } else { Issue.record("Checkpoint was sent as an image") }
    }

    @Test func slowReaderCannotAccumulateUnboundedImagesOrJobsAndResetReleasesData() throws {
        var output = RoomCanvasOutbox()
        let image = Data(repeating: 7, count: RoomCanvasChunk.maximumPayloadBytes)
        try output.enqueuePayload(image, isImage: true)
        #expect(output.bufferedBytes == image.count)
        #expect(throws: SecurePeerChannelError.queueFull) { try output.enqueuePayload(image, isImage: true) }
        #expect(output.bufferedBytes == image.count)
        output.reset()
        #expect(output.bufferedBytes == 0 && output.isEmpty)
        let room = UUID(), canvas = UUID()
        for _ in 0..<RoomCanvasOutbox.maximumJobs { try output.enqueue(.join, roomID: room, canvasID: canvas) }
        #expect(throws: SecurePeerChannelError.queueFull) { try output.enqueue(.join, roomID: room, canvasID: canvas) }
        for _ in 0..<RoomCanvasOutbox.maximumJobs {
            #expect(try output.next(roomID: room, canvasID: canvas) != nil)
        }
        #expect(output.bufferedBytes == 0)
        try output.enqueue(.join, roomID: room, canvasID: canvas)
        #expect(!output.isEmpty)
    }

    @Test func invalidPayloadDoesNotOccupyQueueCapacity() throws {
        var output = RoomCanvasOutbox()
        for data in [Data(), Data(repeating: 0, count: RoomCanvasChunk.maximumPayloadBytes + 1)] {
            #expect(throws: SecureTransportError.oversized) { try output.enqueuePayload(data, isImage: true) }
            #expect(output.bufferedBytes == 0 && output.isEmpty)
        }
    }

    @Test func canvasAdmissionRequiresBothCapabilitiesAndItsOwnAuthenticatedRole() throws {
        #expect(!PeerCapabilities.desktop.contains(.roomCanvas), "Do not advertise an unwired canvas by default")
        let credentials = try makeCredentials()
        try RoomCanvasChannel.validate(credentials, roomID: NetworkFixture.room,
            localID: NetworkFixture.receiver, peerID: NetworkFixture.sender)
        for role in ReliableChannelRole.allCases where role != .roomCanvas {
            let other = try makeCredentials(role: role)
            #expect(throws: SecureTransportError.wrongContext) {
                try RoomCanvasChannel.validate(other, roomID: NetworkFixture.room,
                    localID: NetworkFixture.receiver, peerID: NetworkFixture.sender)
            }
        }
        for (client, server): (PeerCapabilities, PeerCapabilities) in [(.desktop, [.desktop, .roomCanvas]), ([.desktop, .roomCanvas], .desktop)] {
            let unsupported = try makeCredentials(client: client, server: server)
            #expect(throws: SecureTransportError.unsupportedProtocol) {
                try RoomCanvasChannel.validate(unsupported, roomID: NetworkFixture.room,
                    localID: NetworkFixture.receiver, peerID: NetworkFixture.sender)
            }
        }
        for (room, local, peer) in [(UUID(), NetworkFixture.receiver, NetworkFixture.sender),
            (NetworkFixture.room, UUID(), NetworkFixture.sender), (NetworkFixture.room, NetworkFixture.receiver, UUID())] {
            #expect(throws: SecureTransportError.wrongContext) { try RoomCanvasChannel.validate(credentials, roomID: room, localID: local, peerID: peer) }
        }
        credentials.invalidate()
        #expect(throws: SecureTransportError.wrongContext) {
            try RoomCanvasChannel.validate(credentials, roomID: NetworkFixture.room,
                localID: NetworkFixture.receiver, peerID: NetworkFixture.sender)
        }
    }

    private func makeCredentials(role: ReliableChannelRole = .roomCanvas,
                                 client: PeerCapabilities = [.desktop, .roomCanvas],
                                 server: PeerCapabilities = [.desktop, .roomCanvas]) throws -> AuthenticatedChannelCredentials {
        let transcript = try AdmissionTranscript(roomID: NetworkFixture.room,
            initiatorID: NetworkFixture.receiver, responderID: NetworkFixture.sender,
            connectionID: UUID(), initiatorKeyHash: Data(repeating: 1, count: 32),
            responderKeyHash: Data(repeating: 2, count: 32), initiatorNonce: Data(repeating: 3, count: 32),
            responderNonce: Data(repeating: 4, count: 32),
            initiatorOffer: ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: client),
            responderOffer: ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: server),
            policy: .secureV2, channelRole: role)
        return AuthenticatedChannelCredentials(transcript: transcript, localRole: .initiator, rootSecret: NetworkFixture.key)
    }
}
