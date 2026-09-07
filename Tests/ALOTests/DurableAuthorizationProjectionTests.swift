import Foundation
import Automerge
import Testing
@testable import ALOCore

@Suite("Durable provenance is not authorization", .serialized)
struct DurableAuthorizationProjectionTests {
    private let room = "projection-test"
    private func event(_ id: String, _ counter: UInt64, revoked: Bool = false,
                       kind: MeshRoomEventKind = .chat, item: String? = nil) -> MeshRoomEvent {
        MeshRoomEvent(id: id, roomID: room,
            version: MeshVersion(counter: counter, nodeID: revoked ? "revoked" : "allowed"),
            kind: kind, text: kind == .chat ? id : nil,
            queueItem: kind == .queueAdd ? RoomQueueItem(id: item ?? id, title: id, url: "https://example.com/track") : nil,
            queueItemID: kind == .queueRemove ? item : nil)
    }

    private func rawDocument(_ events: [MeshRoomEvent]) throws -> Data {
        let document = Document()
        for event in events {
            try document.put(obj: ObjId.ROOT, key: "event:" + event.id,
                             value: .Bytes(try JSONEncoder().encode(event)))
        }
        return document.save()
    }

    private func receiver(_ events: [MeshRoomEvent]) throws -> AutomergeRoomStateSync {
        try AutomergeRoomStateSync(roomID: room, savedDocument: rawDocument(events),
            eventValidator: { _ in true }, eventProjector: { $0.version.nodeID == "allowed" })
    }

    @Test func unseenRevokedTombstoneCannotRemoveAnAuthorizedQueueItem() throws {
        let add = event("good-add", 1, kind: .queueAdd, item: "song")
        let remove = event("bad-remove", 2, revoked: true, kind: .queueRemove, item: "song")
        let sync = try receiver([add, remove])
        #expect(try sync.snapshot().queue.map(\.id) == ["song"])
        #expect(try sync.snapshot().events.map(\.id) == [add.id])
        #expect(Set(try sync.snapshot().retainedEvents.map(\.id)) == [add.id, remove.id])
    }

    @Test func inertChatCannotEvictAuthorizedHistoryOrAdvanceItsCounter() throws {
        let good = event("good", 1)
        let inert = (2...503).map { event("inert-\($0)", UInt64($0), revoked: true) }
        let sync = try receiver([good] + inert)
        #expect(try sync.snapshot().chatEvents.map(\.id) == [good.id])
        var projected = MeshRoomReplica(events: try sync.snapshot().events)
        #expect(projected.nextVersion(nodeID: "allowed").counter == 2)
        #expect(try sync.snapshot().retainedEvents.count == 501)
        let restored = try AutomergeRoomStateSync(roomID: room, savedDocument: sync.save(),
            eventProjector: { $0.version.nodeID == "allowed" })
        #expect(try restored.snapshot().chatEvents.map(\.id) == [good.id])
    }

    @Test func validLaterOperationsRemainEffectiveBesideInertRecords() throws {
        let add = event("good-add", 1, kind: .queueAdd, item: "song")
        let remove = event("bad-remove", 50, revoked: true, kind: .queueRemove, item: "song")
        let sync = try receiver([add, remove])
        let fresh = event("fresh", 3)
        let goodRemove = event("good-remove", 4, kind: .queueRemove, item: "song")
        #expect(try sync.ingest([fresh, goodRemove]).count == 2)
        #expect(try sync.snapshot().queue.isEmpty)
        #expect(try sync.snapshot().chatEvents.map(\.id) == [fresh.id])
        #expect(try sync.snapshot().retainedEvents.contains(remove))
    }

    @Test func policyChangeDuringRetentionDiscardsTheWholeCandidate() throws {
        let access = ProjectionAccess()
        let sync = try AutomergeRoomStateSync(roomID: room,
            eventProjector: { access.project($0) }, projectionRevision: { access.revision })
        let add = event("good-add", 1, kind: .queueAdd, item: "song")
        try sync.ingest([add])
        access.revokeDuringNextRemoval = true
        let remove = event("good-remove", 2, kind: .queueRemove, item: "song")
        #expect(throws: RoomStateSyncError.authorizationChanged) { try sync.ingest([remove]) }
        #expect(try sync.snapshot().retainedEvents == [add])
        #expect(try sync.snapshot().queue.map(\.id) == ["song"])
    }

