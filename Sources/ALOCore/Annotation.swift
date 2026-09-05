import Foundation

/// Coordinates are fractions of the captured image, with the origin at its top left.
public struct AnnotationPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

public enum AnnotationTool: String, Codable, Sendable { case pencil, arrow, rectangle, ellipse, sticker }
public enum AnnotationStickerID: String, Codable, Sendable, CaseIterable { case heart, star, thumbsUp, question, check }
public enum AnnotationTTL: Int, Codable, Sendable, CaseIterable { case thirty = 30, sixty = 60, threeHundred = 300 }
public enum AnnotationPermission: String, Codable, Sendable, CaseIterable { case everyone, approved, presenterOnly }

public struct AnnotationPolicy: Codable, Sendable, Equatable {
    public var permission: AnnotationPermission
    public var approvedIDs: Set<String>
    public var disabledIDs: Set<String>
    public var paused: Bool
    public var defaultStickerTTL: AnnotationTTL
    public init(permission: AnnotationPermission = .everyone, approvedIDs: Set<String> = [], paused: Bool = false,
                disabledIDs: Set<String> = [], defaultStickerTTL: AnnotationTTL = .sixty) {
        self.permission = permission; self.approvedIDs = approvedIDs; self.paused = paused
        self.disabledIDs = disabledIDs; self.defaultStickerTTL = defaultStickerTTL
    }
}

public struct AnnotationObject: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let authorID: String
    public var revision: UInt64
    public let tool: AnnotationTool
    public var points: [AnnotationPoint]
    /// A bounded palette token, interpreted by the renderer.
    public let color: String
    /// Width as a fraction of the captured image's shorter dimension.
    public let width: Double
    public let stickerID: AnnotationStickerID?
    public let expiresAtHostNanos: UInt64?
    public var isComplete: Bool

    public init(id: UUID = UUID(), authorID: String, revision: UInt64 = 0, tool: AnnotationTool,
                points: [AnnotationPoint], color: String = "red", width: Double = 0.005,
                stickerID: AnnotationStickerID? = nil, expiresAtHostNanos: UInt64? = nil, isComplete: Bool = true) {
        self.id = id; self.authorID = authorID; self.revision = revision; self.tool = tool
        self.points = points; self.color = color; self.width = width; self.stickerID = stickerID
        self.expiresAtHostNanos = expiresAtHostNanos; self.isComplete = isComplete
    }
}

public struct AnnotationLease: Codable, Sendable, Equatable {
    public let id: UUID
    public let objectID: UUID
    public let actorID: String
    /// The object revision at grant. All updates in this ordered drag may use it.
    public let baseRevision: UInt64
    public let expiresAtHostNanos: UInt64
}

public enum AnnotationAction: Codable, Sendable, Equatable {
    case beginDrawing(id: UUID, tool: AnnotationTool, points: [AnnotationPoint], color: String, width: Double)
    case appendDrawing(id: UUID, points: [AnnotationPoint])
    case endDrawing(id: UUID)
    case placeSticker(id: UUID, stickerID: AnnotationStickerID, position: AnnotationPoint, ttl: AnnotationTTL? = nil)
    case acquireSticker(id: UUID)
    case moveSticker(id: UUID, leaseID: UUID, position: AnnotationPoint)
    case releaseSticker(id: UUID, leaseID: UUID)
    case deleteObject(id: UUID)
    case clear
    case clearDrawings
    case clearStickers
    case disablePeer(String)
    case setDefaultStickerTTL(AnnotationTTL)
    case undo
    case setPolicy(AnnotationPolicy)
}

/// No actor identity is accepted from the wire. The host supplies the authenticated connection identity.
public struct AnnotationCommand: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    /// Strictly increasing per authenticated actor for this screen-sharing session.
    public let sequence: UInt64
    public let baseRevision: UInt64?
    public let videoCaptureTimeNanos: UInt64?
    public let action: AnnotationAction
    public init(id: UUID = UUID(), sessionID: UUID, sequence: UInt64, baseRevision: UInt64? = nil,
                videoCaptureTimeNanos: UInt64? = nil, action: AnnotationAction) {
        self.id = id; self.sessionID = sessionID; self.sequence = sequence; self.baseRevision = baseRevision
        self.videoCaptureTimeNanos = videoCaptureTimeNanos; self.action = action
    }
}

