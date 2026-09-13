import Foundation

/// Ephemeral availability from a direct authenticated room peer. The owner
/// identity comes from that connection, never from this payload or chat history.
public struct RoomCanvasAdvertisement: Codable, Equatable, Sendable {
    public let canvasID: UUID
    public let imageName: String
    public init(canvasID: UUID, imageName: String) { self.canvasID = canvasID; self.imageName = imageName }
    public var isValid: Bool {
        !imageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imageName != "." && imageName != ".."
            && imageName.utf8.count <= 240
            && !imageName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !imageName.contains("/") && !imageName.contains("\\")
    }
}

/// A prepared PNG, not a path on another person's Mac. Image bytes are fetched
/// separately and must match this size and digest before they are displayed.
public struct RoomCanvasImage: Codable, Equatable, Sendable {
    public static let maximumBytes = 8 * 1_024 * 1_024
    public let name: String
    public let byteCount: Int
    public let sha256: Data
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(name: String, byteCount: Int, sha256: Data, pixelWidth: Int, pixelHeight: Int) {
        self.name = name; self.byteCount = byteCount; self.sha256 = sha256
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    public var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 240 && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && (1...Self.maximumBytes).contains(byteCount) && sha256.count == 32
            && (1...16_000).contains(pixelWidth) && (1...16_000).contains(pixelHeight)
            && Int64(pixelWidth) * Int64(pixelHeight) <= 40_000_000
    }
}

public enum RoomCanvasError: Error, Equatable, Sendable {
    case invalidImage, notOwner, ended, capacity
}

/// Ordered incremental state; an image is never retransmitted for each stroke.
/// Missing revisions require a full snapshot, not speculative local repair.
public struct RoomCanvasUpdate: Codable, Equatable, Sendable {
    public let canvasID: UUID
    public let revision: UInt64
    public let annotationSessionID: UUID
    public let hostTimeNanos: UInt64
    public let events: [AnnotationEvent]
    public let participants: Set<UUID>?
    public let commandSequences: [String: UInt64]
}

public struct RoomCanvasSnapshot: Codable, Equatable, Sendable {
    public let roomID: UUID
    public let canvasID: UUID
    public let ownerID: UUID
    /// Independent of annotation revision: presence and image changes also
    /// advance this clock. A delayed snapshot cannot restore an old image.
    public let revision: UInt64
    public let image: RoomCanvasImage
    public let participants: Set<UUID>
    public let annotations: AnnotationSnapshot

    public var isValid: Bool {
        guard revision > 0, revision < UInt64.max, image.isValid,
              participants.contains(ownerID), participants.count <= 64,
              annotations.presenterID == ownerID.uuidString, annotations.revision < UInt64.max,
              annotations.objects.count <= AnnotationAuthority.maximumObjects,
              Set(annotations.objects.map(\.id)).count == annotations.objects.count,
              annotations.leases.isEmpty, annotations.commandSequences.count <= 128,
              annotations.commandSequences[ownerID.uuidString] != nil,
              annotations.commandSequences.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value < UInt64.max }),
              annotations.policy.approvedIDs.count <= 128, annotations.policy.disabledIDs.count <= 128,
              annotations.policy.approvedIDs.union(annotations.policy.disabledIDs).allSatisfy({ UUID(uuidString: $0) != nil })
        else { return false }
        return annotations.objects.allSatisfy {
            $0.tool == .pencil && $0.stickerID == nil && $0.expiresAtHostNanos == nil
                && UUID(uuidString: $0.authorID) != nil && $0.revision > 0 && $0.revision <= annotations.revision
                && !$0.points.isEmpty && $0.points.count <= AnnotationAuthority.maximumPoints
                && $0.points.allSatisfy(\.isValid) && AnnotationAuthority.colors.contains($0.color)
                && $0.width.isFinite && (0.001...0.05).contains($0.width)
        }
    }
}

/// Room-canvas lifetime is independent of screen capture and audio playback.
/// The transport supplies authenticated identities, never identities from a
/// command payload. Serialize access on the owning canvas session's executor.
public struct RoomCanvasAuthority: Sendable {
    public let roomID: UUID
    public let canvasID: UUID
    public let ownerID: UUID
    public private(set) var revision: UInt64 = 1
    /// Read immediately after each serialized operation. Image replacement and
    /// initial admission use a full snapshot instead; no stale update is kept.
    public private(set) var lastUpdate: RoomCanvasUpdate?
    private var image: RoomCanvasImage
    private var participants: Set<UUID>
    private var annotations: AnnotationAuthority?