    @Test func repeatedRetentionScansVerifyEachProjectionOncePerTransaction() throws {
        let access = ProjectionAccess()
        let sync = try AutomergeRoomStateSync(roomID: room, eventProjector: { access.project($0) })
        let events = (1...100).map { event("chat-\($0)", UInt64($0)) }
        try sync.ingest(events)
        #expect(access.counts.count == 100)
        #expect(access.counts.values.allSatisfy { $0 == 1 })
        _ = try sync.snapshot()
        #expect(access.counts.values.allSatisfy { $0 == 2 }) // Never cached across API calls.
    }

    @Test func excessiveInertHistoryCannotPoisonCommittedState() throws {
        let good = event("good", 1)
        let sync = try receiver([good])
        let before = sync.save()
        // A relaying member can mint arbitrary self-certified authors. Valid
        // provenance alone must not let their inert records consume the room.
        let inert = (1...1_025).map { index in
            MeshRoomEvent(id: "inert-\(index)", roomID: room,
                version: .init(counter: UInt64(index + 10), nodeID: "inert-\(index)"), kind: .chat, text: "Inert")
        }
        #expect(throws: RoomStateSyncError.untrustedHistoryLimit) { _ = try sync.ingest(inert) }
        #expect(sync.save().elementsEqual(before))
        #expect(try sync.snapshot().retainedEvents == [good])
        #expect(!sync.requiresLifecycleCompaction())
        let next = event("next", 2)
        #expect(try sync.ingest([next]) == [next])
        #expect(try sync.snapshot().chatEvents == [good, next])
    }

    @Test func inertByteBudgetRejectsOneLargeCandidateWithoutLosingHistory() throws {
        let good = event("good", 1)
        let sync = try receiver([good])
        let before = sync.save()
        let inert = (1...140).map { index in
            MeshRoomEvent(id: "large-\(index)", roomID: room,
                version: MeshVersion(counter: UInt64(index + 10), nodeID: "revoked"),
                kind: .chat, text: String(repeating: "x", count: 8_192))
        }
        #expect(throws: RoomStateSyncError.untrustedHistoryLimit) { _ = try sync.ingest(inert) }
        #expect(sync.save().elementsEqual(before))
        #expect(try sync.snapshot().retainedEvents == [good])
    }

