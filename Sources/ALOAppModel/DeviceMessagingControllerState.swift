import Foundation
import CryptoKit
import ALONetworking

/// Pure, serialized app-owner bookkeeping, NOT a transport or consent fence.
/// Inputs must come from the real owner/adapters. Effects confer no execution
/// authority and must pass through the authenticated transport/native facade.
public struct DeviceMessagingControllerState: Sendable {
    public enum Failure: Error, Equatable { case unavailable, capacity, conflict, invalidRequest, unknownLocalMessage }
    public enum Phase: Equatable, Sendable { case disabled, constructing, ready }
    public enum Query: Equatable, Sendable { case statusUnknown, unavailable }
    public enum Result: Sendable {
        case receipt(CodexDeviceMessagingPolicy.Receipt)
        case statusUnknown, unavailable
    }
    public struct Construction: Sendable { fileprivate let generation: UUID }
    public struct Ticket: Equatable, Sendable {
        fileprivate let generation: UUID
        fileprivate let id: UUID
    }
    /// Presentation subscription lifetime, distinct from a pending work ticket.
    /// Only the real adapter may deliver an authoritative receipt through it.
    public struct Observation: Equatable, Sendable {
        fileprivate let generation: UUID
        fileprivate let id: UUID
    }
    public struct Effect: Sendable {
        public let ticket: Ticket
        public let observation: Observation
        /// Original locally established route; never guessed from a receipt ID.
        public let destination: UUID
        public let request: LocalDeviceMessageProtocol.Request
    }
    public struct Snapshot: Equatable, Sendable {
        public let status: LocalDeviceMessageProtocol.Response.Status
        public let query: Query?
    }
    private struct Key: Hashable, Sendable { let registration: UUID; let message: UUID }
    private struct Record: Sendable {
        let digest: Data?
        let destination: UUID
        let observation: Observation
        var receipt: CodexDeviceMessagingPolicy.Receipt?
        var query: Query?
        var unavailable = false
        var ticket: Ticket?
        var querying = false
    }
    public private(set) var phase = Phase.disabled
    private var generation = UUID()
    private var registry = DeviceMessageRegistration()
    private var destinations: [UUID: UUID] = [:]
    private var records: [Key: Record] = [:]
    public init() {}
    public var registrations: [DeviceMessageRegistration.Entry] { registry.registrations }
    public var pendingCount: Int { records.values.filter { $0.ticket != nil }.count }
    public func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.generation == generation && records.values.contains { $0.ticket == ticket }
    }

    /// Preference only; real construction/enable runs elsewhere. No effect here
    /// enables a service. The owner invalidates its actual services separately.
    public mutating func beginEnable() -> Construction {
        invalidate(); phase = .constructing
        return Construction(generation: generation)
    }
    @discardableResult public mutating func finishConstruction(_ ticket: Construction, succeeded: Bool) -> Bool {
        guard ticket.generation == generation, phase == .constructing else { return false }
        phase = succeeded ? .ready : .disabled
        return true
    }
    public mutating func invalidate() {
        generation = UUID(); phase = .disabled
        registry.invalidate(); destinations.removeAll(); records.removeAll()
    }
    public mutating func register(taskID: UUID, title: String) throws -> UUID {
        guard phase == .ready else { throw Failure.unavailable }
        return try registry.register(taskID: taskID, title: title)
    }
    public mutating func beginCapabilityTest(registration: UUID, approvedDigest: Data, now: UInt64) throws -> DeviceMessageRegistration.Challenge {
        guard phase == .ready else { throw Failure.unavailable }
        destinations = destinations.filter { $0.value != registration }
        for key in Array(records.keys) where key.registration == registration {
            records[key]?.ticket = nil
            records[key]?.unavailable = true
        }
        return try registry.beginCapabilityTest(registration: registration, approvedDigest: approvedDigest, now: now)
    }
    public mutating func confirmCapability(_ challenge: DeviceMessageRegistration.Challenge, response: UUID, approvedDigest: Data, now: UInt64) throws {
        guard phase == .ready else { throw Failure.unavailable }
        try registry.confirm(challenge, response: response, approvedDigest: approvedDigest, now: now)
    }
    /// Called only after actual authenticated peer/grant mapping is established
    /// by the owner. This local UUID alone proves no remote authorization.
    public mutating func bindAuthenticatedDestination(registration: UUID, approvedDigest: Data) throws -> UUID {
        guard phase == .ready else { throw Failure.unavailable }
        _ = try registry.verifiedTask(registration: registration, approvedDigest: approvedDigest)
        guard destinations.count < 32 else { throw Failure.capacity }
        let id = UUID(); destinations[id] = registration; return id
    }
    /// The owner must synchronously revoke actual grants before calling this.
    /// This pure transition cannot acknowledge or perform security revocation.
    public mutating func forgetAfterLocalGrantRevocation(_ registration: UUID) {
        registry.forget(registration)
        destinations = destinations.filter { $0.value != registration }
        records = records.filter { $0.key.registration != registration }
    }
    /// Returns one bounded work intention; nil means coalesced, never sent.
    /// Existing text IDs never automatically create another send, even after an
    /// unavailable result. Only explicit receipt requests create query work.
    public mutating func admit(_ request: LocalDeviceMessageProtocol.Request) throws -> Effect? {
        try request.validate(); _ = try LocalDeviceMessageProtocol.encode(request)
        guard phase == .ready, let registration = request.registration,
              let message = request.messageID,
              registry.registrations.contains(where: { $0.id == registration && $0.state == .verified }) else { throw Failure.unavailable }
        guard request.operation == .send || request.operation == .receipt else { throw Failure.invalidRequest }
        let key = Key(registration: registration, message: message)
        let querying = request.operation == .receipt
        let digest: Data?
        if !querying {
            guard let destination = request.destination, destinations[destination] == registration else { throw Failure.unavailable }
            // Hash stable field values, not JSONEncoder's object ordering.
            digest = Data(SHA256.hash(data: Data((destination.uuidString + "\n" + (request.text ?? "")).utf8)))
        } else { digest = nil }
        if let prior = records[key] {
            if !querying {
                guard prior.digest == digest else { throw Failure.conflict }
                return nil
            }
            guard destinations[prior.destination] == registration else { throw Failure.unavailable }
            if prior.ticket != nil { return nil }
        } else {
            // No local route means no peer query. This is not an authoritative
            // receiver not-found result, and must never become cancelled.
            guard !querying else { throw Failure.unknownLocalMessage }
            guard records.count < 32 else { throw Failure.capacity }
            guard let destination = request.destination else { throw Failure.invalidRequest }
            records[key] = Record(digest: digest, destination: destination, observation: Observation(generation: generation, id: UUID()))
        }
        let ticket = Ticket(generation: generation, id: UUID())
        records[key]?.ticket = ticket; records[key]?.querying = querying
        let record = records[key]!
        return Effect(ticket: ticket, observation: record.observation, destination: record.destination, request: request)
    }
    /// Only the real adapter's authoritative lookup/live receipt may supply a
    /// receipt. completion(recorded:) and dispatchFailed must instead request an
    /// ID-only lookup; neither is a terminal receipt in this reducer.
    @discardableResult public mutating func finish(_ ticket: Ticket, result: Result) -> Bool {
        guard ticket.generation == generation,
              let key = records.first(where: { $0.value.ticket == ticket })?.key,
              var record = records[key] else { return false }
        if case .statusUnknown = result, !record.querying { return false }
        if case .receipt(let receipt) = result, !Self.canAdvance(record.receipt, to: receipt) { return false }
        record.ticket = nil
        switch result {
        case .receipt(let receipt): record.receipt = receipt; record.query = nil; record.unavailable = false
        case .statusUnknown:
            record.query = .statusUnknown
        case .unavailable:
            if record.querying { record.query = .unavailable } else { record.unavailable = true }
        }
        records[key] = record
        return true
    }
    /// Live authoritative receipt, not a completion(bool) notification. It does
    /// not finish or allocate query work, nor consume observation ownership.
    @discardableResult public mutating func observe(_ observation: Observation, receipt: CodexDeviceMessagingPolicy.Receipt) -> Bool {
        guard observation.generation == generation,
              let key = records.first(where: { $0.value.observation == observation })?.key,
              var record = records[key], Self.canAdvance(record.receipt, to: receipt) else { return false }
        record.receipt = receipt; record.unavailable = false
        records[key] = record
        return true
    }
    private static func canAdvance(_ prior: CodexDeviceMessagingPolicy.Receipt?, to receipt: CodexDeviceMessagingPolicy.Receipt) -> Bool {
        switch prior {
        case nil, .received?: return true
        case .dispatching?: return receipt != .received
        case .codexQueued?, .uncertain?: return receipt == prior || receipt == .delivered
        case .cancelled?, .delivered?: return receipt == prior
        }
    }
    public func snapshot(registration: UUID, messageID: UUID) -> Snapshot? {
        guard let record = records[Key(registration: registration, message: messageID)] else { return nil }
        let status: LocalDeviceMessageProtocol.Response.Status
        switch record.receipt {
        case .received?, .dispatching?: status = .authenticatedReceipt
        case .codexQueued?: status = .codexQueued
        case .delivered?: status = .deliveredConfirmed
        case .cancelled?: status = .definitelyNotQueued
        case .uncertain?: status = .uncertain
        case nil:
            if record.unavailable || (record.ticket == nil && record.query == .unavailable) { status = .unavailable }
            else if record.ticket == nil && record.query == .statusUnknown { status = .statusUnknown }
            else { status = .pending }
        }
        return Snapshot(status: status, query: record.query)
    }
    /// Explicit local acknowledgement only; durable service receipts remain
    /// authoritative. This frees presentation capacity, not dedupe authority.
    public mutating func retirePresentation(registration: UUID, messageID: UUID) throws {
        let key = Key(registration: registration, message: messageID)
        guard let record = records[key], record.ticket == nil else { throw Failure.unavailable }
        records.removeValue(forKey: key)
    }
}