    public init(roomID: UUID, canvasID: UUID = UUID(), ownerID: UUID,
                image: RoomCanvasImage, isPublicRoom: Bool) throws {
        guard image.isValid else { throw RoomCanvasError.invalidImage }
        self.roomID = roomID; self.canvasID = canvasID; self.ownerID = ownerID; self.image = image
        participants = [ownerID]
        annotations = AnnotationAuthority(presenterID: ownerID.uuidString, isPublicRoom: isPublicRoom)
    }

    public func snapshot(nowNanos: UInt64) -> RoomCanvasSnapshot? {
        guard let annotations else { return nil }
        return .init(roomID: roomID, canvasID: canvasID, ownerID: ownerID, revision: revision,
                     image: image, participants: participants, annotations: annotations.snapshot(nowNanos: nowNanos))
    }

    /// Admission must already have established room membership. Joining here is
    /// explicit canvas participation; being somewhere in the room isn't enough.
    @discardableResult
    public mutating func join(_ peerID: UUID, nowNanos: UInt64) throws -> RoomCanvasSnapshot {
        lastUpdate = nil
        guard annotations != nil else { throw RoomCanvasError.ended }
        if !participants.contains(peerID) {
            guard participants.count < 64, revision < UInt64.max - 1 else { throw RoomCanvasError.capacity }
            participants.insert(peerID); revision += 1
            publishUpdate(events: [], includeParticipants: true, nowNanos: nowNanos)
        }
        return snapshot(nowNanos: nowNanos)!
    }

    @discardableResult
    public mutating func disconnect(_ peerID: UUID, nowNanos: UInt64) -> [AnnotationEvent] {
        lastUpdate = nil
        guard participants.contains(peerID), var annotations else { return [] }
        if peerID == ownerID {
            self.annotations = nil; participants.removeAll()
            return []
        }
        guard revision < UInt64.max - 1 else { return [] }
        participants.remove(peerID)
        let events = annotations.disconnect(actorID: peerID.uuidString, nowNanos: nowNanos)
        self.annotations = annotations; revision += 1
        publishUpdate(events: events, includeParticipants: true, nowNanos: nowNanos)
        return events
    }

    public mutating func process(_ command: AnnotationCommand, from peerID: UUID,
                                 nowNanos: UInt64) -> AnnotationCommandResult {
        lastUpdate = nil
        guard var annotations else { return .init(events: [], rejection: .wrongSession) }
        guard participants.contains(peerID) else { return .init(events: [], rejection: .permissionDenied) }
        guard revision < UInt64.max - 1 else { return .init(events: [], rejection: .capacity) }
        // This prototype is drawing, undo and owner moderation—not every tool
        // available to the separate screen-annotation feature.
        switch command.action {
        case .beginDrawing(_, .pencil, _, _, _), .appendDrawing, .endDrawing, .undo, .clear, .deleteObject: break
        case .setPolicy(let policy):
            guard policy.approvedIDs.union(policy.disabledIDs).allSatisfy({ UUID(uuidString: $0) != nil }) else {
                return .init(events: [], rejection: .invalidPayload)
            }
        default: return .init(events: [], rejection: .invalidPayload)
        }
        let priorRevision = annotations.revision
        let priorSequence = annotations.commandSequences[peerID.uuidString]
        let result = annotations.process(command, actorID: peerID.uuidString, nowNanos: nowNanos)
        let changed = priorRevision != annotations.revision || priorSequence != annotations.commandSequences[peerID.uuidString]
        self.annotations = annotations
        if changed {
            revision += 1
            let sequence = annotations.commandSequences[peerID.uuidString].map { [peerID.uuidString: $0] } ?? [:]
            publishUpdate(events: result.events, sequences: sequence, nowNanos: nowNanos)
        }
        return result
    }

    /// Replacing the image keeps participant/permission choices but creates a
    /// new drawing epoch. No command or undo from the old image can apply to it.
    public mutating func replaceImage(_ image: RoomCanvasImage, by peerID: UUID, nowNanos: UInt64) throws {
        lastUpdate = nil
        guard let prior = annotations else { throw RoomCanvasError.ended }
        guard peerID == ownerID else { throw RoomCanvasError.notOwner }
        guard image.isValid else { throw RoomCanvasError.invalidImage }
        guard revision < UInt64.max - 1 else { throw RoomCanvasError.capacity }
        var next = AnnotationAuthority(presenterID: ownerID.uuidString)
        _ = next.process(.init(sessionID: next.sessionID, sequence: 1, action: .setPolicy(prior.policy)),
                         actorID: ownerID.uuidString, nowNanos: nowNanos)
        self.image = image; annotations = next; revision += 1
    }

