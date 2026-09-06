import Foundation
import Testing
@testable import ALONetworking

@Suite("Bounded v2 media-control wire")
struct MediaControlWireProtocolTests {
    private let request = UUID()
    private var stream: MediaStreamIdentifier {
        .init(sessionID: UUID(), broadcasterEpoch: 7, generation: 9)
    }
    private func ticket(channels: Set<DatagramChannel> = [.audio, .timing], sequence: UInt64 = 42) throws -> MediaSubscriptionTicket {
        try MediaSubscriptionTicket(roomID: UUID(), senderID: UUID(), receiverID: UUID(), sessionID: UUID(),
            generation: 9, broadcasterEpoch: 7, channels: channels, expiresAt: 100,
            validForSeconds: 30, subscriptionSequence: sequence)
    }
    private func anchor(capture: UInt64 = 1_000_000_000, playback: UInt64 = 1_200_000_000,
                        issued: UInt64 = 1_100_000_000, rate: UInt32 = 48_000,
                        channels: UInt16 = 2, frames: UInt16 = 240,
                        frameIndex: UInt64 = 240, state: MediaStreamAnchor.State = .running) -> MediaStreamAnchor {
        .init(stream: stream, captureTimeNanos: capture, frameIndex: frameIndex,
              hostPlaybackTimeNanos: playback, issuedAtHostNanos: issued,
              sampleRate: rate, channelCount: channels, framesPerPacket: frames, state: state)
    }

    @Test func everyMessageRoundTrips() throws {
        let context = stream
        let messages: [MediaControlWireMessage] = [
            .subscribe(requestID: request, broadcasterEpoch: 7, channels: [.audio, .timing]),
            .renew(requestID: request, stream: context), .cancel(stream: context),
            .clockPing(id: 0, clientTimeNanos: 0),
            .clockPong(id: 5, clientTimeNanos: 900, hostTimeNanos: 800, hostReceivedNanos: 700),
            .anchor(anchor()), .anchor(anchor(state: .paused)),
            .anchorReady(stream: context, frameIndex: 241, captureTimeNanos: 1_000,
                         hostPlaybackTimeNanos: 2_000),
            .pause(stream: context, atCaptureTimeNanos: 1_000),
            .resync(requestID: request, stream: context, minimumCaptureTimeNanos: nil),
            .resync(requestID: request, stream: context, minimumCaptureTimeNanos: 1_000),
            .requestKeyframe(requestID: request, stream: context, minimumCaptureTimeNanos: nil),
            .requestKeyframe(requestID: request, stream: context, minimumCaptureTimeNanos: 1_000),
            .rejected(requestID: request, reason: .staleSession)
        ]
        for message in messages {
            let encoded = try message.encoded()
            #expect(encoded.count <= MediaControlWireMessage.maximumWireBytes)
            let decoded = try MediaControlWireMessage(encoded: encoded)
            #expect(try decoded.encoded() == encoded)
        }
    }

    @Test func grantPreservesTheIssuedTicketIncludingSequenceAndServerExpiry() throws {
        let original = try ticket()
        let encoded = try MediaControlWireMessage.subscribed(requestID: request, ticket: original, udpPort: 49_123).encoded()
        guard case let .subscribed(id, decoded, port) = try MediaControlWireMessage(encoded: encoded) else {
            Issue.record("Expected a subscription grant"); return
        }
        #expect(id == request && port == 49_123)
        #expect(decoded.roomID == original.roomID && decoded.senderID == original.senderID)
        #expect(decoded.receiverID == original.receiverID && decoded.sessionID == original.sessionID)
        #expect(decoded.subscriptionSequence == 42 && decoded.generation == 9 && decoded.broadcasterEpoch == 7)
        #expect(decoded.channels == [.audio, .timing])
        #expect(decoded.expiresAt == 100 && decoded.validForSeconds == 30)
        #expect(MediaStreamIdentifier(ticket: decoded) == MediaStreamIdentifier(ticket: original))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let body = try #require((object["message"] as? [String: Any])?["subscribed"] as? [String: Any])
        #expect(Set(body.keys) == ["requestID", "ticket", "udpPort"])
    }

