import Foundation
import ALOCore

/// A publisher-issued subscription identity, not evidence of admission or ownership.
public struct MediaStreamIdentifier: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let broadcasterEpoch: UInt64
    public let generation: UInt64

    public init(sessionID: UUID, broadcasterEpoch: UInt64, generation: UInt64) {
        self.sessionID = sessionID; self.broadcasterEpoch = broadcasterEpoch; self.generation = generation
    }

    public init(ticket: MediaSubscriptionTicket) {
        self.init(sessionID: ticket.sessionID, broadcasterEpoch: ticket.broadcasterEpoch, generation: ticket.generation)
    }

    fileprivate func validate() throws {
        guard broadcasterEpoch < .max, generation < .max else { throw SecureTransportError.malformed }
    }
}

/// Current/future timeline reference. All three timestamps use the publisher's
/// monotonic clock. The receiver converts hostPlaybackTimeNanos through its clock
/// model; it must not compare issuedAtHostNanos directly with its local uptime.
/// A running anchor resumes media after pause. It never changes shared playback.
public struct MediaStreamAnchor: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, paused }
    public let stream: MediaStreamIdentifier
    public let captureTimeNanos: UInt64
    public let frameIndex: UInt64
    public let hostPlaybackTimeNanos: UInt64
    public let issuedAtHostNanos: UInt64
    public let sampleRate: UInt32
    public let channelCount: UInt16
    public let framesPerPacket: UInt16
    public let state: State
    /// Present only for an explicit user sync. Old peers ignore this optional
    /// field; ordinary anchor refreshes and ticket renewals remain seamless.
    public var playbackResetID: UUID?

    public init(stream: MediaStreamIdentifier, captureTimeNanos: UInt64, frameIndex: UInt64,
                hostPlaybackTimeNanos: UInt64, issuedAtHostNanos: UInt64,
                sampleRate: UInt32 = AudioPacket.sampleRate, channelCount: UInt16 = AudioPacket.channelCount,
                framesPerPacket: UInt16 = AudioPacket.framesPerPacket, state: State = .running) {
        self.stream = stream; self.captureTimeNanos = captureTimeNanos; self.frameIndex = frameIndex
        self.hostPlaybackTimeNanos = hostPlaybackTimeNanos; self.issuedAtHostNanos = issuedAtHostNanos
        self.sampleRate = sampleRate; self.channelCount = channelCount
        self.framesPerPacket = framesPerPacket; self.state = state
    }

    fileprivate func validate() throws {
        try stream.validate()
        try MediaControlWireMessage.validateTime(captureTimeNanos)
        try MediaControlWireMessage.validateTime(hostPlaybackTimeNanos)
        try MediaControlWireMessage.validateTime(issuedAtHostNanos)
        guard sampleRate == AudioPacket.sampleRate, channelCount == AudioPacket.channelCount,
              framesPerPacket == AudioPacket.framesPerPacket,
              frameIndex <= UInt64.max - UInt64(framesPerPacket),
              hostPlaybackTimeNanos >= captureTimeNanos,
              hostPlaybackTimeNanos - captureTimeNanos <= RoomTiming.maximumPlayoutDelayNanos else {
            throw SecureTransportError.malformed
        }
        // Refresh old references before sending. This bounds scheduling lead and
        // prevents a far-future remote timestamp from retaining decoded buffers.
        if hostPlaybackTimeNanos >= issuedAtHostNanos {
            guard hostPlaybackTimeNanos - issuedAtHostNanos <= MediaControlWireMessage.maximumAnchorLeadNanos else {
                throw SecureTransportError.malformed
            }
        } else {
            guard issuedAtHostNanos - hostPlaybackTimeNanos <= MediaControlWireMessage.maximumAnchorAgeNanos else {
                throw SecureTransportError.malformed
            }
        }
    }
}

