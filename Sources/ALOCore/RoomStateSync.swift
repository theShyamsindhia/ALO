import Automerge
import Foundation

/// Durable room data that should converge even when peers edit concurrently or
/// miss an earlier message. Realtime playback, presence, leases, video, and
/// voice intentionally stay on ALO's latency-sensitive control plane.
public struct RoomStateSnapshot: Sendable, Equatable {
    public let events: [MeshRoomEvent]
    /// Cryptographically validated records, including records that are not
    /// currently authorized to affect the local UI/queue. Never project these
    /// directly; they exist for replication, archive and receipt retention only.
    public let retainedEvents: [MeshRoomEvent]
    public let chatEvents: [MeshRoomEvent]
    public let queue: [RoomQueueItem]

    public init(events: [MeshRoomEvent], retainedEvents: [MeshRoomEvent]? = nil) {
        let replica = MeshRoomReplica(events: events)
        self.events = replica.events
        self.retainedEvents = retainedEvents ?? replica.events
        self.chatEvents = replica.chatEvents
        self.queue = replica.queue
    }
}

/// Per-connection Automerge sync knowledge. A session must be discarded when
/// its reliable connection closes; a replacement link starts with fresh state.
public final class RoomStateSyncSession: @unchecked Sendable {
    fileprivate let state = SyncState()

    public init() {}
    public func reset() { state.reset() }
}

public protocol RoomStateSync: AnyObject, Sendable {
    func snapshot() throws -> RoomStateSnapshot

    @discardableResult
    func ingest(_ events: [MeshRoomEvent]) throws -> [MeshRoomEvent]

    func makeSession() -> RoomStateSyncSession
    func generateSyncMessage(for session: RoomStateSyncSession) -> Data?

    @discardableResult
    func receiveSyncMessage(_ message: Data, from session: RoomStateSyncSession) throws -> [MeshRoomEvent]

    /// Rewrites retained state into a fresh Automerge history when accumulated
    /// changes approach the transport budget. Callers must reset link sessions
    /// when this returns true.
    func compactIfNeeded() throws -> Bool
    func requiresLifecycleCompaction() -> Bool

    func save() -> Data
}

public extension RoomStateSync {
    func compactIfNeeded() throws -> Bool { false }
    func requiresLifecycleCompaction() -> Bool { false }
}

public enum RoomStateSyncError: Error, Sendable, Equatable {
    case invalidDocument
    case documentTooLarge
    case immutableEventChanged
    case processingTimedOut
    case authorizationChanged
    case untrustedHistoryLimit
}

/// Automerge-backed durable room state. Each immutable ALO event occupies a
/// map key, so concurrent chat and queue changes form a grow-only event set;
/// queue removals remain explicit tombstones in that set.
public final class AutomergeRoomStateSync: RoomStateSync, @unchecked Sendable {
    public static let maximumEventBytes = 131_072
    public static let maximumDocumentBytes = 5 * 1_024 * 1_024
    public static let proactiveFallbackDocumentBytes = maximumDocumentBytes * 3 / 4
    public static let maximumChatEvents = 500
    public static let maximumQueueEvents = 5_000
    public static let maximumChangesPerSyncMessage = 2_048
    /// Inert provenance is useful for convergence, but is not a storage grant.
    /// Reject an oversized candidate atomically instead of retaining it until
    /// it forces the entire channel into a persistent durable-sync fallback.
    public static let maximumInertEvents = 1_024
    public static let maximumInertBytes = 1_024 * 1_024