    @Test func boundedFramingRejectsMalformedAndUnsupportedMessages() throws {
        #expect(throws: SecureTransportError.oversized) {
            try MediaControlWireMessage(encoded: Data(repeating: 32, count: MediaControlWireMessage.maximumWireBytes + 1))
        }
        for bytes in [Data(), Data([0xFF]), Data("{}".utf8), Data("[]".utf8)] {
            #expect(throws: SecureTransportError.malformed) { try MediaControlWireMessage(encoded: bytes) }
        }
        let valid = try MediaControlWireMessage.clockPing(id: 0, clientTimeNanos: 5).encoded()
        for value in [0, 1, 2, Int(MediaControlWireMessage.version) + 1] {
            let invalid = try rewrite(valid) { $0["version"] = value }
            #expect(throws: SecureTransportError.unsupportedProtocol) { try MediaControlWireMessage(encoded: invalid) }
        }
        let wrongProtocol = try rewrite(valid) { $0["protocolName"] = "alo.annotations" }
        #expect(throws: SecureTransportError.unsupportedProtocol) { try MediaControlWireMessage(encoded: wrongProtocol) }
        let missingVersion = try rewrite(valid) { $0.removeValue(forKey: "version") }
        #expect(throws: SecureTransportError.malformed) { try MediaControlWireMessage(encoded: missingVersion) }
        let unknownMessage = try rewrite(valid) { $0["message"] = ["openMicrophone": [:]] }
        #expect(throws: SecureTransportError.malformed) { try MediaControlWireMessage(encoded: unknownMessage) }
    }

    @Test func mediaSubscriptionsCannotGrantVoiceConsentOrReturnPathChannels() throws {
        let invalidChannels: [Set<DatagramChannel>] = [[], [.voice], [.returnPath], [.audio, .voice], [.audio, .timing, .voice]]
        for channels in invalidChannels {
            #expect(throws: SecureTransportError.malformed) {
                try MediaControlWireMessage.subscribe(requestID: request, broadcasterEpoch: 1, channels: channels).encoded()
            }
        }
        let voice = try ticket(channels: [.voice])
        #expect(throws: SecureTransportError.malformed) {
            try MediaControlWireMessage.subscribed(requestID: request, ticket: voice, udpPort: 123).encoded()
        }
        let wire = try MediaControlWireMessage.subscribe(requestID: request, broadcasterEpoch: 1, channels: [.audio]).encoded()
        for channels in [[1, 1], [2], [4], [1, 3, 3], [99], []] {
            let malformed = try rewriteBody(wire, kind: "subscribe") { $0["channels"] = channels }
            #expect(throws: SecureTransportError.malformed) { try MediaControlWireMessage(encoded: malformed) }
        }
    }

    @Test func rejectsPortZeroAndMalformedNestedTicket() throws {
        let issued = try ticket()
        let valid = try MediaControlWireMessage.subscribed(requestID: request, ticket: issued, udpPort: 123).encoded()
        for port in [0, -1, 65_536] {
            let invalid = try rewriteBody(valid, kind: "subscribed") { $0["udpPort"] = port }
            #expect(throws: SecureTransportError.malformed) { try MediaControlWireMessage(encoded: invalid) }
        }
        let broken = try rewriteBody(valid, kind: "subscribed") { $0["ticket"] = Data("{}".utf8).base64EncodedString() }
        #expect(throws: SecureTransportError.malformed) { try MediaControlWireMessage(encoded: broken) }
        let tooLarge = try rewriteBody(valid, kind: "subscribed") {
            $0["ticket"] = Data(repeating: 0, count: 2_049).base64EncodedString()
        }
        #expect(throws: SecureTransportError.oversized) { try MediaControlWireMessage(encoded: tooLarge) }
    }

    @Test func invalidTicketSequencesAreNotSilentlyRewritten() throws {
        let valid = try MediaControlWireMessage.subscribed(requestID: request, ticket: ticket(), udpPort: 123).encoded()
        for sequence in [UInt64(0), UInt64.max] {
            let invalid = try rewriteBody(valid, kind: "subscribed") { body in
                let base64 = try #require(body["ticket"] as? String)
                let bytes = try #require(Data(base64Encoded: base64))
                body["ticket"] = try rewrite(bytes) { $0["subscriptionSequence"] = NSNumber(value: sequence) }.base64EncodedString()
            }
            #expect(throws: SecureTransportError.malformed) { try MediaControlWireMessage(encoded: invalid) }
        }
    }

    @Test func anchorRejectsUnsupportedFormatOverflowAndUnboundedScheduling() throws {
        let invalidAnchors = [anchor(rate: 44_100), anchor(channels: 1), anchor(frames: 0), anchor(frames: 480),
            anchor(frameIndex: .max), anchor(capture: .max),
            anchor(playback: 999_999_999), anchor(playback: 1_600_000_001),
            anchor(capture: 3_000_000_001, playback: 3_100_000_001, issued: 1_000_000_000),
            anchor(issued: 2_200_000_001)]
        for value in invalidAnchors {
            #expect(throws: SecureTransportError.malformed) { try MediaControlWireMessage.anchor(value).encoded() }
        }
        let valid = try MediaControlWireMessage.anchor(anchor()).encoded()
        let badWire = try rewriteBody(valid, kind: "anchor") { payload in
            var value = try #require(payload["_0"] as? [String: Any])
            value["sampleRate"] = 44_100
            payload["_0"] = value
        }
        #expect(throws: SecureTransportError.malformed) { try MediaControlWireMessage(encoded: badWire) }
    }

    @Test func boundaryAnchorsAndDistinctClockEpochsRemainValid() throws {
        let future = anchor(capture: 2_800_000_000, playback: 3_000_000_000, issued: 1_000_000_000)
        let current = anchor(issued: 2_200_000_000)
        for value in [future, current] {
            guard case .anchor(let decoded) = try MediaControlWireMessage(encoded: MediaControlWireMessage.anchor(value).encoded()) else {
                Issue.record("Expected anchor"); continue
            }
            #expect(decoded == value)
        }
        let pong = MediaControlWireMessage.clockPong(id: 1, clientTimeNanos: 9_000_000_000_000, hostTimeNanos: 20, hostReceivedNanos: 10)
        let decoded = try MediaControlWireMessage(encoded: pong.encoded())
        guard case let .clockPong(_, client, sent, received) = decoded else { Issue.record("Missing pong"); return }
        #expect(client == 9_000_000_000_000 && sent == 20 && received == 10)
    }

    @Test func clockBridgeWorksWithTheExistingEstimator() throws {
        let clock = ClockSynchronizer()
        let ping = clock.makePing(at: 1_000)
        let id = try #require(ping.id)
        let request = MediaControlWireMessage.clockPing(id: id, clientTimeNanos: 1_000)
        #expect(request.clockControlMessage?.type == "ping")
        let reply = MediaControlWireMessage.clockPong(id: id, clientTimeNanos: 1_000, hostTimeNanos: 2_000, hostReceivedNanos: 1_900)
        guard case let .clockPong(_, client, host, received) = try MediaControlWireMessage(encoded: reply.encoded()) else { Issue.record("Missing pong"); return }
        let accepted = clock.acceptReply(id: id, echoedSendNanos: client, hostNanos: host, receivedAt: 1_200, hostReceivedNanos: received)
        #expect(accepted && clock.sampleCount == 1)
        #expect(MediaControlWireMessage.cancel(stream: stream).clockControlMessage == nil)
    }

    @Test func exhaustedCountersAndUnrepresentableTimestampsFail() throws {
        let invalid: [MediaControlWireMessage] = [
            .subscribe(requestID: request, broadcasterEpoch: .max, channels: [.audio]),
            .cancel(stream: .init(sessionID: UUID(), broadcasterEpoch: 0, generation: .max)),
            .clockPing(id: .max, clientTimeNanos: 0), .clockPing(id: 0, clientTimeNanos: .max),
            .clockPong(id: 0, clientTimeNanos: 0, hostTimeNanos: .max, hostReceivedNanos: 0),
            .clockPong(id: 0, clientTimeNanos: 0, hostTimeNanos: 9, hostReceivedNanos: 10),
            .pause(stream: stream, atCaptureTimeNanos: .max),
            .resync(requestID: request, stream: stream, minimumCaptureTimeNanos: .max),
            .requestKeyframe(requestID: request, stream: stream, minimumCaptureTimeNanos: .max)
        ]
        for value in invalid {
            #expect(throws: SecureTransportError.malformed) { try value.encoded() }
        }
    }

    @Test func anchorReadyMustEchoEveryFieldOfThePendingProposal() throws {
        // Non-packet-aligned positions are allowed: proposal equality is the
        // contract, not an assumed alignment of the broadcaster's timeline.
        let proposal = anchor(frameIndex: 241)
        let ready = MediaControlWireMessage.anchorReady(stream: proposal.stream, frameIndex: proposal.frameIndex,
            captureTimeNanos: proposal.captureTimeNanos, hostPlaybackTimeNanos: proposal.hostPlaybackTimeNanos)
        let decoded = try MediaControlWireMessage(encoded: ready.encoded())
        #expect(decoded.acknowledges(proposal))
        #expect(!MediaControlWireMessage.anchor(proposal).acknowledges(proposal))
        let wrong: [MediaControlWireMessage] = [
            .anchorReady(stream: stream, frameIndex: 241, captureTimeNanos: proposal.captureTimeNanos,
                         hostPlaybackTimeNanos: proposal.hostPlaybackTimeNanos),
            .anchorReady(stream: .init(sessionID: proposal.stream.sessionID, broadcasterEpoch: 8, generation: 9),
                         frameIndex: 241, captureTimeNanos: proposal.captureTimeNanos, hostPlaybackTimeNanos: proposal.hostPlaybackTimeNanos),
            .anchorReady(stream: .init(sessionID: proposal.stream.sessionID, broadcasterEpoch: 7, generation: 10),
                         frameIndex: 241, captureTimeNanos: proposal.captureTimeNanos, hostPlaybackTimeNanos: proposal.hostPlaybackTimeNanos),
            .anchorReady(stream: proposal.stream, frameIndex: 242, captureTimeNanos: proposal.captureTimeNanos,
                         hostPlaybackTimeNanos: proposal.hostPlaybackTimeNanos),
            .anchorReady(stream: proposal.stream, frameIndex: 241, captureTimeNanos: proposal.captureTimeNanos + 1,
                         hostPlaybackTimeNanos: proposal.hostPlaybackTimeNanos),
            .anchorReady(stream: proposal.stream, frameIndex: 241, captureTimeNanos: proposal.captureTimeNanos,
                         hostPlaybackTimeNanos: proposal.hostPlaybackTimeNanos + 1)
        ]
        for message in wrong {
            let value = try MediaControlWireMessage(encoded: message.encoded())
            #expect(!value.acknowledges(proposal))
        }
    }

    @Test func anchorReadyRejectsInvalidCountersTimesAndDelayOnBothBoundaries() throws {
        let invalid: [MediaControlWireMessage] = [
            .anchorReady(stream: stream, frameIndex: .max, captureTimeNanos: 0, hostPlaybackTimeNanos: 0),
            .anchorReady(stream: stream, frameIndex: 0, captureTimeNanos: .max, hostPlaybackTimeNanos: .max),
            .anchorReady(stream: stream, frameIndex: 0, captureTimeNanos: 2, hostPlaybackTimeNanos: 1),
            .anchorReady(stream: stream, frameIndex: 0, captureTimeNanos: 0, hostPlaybackTimeNanos: 600_000_001),
            .anchorReady(stream: .init(sessionID: UUID(), broadcasterEpoch: .max, generation: 0),
                         frameIndex: 0, captureTimeNanos: 0, hostPlaybackTimeNanos: 0)
        ]
        for value in invalid {
            #expect(throws: SecureTransportError.malformed) { try value.encoded() }
        }
        let valid = try MediaControlWireMessage.anchorReady(stream: stream, frameIndex: 0,
            captureTimeNanos: 0, hostPlaybackTimeNanos: 600_000_000).encoded()
        _ = try MediaControlWireMessage(encoded: valid)
        let bad = try rewriteBody(valid, kind: "anchorReady") { $0["hostPlaybackTimeNanos"] = 600_000_001 }
        #expect(throws: SecureTransportError.malformed) { try MediaControlWireMessage(encoded: bad) }
    }

    private func rewrite(_ data: Data, change: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func rewriteBody(_ data: Data, kind: String, change: (inout [String: Any]) throws -> Void) throws -> Data {
        try rewrite(data) { root in
            var message = try #require(root["message"] as? [String: Any])
            var body = try #require(message[kind] as? [String: Any])
            try change(&body)
            message[kind] = body; root["message"] = message
        }
    }
}
