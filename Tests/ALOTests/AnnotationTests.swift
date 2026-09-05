import Foundation
import Testing
@testable import ALOCore

struct AnnotationTests {
    private let center = AnnotationPoint(x: 0.5, y: 0.5)

    private func command(_ authority: AnnotationAuthority, _ action: AnnotationAction,
                         base: UInt64? = nil) -> AnnotationCommand {
        let objectID: UUID?
        switch action {
        case .appendDrawing(let id, _), .endDrawing(let id), .acquireSticker(let id),
             .moveSticker(let id, _, _), .releaseSticker(let id, _), .deleteObject(let id): objectID = id
        default: objectID = nil
        }
        return AnnotationCommand(sessionID: authority.sessionID,
                                 sequence: (authority.commandSequences.values.max() ?? 0) + 1,
                                 baseRevision: base ?? objectID.flatMap { authority.objects[$0]?.revision }, action: action)
    }

    private func expectTrue(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, sourceLocation: sourceLocation)
    }

    @Test func defaultsAndSessionReset() {
        let privateHost = AnnotationAuthority(presenterID: "host")
        #expect(privateHost.policy.permission == .everyone)
        var publicHost = AnnotationAuthority(presenterID: "host", isPublicRoom: true)
        #expect(publicHost.policy.permission == .presenterOnly)
        let old = command(privateHost, .clear)
        expectTrue(publicHost.process(old, actorID: "host", nowNanos: 0).rejection == .wrongSession)
        #expect(publicHost.objects.isEmpty)
    }

    @Test func authenticatedActorAndMaliciousCoordinates() {
        var host = AnnotationAuthority(presenterID: "host")
        for point in [AnnotationPoint(x: -.infinity, y: 0), AnnotationPoint(x: .nan, y: 0),
                      AnnotationPoint(x: -0.01, y: 0), AnnotationPoint(x: 1.01, y: 0), AnnotationPoint(x: 0, y: 2)] {
            let result = host.process(command(host, .placeSticker(id: UUID(), stickerID: .heart, position: point)),
                                      actorID: "peer", nowNanos: 0)
            #expect(result.rejection == .invalidPayload)
        }
        let id = UUID()
        expectTrue(host.process(command(host, .placeSticker(id: id, stickerID: .star, position: center)),
                             actorID: "connection-peer", nowNanos: 0).accepted)
        #expect(host.objects[id]?.authorID == "connection-peer")
    }

    @Test func replayAfterClearIsRejectedAndExplicitNewCreationIsAllowed() {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        let create = command(host, .placeSticker(id: id, stickerID: .check, position: center))
        expectTrue(host.process(create, actorID: "peer", nowNanos: 0).accepted)
        expectTrue(host.process(create, actorID: "peer", nowNanos: 0).rejection == .replay)
        expectTrue(host.process(command(host, .clear), actorID: "host", nowNanos: 0).accepted)
        expectTrue(host.process(create, actorID: "peer", nowNanos: 0).rejection == .replay)
        expectTrue(host.process(command(host, create.action), actorID: "peer", nowNanos: 0).accepted)
    }

    @Test func policyAndPausePreserveObjects() {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        _ = host.process(command(host, .placeSticker(id: id, stickerID: .heart, position: center)), actorID: "a", nowNanos: 0)
        let next = AnnotationPolicy(permission: .approved, approvedIDs: ["a"])
        expectTrue(host.process(command(host, .setPolicy(next)), actorID: "b", nowNanos: 0).rejection == .permissionDenied)
        expectTrue(host.process(command(host, .setPolicy(next)), actorID: "host", nowNanos: 0).accepted)
        expectTrue(host.process(command(host, .deleteObject(id: id)), actorID: "b", nowNanos: 0).rejection == .permissionDenied)
        _ = host.process(command(host, .acquireSticker(id: id)), actorID: "a", nowNanos: 0)
        _ = host.process(command(host, .setPolicy(.init(paused: true))), actorID: "host", nowNanos: 0)
        #expect(host.objects[id] != nil)
        #expect(host.leases.isEmpty)
        expectTrue(host.process(command(host, .deleteObject(id: id)), actorID: "a", nowNanos: 0).rejection == .paused)
        expectTrue(host.process(command(host, .deleteObject(id: id)), actorID: "host", nowNanos: 0).accepted)
    }

    @Test func drawingOwnershipAndPersistentLifetime() {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        expectTrue(host.process(command(host, .beginDrawing(id: id, tool: .pencil, points: [center], color: "red", width: 0.005)),
                             actorID: "a", nowNanos: 0).accepted)
        expectTrue(host.process(command(host, .beginDrawing(id: UUID(), tool: .arrow, points: [center], color: "red", width: 0.005)),
                             actorID: "a", nowNanos: 0).rejection == .gestureInProgress)
        expectTrue(host.process(command(host, .appendDrawing(id: id, points: [center])), actorID: "b", nowNanos: 0).rejection == .noGesture)
        expectTrue(host.process(command(host, .endDrawing(id: id)), actorID: "a", nowNanos: 0).accepted)
        expectTrue(host.advance(nowNanos: 600_000_000_000).isEmpty)
        #expect(host.objects[id]?.isComplete == true)
        expectTrue(host.process(command(host, .deleteObject(id: id)), actorID: "b", nowNanos: 600_000_000_000).rejection == .permissionDenied)
        expectTrue(host.process(command(host, .deleteObject(id: id)), actorID: "a", nowNanos: 600_000_000_000).accepted)
    }

    @Test func leaseExclusivityStaleRevisionAndDisconnect() throws {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        _ = host.process(command(host, .placeSticker(id: id, stickerID: .star, position: center)), actorID: "a", nowNanos: 0)
        let original = try #require(host.objects[id])
        expectTrue(host.process(command(host, .acquireSticker(id: id)), actorID: "b", nowNanos: 0).accepted)
        let lease = try #require(host.leases[id])
        expectTrue(host.process(command(host, .acquireSticker(id: id)), actorID: "a", nowNanos: 0).rejection == .leaseHeld)
        let move = AnnotationAction.moveSticker(id: id, leaseID: lease.id, position: .init(x: 0.2, y: 0.3))
        expectTrue(host.process(command(host, move, base: original.revision), actorID: "a", nowNanos: 0).rejection == .invalidLease)
        expectTrue(host.process(command(host, move, base: original.revision), actorID: "b", nowNanos: 0).accepted)
        expectTrue(host.process(command(host, move, base: original.revision + 100), actorID: "b", nowNanos: 0).rejection == .staleRevision)
        #expect(host.objects[id]?.expiresAtHostNanos == original.expiresAtHostNanos)
        let events = host.disconnect(actorID: "b", nowNanos: 0)
        #expect(events.count == 1)
        #expect(host.leases.isEmpty)
        expectTrue(host.process(command(host, move, base: host.objects[id]?.revision), actorID: "b", nowNanos: 0).rejection == .invalidLease)
        expectTrue(host.process(command(host, .deleteObject(id: id)), actorID: "c", nowNanos: 0).accepted)
    }

    @Test func leaseExpiresExactlyAtTwoSeconds() throws {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        _ = host.process(command(host, .placeSticker(id: id, stickerID: .star, position: center)), actorID: "a", nowNanos: 0)
        _ = host.process(command(host, .acquireSticker(id: id)), actorID: "b", nowNanos: 0)
        let lease = try #require(host.leases[id])
        expectTrue(host.advance(nowNanos: 1_999_999_999).isEmpty)
        expectTrue(host.advance(nowNanos: 2_000_000_000).count == 1)
        expectTrue(host.process(command(host, .moveSticker(id: id, leaseID: lease.id, position: center), base: host.objects[id]?.revision),
                             actorID: "b", nowNanos: 2_000_000_000).rejection == .invalidLease)
    }

    @Test func ttlLateJoinAndCanonicalExpiry() throws {
        for ttl in AnnotationTTL.allCases {
            var host = AnnotationAuthority(presenterID: "host")
            let id = UUID()
            _ = host.process(command(host, .placeSticker(id: id, stickerID: .question, position: center, ttl: ttl)), actorID: "a", nowNanos: 5_000_000_000)
            let snapshot = host.snapshot(nowNanos: 15_000_000_000)
            #expect(snapshot.remainingTTL(for: try #require(snapshot.objects.first)) == Double(ttl.rawValue - 10))
            let expires = UInt64(ttl.rawValue + 5) * 1_000_000_000
            expectTrue(host.advance(nowNanos: expires - 1).isEmpty)
            expectTrue(host.advance(nowNanos: expires).count == 1)
            #expect(host.objects.isEmpty)
            expectTrue(host.advance(nowNanos: expires + 1).isEmpty)
        }
    }

    @Test func rateAndPointBounds() {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        _ = host.process(command(host, .beginDrawing(id: id, tool: .pencil, points: [center], color: "red", width: 0.005)), actorID: "a", nowNanos: 0)
        for _ in 0..<29 {
            expectTrue(host.process(command(host, .appendDrawing(id: id, points: [center])), actorID: "a", nowNanos: 0).accepted)
        }
        expectTrue(host.process(command(host, .appendDrawing(id: id, points: [center])), actorID: "a", nowNanos: 999_999_999).rejection == .rateLimited)
        expectTrue(host.process(command(host, .appendDrawing(id: id, points: [center])), actorID: "a", nowNanos: 1_000_000_000).accepted)
        expectTrue(host.process(command(host, .appendDrawing(id: id, points: Array(repeating: center, count: 1_024))), actorID: "a", nowNanos: 1_000_000_000).rejection == .capacity)
        expectTrue(host.process(command(host, .appendDrawing(id: id, points: Array(repeating: center, count: 1_025))), actorID: "a", nowNanos: 1_000_000_000).rejection == .invalidPayload)
    }

    @Test func maximumObjects() {
        var host = AnnotationAuthority(presenterID: "host")
        for index in 0..<128 {
            expectTrue(host.process(command(host, .placeSticker(id: UUID(), stickerID: .heart, position: center)), actorID: "a", nowNanos: UInt64(index) * 40_000_000).accepted)
        }
        expectTrue(host.process(command(host, .placeSticker(id: UUID(), stickerID: .heart, position: center)), actorID: "a", nowNanos: 5_120_000_000).rejection == .capacity)
    }

    @Test func undoOwnActionCannotOverwriteSomeoneElseOrResurrect() throws {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        _ = host.process(command(host, .placeSticker(id: id, stickerID: .heart, position: center)), actorID: "a", nowNanos: 0)
        _ = host.process(command(host, .acquireSticker(id: id)), actorID: "b", nowNanos: 0)
        let lease = try #require(host.leases[id])
        let moved = AnnotationPoint(x: 0.9, y: 0.8)
        _ = host.process(command(host, .moveSticker(id: id, leaseID: lease.id, position: moved), base: host.objects[id]?.revision), actorID: "b", nowNanos: 0)
        _ = host.process(command(host, .releaseSticker(id: id, leaseID: lease.id)), actorID: "b", nowNanos: 0)
        expectTrue(host.process(command(host, .undo), actorID: "a", nowNanos: 0).rejection == .staleRevision)
        #expect(host.objects[id]?.points == [moved])
        expectTrue(host.process(command(host, .undo), actorID: "b", nowNanos: 0).accepted)
        #expect(host.objects[id]?.points == [center])
        _ = host.process(command(host, .deleteObject(id: id)), actorID: "b", nowNanos: 0)
        expectTrue(host.process(command(host, .undo), actorID: "b", nowNanos: 0).rejection == .staleRevision)
        #expect(host.objects.isEmpty)
    }

    @Test func undoCompletedDrawingAndClear() {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        _ = host.process(command(host, .beginDrawing(id: id, tool: .rectangle, points: [center], color: "blue", width: 0.005)), actorID: "a", nowNanos: 0)
        _ = host.process(command(host, .appendDrawing(id: id, points: [.init(x: 0.8, y: 0.9)])), actorID: "a", nowNanos: 0)
        _ = host.process(command(host, .endDrawing(id: id)), actorID: "a", nowNanos: 0)
        expectTrue(host.process(command(host, .undo), actorID: "a", nowNanos: 0).accepted)
        #expect(host.objects.isEmpty)
        _ = host.process(command(host, .placeSticker(id: UUID(), stickerID: .heart, position: center)), actorID: "a", nowNanos: 0)
        _ = host.process(command(host, .clear), actorID: "host", nowNanos: 0)
        expectTrue(host.process(command(host, .undo), actorID: "a", nowNanos: 0).rejection == .nothingToUndo)
    }

    @Test func orderedReplicaAndWireRoundTrip() throws {
        var host = AnnotationAuthority(presenterID: "host")
        var replica = AnnotationReplica()
        let start = host.snapshot(nowNanos: 0)
        replica.apply(start)
        let create = command(host, .placeSticker(id: UUID(), stickerID: .thumbsUp, position: center))
        #expect(try JSONDecoder().decode(AnnotationCommand.self, from: JSONEncoder().encode(create)) == create)
        let event = try #require(host.process(create, actorID: "a", nowNanos: 0).events.first)
        expectTrue(replica.apply(event))
        expectTrue(!replica.apply(event))
        replica.apply(start)
        #expect(replica.revision == event.revision)
        #expect(replica.objects == host.objects)
        let event2 = try #require(host.process(command(host, .clear), actorID: "host", nowNanos: 0).events.first)
        var behind = AnnotationReplica()
        behind.apply(start)
        expectTrue(!behind.apply(event2))
        behind.apply(host.snapshot(nowNanos: 0))
        #expect(behind.objects.isEmpty)
        #expect(behind.revision == event2.revision)
    }

    @Test func selectiveModerationAndHostDefaultTTL() throws {
        var host = AnnotationAuthority(presenterID: "host")
        expectTrue(host.process(command(host, .setDefaultStickerTTL(.threeHundred)), actorID: "host", nowNanos: 0).accepted)
        let stickerID = UUID(), drawingID = UUID()
        _ = host.process(command(host, .placeSticker(id: stickerID, stickerID: .star, position: center)), actorID: "a", nowNanos: 0)
        #expect(host.objects[stickerID]?.expiresAtHostNanos == 300_000_000_000)
        _ = host.process(command(host, .beginDrawing(id: drawingID, tool: .ellipse, points: [center], color: "green", width: 0.005)), actorID: "a", nowNanos: 0)
        expectTrue(host.process(command(host, .clearDrawings), actorID: "a", nowNanos: 0).rejection == .permissionDenied)
        expectTrue(host.process(command(host, .clearDrawings), actorID: "host", nowNanos: 0).accepted)
        #expect(host.objects[drawingID] == nil)
        #expect(host.objects[stickerID] != nil)
        _ = host.process(command(host, .acquireSticker(id: stickerID)), actorID: "a", nowNanos: 0)
        #expect(host.leases[stickerID] != nil)
        expectTrue(host.process(command(host, .disablePeer("a")), actorID: "host", nowNanos: 0).accepted)
        #expect(host.leases.isEmpty)
        #expect(!host.mayAnnotate("a"))
        #expect(host.objects[stickerID] != nil)
        expectTrue(host.process(command(host, .deleteObject(id: stickerID)), actorID: "a", nowNanos: 0).rejection == .permissionDenied)
        expectTrue(host.process(command(host, .clearStickers), actorID: "host", nowNanos: 0).accepted)
        #expect(host.objects.isEmpty)
    }

    @Test func exactSequenceAdmissionReconnectAndOverflow() {
        var host = AnnotationAuthority(presenterID: "host")
        let first = AnnotationCommand(sessionID: host.sessionID, sequence: 1_000_000,
                                      action: .placeSticker(id: UUID(), stickerID: .star, position: center))
        expectTrue(host.process(first, actorID: "a", nowNanos: 0).accepted)
        _ = host.disconnect(actorID: "a", nowNanos: 0)
        expectTrue(host.process(first, actorID: "a", nowNanos: 0).rejection == .replay)
        #expect(host.snapshot(nowNanos: 0).commandSequences["a"] == 1_000_000)
        let overflow = AnnotationCommand(sessionID: host.sessionID, sequence: .max, action: .undo)
        expectTrue(host.process(overflow, actorID: "a", nowNanos: 0).rejection == .invalidPayload)
        #expect(host.commandSequences["a"] == 1_000_000)
        for index in 0..<126 {
            let denied = AnnotationCommand(sessionID: host.sessionID, sequence: 1, action: .clear)
            expectTrue(host.process(denied, actorID: "peer-\(index)", nowNanos: 0).rejection == .permissionDenied)
        }
        #expect(host.commandSequences.count == 128)
        expectTrue(host.process(.init(sessionID: host.sessionID, sequence: 1, action: .undo), actorID: "overflow", nowNanos: 0).rejection == .capacity)
        // Presenter has a reserved admission slot even if all guest slots filled.
        expectTrue(host.process(command(host, .clear), actorID: "host", nowNanos: 0).accepted)
    }

    @Test func drawingBatchesDoNotWaitForAcknowledgements() {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        let begin = AnnotationCommand(sessionID: host.sessionID, sequence: 1,
                                      action: .beginDrawing(id: id, tool: .pencil, points: [center], color: "red", width: 0.005))
        let append = AnnotationCommand(sessionID: host.sessionID, sequence: 2,
                                       action: .appendDrawing(id: id, points: [.init(x: 0.8, y: 0.9)]))
        let end = AnnotationCommand(sessionID: host.sessionID, sequence: 3, action: .endDrawing(id: id))
        expectTrue(host.process(begin, actorID: "a", nowNanos: 0).accepted)
        expectTrue(host.process(append, actorID: "a", nowNanos: 0).accepted)
        expectTrue(host.process(end, actorID: "a", nowNanos: 0).accepted)
        #expect(host.objects[id]?.points.count == 2)
        #expect(host.objects[id]?.isComplete == true)
        expectTrue(host.process(append, actorID: "a", nowNanos: 0).rejection == .replay)
    }

    @Test func leaseBaseRevisionSupportsOrderedMovesWithoutAcknowledgements() throws {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        _ = host.process(command(host, .placeSticker(id: id, stickerID: .star, position: center)), actorID: "a", nowNanos: 0)
        _ = host.process(command(host, .acquireSticker(id: id)), actorID: "b", nowNanos: 0)
        let lease = try #require(host.leases[id])
        for sequence in 3...10 {
            let move = AnnotationCommand(sessionID: host.sessionID, sequence: UInt64(sequence), baseRevision: lease.baseRevision,
                                         action: .moveSticker(id: id, leaseID: lease.id, position: .init(x: Double(sequence) / 10, y: 0.5)))
            expectTrue(host.process(move, actorID: "b", nowNanos: UInt64(sequence) * 40_000_000).accepted)
        }
        #expect(host.objects[id]?.points == [.init(x: 1, y: 0.5)])
        _ = host.process(command(host, .releaseSticker(id: id, leaseID: lease.id)), actorID: "b", nowNanos: 500_000_000)
        expectTrue(host.process(command(host, .undo), actorID: "b", nowNanos: 500_000_000).accepted)
        #expect(host.objects[id]?.points == [center])
    }

    @Test func staleDeleteCannotAffectNewGenerationWithReusedID() throws {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        _ = host.process(command(host, .placeSticker(id: id, stickerID: .star, position: center)), actorID: "a", nowNanos: 0)
        let stale = command(host, .deleteObject(id: id))
        _ = host.process(command(host, .clear), actorID: "host", nowNanos: 0)
        _ = host.process(command(host, .placeSticker(id: id, stickerID: .heart, position: center)), actorID: "a", nowNanos: 0)
        expectTrue(host.process(stale, actorID: "b", nowNanos: 0).rejection == .staleRevision)
        #expect(host.objects[id]?.stickerID == .heart)
    }

    @Test func payloadAndPolicyLimits() {
        var host = AnnotationAuthority(presenterID: "host")
        let oversized = command(host, .beginDrawing(id: UUID(), tool: .pencil, points: [center], color: String(repeating: "r", count: 70_000), width: 0.005))
        expectTrue(host.process(oversized, actorID: "a", nowNanos: 0).rejection == .invalidPayload)
        expectTrue(host.process(command(host, .setPolicy(.init(approvedIDs: Set((0..<129).map(String.init))))), actorID: "host", nowNanos: 0).rejection == .invalidPayload)
        expectTrue(host.process(command(host, .undo), actorID: String(repeating: "a", count: 257), nowNanos: 0).rejection == .invalidPayload)
    }

    @Test func temporaryLeaseDoesNotConsumeValidUndo() throws {
        var host = AnnotationAuthority(presenterID: "host")
        let id = UUID()
        _ = host.process(command(host, .placeSticker(id: id, stickerID: .heart, position: center)), actorID: "a", nowNanos: 0)
        _ = host.process(command(host, .acquireSticker(id: id)), actorID: "b", nowNanos: 0)
        expectTrue(host.process(command(host, .undo), actorID: "a", nowNanos: 0).rejection == .leaseHeld)
        _ = host.disconnect(actorID: "b", nowNanos: 0)
        expectTrue(host.process(command(host, .undo), actorID: "a", nowNanos: 0).accepted)
        #expect(host.objects.isEmpty)
    }

    @Test func longSessionSequenceStorageStaysBoundedWithoutFalseRejections() {
        var host = AnnotationAuthority(presenterID: "host")
        for sequence in 1...8_192 {
            let next = AnnotationCommand(sessionID: host.sessionID, sequence: UInt64(sequence), action: .clear)
            let result = host.process(next, actorID: "host", nowNanos: UInt64(sequence) * 40_000_000)
            #expect(result.accepted)
        }
        #expect(host.commandSequences == ["host": 8_192])
        #expect(host.objects.isEmpty)
        #expect(host.leases.isEmpty)
        let old = AnnotationCommand(sessionID: host.sessionID, sequence: 1, action: .clear)
        expectTrue(host.process(old, actorID: "host", nowNanos: 400_000_000_000).rejection == .replay)
        #expect(host.revision == 8_192)
    }
}