    private static let keyPrefix = "event:"
    private let roomID: String
    private let eventValidator: @Sendable (MeshRoomEvent) -> Bool
    private let eventProjector: @Sendable (MeshRoomEvent) -> Bool
    private let authorScopedRetention: Bool
    private let projectionRevision: (@Sendable () -> UInt64?)?
    private var projectionCache = [String: (encodedEvent: Data, allowed: Bool)]()
    private var document: Document
    private var actorID: ActorId
    private var cachedEventsByID = [String: MeshRoomEvent]()
    private var cachedDocumentData: Data
    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(
        roomID: String,
        savedDocument: Data? = nil,
        legacyEvents: [MeshRoomEvent] = [],
        eventValidator: @escaping @Sendable (MeshRoomEvent) -> Bool = { _ in true },
        eventProjector: (@Sendable (MeshRoomEvent) -> Bool)? = nil,
        projectionRevision: (@Sendable () -> UInt64?)? = nil
    ) throws {
        self.eventValidator = eventValidator
        self.eventProjector = eventProjector ?? { _ in true }
        self.authorScopedRetention = eventProjector != nil
        self.projectionRevision = projectionRevision
        self.roomID = roomID
        if let savedDocument {
            document = try Document(savedDocument)
        } else {
            document = Document()
        }
        actorID = document.actor
        cachedDocumentData = document.save()
        let revision = try currentProjectionRevision()
        var loadedEvents = try validatedEvents(in: document)
        _ = try pruneRetainedState(in: document, eventsByID: &loadedEvents)
        try requireProjectionRevision(revision)
        cachedEventsByID = loadedEvents
        cachedDocumentData = document.save()
        guard cachedDocumentData.count <= Self.maximumDocumentBytes else {
            throw RoomStateSyncError.documentTooLarge
        }
        if authorScopedRetention, cachedDocumentData.count >= Self.proactiveFallbackDocumentBytes,
           loadedEvents.values.contains(where: { !isProjected($0) }) {
            throw RoomStateSyncError.untrustedHistoryLimit
        }
        _ = try compactIfNeeded()
        _ = try ingest(legacyEvents)
    }

    /// Recovers from a corrupt sidecar without making the room impossible to
    /// open, then migrates whatever valid legacy events are still available.
    public static func recovering(
        roomID: String,
        savedDocument: Data?,
        legacyEvents: [MeshRoomEvent],
        eventValidator: @escaping @Sendable (MeshRoomEvent) -> Bool = { _ in true },
        eventProjector: (@Sendable (MeshRoomEvent) -> Bool)? = nil,
        projectionRevision: (@Sendable () -> UInt64?)? = nil
    ) -> AutomergeRoomStateSync {
        if let savedDocument,
           let loaded = try? AutomergeRoomStateSync(roomID: roomID, savedDocument: savedDocument,
                eventValidator: eventValidator, eventProjector: eventProjector, projectionRevision: projectionRevision) {
            _ = try? loaded.ingest(legacyEvents)
            return loaded
        }
        let empty = AutomergeRoomStateSync(roomID: roomID, document: Document(), eventValidator: eventValidator,
                                          eventProjector: eventProjector, projectionRevision: projectionRevision)
        _ = try? empty.ingest(legacyEvents)
        return empty
    }

    private init(roomID: String, document: Document, eventValidator: @escaping @Sendable (MeshRoomEvent) -> Bool,
                 eventProjector: (@Sendable (MeshRoomEvent) -> Bool)?,
                 projectionRevision: (@Sendable () -> UInt64?)?) {
        self.eventValidator = eventValidator
        self.eventProjector = eventProjector ?? { _ in true }
        self.authorScopedRetention = eventProjector != nil
        self.projectionRevision = projectionRevision
        self.roomID = roomID
        self.document = document
        self.actorID = document.actor
        self.cachedDocumentData = document.save()
    }

    public func snapshot() throws -> RoomStateSnapshot {
        try withLock {
            projectionCache.removeAll(keepingCapacity: true)
            defer { projectionCache.removeAll(keepingCapacity: true) }
            let revision = try currentProjectionRevision()
            let retained = cachedEventsByID.values.sorted(by: eventPrecedes)
            let result = RoomStateSnapshot(events: retained.filter(isProjected), retainedEvents: retained)
            try requireProjectionRevision(revision)
            return result
        }
    }

