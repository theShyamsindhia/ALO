import Foundation

/// Serialized by the app owner. No method grants remote access or invokes Codex.
/// Same-UID software is trusted locally; this is not task/process attestation.
public struct DeviceMessageRegistration: Sendable {
    public enum Failure: Error, Equatable { case invalidInput, capacity, unavailable, invalidConfirmation }
    public enum State: Equatable, Sendable { case pendingApproval, capabilityPending, verified, revoked }
    public struct Entry: Equatable, Sendable {
        public let id: UUID
        public let taskID: UUID
        public let title: String
        public fileprivate(set) var state: State
    }
    public struct Challenge: Equatable, Sendable {
        public let id: UUID
        public let registration: UUID
        public let taskID: UUID
        public let nonce: UUID
        public let expiresAt: UInt64
        fileprivate let beganAt: UInt64
        fileprivate let generation: UUID
        fileprivate let executableDigest: Data
    }
    private var entries: [UUID: Entry] = [:]
    private var challenges: [UUID: Challenge] = [:]
    private var verifiedDigests: [UUID: Data] = [:]
    private var generation = UUID()
    public init() {}

    public var registrations: [Entry] { entries.values.sorted { $0.id.uuidString < $1.id.uuidString } }

    public mutating func register(taskID: UUID, title: String) throws -> UUID {
        guard !title.isEmpty, title.utf8.count <= 160,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidInput
        }
        if let existing = entries.values.first(where: { $0.taskID == taskID }) { return existing.id }
        guard entries.count < 32 else { throw Failure.capacity }
        let id = UUID()
        entries[id] = Entry(id: id, taskID: taskID, title: title, state: .pendingApproval)
        return id
    }

    /// Only the local approval UI calls this. Queue acceptance does not confirm it.
    public mutating func beginCapabilityTest(registration: UUID, approvedDigest: Data, now: UInt64) throws -> Challenge {
        guard approvedDigest.count == 32, now <= UInt64.max - 120_000_000_000,
              var entry = entries[registration], entry.state != .revoked else { throw Failure.unavailable }
        let challenge = Challenge(id: UUID(), registration: registration, taskID: entry.taskID,
            nonce: UUID(), expiresAt: now + 120_000_000_000, beganAt: now, generation: generation, executableDigest: approvedDigest)
        challenges[registration] = challenge
        verifiedDigests.removeValue(forKey: registration)
        entry.state = .capabilityPending; entries[registration] = entry
        return challenge
    }

    /// Receiver-local confirmation of an actually observed task challenge, not
    /// a network receipt or successful CLI exit. The caller supplies fresh time.
    public mutating func confirm(_ challenge: Challenge, response: UUID, approvedDigest: Data, now: UInt64) throws {
        guard challenges[challenge.registration] == challenge,
              challenge.generation == generation, now >= challenge.beganAt, now < challenge.expiresAt,
              response == challenge.nonce, approvedDigest == challenge.executableDigest,
              var entry = entries[challenge.registration], entry.state == .capabilityPending,
              entry.taskID == challenge.taskID else { throw Failure.invalidConfirmation }
        entry.state = .verified; entries[entry.id] = entry
        verifiedDigests[entry.id] = approvedDigest
        challenges.removeValue(forKey: entry.id)
    }

    public func verifiedTask(registration: UUID, approvedDigest: Data) throws -> UUID {
        guard let entry = entries[registration], entry.state == .verified,
              verifiedDigests[registration] == approvedDigest else { throw Failure.unavailable }
        return entry.taskID
    }

    public mutating func revoke(_ registration: UUID) {
        guard var entry = entries[registration] else { return }
        entry.state = .revoked; entries[registration] = entry
        challenges.removeValue(forKey: registration); verifiedDigests.removeValue(forKey: registration)
    }

    /// Explicit local UI removal, never automatic CLI registration/reapproval.
    /// The controller must first revoke any receiver grants associated with this
    /// registration: this value does not own remote grants or their dispatch fence.
    /// Registering the task again allocates a new pending ID and fresh challenge.
    public mutating func forget(_ registration: UUID) {
        entries.removeValue(forKey: registration)
        challenges.removeValue(forKey: registration)
        verifiedDigests.removeValue(forKey: registration)
    }

    /// Called for identity replacement, disable, or executable replacement.
    /// No old await/challenge can reactivate a registration afterward.
    public mutating func invalidate() {
        generation = UUID(); challenges.removeAll(); verifiedDigests.removeAll()
        for id in Array(entries.keys) { entries[id]?.state = .revoked }
    }
}
