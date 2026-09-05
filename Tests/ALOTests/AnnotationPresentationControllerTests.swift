import CoreGraphics
import Foundation
import Testing
@testable import ALO
import ALOCore

@MainActor
struct AnnotationPresentationControllerTests {
    private final class Overlay: AnnotationOverlayPresenting {
        var updates: [CapturedFrameMetadata] = []
        var hides = 0
        var closes = 0
        func update(metadata: CapturedFrameMetadata) { updates.append(metadata) }
        func hide() { hides += 1 }
        func close() { closes += 1 }
    }

    private func metadata(time: UInt64 = 10, status: CapturedFrameMetadata.Status = .complete) -> CapturedFrameMetadata {
        CapturedFrameMetadata(captureTimeNanos: time,
            contentRect: CGRect(x: 100, y: 50, width: 600, height: 400),
            screenRect: CGRect(x: -500, y: 30, width: 600, height: 400),
            contentScale: 1, scaleFactor: 1, status: status)
    }

    @Test("One admitted scene routes edits and recovery and stays inert after closing")
    func admittedSceneRouting() {
        var commands: [AnnotationCommand] = []
        var requests = 0
        let controller = AnnotationPresentationController(localActorID: "viewer", presenterID: "host",
            send: { commands.append($0) }, requestSnapshot: { requests += 1 })
        let snapshot = AnnotationAuthority(presenterID: "host").snapshot(nowNanos: 1)
        controller.apply(snapshot: AnnotationAuthority(presenterID: "impostor").snapshot(nowNanos: 1))
        #expect(controller.scene.snapshot == nil)
        controller.apply(snapshot: snapshot)
        #expect(!controller.scene.inputAvailable)
        controller.apply(metadata: metadata(), sessionID: snapshot.sessionID, frameSize: CGSize(width: 800, height: 600))
        controller.scene.tool = .sticker
        controller.toggleAnnotations()
        controller.scene.begin(at: CGPoint(x: 0.25, y: 0.5))
        #expect(commands.count == 1)
        #expect(commands.first?.sessionID == snapshot.sessionID)
        #expect(commands.first?.videoCaptureTimeNanos == 10)
        controller.reject(commandID: commands[0].id, reason: .capacity)
        #expect(requests == 1)
        #expect(controller.scene.optimisticStickers.isEmpty)
        controller.close()
        controller.apply(snapshot: snapshot)
        controller.scene.requestSnapshot()
        controller.toggleAnnotations()
        #expect(controller.scene.snapshot == nil)
        #expect(!controller.scene.annotationEnabled)
        #expect(commands.count == 1 && requests == 1)
    }

    @Test("Source replacement clears old metadata while preserving the chosen tool")
    func sourceReplacement() {
        let controller = AnnotationPresentationController(localActorID: "viewer", presenterID: "host", send: { _ in }, requestSnapshot: {})
        let first = AnnotationAuthority(presenterID: "host").snapshot(nowNanos: 1)
        let second = AnnotationAuthority(presenterID: "host").snapshot(nowNanos: 2)
        controller.apply(snapshot: first)
        controller.apply(metadata: metadata(), sessionID: first.sessionID, frameSize: CGSize(width: 800, height: 600))
        controller.scene.tool = .ellipse
        controller.toggleAnnotations()
        controller.toggleAnnotations()
        controller.toggleAnnotations()
        #expect(controller.scene.tool == .ellipse && controller.scene.annotationEnabled)
        controller.apply(snapshot: second)
        #expect(controller.scene.captureMetadata == nil && !controller.scene.annotationEnabled)
        controller.apply(metadata: metadata(time: 20), sessionID: first.sessionID, frameSize: CGSize(width: 800, height: 600))
        #expect(controller.scene.captureMetadata == nil)
        controller.apply(metadata: metadata(time: 30), sessionID: second.sessionID, frameSize: CGSize(width: 800, height: 600))
        controller.apply(metadata: metadata(time: 10, status: .suspended), sessionID: second.sessionID, frameSize: CGSize(width: 800, height: 600))
        #expect(controller.scene.captureMetadata?.captureTimeNanos == 30)
        controller.toggleAnnotations()
        #expect(controller.scene.tool == .ellipse && controller.scene.annotationEnabled)
        controller.close()
    }

