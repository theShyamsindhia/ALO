import Foundation
import Testing
import ALOCore
import ALONetworking
@testable import ALO

struct RejectedRoomEditPresentationTests {
    @Test func failedLocalMessageRestoresClearedDraft() throws {
        let error = try rejection(.message, text: "Keep this message")
        let result = RejectedRoomEditPresentation(error: error, chatDraft: "", queueDraft: "")
        #expect(result.chatDraft == "Keep this message")
        #expect(!result.isQueueEdit)
    }

    @Test func failedMessageDoesNotOverwriteNewInput() throws {
        let error = try rejection(.message, text: "Previous message")
        let result = RejectedRoomEditPresentation(error: error, chatDraft: "New draft", queueDraft: "")
        #expect(result.chatDraft == "New draft")
        #expect(result.notice.contains("Previous message"))
    }

    @Test func failedEditAndRemoteErrorCannotBecomeANewMessage() throws {
        let edited = RejectedRoomEditPresentation(error: try rejection(.edit, text: "Edited message"),
                                                  chatDraft: "", queueDraft: "")
        #expect(edited.chatDraft.isEmpty)
        let remote = RejectedRoomEditPresentation(error: RoomStateSyncError.retentionCapacity,
                                                  chatDraft: "My draft", queueDraft: "My URL")
        #expect(remote.chatDraft == "My draft")
        #expect(remote.queueDraft == "My URL")
    }

    @Test func failedQueueAddRestoresOnlyAnEmptyURLField() {
        let event = MeshRoomEvent(roomID: "fixture", version: MeshVersion(counter: 1, nodeID: "local"),
            kind: .queueAdd, queueItem: RoomQueueItem(title: "Example", url: "https://example.com/media"))
        let error = RoomStateOperationRejection(event: event, underlyingError: RoomStateSyncError.retentionCapacity)
        let result = RejectedRoomEditPresentation(error: error, chatDraft: "", queueDraft: "")
        #expect(result.isQueueEdit)
        #expect(result.queueDraft == "https://example.com/media")
        let newer = RejectedRoomEditPresentation(error: error, chatDraft: "", queueDraft: "Another URL")
        #expect(newer.queueDraft == "Another URL")
    }

    private func rejection(_ kind: RoomChatOperation.Kind, text: String) throws -> RoomStateOperationRejection {
        let operation = RoomChatOperation(kind: kind, target: kind == .edit ? UUID() : nil, text: text)
        let event = MeshRoomEvent(roomID: "fixture", version: MeshVersion(counter: 1, nodeID: "local"),
                                  kind: .chat, text: try #require(operation.encoded))
        return RoomStateOperationRejection(event: event, underlyingError: RoomStateSyncError.retentionCapacity)
    }
}