    @discardableResult
    public func ingest(_ events: [MeshRoomEvent]) throws -> [MeshRoomEvent] {
        try withLock {
            projectionCache.removeAll(keepingCapacity: true)
            defer { projectionCache.removeAll(keepingCapacity: true) }
            let revision = try currentProjectionRevision()
            let durable = events.filter(isDurable)
            guard !durable.isEmpty else { return [] }
            let candidate = document.fork()
            candidate.actor = actorID
            var nextEvents = cachedEventsByID
            // Resolve each retained projection once before scanning insertion
            // candidates. Exact-byte cache comparisons must not re-encode all
            // retained events for every new event in this transaction.
            var projected = nextEvents.values.filter(isProjected)
            var inserted = [MeshRoomEvent]()
            let ordered = durable.sorted { eventPrecedes($1, $0) }
            for event in ordered where nextEvents[event.id] == nil {
                guard let data = try? encoder.encode(event), isValid(event, encodedBytes: data.count) else {
                    continue
                }
                let projects = isProjected(event)
                guard !projects || !shouldSkip(event, given: projected) else { continue }
                try candidate.put(
                    obj: ObjId.ROOT,
                    key: Self.keyPrefix + event.id,
                    value: .Bytes(data)
                )
                nextEvents[event.id] = event
                if projects { projected.append(event) }
                inserted.append(event)
            }
            guard !inserted.isEmpty else { return [] }
            _ = try pruneRetainedState(in: candidate, eventsByID: &nextEvents)
            let validatedData = try validate(candidate, decoded: nextEvents, against: cachedEventsByID)
            try requireProjectionRevision(revision)
            cachedDocumentData = validatedData
            document = candidate
            cachedEventsByID = nextEvents
            return inserted.sorted(by: eventPrecedes)
        }
    }

    public func makeSession() -> RoomStateSyncSession { RoomStateSyncSession() }

    public func generateSyncMessage(for session: RoomStateSyncSession) -> Data? {
        withLock { document.generateSyncMessage(state: session.state) }
    }

    public func compactIfNeeded() throws -> Bool {
        try withLock {
            guard requiresLifecycleCompaction() else {
                return false
            }
            try rebuildDocumentFromRetainedState()
            return true
        }
    }

    public func requiresLifecycleCompaction() -> Bool {
        withLock {
            cachedDocumentData.count >= Self.proactiveFallbackDocumentBytes
                || document.getHistory().count > Self.maximumChangesPerSyncMessage / 2
        }
    }

    /// Test hook for proving compaction without manufacturing a multi-megabyte fixture.
    func compactForTesting() throws {
        try withLock { try rebuildDocumentFromRetainedState() }
    }

    /// Stable actors make randomized network scenarios replayable. Never reuse
    /// these identities for two live documents in a production room.
    convenience init(roomID: String, savedDocument: Data? = nil, testingActorID: ActorId) throws {
        try self.init(roomID: roomID, savedDocument: savedDocument)
        actorID = testingActorID
        document.actor = testingActorID
    }

