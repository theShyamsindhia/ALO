import Foundation

public enum WalkieTalkieKind: String, Codable, Sendable {
    case began
    case audio
    case ended
}

public struct WalkieTalkieMessage: Codable, Sendable, Equatable {
    public let kind: WalkieTalkieKind
    public let senderID: String
    public let senderName: String
    public let targetID: String?
    /// A snapshot of the intended recipients. `nil` preserves the legacy
    /// `targetID == nil` meaning of everyone; an empty array means nobody.
    public let targetIDs: [String]?
    public let sessionID: String
    public let sequence: UInt64
    public let pcm16Mono: Data?

    public init(
        kind: WalkieTalkieKind,
        senderID: String,
        senderName: String,
        targetID: String?,
        targetIDs: Set<String>? = nil,
        sessionID: String,
        sequence: UInt64 = 0,
        pcm16Mono: Data? = nil
    ) {
        self.kind = kind
        self.senderID = senderID
        self.senderName = senderName
        self.targetID = targetID
        self.targetIDs = targetIDs.map { $0.sorted() }
        self.sessionID = sessionID
        self.sequence = sequence
        self.pcm16Mono = pcm16Mono
    }

    /// `nil` means everyone. A non-nil set is an explicit recipient snapshot.
    public var recipientIDs: Set<String>? {
        if let targetIDs { return Set(targetIDs) }
        if let targetID { return [targetID] }
        return nil
    }
}

public enum OpenLineMessageKind: String, Codable, Sendable {
    case invite = "open_line_invite"
    case join = "open_line_join"
    case decline = "open_line_decline"
    case end = "open_line_end"
}

public struct OpenLineMessage: Codable, Sendable, Equatable {
    public let kind: OpenLineMessageKind
    public let invitationID: String
    public let senderID: String
    public let senderName: String
    public let targetID: String

    public init(
        kind: OpenLineMessageKind,
        invitationID: String,
        senderID: String,
        senderName: String,
        targetID: String
    ) {
        self.kind = kind
        self.invitationID = invitationID
        self.senderID = senderID
        self.senderName = senderName
        self.targetID = targetID
    }
}

public struct OpenLineInvitation: Sendable, Equatable {
    public let id: String
    public let callerID: String
    public let callerName: String
    public let inviteeID: String

    public init(id: String, callerID: String, callerName: String, inviteeID: String) {
        self.id = id
        self.callerID = callerID
        self.callerName = callerName
        self.inviteeID = inviteeID
    }
}

public enum OpenLineState: Sendable, Equatable {
    case idle
    case inviting(OpenLineInvitation)
    case invited(OpenLineInvitation)
    case connected(OpenLineInvitation)

    public var invitation: OpenLineInvitation? {
        switch self {
        case .idle: nil
        case .inviting(let invitation), .invited(let invitation), .connected(let invitation): invitation
        }
    }
}

public enum OpenLineTransition: Sendable, Equatable {
    case ignored
    case incomingInvitation(OpenLineInvitation)
    case joined(OpenLineInvitation)
    case declined(OpenLineInvitation)
    case ended(OpenLineInvitation)
}

/// Pure signaling state. In particular, receiving `.invite` or `.join` has no
/// microphone side effect; local code must explicitly call `join` before capture.
public struct OpenLineSessionState: Sendable {
    public let localID: String
    public private(set) var state: OpenLineState = .idle

    public init(localID: String) { self.localID = localID }

    public mutating func invite(
        peerID: String,
        localName: String,
        invitationID: String = UUID().uuidString
    ) -> OpenLineMessage? {
        guard peerID != localID, case .idle = state else { return nil }
        let invitation = OpenLineInvitation(
            id: invitationID, callerID: localID, callerName: localName, inviteeID: peerID
        )
        state = .inviting(invitation)
        return message(.invite, invitation: invitation, senderName: localName)
    }

    public mutating func join(invitationID: String, localName: String) -> OpenLineMessage? {
        guard case .invited(let invitation) = state, invitation.id == invitationID else { return nil }
        state = .connected(invitation)
        return message(.join, invitation: invitation, senderName: localName)
    }

    public mutating func decline(invitationID: String, localName: String) -> OpenLineMessage? {
        guard case .invited(let invitation) = state, invitation.id == invitationID else { return nil }
        state = .idle
        return message(.decline, invitation: invitation, senderName: localName)
    }

    public mutating func end(localName: String) -> OpenLineMessage? {
        guard let invitation = state.invitation else { return nil }
        state = .idle
        return message(.end, invitation: invitation, senderName: localName)
    }

    public mutating func receive(_ message: OpenLineMessage) -> OpenLineTransition {
        guard message.targetID == localID,
              message.senderID != localID,
              !message.invitationID.isEmpty
        else { return .ignored }

        switch message.kind {
        case .invite:
            let incoming = OpenLineInvitation(
                id: message.invitationID,
                callerID: message.senderID,
                callerName: message.senderName,
                inviteeID: localID
            )
            switch state {
            case .idle:
                state = .invited(incoming)
                return .incomingInvitation(incoming)
            case .inviting(let outgoing) where outgoing.inviteeID == message.senderID:
                // Crossed invitations converge on the lexicographically smaller
                // (invitation id, caller id), independent of arrival ordering.
                if (incoming.id, incoming.callerID) < (outgoing.id, outgoing.callerID) {
                    state = .invited(incoming)
                    return .incomingInvitation(incoming)
                }
                return .ignored
            case .invited(let current) where current == incoming:
                return .ignored
            case .inviting, .invited, .connected:
                return .ignored
            }
        case .join:
            guard case .inviting(let invitation) = state,
                  invitation.id == message.invitationID,
                  invitation.inviteeID == message.senderID
            else { return .ignored }
            state = .connected(invitation)
            return .joined(invitation)
        case .decline:
            guard case .inviting(let invitation) = state,
                  invitation.id == message.invitationID,
                  invitation.inviteeID == message.senderID
            else { return .ignored }
            state = .idle
            return .declined(invitation)
        case .end:
            guard let invitation = state.invitation,
                  invitation.id == message.invitationID,
                  otherPeerID(in: invitation) == message.senderID
            else { return .ignored }
            state = .idle
            return .ended(invitation)
        }
    }

    private func message(
        _ kind: OpenLineMessageKind,
        invitation: OpenLineInvitation,
        senderName: String
    ) -> OpenLineMessage {
        OpenLineMessage(
            kind: kind,
            invitationID: invitation.id,
            senderID: localID,
            senderName: senderName,
            targetID: otherPeerID(in: invitation)
        )
    }

    private func otherPeerID(in invitation: OpenLineInvitation) -> String {
        invitation.callerID == localID ? invitation.inviteeID : invitation.callerID
    }
}
