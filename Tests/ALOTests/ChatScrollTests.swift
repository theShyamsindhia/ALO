import Foundation
import Testing
@testable import ALO

struct ChatScrollTests {
    @Test("Opening chat waits for layout and preserves the first unread position")
    func opensAtUnread() {
        let unread = UUID()
        var state = ChatScrollState(firstUnreadMessageID: unread)
        #expect(state.layoutChanged(ChatScrollLayout()) == nil)
        let request = state.layoutChanged(layout(height: 900, offset: 0))
        #expect(request == .message(unread))
        #expect(state.layoutChanged(layout(height: 900, offset: 300)) == nil)
        #expect(!state.followsLatest)
        #expect(!state.isAtLatest)
    }

    @Test("A local send scrolls to its laid-out bubble and follows later height corrections")
    func localSendFromHistory() {
        let sentID = UUID()
        var state = ChatScrollState(firstUnreadMessageID: UUID())
        _ = state.layoutChanged(layout(height: 900, offset: 200))
        #expect(state.messagesChanged(lastOwnMessageID: sentID) == .latest)
        var afterSend = layout(height: 980, offset: 200)
        #expect(state.layoutChanged(afterSend) == .latest)
        #expect(state.followsLatest)
        afterSend.contentFrame.size.height = 1060
        let correction = state.layoutChanged(afterSend)
        #expect(correction == .latest)
        afterSend.contentFrame.origin.y = -760
        _ = state.layoutChanged(afterSend)
        #expect(state.isAtLatest)
    }

    @Test("An incoming message preserves history position; jumping down resumes following")
    func remoteMessageWhileReading() {
        var state = ChatScrollState()
        _ = state.layoutChanged(layout(height: 900, offset: 600))
        state.userStartedScrolling()
        _ = state.layoutChanged(layout(height: 900, offset: 200))
        #expect(!state.followsLatest)
        state.userEndedScrolling()
        #expect(state.messagesChanged(lastOwnMessageID: nil) == nil)
        #expect(state.layoutChanged(layout(height: 980, offset: 200)) == nil)
        #expect(!state.isAtLatest)
        #expect(state.jumpToLatest() == .latest)
        _ = state.layoutChanged(layout(height: 980, offset: 680))
        #expect(state.followsLatest)
        #expect(state.isAtLatest)
    }

    @Test("An own send followed by a remote reply in the same update still reveals the sent message")
    func batchedMessages() {
        var state = ChatScrollState(firstUnreadMessageID: UUID())
        _ = state.layoutChanged(layout(height: 900, offset: 100))
        #expect(state.messagesChanged(lastOwnMessageID: UUID()) == .latest)
        #expect(state.layoutChanged(layout(height: 1020, offset: 100)) == .latest)
    }

    @Test("Viewport resizing follows the conversation only while reading the latest")
    func resizing() {
        var state = ChatScrollState()
        var initial = layout(height: 900, offset: 600)
        _ = state.layoutChanged(initial)
        initial.viewportHeight = 220
        #expect(state.layoutChanged(initial) == .latest)
        state.userStartedScrolling()
        initial.contentFrame.origin.y = -100
        _ = state.layoutChanged(initial)
        initial.viewportHeight = 240
        #expect(state.layoutChanged(initial) == nil)
    }

    @Test("Passive native offset corrections keep following; a real scroll gesture does not")
    func nativeOffsetCorrection() {
        var state = ChatScrollState()
        _ = state.layoutChanged(layout(height: 900, offset: 600))
        #expect(state.layoutChanged(layout(height: 900, offset: 520)) == .latest)
        #expect(state.followsLatest)
        state.userStartedScrolling()
        #expect(state.layoutChanged(layout(height: 900, offset: 580)) == nil)
        #expect(state.layoutChanged(layout(height: 900, offset: 400)) == nil)
        state.userEndedScrolling()
        #expect(!state.followsLatest)
        #expect(state.messagesChanged(lastOwnMessageID: nil) == nil)
        #expect(state.layoutChanged(layout(height: 980, offset: 400)) == nil)
    }

    @Test("Disconnected sends retain the draft") @MainActor
    func disconnectedDraft() {
        let model = ALOViewModel()
        model.draftMessage = "Keep this message"
        model.sendMessage()
        #expect(model.draftMessage == "Keep this message")
    }

    private func layout(height: CGFloat, offset: CGFloat) -> ChatScrollLayout {
        ChatScrollLayout(
            contentFrame: CGRect(x: 0, y: -offset, width: 520, height: height),
            viewportHeight: 300
        )
    }
}
