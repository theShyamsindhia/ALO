import CoreGraphics
import Foundation
import SwiftUI
import ALOCore

@MainActor
final class AnnotationSceneModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select, pencil, arrow, rectangle, ellipse, sticker
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .pencil: "pencil.tip"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "oval"
            case .sticker: "face.smiling"
            }
        }
        var shortcut: Character {
            switch self {
            case .select: "v"
            case .pencil: "p"
            case .arrow: "a"
            case .rectangle: "r"
            case .ellipse: "o"
            case .sticker: "s"
            }
        }
        var drawingTool: AnnotationTool? { AnnotationTool(rawValue: rawValue) }
    }

    struct Draft {
        var id: UUID
        var tool: AnnotationTool
        var points: [AnnotationPoint]
        var color: String
        var width: Double
    }

    @Published private(set) var snapshot: AnnotationSnapshot?
    @Published var annotationEnabled = false
    @Published var tool: Tool = .select
    @Published var color = "red"
    @Published var lineWidth = 0.006
    @Published var sticker: AnnotationStickerID = .heart
    @Published var stickerTTL: AnnotationTTL = .sixty
    @Published var selectedObjectID: UUID?
    @Published private(set) var draft: Draft?
    @Published private(set) var optimisticStickers: [AnnotationObject] = []
    @Published private(set) var stickerPreview: AnnotationPoint?
    @Published private(set) var recentStickers: [AnnotationStickerID] = []
    @Published private(set) var notice: String?
    @Published var inputUnavailableReason: String?
    @Published var authorNames: [String: String] = [:]
    @Published private(set) var captureMetadata: CapturedFrameMetadata?
    private var captureFrameSize: CGSize?
    var videoCaptureTimeNanos: UInt64?
    var requestSnapshot: () -> Void = {}
    let localActorID: String
    private let send: (AnnotationCommand) -> Void
    private var batchTask: Task<Void, Never>?
    private var pendingPoints: [AnnotationPoint] = []
    private var endingDrawing = false
    private var drawingEndSent = false
    private var movingStickerID: UUID?
    private var endingStickerMove = false
    private var moveInFlightRevision: UInt64?
    private var snapshotReceivedNanos = MonotonicClock.nowNanos()
    private var replica = AnnotationReplica()
    private var commandSequence: UInt64 = 0
    private var commandObjects: [UUID: UUID] = [:]
    private var cleanupSentObjectIDs = Set<UUID>()

    init(localActorID: String, send: @escaping (AnnotationCommand) -> Void) {
        self.localActorID = localActorID
        self.send = send
    }

    var canAnnotate: Bool {
        guard let snapshot, !snapshot.policy.paused else { return false }
        if snapshot.presenterID == localActorID { return true }
        if snapshot.policy.disabledIDs.contains(localActorID) { return false }
        switch snapshot.policy.permission {
        case .everyone: return true
        case .approved: return snapshot.policy.approvedIDs.contains(localActorID)
        case .presenterOnly: return false
        }
    }
    var isPresenter: Bool { snapshot?.presenterID == localActorID }
    var inputAvailable: Bool { canAnnotate && inputUnavailableReason == nil }
    var acceptsInput: Bool { annotationEnabled && inputAvailable }
    var disabledReason: String {
        if let inputUnavailableReason { return inputUnavailableReason }
        guard let snapshot else { return "Annotations are connecting" }
        if snapshot.policy.paused { return "Annotations are paused by the presenter" }
        return "The presenter has not enabled annotations for you"
    }

    func apply(snapshot next: AnnotationSnapshot) {
        if let snapshot, snapshot.sessionID == next.sessionID, next.revision < snapshot.revision { return }
        if snapshot?.sessionID != next.sessionID {
            cancelLocalGesture()
            commandSequence = 0
            commandObjects.removeAll()
            optimisticStickers.removeAll()
            selectedObjectID = nil
            cleanupSentObjectIDs.removeAll()
        }
        let previous = snapshot
        snapshot = next
        replica.apply(next)
        commandSequence = max(commandSequence, next.commandSequences[localActorID] ?? 0)
        snapshotReceivedNanos = MonotonicClock.nowNanos()
        optimisticStickers.removeAll { optimistic in next.objects.contains { $0.id == optimistic.id } }
        cleanupSentObjectIDs = cleanupSentObjectIDs.filter { id in
            next.objects.contains(where: { $0.id == id && !$0.isComplete })
                || next.leases.contains(where: { $0.objectID == id && $0.actorID == localActorID })
        }
        if let draft, next.objects.contains(where: { $0.id == draft.id && $0.isComplete }) { self.draft = nil }
        if previous?.policy.defaultStickerTTL != next.policy.defaultStickerTTL { stickerTTL = next.policy.defaultStickerTTL }
        if let movingStickerID, let previousRevision = moveInFlightRevision,
           next.objects.first(where: { $0.id == movingStickerID })?.revision != previousRevision {
            moveInFlightRevision = nil
        }
        if let selectedObjectID, !next.objects.contains(where: { $0.id == selectedObjectID }) {
            if !optimisticStickers.contains(where: { $0.id == selectedObjectID }) { self.selectedObjectID = nil }
        }
        if let movingStickerID,
           !next.objects.contains(where: { $0.id == movingStickerID })
            || (previous?.leases.contains(where: { $0.objectID == movingStickerID && $0.actorID == localActorID }) == true
                && !next.leases.contains(where: { $0.objectID == movingStickerID && $0.actorID == localActorID })) {
            self.movingStickerID = nil
            stickerPreview = nil
            endingStickerMove = false
            moveInFlightRevision = nil
        }
        if !canAnnotate { cancelLocalGesture() }
    }

    func apply(event: AnnotationEvent) {
        guard let previous = snapshot else { requestSnapshot(); return }
        if event.sessionID == previous.sessionID, event.revision <= previous.revision { return }
        guard replica.apply(event) else { requestSnapshot(); return }
        if let commandID = event.commandID { commandObjects.removeValue(forKey: commandID) }
        let now = MonotonicClock.nowNanos()
        let elapsed = now >= snapshotReceivedNanos ? now - snapshotReceivedNanos : 0
        let (hostNow, overflow) = previous.hostTimeNanos.addingReportingOverflow(elapsed)
        apply(snapshot: AnnotationSnapshot(
            sessionID: previous.sessionID, revision: replica.revision, presenterID: replica.presenterID,
            hostTimeNanos: overflow ? UInt64.max : hostNow, policy: replica.policy,
            objects: replica.objects.values.sorted { $0.revision < $1.revision },
            leases: Array(replica.leases.values), commandSequences: replica.commandSequences
        ))
    }

    func reject(_ reason: AnnotationRejection) {
        var drawingsToEnd = Set(snapshot?.objects.filter { $0.authorID == localActorID && !$0.isComplete }.map(\.id) ?? [])
        if let draft { drawingsToEnd.insert(draft.id) }
        let leasesToRelease = snapshot?.leases.filter { $0.actorID == localActorID } ?? []
        notice = reason == .leaseHeld ? "Someone else is moving that sticker" : "Annotation was not applied: \(reason.rawValue)"
        optimisticStickers.removeAll()
        commandObjects.removeAll()
        cancelLocalGesture()
        // A rejected append must not strand the host's active gesture. Clear local
        // state before sending cleanup because a local presenter can reply inline.
        if ![.wrongSession, .replay, .permissionDenied, .paused].contains(reason) {
            for id in drawingsToEnd where !cleanupSentObjectIDs.contains(id) {
                if snapshot?.objects.contains(where: { $0.id == id }) == true { cleanupSentObjectIDs.insert(id) }
                emit(.endDrawing(id: id))
            }
            for lease in leasesToRelease where cleanupSentObjectIDs.insert(lease.objectID).inserted {
                emit(.releaseSticker(id: lease.objectID, leaseID: lease.id))
            }
        }
    }

    func reject(commandID: UUID, reason: AnnotationRejection) {
        if let objectID = commandObjects.removeValue(forKey: commandID) {
            optimisticStickers.removeAll { $0.id == objectID }
        }
        reject(reason)
        requestSnapshot()
    }

    func reset() {
        cancelLocalGesture()
        snapshot = nil
        selectedObjectID = nil
        annotationEnabled = false
        notice = nil
        inputUnavailableReason = nil
        optimisticStickers.removeAll()
        commandObjects.removeAll()
        commandSequence = 0
        cleanupSentObjectIDs.removeAll()
        replica = AnnotationReplica()
        captureMetadata = nil
        captureFrameSize = nil
        videoCaptureTimeNanos = nil
    }

    func toggleAnnotations() {
        if annotationEnabled { escape() }
        else if inputAvailable { annotationEnabled = true }
    }

    func updateCaptureMetadata(_ metadata: CapturedFrameMetadata, frameSize: CGSize) {
        captureMetadata = metadata
        captureFrameSize = frameSize
        videoCaptureTimeNanos = metadata.captureTimeNanos
        let validGeometry = AnnotationGeometry.isUsable(CGRect(origin: .zero, size: frameSize))
            && AnnotationGeometry.isUsable(metadata.contentRect)
            && CGRect(origin: .zero, size: frameSize).contains(metadata.contentRect)
            && metadata.contentScale.isFinite && metadata.contentScale > 0
            && metadata.scaleFactor.isFinite && metadata.scaleFactor > 0
        if isPresenter && !metadata.desktopOverlaySupported {
            inputUnavailableReason = "Desktop annotations are unavailable for this display selection. Share a single window, or update macOS."
        } else if !metadata.status.isVisible || !validGeometry || (isPresenter && !metadata.isInteractive) {
            inputUnavailableReason = "The shared content is unavailable. Restore the shared window to annotate."
        } else {
            inputUnavailableReason = nil
        }
        if inputUnavailableReason != nil { escape() }
    }

    func visibleContentRect(frameSize: CGSize, in bounds: CGRect) -> CGRect? {
        guard let metadata = captureMetadata, metadata.status.isVisible,
              let capturedSize = captureFrameSize,
              AnnotationGeometry.isUsable(CGRect(origin: .zero, size: capturedSize)),
              CGRect(origin: .zero, size: capturedSize).contains(metadata.contentRect) else { return nil }
        let rect = CGRect(x: metadata.contentRect.minX / capturedSize.width * frameSize.width,
                          y: metadata.contentRect.minY / capturedSize.height * frameSize.height,
                          width: metadata.contentRect.width / capturedSize.width * frameSize.width,
                          height: metadata.contentRect.height / capturedSize.height * frameSize.height)
        return AnnotationGeometry.visibleContentRect(frameSize: frameSize, contentRect: rect, in: bounds)
    }

    func authorName(_ object: AnnotationObject) -> String {
        object.authorID == localActorID ? "You" : authorNames[object.authorID] ?? "Participant"
    }

    func remainingTTL(_ object: AnnotationObject) -> Double? {
        guard let remaining = snapshot?.remainingTTL(for: object) else { return nil }
        let now = MonotonicClock.nowNanos()
        return max(0, remaining - Double(now >= snapshotReceivedNanos ? now - snapshotReceivedNanos : 0) / 1_000_000_000)
    }

    func begin(at point: CGPoint) {
        guard acceptsInput, draft == nil, movingStickerID == nil else { return }
        let point = AnnotationPoint(x: point.x, y: point.y)
        guard point.isValid else { return }
        notice = nil
        if tool == .select {
            selectedObjectID = snapshot?.objects.reversed().first(where: { object in
                guard object.tool != .sticker, let first = object.points.first else { return false }
                let xs = object.points.map(\.x), ys = object.points.map(\.y)
                let bounds = CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y,
                                    width: (xs.max() ?? first.x) - (xs.min() ?? first.x),
                                    height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
                return bounds.insetBy(dx: -0.015, dy: -0.015).contains(CGPoint(x: point.x, y: point.y))
            })?.id
            return
        }
        if tool == .sticker {
            guard optimisticStickers.count < AnnotationAuthority.maximumObjects,
                  (snapshot?.objects.count ?? 0) + optimisticStickers.count < AnnotationAuthority.maximumObjects else {
                notice = "The annotation limit has been reached. Remove an annotation before adding another."
                return
            }
            let id = UUID()
            selectedObjectID = id
            recentStickers.removeAll { $0 == sticker }
            recentStickers.insert(sticker, at: 0)
            recentStickers = Array(recentStickers.prefix(8))
            optimisticStickers.append(AnnotationObject(
                id: id, authorID: localActorID, tool: .sticker, points: [point], color: "white",
                width: 0.04, stickerID: sticker, expiresAtHostNanos: nil
            ))
            emit(.placeSticker(id: id, stickerID: sticker, position: point, ttl: stickerTTL), objectID: id)
            return
        }
        guard let drawingTool = tool.drawingTool else { return }
        let next = Draft(id: UUID(), tool: drawingTool, points: [point], color: color, width: lineWidth)
        draft = next
        drawingEndSent = false
        emit(.beginDrawing(id: next.id, tool: drawingTool, points: [point], color: color, width: lineWidth))
        ensureBatchTask()
    }

    func drag(to point: CGPoint) {
        guard acceptsInput, var draft else { return }
        let point = AnnotationPoint(x: point.x, y: point.y)
        guard point.isValid, draft.points.last != point else { return }
        if draft.tool == .pencil {
            guard draft.points.count < AnnotationAuthority.maximumPoints else { return }
            draft.points.append(point)
            pendingPoints.append(point)
        } else {
            draft.points = [draft.points[0], point]
            pendingPoints = [point]
        }
        self.draft = draft
    }

    func end() {
        guard draft != nil else { return }
        endingDrawing = true
        ensureBatchTask()
    }

    func selectSticker(_ id: UUID) { selectedObjectID = id }

    func moveSticker(_ id: UUID, to point: CGPoint, finished: Bool = false) {
        guard acceptsInput, draft == nil, let object = snapshot?.objects.first(where: { $0.id == id }),
              object.tool == .sticker else { return }
        let position = AnnotationPoint(x: point.x, y: point.y)
        guard position.isValid else { return }
        selectedObjectID = id
        if movingStickerID == nil {
            movingStickerID = id
            emit(.acquireSticker(id: id), revision: object.revision)
        }
        guard movingStickerID == id else { return }
        stickerPreview = position
        endingStickerMove = finished
        ensureBatchTask()
    }

    func nudgeSticker(_ id: UUID, dx: Double, dy: Double) {
        guard let point = snapshot?.objects.first(where: { $0.id == id })?.points.first else { return }
        moveSticker(id, to: CGPoint(x: min(1, max(0, point.x + dx)), y: min(1, max(0, point.y + dy))), finished: true)
    }

    func deleteSelection() {
        guard let id = selectedObjectID else { return }
        deleteObject(id)
    }

    func deleteObject(_ id: UUID) {
        guard let object = snapshot?.objects.first(where: { $0.id == id }),
              isPresenter || (canAnnotate && (object.tool == .sticker || object.authorID == localActorID)) else { return }
        emit(.deleteObject(id: id), revision: object.revision)
    }

    func undo() { guard canAnnotate else { return }; emit(.undo) }
    func clear() { guard isPresenter else { return }; emit(.clear) }
    func clearDrawings() { guard isPresenter else { return }; emit(.clearDrawings) }
    func clearStickers() { guard isPresenter else { return }; emit(.clearStickers) }
    func disablePeer(_ id: String) { guard isPresenter else { return }; emit(.disablePeer(id)) }
    func setDefaultStickerTTL(_ ttl: AnnotationTTL) { guard isPresenter else { return }; emit(.setDefaultStickerTTL(ttl)) }
    func setPolicy(_ policy: AnnotationPolicy) { guard isPresenter else { return }; emit(.setPolicy(policy)) }

    func escape() {
        if draft != nil { end() }
        if movingStickerID != nil { endingStickerMove = true }
        selectedObjectID = nil
        annotationEnabled = false
    }

    private func emit(_ action: AnnotationAction, revision: UInt64? = nil, objectID: UUID? = nil) {
        guard let snapshot else { return }
        guard commandSequence < UInt64.max else { return }
        commandSequence += 1
        let command = AnnotationCommand(sessionID: snapshot.sessionID, sequence: commandSequence, baseRevision: revision,
                                        videoCaptureTimeNanos: videoCaptureTimeNanos, action: action)
        if let objectID { commandObjects[command.id] = objectID }
        send(command)
    }

    private func ensureBatchTask() {
        guard batchTask == nil else { return }
        batchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(34))
                guard !Task.isCancelled, let self else { return }
                self.flushBatch()
                if self.draft == nil && self.movingStickerID == nil {
                    self.batchTask = nil
                    return
                }
            }
        }
    }

    private func flushBatch() {
        if let draft, !drawingEndSent {
            if !pendingPoints.isEmpty {
                let points = pendingPoints
                pendingPoints.removeAll()
                emit(.appendDrawing(id: draft.id, points: points))
            }
            if endingDrawing {
                endingDrawing = false
                drawingEndSent = true
                emit(.endDrawing(id: draft.id))
            }
        }
        guard let id = movingStickerID, let snapshot,
              let object = snapshot.objects.first(where: { $0.id == id }) else { return }
        guard let lease = snapshot.leases.first(where: { $0.objectID == id && $0.actorID == localActorID }) else { return }
        guard moveInFlightRevision == nil else { return }
        if let stickerPreview, object.points.first != stickerPreview {
            moveInFlightRevision = object.revision
            emit(.moveSticker(id: id, leaseID: lease.id, position: stickerPreview), revision: object.revision)
        } else if endingStickerMove {
            emit(.releaseSticker(id: id, leaseID: lease.id))
            movingStickerID = nil
            stickerPreview = nil
            endingStickerMove = false
        }
    }

    private func cancelLocalGesture() {
        batchTask?.cancel()
        batchTask = nil
        draft = nil
        pendingPoints.removeAll()
        endingDrawing = false
        drawingEndSent = false
        movingStickerID = nil
        stickerPreview = nil
        endingStickerMove = false
        moveInFlightRevision = nil
    }
}