    public mutating func end(by peerID: UUID) throws {
        guard peerID == ownerID else { throw RoomCanvasError.notOwner }
        annotations = nil; participants.removeAll(); lastUpdate = nil
    }

    private mutating func publishUpdate(events: [AnnotationEvent], includeParticipants: Bool = false,
                                       sequences: [String: UInt64] = [:], nowNanos: UInt64) {
        guard let annotations else { return }
        lastUpdate = .init(canvasID: canvasID, revision: revision, annotationSessionID: annotations.sessionID,
                           hostTimeNanos: nowNanos, events: events,
                           participants: includeParticipants ? participants : nil, commandSequences: sequences)
    }
}

/// The viewer is pinned to the canvas it explicitly joined and its authenticated
/// owner. Restoring a snapshot never silently switches rooms, owners or canvases.
public struct RoomCanvasReplica: Sendable {
    public let roomID: UUID
    public let canvasID: UUID
    public let ownerID: UUID
    public private(set) var snapshot: RoomCanvasSnapshot?
    public private(set) var ended = false
    public init(roomID: UUID, canvasID: UUID, ownerID: UUID) {
        self.roomID = roomID; self.canvasID = canvasID; self.ownerID = ownerID
    }

    @discardableResult
    public mutating func apply(_ next: RoomCanvasSnapshot, from authenticatedOwner: UUID) -> Bool {
        guard !ended, authenticatedOwner == ownerID, next.ownerID == ownerID,
              next.roomID == roomID, next.canvasID == canvasID, next.isValid else { return false }
        if let current = snapshot {
            if current.annotations.sessionID == next.annotations.sessionID {
                guard next.image == current.image, next.annotations.revision >= current.annotations.revision,
                      current.annotations.commandSequences.allSatisfy({
                          (next.annotations.commandSequences[$0.key] ?? 0) >= $0.value
                      }) else { return false }
            }
            if next.revision == current.revision {
                let a = current.annotations, b = next.annotations
                guard next.image == current.image, next.participants == current.participants,
                      a.sessionID == b.sessionID, a.revision == b.revision, a.policy == b.policy,
                      a.objects == b.objects, a.commandSequences == b.commandSequences,
                      b.hostTimeNanos >= a.hostTimeNanos else { return false }
                snapshot = next
                return true
            }
            guard next.revision > current.revision else { return false }
        }
        snapshot = next
        return true
    }

    public mutating func end(from authenticatedOwner: UUID) {
        guard authenticatedOwner == ownerID else { return }
        snapshot = nil; ended = true
    }

    @discardableResult
    public mutating func apply(_ update: RoomCanvasUpdate, from authenticatedOwner: UUID) -> Bool {
        guard !ended, authenticatedOwner == ownerID, let current = snapshot,
              update.canvasID == canvasID, current.revision < UInt64.max - 1,
              update.revision == current.revision + 1,
              update.annotationSessionID == current.annotations.sessionID,
              update.events.count <= AnnotationAuthority.maximumObjects + 1,
              update.commandSequences.count <= 128 else { return false }
        var replica = AnnotationReplica()
        replica.apply(current.annotations)
        for event in update.events {
            guard replica.apply(event) else { return false }
        }
        guard let applied = replica.snapshot(hostTimeNanos: max(current.annotations.hostTimeNanos, update.hostTimeNanos)) else { return false }
        var sequences = applied.commandSequences
        for (actor, sequence) in update.commandSequences {
            guard UUID(uuidString: actor) != nil, sequence < UInt64.max,
                  sequence >= (sequences[actor] ?? 0) else { return false }
            sequences[actor] = sequence
        }
        let annotations = AnnotationSnapshot(sessionID: applied.sessionID, revision: applied.revision,
            presenterID: applied.presenterID, hostTimeNanos: applied.hostTimeNanos, policy: applied.policy,
            objects: applied.objects, leases: applied.leases, commandSequences: sequences)
        let next = RoomCanvasSnapshot(roomID: roomID, canvasID: canvasID, ownerID: ownerID,
            revision: update.revision, image: current.image, participants: update.participants ?? current.participants,
            annotations: annotations)
        guard next.isValid else { return false }
        snapshot = next
        return true
    }
}