public enum AnnotationChange: Codable, Sendable, Equatable {
    case upsert(AnnotationObject)
    case remove(UUID)
    case lease(AnnotationLease)
    case releaseLease(UUID)
    case policy(AnnotationPolicy)
    case clear
}

public struct AnnotationEvent: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let revision: UInt64
    public let commandID: UUID?
    public let sequence: UInt64?
    public let actorID: String?
    public let videoCaptureTimeNanos: UInt64?
    public let change: AnnotationChange
}

public struct AnnotationSnapshot: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let revision: UInt64
    public let presenterID: String
    public let hostTimeNanos: UInt64
    public let policy: AnnotationPolicy
    public let objects: [AnnotationObject]
    public let leases: [AnnotationLease]
    public let commandSequences: [String: UInt64]
    public init(sessionID: UUID, revision: UInt64, presenterID: String, hostTimeNanos: UInt64,
                policy: AnnotationPolicy, objects: [AnnotationObject], leases: [AnnotationLease],
                commandSequences: [String: UInt64] = [:]) {
        self.sessionID = sessionID; self.revision = revision; self.presenterID = presenterID
        self.hostTimeNanos = hostTimeNanos; self.policy = policy; self.objects = objects; self.leases = leases
        self.commandSequences = commandSequences
    }
    public func remainingTTL(for object: AnnotationObject) -> Double? {
        object.expiresAtHostNanos.map { Double($0 > hostTimeNanos ? $0 - hostTimeNanos : 0) / 1_000_000_000 }
    }
}

public enum AnnotationRejection: String, Codable, Sendable {
    case wrongSession, replay, invalidPayload, permissionDenied, paused, capacity, missingObject
    case staleRevision, gestureInProgress, noGesture, rateLimited, leaseHeld, invalidLease, nothingToUndo
}

public struct AnnotationCommandResult: Sendable, Equatable {
    public let events: [AnnotationEvent]
    public let rejection: AnnotationRejection?
    public var accepted: Bool { rejection == nil }
}

/// A value-type reducer owned exclusively by the broadcaster's serial session queue.
/// All time arguments must come from the host monotonic clock, never from a peer.
public struct AnnotationAuthority: Sendable {
    public static let maximumObjects = 128
    public static let maximumPoints = 1_024
    public static let maximumPayloadBytes = 65_536
    public static let maximumBatchesPerSecond = 30
    public static let colors = ["red", "orange", "yellow", "green", "blue", "purple", "white", "black"]
    public let sessionID: UUID
    public let presenterID: String
    public private(set) var revision: UInt64 = 0
    public private(set) var policy: AnnotationPolicy
    public private(set) var objects: [UUID: AnnotationObject] = [:]
    public private(set) var leases: [UUID: AnnotationLease] = [:]
    public private(set) var commandSequences: [String: UInt64] = [:]
    private var gestures: [String: UUID] = [:]
    private var batches: [String: [UInt64]] = [:]
    private var undoActions: [UndoAction] = []
    private var lastNow: UInt64 = 0

    private struct UndoAction: Sendable {
        let actorID: String
        let objectID: UUID
        var expectedRevision: UInt64
        let previousPoints: [AnnotationPoint]?
        var previousRevision: UInt64? = nil
        var leaseID: UUID? = nil
    }

    public init(sessionID: UUID = UUID(), presenterID: String, isPublicRoom: Bool = false) {
        self.sessionID = sessionID; self.presenterID = presenterID
        self.policy = AnnotationPolicy(permission: isPublicRoom ? .presenterOnly : .everyone)
        self.commandSequences[presenterID] = 0
    }

    public func snapshot(nowNanos: UInt64) -> AnnotationSnapshot {
        AnnotationSnapshot(sessionID: sessionID, revision: revision, presenterID: presenterID,
                           hostTimeNanos: max(lastNow, nowNanos), policy: policy,
                           objects: objects.values.sorted { $0.revision < $1.revision },
                           leases: leases.values.sorted { $0.objectID.uuidString < $1.objectID.uuidString },
                           commandSequences: commandSequences)
    }

