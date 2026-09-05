import Foundation
import CryptoKit
import Testing
@testable import ALONetworking

@Suite("Authorized media return paths")
struct MediaSubscriptionTests {
    @Test func admittedCredentialsPreserveReplayStateAndRevokeMediaFactories() throws {
        let offer = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop)
        let transcript = try AdmissionTranscript(roomID: NetworkFixture.room, initiatorID: NetworkFixture.receiver,
            responderID: NetworkFixture.sender, connectionID: NetworkFixture.session,
            initiatorKeyHash: Data(repeating: 1, count: 32), responderKeyHash: Data(repeating: 2, count: 32),
            initiatorNonce: Data(repeating: 3, count: 32), responderNonce: Data(repeating: 4, count: 32),
            initiatorOffer: offer, responderOffer: offer, policy: .secureV2, channelRole: .mediaControl, admissionKind: .publicRoom)
        let publisher = AuthenticatedChannelCredentials(transcript: transcript, localRole: .responder, rootSecret: NetworkFixture.key)
        let subscriber = AuthenticatedChannelCredentials(transcript: transcript, localRole: .initiator, rootSecret: NetworkFixture.key)
        let registry = MediaSubscriptionRegistry()
        let ticket = try registry.reserveAdmittedSubscription(credentials: publisher, broadcasterEpoch: 7,
            generation: 9, channels: [.audio], now: 0)
        let decoded = try MediaSubscriptionTicket(encoded: ticket.encoded())
        #expect(decoded.sessionID == ticket.sessionID)
        #expect(decoded.generation == 9 && decoded.channels == [.audio])
        let flow = UUID()
        let probe = try subscriber.makeReturnPathProbe(ticket: decoded)
        let challenge = try registry.receiveProbe(probe, sessionID: decoded.sessionID, acceptedFlowID: flow, now: 1)
        let response = try subscriber.answerReturnPathChallenge(challenge, ticket: decoded)
        try registry.receiveResponse(response, sessionID: decoded.sessionID, acceptedFlowID: flow, now: 2)
        let packet = try registry.sealMedia(Data([7]), sessionID: decoded.sessionID, acceptedFlowID: flow, channel: .audio, now: 3)
        let opener = try subscriber.makeSubscriberDatagramOpener(ticket: decoded, channel: .audio)
        #expect(try opener.open(packet) == Data([7]))
        let sameOpener = try subscriber.makeSubscriberDatagramOpener(ticket: decoded, channel: .audio)
        #expect(opener === sameOpener)
        #expect(throws: SecureTransportError.replay) { try sameOpener.open(packet) }
        subscriber.invalidate()
        #expect(throws: SecureTransportError.invalidCredentials) { try opener.open(packet) }
        publisher.invalidate()
        #expect(throws: SecureTransportError.invalidCredentials) {
            try registry.sealMedia(Data([7]), sessionID: decoded.sessionID, acceptedFlowID: flow, channel: .audio, now: 4)
        }
    }

    @Test func ticketDecoderBoundsAndUnadmittedRolesFailClosed() throws {
        #expect(throws: SecureTransportError.oversized) { try MediaSubscriptionTicket(encoded: Data(repeating: 0, count: 2_049)) }
        let credentials = AuthenticatedChannelCredentials(transcript: try NetworkFixture.transcript(),
                                                           localRole: .responder, rootSecret: NetworkFixture.key)
        let registry = MediaSubscriptionRegistry()
        #expect(throws: SecureTransportError.invalidCredentials) {
            try registry.reserveAdmittedSubscription(credentials: credentials, broadcasterEpoch: 1,
                                                     generation: 1, channels: [.audio], now: 0)
        }
    }
    private func reserve(_ registry: MediaSubscriptionRegistry, now: TimeInterval = 0,
                         lifetime: TimeInterval = 30) throws -> (MediaSubscriptionTicket, SymmetricKey) {
        let transcript = try NetworkFixture.transcript()
        let proof = try TLSBoundAdmissionProof.make(roomSecret: NetworkFixture.secret, transcript: transcript,
                                                    exporter: NetworkFixture.exporter, role: .initiator)
        let ticket = try registry.reservePrivateSubscription(proof: proof, roomSecret: NetworkFixture.secret,
            transcript: transcript, exporter: NetworkFixture.exporter, broadcasterEpoch: 7,
            generation: 9, channels: [.audio, .timing], now: now, lifetime: lifetime)
        let key = try TLSBoundAdmissionProof.channelSecret(roomSecret: NetworkFixture.secret, transcript: transcript,
                                                           exporter: NetworkFixture.exporter)
        return (ticket, key)
    }

    @Test func noMediaBeforeSameFlowProofThenEncryptedRoundTrip() throws {
        let registry = MediaSubscriptionRegistry()
        let (ticket, secret) = try reserve(registry)
        let flow = UUID()
        #expect(throws: SecureTransportError.unvalidatedReturnPath) {
            try registry.sealMedia(Data([1]), sessionID: ticket.sessionID, acceptedFlowID: flow, channel: .audio, now: 0)
        }
        let probe = try MediaReturnPathProof.makeProbe(ticket: ticket, secret: secret)
        let challenge = try registry.receiveProbe(probe, sessionID: ticket.sessionID, acceptedFlowID: flow, now: 1)
        #expect(challenge.count <= probe.count)
        #expect(throws: SecureTransportError.unvalidatedReturnPath) {
            try registry.sealMedia(Data([1]), sessionID: ticket.sessionID, acceptedFlowID: flow, channel: .audio, now: 1)
        }
        let response = try MediaReturnPathProof.answerChallenge(challenge, ticket: ticket, secret: secret)
        #expect(throws: SecureTransportError.unvalidatedReturnPath) {
            try registry.receiveResponse(response, sessionID: ticket.sessionID, acceptedFlowID: UUID(), now: 2)
        }
        try registry.receiveResponse(response, sessionID: ticket.sessionID, acceptedFlowID: flow, now: 2)
        let packet = try registry.sealMedia(Data([1,2,3]), sessionID: ticket.sessionID, acceptedFlowID: flow, channel: .audio, now: 3)
        let opener = try DatagramOpener(secret: secret, context: ticket.context(for: .audio))
        #expect(try opener.open(packet) == Data([1,2,3]))
        #expect(throws: SecureTransportError.invalidCredentials) {
            try registry.sealMedia(Data([1]), sessionID: ticket.sessionID, acceptedFlowID: flow, channel: .voice, now: 3)
        }
        #expect(throws: SecureTransportError.unvalidatedReturnPath) {
            try registry.sealMedia(Data([1]), sessionID: ticket.sessionID, acceptedFlowID: UUID(), channel: .audio, now: 3)
        }
        #expect(registry.pendingCount == 0)
        #expect(throws: SecureTransportError.expired) {
            try registry.sealMedia(Data([1]), sessionID: ticket.sessionID, acceptedFlowID: flow, channel: .audio, now: 30)
        }
        #expect(registry.count == 0)
    }

    @Test func badProofDoesNotAllocateOrValidateAndBoundsAreEnforced() throws {
        let registry = MediaSubscriptionRegistry(limits: .init(maximumSubscriptions: 2, maximumPending: 1, maximumPerPeer: 1))
        let transcript = try NetworkFixture.transcript()
        #expect(throws: SecureTransportError.invalidCredentials) {
            try registry.reservePrivateSubscription(proof: Data(repeating: 0, count: 32), roomSecret: NetworkFixture.secret,
                transcript: transcript, exporter: NetworkFixture.exporter, broadcasterEpoch: 7, generation: 9,
                channels: [.audio], now: 0)
        }
        #expect(registry.count == 0)
        let (ticket, key) = try reserve(registry)
        #expect(throws: SecureTransportError.capacity) { try reserve(registry) }
        let flow = UUID()
        var probe = try MediaReturnPathProof.makeProbe(ticket: ticket, secret: key)
        probe[probe.startIndex + 100] ^= 1
        #expect(throws: SecureTransportError.invalidCredentials) {
            try registry.receiveProbe(probe, sessionID: ticket.sessionID, acceptedFlowID: flow, now: 1)
        }
        for size in [0,64,127,129,1200,10_000] {
            #expect(throws: SecureTransportError.malformed) {
                try registry.receiveProbe(Data(repeating: 0, count: size), sessionID: ticket.sessionID, acceptedFlowID: flow, now: 1)
            }
        }
        #expect(registry.pendingCount == 1)
        registry.cancel(sessionID: ticket.sessionID)
        #expect(registry.count == 0)
        let (fresh, _) = try reserve(registry, now: 2)
        #expect(fresh.sessionID != ticket.sessionID)
        registry.cancelAll()
        #expect(registry.count == 0)
    }

    @Test func challengeExpiresAndRetriesAreBounded() throws {
        let registry = MediaSubscriptionRegistry()
        let (ticket, key) = try reserve(registry)
        let flow = UUID()
        let probe = try MediaReturnPathProof.makeProbe(ticket: ticket, secret: key)
        let challenge = try registry.receiveProbe(probe, sessionID: ticket.sessionID, acceptedFlowID: flow, now: 0)
        let response = try MediaReturnPathProof.answerChallenge(challenge, ticket: ticket, secret: key)
        #expect(throws: SecureTransportError.unvalidatedReturnPath) {
            try registry.receiveResponse(response, sessionID: ticket.sessionID, acceptedFlowID: flow, now: 10)
        }
        _ = try registry.receiveProbe(probe, sessionID: ticket.sessionID, acceptedFlowID: flow, now: 11)
        #expect(throws: SecureTransportError.wrongContext) {
            try registry.receiveResponse(response, sessionID: ticket.sessionID, acceptedFlowID: flow, now: 12)
        }
        _ = try registry.receiveProbe(probe, sessionID: ticket.sessionID, acceptedFlowID: flow, now: 13)
        #expect(throws: SecureTransportError.invalidState) {
            try registry.receiveProbe(probe, sessionID: ticket.sessionID, acceptedFlowID: flow, now: 14)
        }
        registry.expire(now: 30)
        #expect(registry.count == 0)
    }
}
