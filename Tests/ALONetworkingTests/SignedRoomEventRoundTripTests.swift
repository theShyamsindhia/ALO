import Foundation
import Testing
import ALOCore
@testable import ALONetworking

@Suite("Signed room event Codable compatibility")
struct SignedRoomEventRoundTripTests {
    @Test func signedChatCannotImpersonateAnotherAuthor() throws {
        let identity = try InstallationIdentity.ephemeral()
        let author = identity.publicIdentity.nodeID.uuidString
        let policy = SecureRoomEventPolicy(roomID: "chat", identity: identity, capabilities: .chat)
        for claimedAuthor in [author, UUID().uuidString] {
            let event = MeshRoomEvent(roomID: "chat", version: .init(counter: 1, nodeID: author),
                kind: .chat, senderID: claimedAuthor, text: "Authenticated operation")
            let signed = try #require(policy.sign(event))
            #expect(policy.accepts(signed) == (claimedAuthor == author))
        }
    }
    @Test func signaturesSurviveChatAndLegacyCompatibleQueueOrderEncoding() throws {
        let identity = try InstallationIdentity.ephemeral()
        let author = identity.publicIdentity.nodeID.uuidString
        let policy = SecureRoomEventPolicy(roomID: "roundtrip", identity: identity, capabilities: .desktop)
        let events = [
            MeshRoomEvent(roomID: "roundtrip", version: .init(counter: 1, nodeID: author),
                          kind: .chat, senderID: author, text: "hello"),
            MeshRoomEvent(roomID: "roundtrip", version: .init(counter: 2, nodeID: author),
                          kind: .queueReorder, senderID: author, queueOrder: ["second", "first"])
        ]
        for event in events {
            let signed = try #require(policy.sign(event))
            let bytes = try JSONEncoder().encode(signed)
            let decoded = try JSONDecoder().decode(MeshRoomEvent.self, from: bytes)
            #expect(decoded == signed)
            #expect(decoded.authorization != nil)
            #expect(policy.accepts(decoded))
            #expect(try decoded.signingBytes() == event.signingBytes())
            if event.kind == .queueReorder {
                let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                #expect(object["kind"] as? String == "queueRemove")
                #expect(object["queueItemID"] as? String == "alo:queue-order:v1")
                #expect(decoded.queueOrder == ["second", "first"])
                #expect(MeshRoomReplica.hasValidQueueOrder(decoded))
            }
        }
    }
}