    @discardableResult
    public func receiveSyncMessage(
        _ message: Data,
        from session: RoomStateSyncSession
    ) throws -> [MeshRoomEvent] {
        try withLock {
            projectionCache.removeAll(keepingCapacity: true)
            defer { projectionCache.removeAll(keepingCapacity: true) }
            let revision = try currentProjectionRevision()
            let previous = cachedEventsByID
            let candidate = document.fork()
            candidate.actor = actorID
            let previousHistory = Set(document.getHistory())
            let startedAt = DispatchTime.now().uptimeNanoseconds
            do {
                try candidate.receiveSyncMessage(state: session.state, message: message)
                let receivedChanges = candidate.getHistory().filter { !previousHistory.contains($0) }
                let receivedChangeBytes = receivedChanges.compactMap {
                    candidate.change(hash: $0)?.bytes.count
                }
                guard receivedChanges.count <= Self.maximumChangesPerSyncMessage,
                      receivedChangeBytes.count == receivedChanges.count,
                      receivedChangeBytes.reduce(0, +) <= Self.maximumDocumentBytes
                else { throw RoomStateSyncError.documentTooLarge }
                guard candidate.heads() != document.heads() else {
                    // A sync Bloom filter can omit a dependency, even on an
                    // ordered TCP link. Keep the candidate's pending changes
                    // so the next sync round can request that dependency.
                    // save() includes orphan changes: bound the whole pending
                    // state, not just visible history, before retaining it.
                    let saved = candidate.save()
                    guard saved.count <= Self.maximumDocumentBytes else {
                        throw RoomStateSyncError.documentTooLarge
                    }
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
                    guard elapsed <= 3_000_000_000 else {
                        throw RoomStateSyncError.processingTimedOut
                    }
                    try requireProjectionRevision(revision)
                    document = candidate
                    cachedDocumentData = saved
                    return []
                }
                var next = try validatedEvents(in: candidate)
                if try pruneRetainedState(in: candidate, eventsByID: &next) {
                    next = try validatedEvents(in: candidate)
                }
                let validatedData = try validate(candidate, decoded: next, against: previous)
                let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
                guard elapsed <= 3_000_000_000 else {
                    throw RoomStateSyncError.processingTimedOut
                }
                try requireProjectionRevision(revision)
                document = candidate
                cachedEventsByID = next
                cachedDocumentData = validatedData
                return next.values.filter { previous[$0.id] == nil }.sorted(by: eventPrecedes)
            } catch {
                session.reset()
                throw error
            }
        }
    }

    public func save() -> Data { withLock { cachedDocumentData } }

    private func validatedEvents(in document: Document) throws -> [String: MeshRoomEvent] {
        var eventsByID = [String: MeshRoomEvent]()
        for key in document.keys(obj: ObjId.ROOT) {
            guard key.hasPrefix(Self.keyPrefix) else { throw RoomStateSyncError.invalidDocument }
            let expectedID = String(key.dropFirst(Self.keyPrefix.count))
            guard !expectedID.isEmpty, expectedID.utf8.count <= 256 else {
                throw RoomStateSyncError.invalidDocument
            }

            let values = try document.getAll(obj: ObjId.ROOT, key: key)
            let candidates = values.compactMap { value -> Data? in
                guard case let .Scalar(.Bytes(data)) = value,
                      data.count <= Self.maximumEventBytes
                else { return nil }
                return data
            }
            let decodedCandidates = candidates.compactMap { data in
                (try? decoder.decode(MeshRoomEvent.self, from: data)).map { (data, $0) }
            }
            let identities = try decodedCandidates.map { try eventIdentity($0.1) }
            let winner = decodedCandidates.min { lhs, rhs in
                lhs.0.lexicographicallyPrecedes(rhs.0)
            }
            guard candidates.count == values.count,
                  decodedCandidates.count == candidates.count,
                  let winner,
                  let identity = identities.first,
                  identities.allSatisfy({ $0 == identity }),
                  let event = Optional(winner.1),
                  event.id.utf8.elementsEqual(expectedID.utf8),
                  decodedCandidates.allSatisfy({ isValid($0.1, encodedBytes: $0.0.count) })
            else { throw RoomStateSyncError.invalidDocument }
            eventsByID[event.id] = event
        }
        return eventsByID
    }