private extension AnnotationStickerID {
    var emoji: String {
        switch self { case .heart: "❤️"; case .star: "⭐️"; case .thumbsUp: "👍"; case .question: "❓"; case .check: "✅" }
    }
    var title: String {
        switch self { case .heart: "Heart"; case .star: "Star"; case .thumbsUp: "Thumbs up"; case .question: "Question"; case .check: "Check" }
    }
}

@MainActor
struct AnnotationSceneView: View {
    @ObservedObject var model: AnnotationSceneModel
    let contentRect: CGRect
    @State private var isDrawing = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            Canvas { context, _ in
                for object in model.snapshot?.objects ?? [] where object.tool != .sticker && object.id != model.draft?.id {
                    draw(tool: object.tool, points: object.points, color: object.color, width: object.width, context: &context)
                    if object.id == model.selectedObjectID {
                        let points = object.points.compactMap { AnnotationGeometry.point(CGPoint(x: $0.x, y: $0.y), in: contentRect) }
                        if let first = points.first {
                            let xs = points.map(\.x), ys = points.map(\.y)
                            let bounds = CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y,
                                                width: (xs.max() ?? first.x) - (xs.min() ?? first.x),
                                                height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
                            context.stroke(Path(bounds.insetBy(dx: -5, dy: -5)), with: .color(.accentColor),
                                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                }
                if let draft = model.draft {
                    draw(tool: draft.tool, points: draft.points, color: draft.color, width: draft.width, context: &context)
                }
            }
            .allowsHitTesting(false)
            if model.acceptsInput {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: contentRect.width, height: contentRect.height)
                    .position(x: contentRect.midX, y: contentRect.midY)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let rect = CGRect(origin: .zero, size: contentRect.size)
                        guard let point = AnnotationGeometry.normalizedPoint(value.location, in: rect) else { return }
                        if !isDrawing { isDrawing = true; model.begin(at: point) }
                        else { model.drag(to: point) }
                    }.onEnded { _ in isDrawing = false; model.end() })
                    .accessibilityLabel(model.tool == .select ? "Annotation selection area" : "Annotation drawing area")
                    .accessibilityHint("Choose a drawing tool, then drag to annotate the shared screen")
            }
            ForEach((model.snapshot?.objects ?? []).filter { $0.tool == .sticker } + model.optimisticStickers) { object in
                stickerView(object)
            }
        }
        .coordinateSpace(name: "annotationScene")
        .clipped()
        .onChange(of: model.acceptsInput) { _, enabled in if !enabled { isDrawing = false } }
    }

    private func stickerView(_ object: AnnotationObject) -> some View {
        let position = object.id == model.selectedObjectID ? model.stickerPreview ?? object.points.first : object.points.first
        let normalized = position ?? AnnotationPoint(x: 0, y: 0)
        let location = AnnotationGeometry.point(CGPoint(x: normalized.x, y: normalized.y), in: contentRect) ?? .zero
        let sticker = object.stickerID ?? .heart
        return TimelineView(.periodic(from: .now, by: 1)) { _ in
            let ttl = Int(ceil(model.remainingTTL(object) ?? Double(model.stickerTTL.rawValue)))
            Button { model.selectSticker(object.id) } label: {
                Text(sticker.emoji).font(.system(size: 30))
                    .frame(width: 40, height: 40)
                    .background(model.selectedObjectID == object.id ? Color.accentColor.opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                        model.selectedObjectID == object.id ? Color.accentColor : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .disabled(!model.acceptsInput)
            .help("\(sticker.title) · \(model.authorName(object)) · \(ttl)s remaining")
            .accessibilityLabel("\(sticker.title) sticker by \(model.authorName(object))")
            .accessibilityValue("\(ttl) seconds remaining")
            .accessibilityAction(named: "Move left") { model.nudgeSticker(object.id, dx: -0.02, dy: 0) }
            .accessibilityAction(named: "Move right") { model.nudgeSticker(object.id, dx: 0.02, dy: 0) }
            .accessibilityAction(named: "Move up") { model.nudgeSticker(object.id, dx: 0, dy: -0.02) }
            .accessibilityAction(named: "Move down") { model.nudgeSticker(object.id, dx: 0, dy: 0.02) }
            .accessibilityAction(named: "Remove sticker") { model.deleteObject(object.id) }
            .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("annotationScene"))
                .onChanged { value in
                    guard let point = AnnotationGeometry.normalizedPoint(value.location, in: contentRect) else { return }
                    model.moveSticker(object.id, to: point)
                }.onEnded { value in
                    let clamped = CGPoint(x: min(contentRect.maxX, max(contentRect.minX, value.location.x)),
                                          y: min(contentRect.maxY, max(contentRect.minY, value.location.y)))
                    guard let point = AnnotationGeometry.normalizedPoint(clamped, in: contentRect) else { return }
                    model.moveSticker(object.id, to: point, finished: true)
                })
            .contextMenu {
                Text("\(model.authorName(object)) · \(ttl)s remaining")
                Button("Move left") { model.nudgeSticker(object.id, dx: -0.02, dy: 0) }
                Button("Move right") { model.nudgeSticker(object.id, dx: 0.02, dy: 0) }
                Button("Move up") { model.nudgeSticker(object.id, dx: 0, dy: -0.02) }
                Button("Move down") { model.nudgeSticker(object.id, dx: 0, dy: 0.02) }
                Button("Remove sticker", role: .destructive) { model.deleteObject(object.id) }
            }
            .opacity(ttl > 0 ? 1 : 0)
            .allowsHitTesting(ttl > 0 && model.acceptsInput)
        }
        .position(location)
    }

    private func draw(tool: AnnotationTool, points: [AnnotationPoint], color: String,
                      width: Double, context: inout GraphicsContext) {
        let points = points.compactMap { AnnotationGeometry.point(CGPoint(x: $0.x, y: $0.y), in: contentRect) }
        guard let first = points.first else { return }
        let last = points.last ?? first
        let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                          width: abs(last.x - first.x), height: abs(last.y - first.y))
        var path = Path()
        switch tool {
        case .pencil:
            path.move(to: first)
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            else { for point in points.dropFirst() { path.addLine(to: point) } }
        case .arrow:
            path.move(to: first); path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(10, min(contentRect.width, contentRect.height) * width * 4)
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x - head * cos(angle + offset), y: last.y - head * sin(angle + offset)))
            }
        case .rectangle: path.addRect(rect)
        case .ellipse: path.addEllipse(in: rect)
        case .sticker: return
        }
        context.stroke(path, with: .color(annotationColor(color)),
                       style: StrokeStyle(lineWidth: max(1, min(contentRect.width, contentRect.height) * width), lineCap: .round, lineJoin: .round))
    }
}