    @Test("Viewer annotations follow visible source bounds after decoder scaling")
    func viewerBoundsAndUnavailableContent() {
        let controller = AnnotationPresentationController(localActorID: "viewer", presenterID: "host", send: { _ in }, requestSnapshot: {})
        let snapshot = AnnotationAuthority(presenterID: "host").snapshot(nowNanos: 1)
        controller.apply(snapshot: snapshot)
        var geometry = metadata()
        geometry.screenRect = nil
        geometry.desktopOverlaySupported = false
        controller.apply(metadata: geometry, sessionID: snapshot.sessionID, frameSize: CGSize(width: 800, height: 600))
        #expect(controller.scene.inputAvailable, "Viewers do not require desktop location or host panel support")
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 800)
        let rect = controller.scene.visibleContentRect(frameSize: CGSize(width: 400, height: 300), in: bounds)
        #expect(rect == CGRect(x: 100, y: 150, width: 600, height: 400))
        #expect(rect.flatMap { AnnotationGeometry.normalizedPoint(CGPoint(x: 50, y: 200), in: $0) } == nil)
        controller.toggleAnnotations()
        controller.apply(metadata: metadata(time: 20, status: .suspended), sessionID: snapshot.sessionID,
                         frameSize: CGSize(width: 800, height: 600))
        #expect(!controller.scene.annotationEnabled && !controller.scene.inputAvailable)
        #expect(controller.scene.visibleContentRect(frameSize: CGSize(width: 400, height: 300), in: bounds) == nil)
        controller.close()
    }

    @Test("The presenter overlay is created only with admitted capture geometry and closes once")
    func presenterOverlayLifetime() {
        let overlay = Overlay()
        var creations = 0
        let controller = AnnotationPresentationController(localActorID: "host", presenterID: "host",
            send: { _ in }, requestSnapshot: {}, makeOverlay: { _ in creations += 1; return overlay })
        let snapshot = AnnotationAuthority(presenterID: "host").snapshot(nowNanos: 1)
        controller.apply(metadata: metadata(), sessionID: snapshot.sessionID, frameSize: CGSize(width: 800, height: 600))
        #expect(creations == 0)
        controller.apply(snapshot: snapshot)
        controller.apply(metadata: metadata(), sessionID: snapshot.sessionID, frameSize: CGSize(width: 800, height: 600))
        #expect(creations == 1 && overlay.updates.count == 1)
        controller.apply(snapshot: nil)
        #expect(overlay.hides == 1 && controller.scene.snapshot == nil)
        controller.close()
        controller.close()
        #expect(overlay.closes == 1)
    }

    @Test("Participant labels populate moderation controls and remain bounded")
    func participantNames() {
        let controller = AnnotationPresentationController(localActorID: "viewer", presenterID: "host", send: { _ in }, requestSnapshot: {})
        controller.updateParticipants(["host": "Presenter", "viewer": "Viewer"])
        #expect(controller.scene.authorNames["host"] == "Presenter")
        controller.updateParticipants(Dictionary(uniqueKeysWithValues: (0..<200).map { (String($0), String(repeating: "x", count: 200)) }))
        #expect(controller.scene.authorNames.count == 128)
        #expect(controller.scene.authorNames.values.allSatisfy { $0.count == 128 })
        controller.close()
        #expect(controller.scene.authorNames.isEmpty)
    }

    @Test("Accepted host events reach the scene and stale source events cannot revive it")
    func acceptedEventRouting() {
        let controller = AnnotationPresentationController(localActorID: "viewer", presenterID: "host", send: { _ in }, requestSnapshot: {})
        var authority = AnnotationAuthority(presenterID: "host")
        controller.apply(snapshot: authority.snapshot(nowNanos: 1))
        let objectID = UUID()
        let command = AnnotationCommand(sessionID: authority.sessionID, sequence: 1,
            action: .placeSticker(id: objectID, stickerID: .heart, position: .init(x: 0.5, y: 0.5)))
        let events = authority.process(command, actorID: "host", nowNanos: 2).events
        #expect(!events.isEmpty)
        for event in events { controller.apply(event: event) }
        #expect(controller.scene.snapshot?.objects.first?.id == objectID)
        controller.apply(snapshot: AnnotationAuthority(presenterID: "host").snapshot(nowNanos: 3))
        for event in events { controller.apply(event: event) }
        #expect(controller.scene.snapshot?.objects.isEmpty == true)
        controller.close()
    }
}