    private func validate(
        _ candidate: Document,
        decoded: [String: MeshRoomEvent]? = nil,
        against previous: [String: MeshRoomEvent]
    ) throws -> Data {
        let saved = candidate.save()
        guard saved.count <= Self.maximumDocumentBytes else {
            throw RoomStateSyncError.documentTooLarge
        }
        let next = try decoded ?? validatedEvents(in: candidate)
        if authorScopedRetention, saved.count >= Self.proactiveFallbackDocumentBytes,
           next.values.contains(where: { previous[$0.id] == nil && !isProjected($0) }) {
            throw RoomStateSyncError.untrustedHistoryLimit
        }
        let projected = next.values.filter(isProjected)
        let visibleChats = projected.filter { $0.kind == .chat }
        let visibleQueueEvents = projected.filter {
            $0.kind == .queueAdd || $0.kind == .queueRemove
        }.sorted(by: eventPrecedes)
        let retainedQueueByItemID = visibleQueueEvents.reduce(into: [QueueRetentionKey: MeshRoomEvent]()) {
            result, event in
            guard let itemID = event.queueItem?.id ?? event.queueItemID else { return }
            result[queueRetentionKey(event, itemID: itemID)] = event
        }
        for (id, old) in previous {
            if let current = next[id] {
                // String equality folds canonical Unicode equivalents, while
                // signatures and historical receipts cover their distinct bytes.
                guard try encoder.encode(current) == encoder.encode(old) else {
                    throw RoomStateSyncError.immutableEventChanged
                }
                continue
            }
            // Removing an inert record cannot remove local authorized state.
            // This also lets peers with already-accepted historical receipts
            // prune their older history without poisoning a fresh peer's sync.
            guard isProjected(old) else { continue }
            if old.kind == .queueReorder,
               projected.contains(where: { $0.kind == .queueReorder && sharesRetentionScope($0, old) && eventPrecedes(old, $0) }) { continue }
            if old.kind == .chat {
                let newerCount = visibleChats.lazy.filter { self.sharesRetentionScope($0, old) && self.eventPrecedes(old, $0) }.count
                guard newerCount >= Self.maximumChatEvents else {
                    throw RoomStateSyncError.immutableEventChanged
                }
                continue
            }
            if old.kind == .queueAdd || old.kind == .queueRemove,
               let itemID = old.queueItem?.id ?? old.queueItemID,
               let retained = retainedQueueByItemID[queueRetentionKey(old, itemID: itemID)] {
                if old.kind == .queueRemove {
                    guard retained.kind == .queueRemove, eventPrecedes(old, retained) else {
                        throw RoomStateSyncError.immutableEventChanged
                    }
                    continue
                }
                if retained.kind == .queueRemove || eventPrecedes(old, retained) {
                    continue
                }
            }
            if old.kind == .queueAdd || old.kind == .queueRemove {
                let newerCount = countEvents(after: old, in: visibleQueueEvents.filter { sharesRetentionScope($0, old) })
                guard newerCount >= Self.maximumQueueEvents else {
                    throw RoomStateSyncError.immutableEventChanged
                }
                continue
            }
            throw RoomStateSyncError.immutableEventChanged
        }
        return saved
    }

