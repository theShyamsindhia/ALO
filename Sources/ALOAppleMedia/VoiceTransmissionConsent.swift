import Foundation

/// Local-user consent only. Remote signaling has no entry point that can create
/// a request. Permission completion must match the original fixed peer snapshot.
public struct VoiceTransmissionConsent: Sendable {
    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let recipients: Set<UUID>
    }
    public private(set) var pending: Request?
    public private(set) var active: Request?
    public init() {}
    public mutating func request(recipients: Set<UUID>, connected: Set<UUID>, localID: UUID) throws -> Request {
        guard pending == nil, active == nil else { throw AppleMediaError.invalidState }
        guard !recipients.isEmpty, recipients.count <= 8, !recipients.contains(localID),
              recipients.isSubset(of: connected) else { throw AppleMediaError.invalidState }
        let request = Request(id: UUID(), recipients: recipients)
        pending = request
        return request
    }
    public mutating func grant(_ id: UUID, connected: Set<UUID>) -> Request? {
        guard let pending, pending.id == id, pending.recipients.isSubset(of: connected) else { return nil }
        self.pending = nil; active = pending
        return pending
    }
    @discardableResult public mutating func revoke() -> Request? {
        let previous = active
        pending = nil; active = nil
        return previous
    }
    public func remainsValid(connected: Set<UUID>) -> Bool {
        (active ?? pending).map { $0.recipients.isSubset(of: connected) } ?? true
    }
}
