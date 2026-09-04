import Foundation

/// A snapshot from the laid-out transcript.
struct ChatScrollLayout: Equatable {
    var contentFrame: CGRect = .zero
    var viewportHeight: CGFloat = 0

    var distanceFromLatest: CGFloat { max(0, contentFrame.maxY - viewportHeight) }
    var isAtLatest: Bool { distanceFromLatest <= 2 }
}

struct ChatScrollState {
    enum Target: Hashable {
        case latest
        case message(UUID)
    }

    private var lastOwnMessageID: UUID?
    private var openingTarget: Target?
    private var userIsScrolling = false
    private(set) var followsLatest = true
    private(set) var isAtLatest = false
    var shouldFollowLatest: Bool { followsLatest && !userIsScrolling }

    init(firstUnreadMessageID: UUID? = nil, lastOwnMessageID: UUID? = nil) {
        openingTarget = firstUnreadMessageID.map(Target.message) ?? .latest
        followsLatest = firstUnreadMessageID == nil
        self.lastOwnMessageID = lastOwnMessageID
    }

    mutating func layoutChanged(_ layout: ChatScrollLayout) -> Target? {
        guard layout.viewportHeight > 0, layout.contentFrame.height > 0 else { return nil }
        isAtLatest = layout.isAtLatest
        if let openingTarget {
            self.openingTarget = nil
            return openingTarget
        }
        // Only a user gesture leaves following mode. Native lazy-layout corrections
        // can also move the viewport and must not be mistaken for reading history.
        if userIsScrolling {
            followsLatest = layout.distanceFromLatest <= 36
            return nil
        }
        if followsLatest && !isAtLatest { return .latest }
        return nil
    }

    mutating func messagesChanged(lastOwnMessageID: UUID?) -> Target? {
        let sentMessage = lastOwnMessageID != nil && lastOwnMessageID != self.lastOwnMessageID
        self.lastOwnMessageID = lastOwnMessageID
        // A local send wins even when a remote reply arrives in the same update.
        if sentMessage || shouldFollowLatest { return jumpToLatest() }
        return nil
    }

    mutating func jumpToLatest() -> Target {
        followsLatest = true
        userIsScrolling = false
        return .latest
    }

    mutating func userStartedScrolling() {
        userIsScrolling = true
        followsLatest = false
    }

    mutating func userEndedScrolling() {
        userIsScrolling = false
    }
}