    @discardableResult
    private func pruneRetainedState(
        in document: Document,
        eventsByID: inout [String: MeshRoomEvent],
        splitAuthors: Bool = true
    ) throws -> Bool {
        if authorScopedRetention && splitAuthors {
            var inertCount = 0
            var inertBytes = 0
            for event in eventsByID.values where !isProjected(event) {
                inertCount += 1
                inertBytes += try encoder.encode(event).count
                guard inertCount <= Self.maximumInertEvents, inertBytes <= Self.maximumInertBytes else {
                    // Do not evict records that another legitimate peer may
                    // have previously accepted. Reject only this candidate;
                    // the committed document and its receipts remain intact.
                    throw RoomStateSyncError.untrustedHistoryLimit
                }
            }
        }
        if authorScopedRetention && splitAuthors {
            // Two peers can legitimately have different receipts for a removed
            // author's history. Retiring that author's records must never erase
            // another author's records (or require trusting the removed author).
            var changed = false
            for events in Dictionary(grouping: eventsByID.values, by: { $0.version.nodeID }).values {
                var group = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
                if try pruneRetainedState(in: document, eventsByID: &group, splitAuthors: false) {
                    changed = true
                    for event in events where group[event.id] == nil { eventsByID.removeValue(forKey: event.id) }
                }
            }
            return changed
        }
        var changed = false
        // Cryptographic provenance alone must NEVER enable a queue tombstone,
        // order, retention eviction, or Lamport advancement. Keep inert signed
        // records for CRDT convergence, bounded separately above, but
        // apply effects/retention only to the authorized local projection.
        let projected = eventsByID.values.filter(isProjected)
        let chats = projected.filter { $0.kind == .chat }.sorted(by: eventPrecedes)
        let excess = chats.count - Self.maximumChatEvents
        if excess > 0 {
            for event in chats.prefix(excess) {
                try document.delete(obj: ObjId.ROOT, key: Self.keyPrefix + event.id)
                eventsByID.removeValue(forKey: event.id)
                changed = true
            }
        }

        let orders = projected.filter { $0.kind == .queueReorder }.sorted(by: eventPrecedes)
        for event in orders.dropLast() {
            try document.delete(obj: ObjId.ROOT, key: Self.keyPrefix + event.id)
            eventsByID.removeValue(forKey: event.id)
            changed = true
        }
        var queueEventsByItem = [String: [MeshRoomEvent]]()
        for event in projected where event.kind == .queueAdd || event.kind == .queueRemove {
            guard let itemID = event.queueItem?.id ?? event.queueItemID else { continue }
            queueEventsByItem[itemID, default: []].append(event)
        }
        for itemEvents in queueEventsByItem.values where itemEvents.count > 1 {
            let removes = itemEvents.filter { $0.kind == .queueRemove }
            let retained = (removes.isEmpty ? itemEvents : removes).max(by: eventPrecedes)
            for event in itemEvents where event.id != retained?.id {
                try document.delete(obj: ObjId.ROOT, key: Self.keyPrefix + event.id)
                eventsByID.removeValue(forKey: event.id)
                changed = true
            }
        }
        let queueEvents = eventsByID.values.filter(isProjected).filter {
            $0.kind == .queueAdd || $0.kind == .queueRemove
        }.sorted(by: eventPrecedes)
        let queueExcess = queueEvents.count - Self.maximumQueueEvents
        if queueExcess > 0 {
            for event in queueEvents.prefix(queueExcess) {
                try document.delete(obj: ObjId.ROOT, key: Self.keyPrefix + event.id)
                eventsByID.removeValue(forKey: event.id)
                changed = true
            }
        }
        return changed
    }

    private func isDurable(_ event: MeshRoomEvent) -> Bool {
        event.kind == .chat || event.kind == .queueAdd || event.kind == .queueRemove || event.kind == .queueReorder
    }

    private func shouldSkip(
        _ event: MeshRoomEvent,
        given retained: [MeshRoomEvent]
    ) -> Bool {
        let projected = retained.filter { sharesRetentionScope($0, event) }
        if event.kind == .queueReorder,
           let current = projected.filter({ $0.kind == .queueReorder }).max(by: eventPrecedes) {
            return !eventPrecedes(current, event)
        }
        if event.kind == .chat {
            let chats = projected.filter { $0.kind == .chat }
            guard chats.count >= Self.maximumChatEvents,
                  let oldest = chats.min(by: eventPrecedes)
            else { return false }
            return !eventPrecedes(oldest, event)
        }
        guard event.kind == .queueAdd || event.kind == .queueRemove else { return false }
        let queueEvents = projected.filter {
            $0.kind == .queueAdd || $0.kind == .queueRemove
        }
        guard let itemID = event.queueItem?.id ?? event.queueItemID else { return false }
        guard let current = queueEvents.filter({
                  ($0.queueItem?.id ?? $0.queueItemID) == itemID
              }).max(by: eventPrecedes) else {
            guard queueEvents.count >= Self.maximumQueueEvents,
                  let oldest = queueEvents.min(by: eventPrecedes)
            else { return false }
            return !eventPrecedes(oldest, event)
        }
        if event.kind == .queueRemove, current.kind == .queueAdd { return false }
        if current.kind == .queueRemove, event.kind == .queueAdd { return true }
        return !eventPrecedes(current, event)
    }

