import Foundation
@_exported import ALOTiming

/// Serialization adapter only. The estimator lives in ALOTiming and has no
/// dependency on room messages, sockets, UI, persistence or audio hardware.
extension ClockSynchronizer {
    public func makePing(at clientNanos: UInt64) -> ControlMessage {
        let probe = makeProbe(at: clientNanos)
        return ControlMessage(type: "ping", id: probe.id, clientNanos: probe.sentAtNanos)
    }

    @discardableResult
    public func acceptPong(_ message: ControlMessage, receivedAt: UInt64) -> Bool {
        guard message.type == "pong", let id = message.id,
              let client = message.clientNanos, let host = message.hostNanos else { return false }
        return acceptReply(id: id, echoedSendNanos: client, hostNanos: host, receivedAt: receivedAt)
    }
}