/// One message per SecurePeerChannel payload on an admitted `.mediaControl`
/// channel. This schema deliberately covers media only: `.voice` requires a
/// separate contract bound to local Talk/Open Line consent and fixed recipients.
///
/// Adapter obligations (parsing is NOT authorization):
/// - Bind the channel to the selected room, authenticated peer and current
///   broadcaster/epoch. Check negotiated capabilities and message direction.
/// - Match request IDs, then validate grants through that channel's credentials;
///   compare every subsequent stream identifier to the current issued ticket.
/// - Obtain the UDP host from the authenticated connection. The grant carries
///   only a port, never a hostname, IP address, URL or arbitrary endpoint.
/// - Renew with a fresh publisher-issued ticket, sequence and nonce space. Cancel
///   old tickets on leave/epoch change; apply rate limits and request deadlines.
/// - Bound outstanding clock probes, verify pong echo/time freshness, and reject
///   stale anchors against the local lifecycle and clock model before scheduling.
/// - Pause/anchor are publisher notifications; resync/IDR are receiver requests,
///   not authorization to change shared playback or broadcaster ownership.
/// - A receiver sends anchorReady only after preparing the proposed timeline.
///   Match every echoed field against the pending host proposal, on the same
///   authenticated peer/session and before its deadline. Successful socket send
///   completion is NOT a receiver acknowledgment or permission to cut over.
public enum MediaControlWireMessage: Sendable {
    case subscribe(requestID: UUID, broadcasterEpoch: UInt64, channels: Set<DatagramChannel>)
    case renew(requestID: UUID, stream: MediaStreamIdentifier)
    case cancel(stream: MediaStreamIdentifier)
    case subscribed(requestID: UUID, ticket: MediaSubscriptionTicket, udpPort: UInt16)
    case clockPing(id: UInt64, clientTimeNanos: UInt64)
    case clockPong(id: UInt64, clientTimeNanos: UInt64, hostTimeNanos: UInt64)
    case anchor(MediaStreamAnchor)
    case anchorReady(stream: MediaStreamIdentifier, frameIndex: UInt64,
                     captureTimeNanos: UInt64, hostPlaybackTimeNanos: UInt64)
    case pause(stream: MediaStreamIdentifier, atCaptureTimeNanos: UInt64)
    case resync(requestID: UUID, stream: MediaStreamIdentifier, minimumCaptureTimeNanos: UInt64?)
    case requestKeyframe(requestID: UUID, stream: MediaStreamIdentifier, minimumCaptureTimeNanos: UInt64?)
    case timingReport(stream: MediaStreamIdentifier, report: MediaReceiverTimingReport)
    case rejected(requestID: UUID, reason: Rejection)

    public enum Rejection: String, Codable, Sendable {
        case unsupported, unavailable, staleSession, denied, busy
    }
    public static let protocolName = "alo.media-control"
    public static let version: UInt16 = 2
    public static let maximumWireBytes = 4_096
    public static let maximumAnchorLeadNanos: UInt64 = 2_000_000_000
    public static let maximumAnchorAgeNanos: UInt64 = 1_000_000_000

    // Keep Codable private: callers cannot bypass validation by decoding this
    // public enum directly. The outer framing is explicit and versioned.
    private struct Envelope: Codable {
        let protocolName: String
        let version: UInt16
        let message: Payload
    }
    private enum Payload: Codable {
        case subscribe(requestID: UUID, broadcasterEpoch: UInt64, channels: [DatagramChannel])
        case renew(requestID: UUID, stream: MediaStreamIdentifier)
        case cancel(stream: MediaStreamIdentifier)
        case subscribed(requestID: UUID, ticket: Data, udpPort: UInt16)
        case clockPing(id: UInt64, clientTimeNanos: UInt64)
        case clockPong(id: UInt64, clientTimeNanos: UInt64, hostTimeNanos: UInt64)
        case anchor(MediaStreamAnchor)
        case anchorReady(stream: MediaStreamIdentifier, frameIndex: UInt64,
                         captureTimeNanos: UInt64, hostPlaybackTimeNanos: UInt64)
        case pause(stream: MediaStreamIdentifier, atCaptureTimeNanos: UInt64)
        case resync(requestID: UUID, stream: MediaStreamIdentifier, minimumCaptureTimeNanos: UInt64?)
        case requestKeyframe(requestID: UUID, stream: MediaStreamIdentifier, minimumCaptureTimeNanos: UInt64?)
        case timingReport(stream: MediaStreamIdentifier, report: MediaReceiverTimingReport)
        case rejected(requestID: UUID, reason: Rejection)
    }

    public func encoded() throws -> Data {
        let payload: Payload
        switch self {
        case let .subscribe(id, epoch, channels):
            try Self.validateChannels(channels)
            guard epoch < .max else { throw SecureTransportError.malformed }
            payload = .subscribe(requestID: id, broadcasterEpoch: epoch, channels: channels.sorted { $0.rawValue < $1.rawValue })
        case let .renew(id, stream): try stream.validate(); payload = .renew(requestID: id, stream: stream)
        case .cancel(let stream): try stream.validate(); payload = .cancel(stream: stream)
        case let .subscribed(id, ticket, port):
            try Self.validateChannels(ticket.channels)
            try MediaStreamIdentifier(ticket: ticket).validate()
            guard port != 0, ticket.subscriptionSequence > 0, ticket.subscriptionSequence < .max,
                  ticket.expiresAt.isFinite, ticket.expiresAt >= 0,
                  ticket.validForSeconds.isFinite, ticket.validForSeconds > 0, ticket.validForSeconds <= 300 else {
                throw SecureTransportError.malformed
            }
            payload = .subscribed(requestID: id, ticket: try ticket.encoded(), udpPort: port)
        case let .clockPing(id, time):
            guard id < .max else { throw SecureTransportError.malformed }
            try Self.validateTime(time); payload = .clockPing(id: id, clientTimeNanos: time)
        case let .clockPong(id, client, host):
            guard id < .max else { throw SecureTransportError.malformed }
            try Self.validateTime(client); try Self.validateTime(host)
            payload = .clockPong(id: id, clientTimeNanos: client, hostTimeNanos: host)
        case .anchor(let anchor): try anchor.validate(); payload = .anchor(anchor)
        case let .anchorReady(stream, frame, capture, playback):
            try stream.validate(); try Self.validateTime(capture); try Self.validateTime(playback)
            guard frame <= UInt64.max - UInt64(AudioPacket.framesPerPacket), playback >= capture,
                  playback - capture <= RoomTiming.maximumPlayoutDelayNanos else {
                throw SecureTransportError.malformed
            }
            payload = .anchorReady(stream: stream, frameIndex: frame,
                                   captureTimeNanos: capture, hostPlaybackTimeNanos: playback)
        case let .pause(stream, time):
            try stream.validate(); try Self.validateTime(time)
            payload = .pause(stream: stream, atCaptureTimeNanos: time)
        case let .resync(id, stream, time):
            try stream.validate(); if let time { try Self.validateTime(time) }
            payload = .resync(requestID: id, stream: stream, minimumCaptureTimeNanos: time)
        case let .requestKeyframe(id, stream, time):
            try stream.validate(); if let time { try Self.validateTime(time) }
            payload = .requestKeyframe(requestID: id, stream: stream, minimumCaptureTimeNanos: time)
        case let .timingReport(stream, report):
            try stream.validate(); try report.validate()
            payload = .timingReport(stream: stream, report: report)
        case let .rejected(id, reason): payload = .rejected(requestID: id, reason: reason)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(protocolName: Self.protocolName, version: Self.version, message: payload))
        guard data.count <= Self.maximumWireBytes else { throw SecureTransportError.oversized }
        return data
    }