    public mutating func process(_ command: AnnotationCommand, actorID: String, nowNanos: UInt64) -> AnnotationCommandResult {
        var events = advance(nowNanos: nowNanos)
        let now = lastNow
        func rejected(_ reason: AnnotationRejection) -> AnnotationCommandResult { .init(events: events, rejection: reason) }
        guard command.sessionID == sessionID else { return rejected(.wrongSession) }
        guard !actorID.isEmpty, actorID.utf8.count <= 256,
              let encoded = try? JSONEncoder().encode(command), encoded.count <= Self.maximumPayloadBytes
        else { return rejected(.invalidPayload) }
        guard command.sequence > (commandSequences[actorID] ?? 0) else { return rejected(.replay) }
        guard command.sequence < UInt64.max else { return rejected(.invalidPayload) }
        guard commandSequences[actorID] != nil || commandSequences.count < 128 else { return rejected(.capacity) }
        commandSequences[actorID] = command.sequence
        let isPresenter = actorID == presenterID
        var nextPolicy: AnnotationPolicy?
        switch command.action {
        case .setPolicy(let next): nextPolicy = next
        case .disablePeer(let peerID):
            var next = policy; next.disabledIDs.insert(peerID); nextPolicy = next
        case .setDefaultStickerTTL(let ttl):
            var next = policy; next.defaultStickerTTL = ttl; nextPolicy = next
        default: break
        }
        if let next = nextPolicy {
            guard isPresenter else { return rejected(.permissionDenied) }
            guard next.approvedIDs.count <= 128, next.disabledIDs.count <= 128,
                  next.approvedIDs.union(next.disabledIDs).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
            else { return rejected(.invalidPayload) }
            policy = next
            events.append(emit(.policy(next), command: command, actorID: actorID))
            // Revocation/pause terminates manipulation without hiding annotations.
            for actor in gestures.keys.sorted() where !mayAnnotate(actor) {
                events += finishGesture(actorID: actor, command: command)
            }
            return .init(events: events, rejection: nil)
        }
        if case .clear = command.action {
            guard isPresenter else { return rejected(.permissionDenied) }
            objects.removeAll(); leases.removeAll(); gestures.removeAll(); undoActions.removeAll()
            events.append(emit(.clear, command: command, actorID: actorID))
            return .init(events: events, rejection: nil)
        }
        if command.action == .clearDrawings || command.action == .clearStickers {
            guard isPresenter else { return rejected(.permissionDenied) }
            let stickers = command.action == .clearStickers
            for id in objects.keys.sorted(by: { $0.uuidString < $1.uuidString }) where (objects[id]?.tool == .sticker) == stickers {
                events += remove(id, command: command, actorID: actorID)
            }
            return .init(events: events, rejection: nil)
        }
        if case .deleteObject = command.action, isPresenter {
            // Presenter moderation remains available while input is paused.
        } else {
            guard !policy.paused else { return rejected(.paused) }
            guard mayAnnotate(actorID) else { return rejected(.permissionDenied) }
        }
        // Begin/append/place/move all spend the same input budget. Gesture cleanup
        // is exempt so rate limiting can never leave a drag or stroke stuck open.
        switch command.action {
        case .endDrawing, .releaseSticker: break
        default:
            guard acceptBatch(actorID, now: now) else { return rejected(.rateLimited) }
        }
        switch command.action {
        case let .beginDrawing(id, tool, points, color, width):
            guard tool != .sticker, valid(points), !points.isEmpty,
                  (tool == .pencil || points.count <= 2), Self.colors.contains(color),
                  width.isFinite, (0.001...0.05).contains(width) else { return rejected(.invalidPayload) }
            guard gestures[actorID] == nil else { return rejected(.gestureInProgress) }
            guard objects.count < Self.maximumObjects else { return rejected(.capacity) }
            guard objects[id] == nil else { return rejected(.replay) }
            let object = AnnotationObject(id: id, authorID: actorID, revision: revision + 1, tool: tool,
                                          points: points, color: color, width: width, stickerID: nil,
                                          expiresAtHostNanos: nil, isComplete: false)
            objects[id] = object; gestures[actorID] = id
            remember(.init(actorID: actorID, objectID: id, expectedRevision: object.revision, previousPoints: nil))
            events.append(emit(.upsert(object), command: command, actorID: actorID))
        case let .appendDrawing(id, points):
            guard var object = objects[id] else { return rejected(.missingObject) }
            guard object.authorID == actorID, gestures[actorID] == id, !object.isComplete else { return rejected(.noGesture) }
            guard valid(points), !points.isEmpty else { return rejected(.invalidPayload) }
            let updated = object.tool == .pencil ? object.points + points : [object.points[0], points.last!]
            guard updated.count <= Self.maximumPoints else { return rejected(.capacity) }
            object.points = updated; object.revision = revision + 1; objects[id] = object
            updateCreationUndo(id: id, actorID: actorID, revision: object.revision)
            events.append(emit(.upsert(object), command: command, actorID: actorID))
        case .endDrawing(let id):
            guard let object = objects[id] else { return rejected(.missingObject) }
            guard gestures[actorID] == id, object.authorID == actorID else { return rejected(.noGesture) }
            events += finishGesture(actorID: actorID, command: command)
        case let .placeSticker(id, stickerID, position, ttl):
            guard position.isValid else { return rejected(.invalidPayload) }
            guard gestures[actorID] == nil else { return rejected(.gestureInProgress) }
            guard objects.count < Self.maximumObjects else { return rejected(.capacity) }
            guard objects[id] == nil else { return rejected(.replay) }
            let object = AnnotationObject(id: id, authorID: actorID, revision: revision + 1, tool: .sticker,
                                          points: [position], color: "white", width: 0.04, stickerID: stickerID,
                                          expiresAtHostNanos: deadline(now, UInt64((ttl ?? policy.defaultStickerTTL).rawValue) * 1_000_000_000), isComplete: true)
            objects[id] = object
            remember(.init(actorID: actorID, objectID: id, expectedRevision: object.revision, previousPoints: nil))
            events.append(emit(.upsert(object), command: command, actorID: actorID))
        case .acquireSticker(let id):
            guard let object = objects[id], object.tool == .sticker else { return rejected(.missingObject) }
            guard matches(command, object) else { return rejected(.staleRevision) }
            guard leases[id] == nil else { return rejected(.leaseHeld) }
            guard gestures[actorID] == nil else { return rejected(.gestureInProgress) }
            let lease = AnnotationLease(id: UUID(), objectID: id, actorID: actorID, baseRevision: object.revision,
                                        expiresAtHostNanos: deadline(now, 2_000_000_000))
            leases[id] = lease; gestures[actorID] = id
            events.append(emit(.lease(lease), command: command, actorID: actorID))
        case let .moveSticker(id, leaseID, position):
            guard var object = objects[id], object.tool == .sticker else { return rejected(.missingObject) }
            guard let lease = leases[id], lease.id == leaseID, lease.actorID == actorID else { return rejected(.invalidLease) }
            guard command.baseRevision == object.revision || command.baseRevision == lease.baseRevision else { return rejected(.staleRevision) }
            guard position.isValid else { return rejected(.invalidPayload) }
            let previous = object.points
            let previousRevision = object.revision
            object.points = [position]; object.revision = revision + 1; objects[id] = object
            // One undo item for the complete drag, preserving the first position.
            if let index = undoActions.lastIndex(where: { $0.actorID == actorID && $0.objectID == id }),
               undoActions[index].leaseID == leaseID, undoActions[index].expectedRevision == previousRevision {
                undoActions[index].expectedRevision = object.revision
            } else {
                remember(.init(actorID: actorID, objectID: id, expectedRevision: object.revision, previousPoints: previous,
                               previousRevision: previousRevision, leaseID: leaseID))
            }
            events.append(emit(.upsert(object), command: command, actorID: actorID))
        case let .releaseSticker(id, leaseID):
            guard let lease = leases[id], lease.id == leaseID, lease.actorID == actorID else { return rejected(.invalidLease) }
            events += finishGesture(actorID: actorID, command: command)
        case .deleteObject(let id):
            guard let object = objects[id] else { return rejected(.missingObject) }
            guard isPresenter || object.tool == .sticker || object.authorID == actorID else { return rejected(.permissionDenied) }
            guard matches(command, object) else { return rejected(.staleRevision) }
            events += remove(id, command: command, actorID: actorID)
            // Deletion is an irreversible own action. Consume an undo for it without
            // restoring the deleted object or silently undoing an earlier drawing.
            remember(.init(actorID: actorID, objectID: id, expectedRevision: revision, previousPoints: nil))
        case .undo:
            guard let index = undoActions.lastIndex(where: { $0.actorID == actorID }) else { return rejected(.nothingToUndo) }
            if let lease = leases[undoActions[index].objectID], lease.actorID != actorID {
                return rejected(.leaseHeld)
            }
            let action = undoActions.remove(at: index)
            guard var object = objects[action.objectID], object.revision == action.expectedRevision else { return rejected(.staleRevision) }
            if let previous = action.previousPoints {
                object.points = previous; object.revision = revision + 1; objects[object.id] = object
                if let earlier = undoActions.lastIndex(where: { $0.actorID == actorID && $0.objectID == object.id }),
                   undoActions[earlier].expectedRevision == action.previousRevision {
                    undoActions[earlier].expectedRevision = object.revision
                }
                events.append(emit(.upsert(object), command: command, actorID: actorID))
            } else {
                events += remove(object.id, command: command, actorID: actorID)
            }
        case .clear, .clearDrawings, .clearStickers, .setPolicy, .disablePeer, .setDefaultStickerTTL: break
        }
        return .init(events: events, rejection: nil)
    }