    private func eventIdentity(_ event: MeshRoomEvent) throws -> Data {
        try encoder.encode(EventIdentity(id: event.id, roomID: event.roomID, version: event.version, kind: event.kind))
    }

    /// Cache only inside one locked transaction/snapshot and compare canonical
    /// encoded bytes, including proof and the exact Unicode representation. The
    /// next call rechecks current authority.
    private func isProjected(_ event: MeshRoomEvent) -> Bool {
        guard authorScopedRetention else { return true }
        guard let encodedEvent = try? encoder.encode(event) else { return false }
        if let cached = projectionCache[event.id], cached.encodedEvent == encodedEvent { return cached.allowed }
        let allowed = eventProjector(event)
        projectionCache[event.id] = (encodedEvent, allowed)
        return allowed
    }

    private func currentProjectionRevision() throws -> UInt64? {
        guard let projectionRevision else { return nil }
        guard let revision = projectionRevision() else { throw RoomStateSyncError.authorizationChanged }
        return revision
    }

    private func requireProjectionRevision(_ expected: UInt64?) throws {
        guard try currentProjectionRevision() == expected else { throw RoomStateSyncError.authorizationChanged }
    }

    private func sharesRetentionScope(_ left: MeshRoomEvent, _ right: MeshRoomEvent) -> Bool {
        !authorScopedRetention || left.version.nodeID == right.version.nodeID
    }

    private struct QueueRetentionKey: Hashable { let author: String?; let itemID: String }
    private func queueRetentionKey(_ event: MeshRoomEvent, itemID: String) -> QueueRetentionKey {
        QueueRetentionKey(author: authorScopedRetention ? event.version.nodeID : nil, itemID: itemID)
    }

    private struct EventIdentity: Encodable {
        let id: String
        let roomID: String
        let version: MeshVersion
        let kind: MeshRoomEventKind
    }

    private func rebuildDocumentFromRetainedState() throws {
        let replacement = Document()
        let replacementActor = replacement.actor
        for event in cachedEventsByID.values.sorted(by: eventPrecedes) {
            let data = try encoder.encode(event)
            guard isValid(event, encodedBytes: data.count) else {
                throw RoomStateSyncError.invalidDocument
            }
            try replacement.put(
                obj: ObjId.ROOT,
                key: Self.keyPrefix + event.id,
                value: .Bytes(data)
            )
        }
        let saved = replacement.save()
        guard saved.count <= Self.maximumDocumentBytes else {
            throw RoomStateSyncError.documentTooLarge
        }
        document = replacement
        actorID = replacementActor
        cachedDocumentData = saved
    }

    private func isValid(_ event: MeshRoomEvent, encodedBytes: Int) -> Bool {
        guard event.roomID == roomID,
              MeshRoomReplica.hasPlausibleCounters(event),
              eventValidator(event),
              event.id.utf8.count <= 256,
              encodedBytes <= Self.maximumEventBytes
        else { return false }
        switch event.kind {
        case .chat:
            return event.text != nil && (event.text?.utf8.count ?? 0) <= 8_192
        case .queueAdd:
            guard let item = event.queueItem else { return false }
            return item.id.utf8.count <= 256 && item.title.utf8.count <= 8_192 && item.url.utf8.count <= 16_384
        case .queueReorder:
            return MeshRoomReplica.hasValidQueueOrder(event)
        case .queueRemove:
            return event.queueItemID.map { !$0.isEmpty && $0.utf8.count <= 256 } == true
        case .broadcaster, .playback, .video:
            return false
        }
    }

    private func eventPrecedes(_ lhs: MeshRoomEvent, _ rhs: MeshRoomEvent) -> Bool {
        lhs.version == rhs.version ? lhs.id < rhs.id : lhs.version < rhs.version
    }

    private func countEvents(after event: MeshRoomEvent, in sorted: [MeshRoomEvent]) -> Int {
        var lower = 0
        var upper = sorted.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if eventPrecedes(event, sorted[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return sorted.count - lower
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
