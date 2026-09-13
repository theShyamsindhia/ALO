import Foundation
import Testing
@testable import ALOCore

struct RoomCanvasTests {
    private let owner = UUID()
    private let a = UUID()
    private let b = UUID()
    private let point = AnnotationPoint(x: 0.3, y: 0.4)
    private var image: RoomCanvasImage {
        .init(name: "Shared image.png", byteCount: 100, sha256: Data(repeating: 1, count: 32), pixelWidth: 800, pixelHeight: 600)
    }
    private func host(publicRoom: Bool = false) throws -> RoomCanvasAuthority {
        try .init(roomID: UUID(), ownerID: owner, image: image, isPublicRoom: publicRoom)
    }
    private func command(_ host: RoomCanvasAuthority, actor: UUID, action: AnnotationAction) throws -> AnnotationCommand {
        let snapshot = try #require(host.snapshot(nowNanos: 0)).annotations
        let objectID: UUID?
        switch action {
        case .appendDrawing(let id, _), .endDrawing(let id), .deleteObject(let id): objectID = id
        default: objectID = nil
        }
        return .init(sessionID: snapshot.sessionID, sequence: (snapshot.commandSequences[actor.uuidString] ?? 0) + 1,
                     baseRevision: snapshot.objects.first(where: { $0.id == objectID })?.revision, action: action)
    }
    private func stroke(_ id: UUID) -> AnnotationAction {
        .beginDrawing(id: id, tool: .pencil, points: [point], color: "blue", width: 0.006)
    }

    @Test func simultaneousDrawingAndUndoOnlyAffectTheAuthorsOwnStroke() throws {
        var host = try host()
        try host.join(a, nowNanos: 0); try host.join(b, nowNanos: 0)
        let first = UUID(), second = UUID()
        for (actor, action) in [(a, stroke(first)), (b, stroke(second)), (a, .endDrawing(id: first)), (b, .endDrawing(id: second))] {
            let command = try command(host, actor: actor, action: action)
            #expect(host.process(command, from: actor, nowNanos: 0).accepted)
        }
        let both = try #require(host.snapshot(nowNanos: 0))
        #expect(both.annotations.objects.count == 2)
        #expect(both.isValid)
        let undo = try command(host, actor: a, action: .undo)
        #expect(host.process(undo, from: a, nowNanos: 0).accepted)
        let remaining = try #require(host.snapshot(nowNanos: 0)).annotations.objects
        #expect(remaining.map(\.id) == [second])
        #expect(remaining.first?.authorID == b.uuidString)
    }

    @Test func onlyJoinedPeersCanDrawAndOnlyOwnerCanChangePermission() throws {
        var host = try host(publicRoom: true)
        let draw = try command(host, actor: a, action: stroke(UUID()))
        #expect(host.process(draw, from: a, nowNanos: 0).rejection == .permissionDenied)
        try host.join(a, nowNanos: 0)
        #expect(host.process(draw, from: a, nowNanos: 0).rejection == .permissionDenied)
        let policy = AnnotationPolicy(permission: .approved, approvedIDs: [a.uuidString])
        let refused = try command(host, actor: a, action: .setPolicy(policy))
        #expect(host.process(refused, from: a, nowNanos: 0).rejection == .permissionDenied)
        let granted = try command(host, actor: owner, action: .setPolicy(policy))
        #expect(host.process(granted, from: owner, nowNanos: 0).accepted)
        let fresh = try command(host, actor: a, action: stroke(UUID()))
        #expect(host.process(fresh, from: a, nowNanos: 0).accepted)
    }

    @Test func disconnectFinishesGestureAndReconnectRetainsReplayProtection() throws {
        var host = try host()
        try host.join(a, nowNanos: 0)
        let id = UUID()
        let draw = try command(host, actor: a, action: stroke(id))
        #expect(host.process(draw, from: a, nowNanos: 0).accepted)
        #expect(!host.disconnect(a, nowNanos: 1).isEmpty)
        let left = try #require(host.snapshot(nowNanos: 1))
        #expect(!left.participants.contains(a))
        #expect(left.annotations.objects.first?.isComplete == true)
        #expect(host.process(draw, from: a, nowNanos: 1).rejection == .permissionDenied)
        let rejoined = try host.join(a, nowNanos: 2)
        #expect(rejoined.annotations.commandSequences[a.uuidString] == draw.sequence)
        #expect(host.process(draw, from: a, nowNanos: 2).rejection == .replay)
    }