    /// Run on a timer and before producing a join snapshot to publish canonical expiry events.
    public mutating func advance(nowNanos: UInt64) -> [AnnotationEvent] {
        lastNow = max(lastNow, nowNanos)
        var events: [AnnotationEvent] = []
        for id in objects.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let expiry = objects[id]?.expiresAtHostNanos, expiry <= lastNow { events += remove(id, command: nil, actorID: nil) }
        }
        for lease in leases.values.sorted(by: { $0.objectID.uuidString < $1.objectID.uuidString }) where lease.expiresAtHostNanos <= lastNow {
            events += finishGesture(actorID: lease.actorID, command: nil)
        }
        // Discard idle actors so a succession of departed participants cannot grow memory.
        batches = batches.filter { $0.value.last.map { lastNow - min(lastNow, $0) < 1_000_000_000 } ?? false }
        return events
    }

    public mutating func disconnect(actorID: String, nowNanos: UInt64) -> [AnnotationEvent] {
        var events = advance(nowNanos: nowNanos)
        events += finishGesture(actorID: actorID, command: nil)
        batches.removeValue(forKey: actorID)
        return events
    }

    public func mayAnnotate(_ actorID: String) -> Bool {
        !policy.paused && (actorID == presenterID || (!policy.disabledIDs.contains(actorID) &&
            (policy.permission == .everyone || (policy.permission == .approved && policy.approvedIDs.contains(actorID)))))
    }

    private func valid(_ points: [AnnotationPoint]) -> Bool { points.count <= Self.maximumPoints && points.allSatisfy(\.isValid) }
    private func matches(_ command: AnnotationCommand, _ object: AnnotationObject) -> Bool {
        command.baseRevision == object.revision
    }
    private func deadline(_ now: UInt64, _ duration: UInt64) -> UInt64 { now > UInt64.max - duration ? UInt64.max : now + duration }
    private mutating func acceptBatch(_ actor: String, now: UInt64) -> Bool {
        guard batches[actor] != nil || batches.count < Self.maximumObjects else { return false }
        var recent = (batches[actor] ?? []).filter { now - min(now, $0) < 1_000_000_000 }
        guard recent.count < Self.maximumBatchesPerSecond else { return false }
        recent.append(now); batches[actor] = recent
        return true
    }
    private mutating func remember(_ action: UndoAction) {
        undoActions.append(action)
        if undoActions.count > 512 { undoActions.removeFirst(undoActions.count - 512) }
    }
    private mutating func updateCreationUndo(id: UUID, actorID: String, revision: UInt64) {
        if let index = undoActions.lastIndex(where: { $0.objectID == id && $0.actorID == actorID && $0.previousPoints == nil }) {
            undoActions[index].expectedRevision = revision
        }
    }
    private mutating func emit(_ change: AnnotationChange, command: AnnotationCommand?, actorID: String?) -> AnnotationEvent {
        revision += 1
        return AnnotationEvent(sessionID: sessionID, revision: revision, commandID: command?.id, sequence: command?.sequence,
                               actorID: actorID, videoCaptureTimeNanos: command?.videoCaptureTimeNanos, change: change)
    }
    private mutating func finishGesture(actorID: String, command: AnnotationCommand?) -> [AnnotationEvent] {
        guard let id = gestures.removeValue(forKey: actorID) else { return [] }
        if leases.removeValue(forKey: id) != nil { return [emit(.releaseLease(id), command: command, actorID: actorID)] }
        guard var object = objects[id], !object.isComplete else { return [] }
        object.isComplete = true; object.revision = revision + 1; objects[id] = object
        updateCreationUndo(id: id, actorID: actorID, revision: object.revision)
        return [emit(.upsert(object), command: command, actorID: actorID)]
    }
    private mutating func remove(_ id: UUID, command: AnnotationCommand?, actorID: String?) -> [AnnotationEvent] {
        objects.removeValue(forKey: id)
        leases.removeValue(forKey: id)
        gestures = gestures.filter { $0.value != id }
        undoActions.removeAll { $0.objectID == id }
        return [emit(.remove(id), command: command, actorID: actorID)]
    }
}