    @Test func recoveryDoesNotReplacePolicyRejectedHistoryWithAnEmptyDocument() throws {
        let good = event("good", 1)
        let inert = (1...1_025).map { event("inert-\($0)", UInt64($0 + 10), revoked: true) }
        let saved = try rawDocument([good] + inert)
        #expect(throws: RoomStateSyncError.untrustedHistoryLimit) {
            try AutomergeRoomStateSync.recovering(roomID: room, savedDocument: saved, legacyEvents: [],
                eventProjector: { $0.version.nodeID == "allowed" })
        }
        #expect(throws: RoomStateSyncError.authorizationChanged) {
            try AutomergeRoomStateSync.recovering(roomID: room, savedDocument: rawDocument([good]), legacyEvents: [],
                eventProjector: { _ in true }, projectionRevision: { nil })
        }
    }

    @Test func recoveryPreservesLargeValidArchiveWhenOneRecordIsInert() throws {
        var random: UInt64 = 713
        func randomText() -> String {
            Data((0..<6_144).map { _ in
                random ^= random << 13; random ^= random >> 7; random ^= random << 17
                return UInt8(truncatingIfNeeded: random)
            }).base64EncodedString()
        }
        var events = (1...500).map { index in
            MeshRoomEvent(id: "chat-\(index)", roomID: room, version: .init(counter: UInt64(index), nodeID: "allowed"),
                kind: .chat, text: randomText())
        }
        events += (1...160).map { index in
            MeshRoomEvent(id: "queue-\(index)", roomID: room, version: .init(counter: UInt64(index + 500), nodeID: "allowed"),
                kind: .queueAdd, queueItem: .init(id: "track-\(index)", title: randomText(), url: "https://example.com/track"))
        }
        events.append(event("inert", 700, revoked: true, kind: .queueAdd))
        let saved = try rawDocument(events)
        #expect(saved.count >= AutomergeRoomStateSync.proactiveFallbackDocumentBytes)
        #expect(saved.count < AutomergeRoomStateSync.maximumDocumentBytes)
        #expect(try AutomergeRoomStateSync(roomID: room, savedDocument: saved).snapshot().retainedEvents.count == events.count)
        #expect(throws: RoomStateSyncError.retentionCapacity) {
            try AutomergeRoomStateSync.recovering(roomID: room, savedDocument: saved, legacyEvents: [],
                eventProjector: { $0.version.nodeID == "allowed" })
        }
    }

    @Test func installationsOfOneRootShareTheSameChatRetentionLimit() throws {
        let events = (1...600).map { index in
            MeshRoomEvent(id: "multi-device-\(index)", roomID: room,
                version: .init(counter: UInt64(index), nodeID: "installation-\(index % 60)"), kind: .chat, text: "One root's history")
        }
        let sync = try AutomergeRoomStateSync(roomID: room, legacyEvents: events,
            eventProjector: { _ in true }, eventScope: { _ in "one-root" })
        let retained = try sync.snapshot().retainedEvents
        #expect(retained.count == AutomergeRoomStateSync.maximumChatEvents)
        #expect(retained.map(\.version.counter) == Array(UInt64(101)...600))
        #expect(throws: RoomStateSyncError.invalidDocument) {
            try AutomergeRoomStateSync(roomID: room, savedDocument: rawDocument([event("no-scope", 1)]),
                eventProjector: { _ in true }, eventScope: { _ in nil })
        }
    }

    @Test func partialHistoricalReceiptsAgreeOnSameRootChatEviction() throws {
        let initial = (1...300).map { event("history-\($0)", UInt64($0)) }
        let saved = try rawDocument(initial)
        let allReceipts = try AutomergeRoomStateSync(roomID: room, savedDocument: saved,
            eventProjector: { _ in true }, eventScope: { _ in "revoked-root" })
        let partialReceipts = try AutomergeRoomStateSync(roomID: room, savedDocument: saved,
            eventProjector: { $0.version.counter <= 300 }, eventScope: { _ in "revoked-root" })
        try allReceipts.ingest((301...600).map { event("history-\($0)", UInt64($0)) })
        let sourceSession = allReceipts.makeSession(), targetSession = partialReceipts.makeSession()
        var failure: RoomStateSyncError?
        for _ in 0..<10 where failure == nil {
            if let message = allReceipts.generateSyncMessage(for: sourceSession) {
                do { try partialReceipts.receiveSyncMessage(message, from: targetSession) }
                catch { failure = error as? RoomStateSyncError }
            }
            if failure == nil, let message = partialReceipts.generateSyncMessage(for: targetSession) {
                try allReceipts.receiveSyncMessage(message, from: sourceSession)
            }
        }
        #expect(failure == nil)
        let partial = try partialReceipts.snapshot()
        #expect(try partial.retainedEvents.map(\.id).elementsEqual(allReceipts.snapshot().retainedEvents.map(\.id)))
        #expect(partial.chatEvents.map(\.version.counter) == Array(UInt64(101)...300))
        #expect(partial.retainedEvents.count == 500)
    }

    @Test func globalRetentionCountRejectsOnlyTheOverflowCandidate() throws {
        let events = (0..<AutomergeRoomStateSync.maximumRetainedEvents).map { index in
            MeshRoomEvent(id: "r\(index)", roomID: room, version: .init(counter: 1, nodeID: "u\(index)"), kind: .chat, text: "x")
        }
        let sync = try AutomergeRoomStateSync(roomID: room, savedDocument: rawDocument(events),
            eventProjector: { _ in true }, eventScope: { $0.version.nodeID })
        let before = sync.save()
        #expect(throws: RoomStateSyncError.retentionCapacity) { try sync.ingest([event("overflow", 2)]) }
        #expect(sync.save().elementsEqual(before))
        #expect(try sync.snapshot().retainedEvents.count == events.count)
        #expect(!sync.requiresLifecycleCompaction())
    }

    @Test func globalRetentionBytesRejectOverflowButAllowAReplacementToFreeSpace() throws {
        func queueEvent(_ index: Int, replacing: String? = nil, large: Bool = true) -> MeshRoomEvent {
            MeshRoomEvent(id: "bytes-\(index)", roomID: room, version: .init(counter: UInt64(index + 1), nodeID: "allowed"),
                kind: .queueAdd, queueItem: .init(id: replacing ?? "track-\(index)",
                    title: large ? String(repeating: "x", count: 8_192) : "Replacement",
                    url: large ? String(repeating: "u", count: 16_384) : "https://example.com/track"))
        }
        var events = [MeshRoomEvent](), bytes = 0
        for index in 0..<100 {
            let event = queueEvent(index)
            let size = try JSONEncoder().encode(event).count
            guard bytes + size <= AutomergeRoomStateSync.maximumRetainedEventBytes else { break }
            events.append(event); bytes += size
        }
        let sync = try AutomergeRoomStateSync(roomID: room, savedDocument: rawDocument(events),
            eventProjector: { _ in true }, eventScope: { _ in "root" })
        let before = sync.save()
        #expect(throws: RoomStateSyncError.retentionCapacity) { try sync.ingest([queueEvent(100)]) }
        #expect(sync.save().elementsEqual(before))
        let replacement = queueEvent(101, replacing: "track-0", large: false)
        #expect(try sync.ingest([replacement]) == [replacement])
        #expect(try sync.ingest([queueEvent(102)]).count == 1)
        #expect(!sync.requiresLifecycleCompaction())
    }

    @Test func boundedHistoryReusesCanonicalBytesAcrossSnapshotsEditsAndSync() throws {
        // Near the global count cap, with non-canonical archive JSON and both
        // projected and inert records. Every scan must preserve exact bytes
        // without repeatedly serializing the entire retained history.
        let events = (0..<(AutomergeRoomStateSync.maximumRetainedEvents - 1)).map { index in
            MeshRoomEvent(id: "cached-\(index)", roomID: room,
                version: .init(counter: 1, nodeID: "scope-\(index)"), kind: .chat, text: "History")
        }
        let saved = try rawDocument(events)
        let source = try AutomergeRoomStateSync(roomID: room, savedDocument: saved,
            eventProjector: { $0.id != "cached-0" }, eventScope: { $0.version.nodeID })
        let target = try AutomergeRoomStateSync(roomID: room, savedDocument: saved,
            eventProjector: { $0.id != "cached-0" }, eventScope: { $0.version.nodeID })
        let sourceEncodings = source.canonicalEncodingCountForTesting
        let targetEncodings = target.canonicalEncodingCountForTesting
        _ = try source.snapshot()
        #expect(source.canonicalEncodingCountForTesting == sourceEncodings)
        let fresh = event("new-at-capacity", 2)
        #expect(try source.ingest([fresh]) == [fresh])
        #expect(source.canonicalEncodingCountForTesting - sourceEncodings == 1)
        let sourceSession = source.makeSession(), targetSession = target.makeSession()
        for _ in 0..<10 {
            if let message = source.generateSyncMessage(for: sourceSession) {
                try target.receiveSyncMessage(message, from: targetSession)
            }
            if let message = target.generateSyncMessage(for: targetSession) {
                try source.receiveSyncMessage(message, from: sourceSession)
            }
        }
        #expect(target.canonicalEncodingCountForTesting - targetEncodings == 1)
        #expect(source.canonicalEncodingCountForTesting - sourceEncodings == 1)
        #expect(try target.snapshot().retainedEvents.count == AutomergeRoomStateSync.maximumRetainedEvents)
        #expect(try target.snapshot().chatEvents.contains(fresh))
        try target.compactForTesting()
        #expect(target.canonicalEncodingCountForTesting - targetEncodings == 1)
    }

    @Test func noncanonicalStoredJSONStillConsumesTheRetainedByteBudget() throws {
        let document = Document()
        for index in 0..<18 {
            let value = event("padded-\(index)", UInt64(index + 1))
            var bytes = try JSONEncoder().encode(value)
            bytes.append(Data(repeating: 32, count: 120_000))
            #expect(bytes.count < AutomergeRoomStateSync.maximumEventBytes)
            try document.put(obj: .ROOT, key: "event:" + value.id, value: .Bytes(bytes))
        }
        #expect(document.save().count < AutomergeRoomStateSync.maximumDocumentBytes)
        #expect(throws: RoomStateSyncError.retentionCapacity) {
            try AutomergeRoomStateSync.recovering(roomID: room, savedDocument: document.save(), legacyEvents: [],
                eventProjector: { _ in true }, eventScope: { _ in "root" })
        }
    }
}

private final class ProjectionAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1
    private var checks = [String: Int]()
    // Used only by the test driver between synchronous transactions.
    var revokeDuringNextRemoval = false
    var revision: UInt64? { lock.lock(); defer { lock.unlock() }; return value }
    var counts: [String: Int] { lock.lock(); defer { lock.unlock() }; return checks }
    func project(_ event: MeshRoomEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        checks[event.id, default: 0] += 1
        if event.kind == .queueRemove {
            if revokeDuringNextRemoval { revokeDuringNextRemoval = false; value += 1; return true }
            return value == 1
        }
        return true
    }
}