private func annotationColor(_ token: String) -> Color {
    switch token {
    case "orange": .orange
    case "yellow": .yellow
    case "green": .green
    case "blue": .blue
    case "purple": .purple
    case "white": .white
    case "black": .black
    default: .red
    }
}

@MainActor
struct AnnotationToolbarView: View {
    @ObservedObject var model: AnnotationSceneModel
    @State private var showsStickers = false
    @State private var search = ""
    private var buttonSide: CGFloat {
        #if os(iOS)
        44
        #else
        34
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Toggle("Annotate", isOn: $model.annotationEnabled).toggleStyle(.button)
                    .disabled(!model.inputAvailable)
                ForEach(AnnotationSceneModel.Tool.allCases) { tool in
                    Button {
                        model.tool = tool
                        model.annotationEnabled = true
                        if tool == .sticker { showsStickers = true }
                    } label: {
                        Image(systemName: tool.symbol).font(.system(size: 15, weight: .medium))
                            .frame(width: buttonSide, height: buttonSide)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.2) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.inputAvailable)
                    .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
                    .accessibilityLabel(tool.title)
                    .accessibilityValue(model.tool == tool ? "Selected" : "")
                    .keyboardShortcut(KeyEquivalent(tool.shortcut), modifiers: [])
                }
                Divider().frame(height: 24)
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: buttonSide, height: buttonSide) }
                    .help("Undo your last annotation (⌘Z)").accessibilityLabel("Undo your last annotation")
                    .keyboardShortcut("z", modifiers: .command).disabled(!model.canAnnotate)
                Button { model.deleteSelection() } label: { Image(systemName: "trash").frame(width: buttonSide, height: buttonSide) }
                    .help("Remove selected annotation (Delete)").accessibilityLabel("Remove selected annotation")
                    .keyboardShortcut(.delete, modifiers: []).disabled(model.selectedObjectID == nil || !model.canAnnotate)
                Button { model.escape() } label: { Image(systemName: "xmark").frame(width: buttonSide, height: buttonSide) }
                    .help("Stop annotating (Escape)").accessibilityLabel("Stop annotating")
                    .keyboardShortcut(.escape, modifiers: [])
            }
            HStack(spacing: 8) {
                Picker("Color", selection: $model.color) {
                    ForEach(AnnotationAuthority.colors, id: \.self) { color in Text(color.capitalized).tag(color) }
                }.frame(width: 115)
                Picker("Width", selection: $model.lineWidth) {
                    Text("Fine").tag(0.003); Text("Medium").tag(0.006); Text("Bold").tag(0.012)
                }.frame(width: 140)
                if model.tool == .sticker {
                    Button("\(model.sticker.emoji) Stickers") { showsStickers = true }
                }
                if model.isPresenter {
                    Menu("Manage") {
                        Button(model.snapshot?.policy.paused == true ? "Resume annotations" : "Pause annotations") {
                            guard var policy = model.snapshot?.policy else { return }
                            policy.paused.toggle(); model.setPolicy(policy)
                        }
                        ForEach(AnnotationPermission.allCases, id: \.self) { permission in
                            Button(permission == .everyone ? "Allow everyone" : permission == .approved ? "Allow approved participants" : "Presenter only") {
                                guard var policy = model.snapshot?.policy else { return }
                                policy.permission = permission; model.setPolicy(policy)
                            }
                        }
                        Menu("Approve participants") {
                            ForEach(model.authorNames.keys.sorted(), id: \.self) { id in
                                if id != model.localActorID {
                                    Button(model.authorNames[id] ?? "Participant") {
                                        guard var policy = model.snapshot?.policy else { return }
                                        if policy.approvedIDs.contains(id) { policy.approvedIDs.remove(id) }
                                        else { policy.approvedIDs.insert(id); policy.disabledIDs.remove(id) }
                                        model.setPolicy(policy)
                                    }
                                }
                            }
                        }
                        Menu("Disable participant annotations") {
                            ForEach(model.authorNames.keys.sorted(), id: \.self) { id in
                                if id != model.localActorID {
                                    Button(model.authorNames[id] ?? "Participant") { model.disablePeer(id) }
                                }
                            }
                        }
                        Menu("Default sticker lifetime") {
                            ForEach(AnnotationTTL.allCases, id: \.self) { ttl in
                                Button(ttl == .threeHundred ? "5 minutes" : "\(ttl.rawValue) seconds") { model.setDefaultStickerTTL(ttl) }
                            }
                        }
                        Divider()
                        Button("Clear drawings", role: .destructive) { model.clearDrawings() }
                        Button("Clear stickers", role: .destructive) { model.clearStickers() }
                        Button("Clear all annotations", role: .destructive) { model.clear() }
                    }
                }
            }.disabled(!model.canAnnotate && !model.isPresenter)
            if !model.inputAvailable { Label(model.disabledReason, systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .popover(isPresented: $showsStickers) { stickerPicker }
    }

    private var stickerPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stickers").font(.headline)
            TextField("Search stickers", text: $search).textFieldStyle(.roundedBorder)
            if search.isEmpty && !model.recentStickers.isEmpty {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                stickerRow(model.recentStickers)
            }
            stickerRow(AnnotationStickerID.allCases.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) })
            Picker("Visible for", selection: $model.stickerTTL) {
                ForEach(AnnotationTTL.allCases, id: \.self) { ttl in
                    Text(ttl == .threeHundred ? "5 minutes" : "\(ttl.rawValue) seconds").tag(ttl)
                }
            }
            Text("Choose a sticker, then click the shared screen to place it.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 300)
    }

    private func stickerRow(_ stickers: [AnnotationStickerID]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 5), spacing: 8) {
            ForEach(stickers, id: \.self) { sticker in
                Button {
                    model.sticker = sticker; model.tool = .sticker; model.annotationEnabled = true; showsStickers = false
                } label: { Text(sticker.emoji).font(.system(size: 28)).frame(width: 40, height: 40) }
                    .buttonStyle(.plain).help(sticker.title).accessibilityLabel(sticker.title)
            }
        }
    }
}