/// Clients request a fresh snapshot on a sequence gap; they never guess canonical state.
public struct AnnotationReplica: Sendable {
    public private(set) var sessionID: UUID?
    public private(set) var revision: UInt64 = 0
    public private(set) var presenterID: String = ""
    public private(set) var policy = AnnotationPolicy()
    public private(set) var objects: [UUID: AnnotationObject] = [:]
    public private(set) var leases: [UUID: AnnotationLease] = [:]
    public private(set) var commandSequences: [String: UInt64] = [:]
    public init() {}
    public mutating func apply(_ snapshot: AnnotationSnapshot) {
        guard sessionID != snapshot.sessionID || snapshot.revision >= revision else { return }
        sessionID = snapshot.sessionID; revision = snapshot.revision; presenterID = snapshot.presenterID
        policy = snapshot.policy
        commandSequences = snapshot.commandSequences
        objects = Dictionary(snapshot.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        leases = Dictionary(snapshot.leases.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
    }
    @discardableResult public mutating func apply(_ event: AnnotationEvent) -> Bool {
        guard revision < UInt64.max, sessionID == event.sessionID, event.revision == revision + 1 else { return false }
        switch event.change {
        case .upsert(let object): objects[object.id] = object
        case .remove(let id): objects.removeValue(forKey: id); leases.removeValue(forKey: id)
        case .lease(let lease): leases[lease.objectID] = lease
        case .releaseLease(let id): leases.removeValue(forKey: id)
        case .policy(let policy): self.policy = policy
        case .clear: objects.removeAll(); leases.removeAll()
        }
        revision = event.revision
        if let actorID = event.actorID, let sequence = event.sequence {
            commandSequences[actorID] = max(commandSequences[actorID] ?? 0, sequence)
        }
        return true
    }
    public func snapshot(hostTimeNanos: UInt64) -> AnnotationSnapshot? {
        guard let sessionID else { return nil }
        return AnnotationSnapshot(sessionID: sessionID, revision: revision, presenterID: presenterID,
                                  hostTimeNanos: hostTimeNanos, policy: policy,
                                  objects: objects.values.sorted { $0.revision < $1.revision },
                                  leases: leases.values.sorted { $0.objectID.uuidString < $1.objectID.uuidString },
                                  commandSequences: commandSequences)
    }
}
