import CoreGraphics
import Combine
import Testing
@testable import ALO
import ALOCore

@MainActor
struct AnnotationSceneModelTests {
    @Test("Timestamp-only capture updates stay silent while commands retain fresh timing")
    func idleCaptureDoesNotInvalidateViews() {
        let model = AnnotationSceneModel(localActorID: "presenter") { _ in }
        model.apply(snapshot: AnnotationAuthority(presenterID: "presenter").snapshot(nowNanos: 1))
        var metadata = CapturedFrameMetadata(captureTimeNanos: 1,
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            screenRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            contentScale: 1, scaleFactor: 1, status: .complete)
        let size = CGSize(width: 1280, height: 720)
        model.updateCaptureMetadata(metadata, frameSize: size)
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        for time in 2...121 {
            metadata.captureTimeNanos = UInt64(time)
            model.updateCaptureMetadata(metadata, frameSize: size)
        }
        #expect(changes == 0)
        #expect(model.captureMetadata?.captureTimeNanos == 121)
        #expect(model.videoCaptureTimeNanos == 121)
        metadata.contentRect.size.width = 1000
        model.updateCaptureMetadata(metadata, frameSize: size)
        #expect(changes > 0)
        model.annotationEnabled = true
        metadata.status = .suspended
        model.updateCaptureMetadata(metadata, frameSize: size)
        #expect(!model.inputAvailable && !model.annotationEnabled)
        observation.cancel()
        model.reset()
    }

    @Test("Rejected drawing updates send cleanup so the host can accept another gesture")
    func rejectedDrawingCleanup() {
        var commands: [AnnotationCommand] = []
        let model = AnnotationSceneModel(localActorID: "presenter") { commands.append($0) }
        let authority = AnnotationAuthority(presenterID: "presenter")
        model.apply(snapshot: authority.snapshot(nowNanos: 1))
        model.annotationEnabled = true
        model.tool = .pencil
        model.begin(at: CGPoint(x: 0.2, y: 0.2))
        let objectID = model.draft?.id
        model.reject(.rateLimited)
        #expect(model.draft == nil)
        #expect(commands.count == 2)
        if let objectID { #expect(commands.last?.action == .endDrawing(id: objectID)) }
        #expect(commands.map(\.sequence) == [1, 2])
        model.reset()
    }

    @Test("A new sharing session removes optimistic stickers and restarts its command sequence")
    func sessionReplacement() {
        var commands: [AnnotationCommand] = []
        let model = AnnotationSceneModel(localActorID: "presenter") { commands.append($0) }
        let initial = AnnotationAuthority(presenterID: "presenter")
        model.apply(snapshot: initial.snapshot(nowNanos: 1))
        model.annotationEnabled = true
        model.tool = .sticker
        model.begin(at: CGPoint(x: 0.2, y: 0.2))
        #expect(model.optimisticStickers.count == 1)
        let replacement = AnnotationAuthority(presenterID: "presenter")
        model.apply(snapshot: replacement.snapshot(nowNanos: 2))
        #expect(model.optimisticStickers.isEmpty)
        #expect(model.selectedObjectID == nil)
        model.begin(at: CGPoint(x: 0.4, y: 0.4))
        #expect(commands.last?.sessionID == replacement.sessionID)
        #expect(commands.last?.sequence == 1)
        model.reset()
    }

    @Test("Unacknowledged sticker drafts stay bounded while the connection is stalled")
    func boundedOptimisticStickers() {
        var commands: [AnnotationCommand] = []
        let model = AnnotationSceneModel(localActorID: "presenter") { commands.append($0) }
        model.apply(snapshot: AnnotationAuthority(presenterID: "presenter").snapshot(nowNanos: 1))
        model.annotationEnabled = true
        model.tool = .sticker
        for _ in 0..<(AnnotationAuthority.maximumObjects + 10) { model.begin(at: CGPoint(x: 0.5, y: 0.5)) }
        #expect(model.optimisticStickers.count == AnnotationAuthority.maximumObjects)
        #expect(commands.count == AnnotationAuthority.maximumObjects)
        #expect(model.notice != nil)
        model.reset()
    }

    @Test("Unavailable desktop capture keeps the annotation surface from accepting input")
    func unavailableInput() {
        var commands: [AnnotationCommand] = []
        let model = AnnotationSceneModel(localActorID: "presenter") { commands.append($0) }
        model.apply(snapshot: AnnotationAuthority(presenterID: "presenter").snapshot(nowNanos: 1))
        model.annotationEnabled = true
        model.tool = .pencil
        model.inputUnavailableReason = "Restore the shared window"
        model.begin(at: CGPoint(x: 0.5, y: 0.5))
        #expect(!model.acceptsInput)
        #expect(commands.isEmpty)
        model.reset()
    }
}