    @Test func replacingImagePreservesPermissionsButRejectsOldDrawingAndSnapshots() throws {
        var host = try host(publicRoom: true)
        try host.join(a, nowNanos: 0)
        let before = try #require(host.snapshot(nowNanos: 0))
        var replica = RoomCanvasReplica(roomID: before.roomID, canvasID: before.canvasID, ownerID: owner)
        #expect(replica.apply(before, from: owner) == true)
        let old = try command(host, actor: owner, action: stroke(UUID()))
        #expect(throws: RoomCanvasError.notOwner) { try host.replaceImage(image, by: a, nowNanos: 1) }
        try host.replaceImage(image, by: owner, nowNanos: 2)
        let after = try #require(host.snapshot(nowNanos: 2))
        #expect(after.canvasID == before.canvasID)
        #expect(after.annotations.sessionID != before.annotations.sessionID)
        #expect(after.annotations.policy == before.annotations.policy)
        #expect(after.participants == before.participants)
        #expect(after.annotations.objects.isEmpty)
        #expect(host.process(old, from: owner, nowNanos: 2).rejection == .wrongSession)
        #expect(replica.apply(after, from: owner) == true)
        #expect(replica.apply(before, from: owner) == false)
        #expect(replica.snapshot?.annotations.sessionID == after.annotations.sessionID)
    }

    @Test func replicaRequiresExpectedRoomCanvasAndAuthenticatedOwner() throws {
        let host = try host()
        let snapshot = try #require(host.snapshot(nowNanos: 1))
        var replica = RoomCanvasReplica(roomID: snapshot.roomID, canvasID: snapshot.canvasID, ownerID: owner)
        #expect(replica.apply(snapshot, from: a) == false)
        #expect(replica.apply(snapshot, from: owner) == true)
        #expect(replica.apply(try #require(host.snapshot(nowNanos: 2)), from: owner) == true, "A refreshed host clock is not a conflicting state")
        var other = RoomCanvasReplica(roomID: UUID(), canvasID: snapshot.canvasID, ownerID: owner)
        #expect(other.apply(snapshot, from: owner) == false)
        other = RoomCanvasReplica(roomID: snapshot.roomID, canvasID: UUID(), ownerID: owner)
        #expect(other.apply(snapshot, from: owner) == false)
        replica.end(from: a)
        #expect(!replica.ended)
        replica.end(from: owner)
        #expect(replica.ended)
        #expect(replica.apply(snapshot, from: owner) == false)
        #expect(replica.snapshot == nil)
    }

    @Test func ownerLeavingEndsSessionAndParticipantCapacityIsBounded() throws {
        var host = try host()
        for _ in 0..<63 { try host.join(UUID(), nowNanos: 0) }
        #expect(throws: RoomCanvasError.capacity) { try host.join(a, nowNanos: 0) }
        #expect(throws: RoomCanvasError.notOwner) { try host.end(by: a) }
        host.disconnect(owner, nowNanos: 1)
        #expect(host.snapshot(nowNanos: 1) == nil)
        #expect(throws: RoomCanvasError.ended) { try host.join(a, nowNanos: 2) }
        #expect(throws: RoomCanvasError.ended) { try host.replaceImage(image, by: owner, nowNanos: 2) }
    }