    public init(encoded data: Data) throws {
        guard data.count <= Self.maximumWireBytes else { throw SecureTransportError.oversized }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw SecureTransportError.malformed }
        guard envelope.protocolName == Self.protocolName, envelope.version == Self.version else {
            throw SecureTransportError.unsupportedProtocol
        }
        switch envelope.message {
        case let .subscribe(id, epoch, channels):
            guard channels.count <= 2, Set(channels).count == channels.count else { throw SecureTransportError.malformed }
            self = .subscribe(requestID: id, broadcasterEpoch: epoch, channels: Set(channels))
        case let .renew(id, stream): self = .renew(requestID: id, stream: stream)
        case .cancel(let stream): self = .cancel(stream: stream)
        case let .subscribed(id, bytes, port):
            let ticket: MediaSubscriptionTicket
            do { ticket = try MediaSubscriptionTicket(encoded: bytes) }
            catch let error as SecureTransportError { throw error }
            catch { throw SecureTransportError.malformed }
            self = .subscribed(requestID: id, ticket: ticket, udpPort: port)
        case let .clockPing(id, time): self = .clockPing(id: id, clientTimeNanos: time)
        case let .clockPong(id, client, host): self = .clockPong(id: id, clientTimeNanos: client, hostTimeNanos: host)
        case .anchor(let anchor): self = .anchor(anchor)
        case let .anchorReady(stream, frame, capture, playback):
            self = .anchorReady(stream: stream, frameIndex: frame,
                                captureTimeNanos: capture, hostPlaybackTimeNanos: playback)
        case let .pause(stream, time): self = .pause(stream: stream, atCaptureTimeNanos: time)
        case let .resync(id, stream, time): self = .resync(requestID: id, stream: stream, minimumCaptureTimeNanos: time)
        case let .requestKeyframe(id, stream, time): self = .requestKeyframe(requestID: id, stream: stream, minimumCaptureTimeNanos: time)
        case let .timingReport(stream, report): self = .timingReport(stream: stream, report: try report.normalized())
        case let .rejected(id, reason): self = .rejected(requestID: id, reason: reason)
        }
        _ = try encoded() // Exactly the same structural checks for inbound and outbound values.
    }

    /// Bridge to the existing ClockSynchronizer; no new clock estimator is needed.
    /// This does not perform outstanding-request or authenticated-origin checks.
    public var clockControlMessage: ControlMessage? {
        switch self {
        case let .clockPing(id, client): return ControlMessage(type: "ping", id: id, clientNanos: client)
        case let .clockPong(id, client, host): return ControlMessage(type: "pong", id: id, clientNanos: client, hostNanos: host)
        default: return nil
        }
    }

    /// Exact proposal echo matching, not authentication or deadline validation.
    /// The adapter must retain the actual pending proposal, rather than rebuild
    /// one using fields supplied by this acknowledgment.
    public func acknowledges(_ proposal: MediaStreamAnchor) -> Bool {
        guard case let .anchorReady(stream, frame, capture, playback) = self else { return false }
        return stream == proposal.stream && frame == proposal.frameIndex &&
            capture == proposal.captureTimeNanos && playback == proposal.hostPlaybackTimeNanos
    }

    private static func validateChannels(_ channels: Set<DatagramChannel>) throws {
        guard !channels.isEmpty, channels.isSubset(of: [.audio, .timing]) else { throw SecureTransportError.malformed }
    }
    fileprivate static func validateTime(_ time: UInt64) throws {
        guard time <= UInt64(Int64.max) else { throw SecureTransportError.malformed }
    }
}
