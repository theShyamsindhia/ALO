import Foundation
import CryptoKit

/// Created only after SecurePeerChannel's mutual admission. The root key remains inside
/// ALONetworking. Factories and revocation are locked across control/media queues; each
/// returned opener still belongs to one serial receive executor.
public final class AuthenticatedChannelCredentials: @unchecked Sendable {
    public let roomID: UUID
    public let localPeerID: UUID
    public let remotePeerID: UUID
    public let connectionID: UUID
    public let channelRole: ReliableChannelRole
    public let negotiated: NegotiatedProtocol
    public let localRole: AdmissionProofRole
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    let rootSecret: SymmetricKey
    private var issuedSequence: UInt64 = 0
    private var highestReceivedSequence: UInt64?
    private var deadlines: [UUID: TimeInterval] = [:]
    private var openers: [UUID: [DatagramChannel: DatagramOpener]] = [:]

    init(transcript: AdmissionTranscript, localRole: AdmissionProofRole, rootSecret: SymmetricKey) {
        self.roomID = transcript.roomID; self.localRole = localRole; self.rootSecret = rootSecret
        localPeerID = localRole == .initiator ? transcript.initiatorID : transcript.responderID
        remotePeerID = localRole == .initiator ? transcript.responderID : transcript.initiatorID
        connectionID = transcript.connectionID; channelRole = transcript.channelRole; negotiated = transcript.negotiated
    }
    func invalidate() { lock.lock(); defer { lock.unlock() }; active = false; openers.removeAll(); deadlines.removeAll() }

    func nextSubscriptionSequence() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard active, issuedSequence < UInt64.max else { throw SecureTransportError.invalidCredentials }
        issuedSequence += 1
        return issuedSequence
    }

    /// Releases receive state without allowing the same ticket to reset its replay window.
    /// Tickets are issued in order on the reliable media-control channel.
    public func retireSubscriberTicket(_ ticket: MediaSubscriptionTicket) {
        lock.lock(); defer { lock.unlock() }
        guard ticket.roomID == roomID, ticket.senderID == remotePeerID, ticket.receiverID == localPeerID else { return }
        highestReceivedSequence = max(highestReceivedSequence ?? 0, ticket.subscriptionSequence)
        openers.removeValue(forKey: ticket.sessionID)
        deadlines.removeValue(forKey: ticket.sessionID)
    }

    private func isLive(sessionID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && deadlines[sessionID].map { $0 > ProcessInfo.processInfo.systemUptime } == true
    }

    func validate(ticket: MediaSubscriptionTicket, subscriber: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try validateLocked(ticket: ticket, subscriber: subscriber)
    }
    private func validateLocked(ticket: MediaSubscriptionTicket, subscriber: Bool) throws {
        let validRole = channelRole == .mediaControl || (channelRole == .voiceControl && ticket.channels == [.voice])
        guard active, validRole, ticket.roomID == roomID,
              ticket.senderID == (subscriber ? remotePeerID : localPeerID),
              ticket.receiverID == (subscriber ? localPeerID : remotePeerID) else { throw SecureTransportError.wrongContext }
        if subscriber, let highestReceivedSequence, ticket.subscriptionSequence <= highestReceivedSequence {
            guard let deadline = deadlines[ticket.sessionID] else { throw SecureTransportError.wrongContext }
            guard deadline > ProcessInfo.processInfo.systemUptime else { throw SecureTransportError.expired }
        }
    }

    public func makeSubscriberDatagramOpener(ticket: MediaSubscriptionTicket, channel: DatagramChannel) throws -> DatagramOpener {
        lock.lock(); defer { lock.unlock() }
        try validateLocked(ticket: ticket, subscriber: true)
        guard localRole == .initiator, ticket.channels.contains(channel) else { throw SecureTransportError.invalidCredentials }
        if let existing = openers[ticket.sessionID]?[channel] {
            guard existing.context == ticket.context(for: channel) else { throw SecureTransportError.wrongContext }
            return existing
        }
        let now = ProcessInfo.processInfo.systemUptime
        for (id, deadline) in deadlines where deadline <= now {
            openers.removeValue(forKey: id)
            deadlines.removeValue(forKey: id)
        }
        if openers[ticket.sessionID] == nil {
            guard highestReceivedSequence.map({ ticket.subscriptionSequence > $0 }) ?? true else {
                throw SecureTransportError.wrongContext
            }
            guard openers.count < 64 else { throw SecureTransportError.capacity }
            highestReceivedSequence = ticket.subscriptionSequence
            deadlines[ticket.sessionID] = now + ticket.validForSeconds
        }
        let opener = try DatagramOpener(secret: rootSecret, context: ticket.context(for: channel))
        opener.bindAuthorization { [weak self] in self?.isLive(sessionID: ticket.sessionID) == true }
        openers[ticket.sessionID, default: [:]][channel] = opener
        return opener
    }

    public func makeReturnPathProbe(ticket: MediaSubscriptionTicket) throws -> Data {
        try validate(ticket: ticket, subscriber: true)
        guard localRole == .initiator else { throw SecureTransportError.invalidCredentials }
        return try MediaReturnPathProof.makeProbe(ticket: ticket, secret: rootSecret)
    }

    public func answerReturnPathChallenge(_ challenge: Data, ticket: MediaSubscriptionTicket) throws -> Data {
        try validate(ticket: ticket, subscriber: true)
        guard localRole == .initiator else { throw SecureTransportError.invalidCredentials }
        return try MediaReturnPathProof.answerChallenge(challenge, ticket: ticket, secret: rootSecret)
    }
    public func verifyReturnPathConfirmation(_ confirmation: Data, response: Data,
                                            ticket: MediaSubscriptionTicket) throws {
        try validate(ticket: ticket, subscriber: true)
        guard localRole == .initiator, response.count == MediaReturnPathProof.packetSize else {
            throw SecureTransportError.invalidCredentials
        }
        let key = try MediaReturnPathProof.key(ticket: ticket, secret: rootSecret)
        _ = try MediaReturnPathProof.parse(confirmation, ticket: ticket, key: key, expectedKind: 4)
        var expectedBody = Data(response.prefix(96)); expectedBody[expectedBody.startIndex + 5] = 4
        guard confirmation.prefix(96) == expectedBody else { throw SecureTransportError.wrongContext }
    }
}