    @Test func imageLimitsRejectInvalidMetadataAndSurviveDecoding() throws {
        for candidate in [
            RoomCanvasImage(name: "../photo.png", byteCount: 100, sha256: image.sha256, pixelWidth: 800, pixelHeight: 600),
            RoomCanvasImage(name: "photo.png", byteCount: RoomCanvasImage.maximumBytes + 1, sha256: image.sha256, pixelWidth: 800, pixelHeight: 600),
            RoomCanvasImage(name: "photo.png", byteCount: 100, sha256: Data(), pixelWidth: 800, pixelHeight: 600),
            RoomCanvasImage(name: "photo.png", byteCount: 100, sha256: image.sha256, pixelWidth: Int.max, pixelHeight: Int.max),
            RoomCanvasImage(name: "photo.png", byteCount: 100, sha256: image.sha256, pixelWidth: 16_000, pixelHeight: 16_000)
        ] {
            let decoded = try JSONDecoder().decode(RoomCanvasImage.self, from: JSONEncoder().encode(candidate))
            #expect(!decoded.isValid)
            #expect(throws: RoomCanvasError.invalidImage) {
                try RoomCanvasAuthority(roomID: UUID(), ownerID: owner, image: decoded, isPublicRoom: false)
            }
        }
        let snapshot = try #require(try host().snapshot(nowNanos: 0))
        #expect(try JSONDecoder().decode(RoomCanvasSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    @Test func incrementalUpdatesDetectGapsAndRecoverFromFullSnapshot() throws {
        var host = try host()
        let initial = try #require(host.snapshot(nowNanos: 0))
        var replica = RoomCanvasReplica(roomID: initial.roomID, canvasID: initial.canvasID, ownerID: owner)
        #expect(replica.apply(initial, from: owner) == true)
        try host.join(a, nowNanos: 1)
        let joined = try #require(host.lastUpdate)
        let decoded = try JSONDecoder().decode(RoomCanvasUpdate.self, from: JSONEncoder().encode(joined))
        #expect(replica.apply(decoded, from: owner) == true)
        let beforeGap = replica.snapshot
        let id = UUID()
        let begin = try command(host, actor: a, action: stroke(id))
        #expect(host.process(begin, from: a, nowNanos: 2).accepted)
        let lost = try #require(host.lastUpdate)
        #expect(lost.participants == nil)
        #expect(lost.events.count == 1)
        let end = try command(host, actor: a, action: .endDrawing(id: id))
        #expect(host.process(end, from: a, nowNanos: 3).accepted)
        let afterGap = try #require(host.lastUpdate)
        #expect(replica.apply(afterGap, from: owner) == false)
        #expect(replica.snapshot == beforeGap, "A gap must not partially change local state")
        let recovered = try #require(host.snapshot(nowNanos: 3))
        #expect(replica.apply(recovered, from: owner) == true)
        #expect(replica.apply(afterGap, from: owner) == false)
        #expect(replica.apply(lost, from: owner) == false)
        try host.join(b, nowNanos: 4)
        #expect(replica.apply(try #require(host.lastUpdate), from: owner) == true)
        #expect(replica.snapshot == host.snapshot(nowNanos: 4))
    }

    @Test func invalidMultiEventUpdateCannotPartiallyApplyAndOldEpochIsRejected() throws {
        var host = try host()
        try host.join(a, nowNanos: 0)
        let begin = try command(host, actor: a, action: stroke(UUID()))
        #expect(host.process(begin, from: a, nowNanos: 0).accepted)
        let initial = try #require(host.snapshot(nowNanos: 0))
        var replica = RoomCanvasReplica(roomID: initial.roomID, canvasID: initial.canvasID, ownerID: owner)
        #expect(replica.apply(initial, from: owner) == true)
        let pause = try command(host, actor: owner, action: .setPolicy(.init(paused: true)))
        #expect(host.process(pause, from: owner, nowNanos: 1).accepted)
        let update = try #require(host.lastUpdate)
        #expect(update.events.count > 1)
        let corrupt = RoomCanvasUpdate(canvasID: update.canvasID, revision: update.revision,
            annotationSessionID: update.annotationSessionID, hostTimeNanos: update.hostTimeNanos,
            events: update.events + [try #require(update.events.last)], participants: update.participants,
            commandSequences: update.commandSequences)
        #expect(replica.apply(corrupt, from: owner) == false)
        #expect(replica.snapshot == initial)
        #expect(replica.apply(update, from: a) == false)
        #expect(replica.apply(update, from: owner) == true)
        #expect(replica.snapshot == host.snapshot(nowNanos: 1))
        try host.replaceImage(image, by: owner, nowNanos: 2)
        #expect(host.lastUpdate == nil, "Image replacement requires a full checkpoint")
        #expect(replica.apply(try #require(host.snapshot(nowNanos: 2)), from: owner) == true)
        #expect(replica.apply(update, from: owner) == false)
    }

    @Test func newerPresenceRevisionCannotRollbackDrawingHistory() throws {
        var host = try host()
        let initial = try #require(host.snapshot(nowNanos: 0))
        let draw = try command(host, actor: owner, action: stroke(UUID()))
        #expect(host.process(draw, from: owner, nowNanos: 1).accepted)
        let current = try #require(host.snapshot(nowNanos: 1))
        var replica = RoomCanvasReplica(roomID: current.roomID, canvasID: current.canvasID, ownerID: owner)
        #expect(replica.apply(current, from: owner) == true)
        let corrupt = RoomCanvasSnapshot(roomID: current.roomID, canvasID: current.canvasID, ownerID: owner,
            revision: current.revision + 1, image: current.image, participants: current.participants,
            annotations: initial.annotations)
        #expect(replica.apply(corrupt, from: owner) == false)
        #expect(replica.snapshot == current)
    }
}
