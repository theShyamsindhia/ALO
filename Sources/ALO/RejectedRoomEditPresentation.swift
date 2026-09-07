import Foundation
import ALOCore
import ALONetworking

/// An asynchronous durable commit may fail after a composer cleared its draft.
/// Only locally rejected operations can restore input; remote errors cannot
/// inject another member's text into the local composer.
struct RejectedRoomEditPresentation {
    let notice: String
    let chatDraft: String
    let queueDraft: String
    let isQueueEdit: Bool

    init(error: Error, chatDraft: String, queueDraft: String) {
        var notice = error.localizedDescription
        var restoredChat = chatDraft
        var restoredQueue = queueDraft
        let event = (error as? RoomStateOperationRejection)?.event
        if event?.kind == .chat, let wire = event?.text,
           let operation = RoomChatOperation.decode(wire), operation.kind == .message,
           let text = operation.text, !text.isEmpty {
            if chatDraft.isEmpty { restoredChat = text }
            else if chatDraft != text { notice += "\n\nUnsent message:\n\(text)" }
        }
        if event?.kind == .queueAdd, queueDraft.isEmpty, let url = event?.queueItem?.url {
            restoredQueue = url
        }
        self.notice = notice
        self.chatDraft = restoredChat
        self.queueDraft = restoredQueue
        isQueueEdit = event?.kind == .queueAdd || event?.kind == .queueRemove || event?.kind == .queueReorder
    }
}
