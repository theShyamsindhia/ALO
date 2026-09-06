import Foundation
import Testing
@testable import ALOCore

struct RoomTrayEnvelopeTests {
    @Test func lateJoinRequestSurvivesWireEncoding() throws {
        let itemID = UUID().uuidString
        let request = RoomTrayFileRequest(itemID: itemID, digest: Data(repeating: 7, count: 32))
        let envelope = MeshEnvelope(type: "room_tray_file_request", nodeID: UUID().uuidString,
                                    roomTrayFileRequest: request)

        let decoded = try #require(MeshEnvelopeDecoder().append(try envelope.encodedLine()).first)
        #expect(decoded.roomTrayFileRequest == request)
        #expect(decoded.roomTrayFileRequest?.isValid == true)
    }

    @Test func targetedTrayPayloadKeepsItsRecipient() throws {
        let attachment = RoomChatAttachment(fileName: "shared.txt", byteCount: 4)
        let payload = try #require(RoomChatAttachmentPayload(attachment: attachment, data: Data("ALO!".utf8)))
        let packet = try #require(RoomChatAttachmentPacket.packets(for: payload).first)
        let target = UUID().uuidString

        let envelope = MeshEnvelope(type: "chat_attachment", nodeID: UUID().uuidString,
                                    targetID: target, chatAttachmentPacket: packet)
        let decoded = try #require(MeshEnvelopeDecoder().append(try envelope.encodedLine()).first)
        #expect(decoded.targetID == target)
        #expect(decoded.chatAttachmentPacket == packet)
    }
}
