import CoreGraphics
import Foundation
import ALOCore

@MainActor
protocol AnnotationOverlayPresenting: AnyObject {
    func update(metadata: CapturedFrameMetadata)
    func hide()
    func close()
}

#if os(iOS)
/// iOS renders annotations inside the received image, never in a desktop panel.
@MainActor private final class ViewerOnlyAnnotationOverlay: AnnotationOverlayPresenting {
    func update(metadata: CapturedFrameMetadata) {}
    func hide() {}
    func close() {}
}
#endif

/// Main-thread presentation owner for one admitted broadcaster connection.
/// The session supplies authenticated coordinator callbacks and owns `close()`.
@MainActor
final class AnnotationPresentationController {
    let scene: AnnotationSceneModel
    private let presenterID: String
    private let relay: Relay
    private let makeOverlay: @MainActor (AnnotationSceneModel) -> any AnnotationOverlayPresenting
    private var overlay: (any AnnotationOverlayPresenting)?
    private var closed = false

    @MainActor private final class Relay {
        var active = false
        let send: (AnnotationCommand) -> Void
        let requestSnapshot: () -> Void
        init(send: @escaping (AnnotationCommand) -> Void, requestSnapshot: @escaping () -> Void) {
            self.send = send
            self.requestSnapshot = requestSnapshot
        }
    }

    init(localActorID: String, presenterID: String,
         send: @escaping (AnnotationCommand) -> Void,
         requestSnapshot: @escaping () -> Void,
         makeOverlay: @escaping @MainActor (AnnotationSceneModel) -> any AnnotationOverlayPresenting = {
             #if os(macOS)
             AnnotationOverlayController(model: $0)
             #else
             _ = $0
             return ViewerOnlyAnnotationOverlay()
             #endif
         }) {
        self.presenterID = presenterID
        self.makeOverlay = makeOverlay
        let relay = Relay(send: send, requestSnapshot: requestSnapshot)
        self.relay = relay
        scene = AnnotationSceneModel(localActorID: localActorID) { [weak relay] command in
            guard let relay, relay.active else { return }
            relay.send(command)
        }
        scene.requestSnapshot = { [weak relay] in
            guard let relay, relay.active else { return }
            relay.requestSnapshot()
        }
        scene.inputUnavailableReason = "Waiting for shared-screen geometry"
    }

    /// Only snapshots accepted by the authenticated coordinator belong here.
    func apply(snapshot: AnnotationSnapshot?) {
        guard !closed else { return }
        guard let snapshot else {
            relay.active = false
            overlay?.hide()
            scene.reset()
            return
        }
        guard snapshot.presenterID == presenterID else { return }
        if scene.snapshot?.sessionID != snapshot.sessionID {
            relay.active = false
            overlay?.hide()
            scene.reset()
            scene.inputUnavailableReason = "Waiting for shared-screen geometry"
        }
        scene.apply(snapshot: snapshot)
        relay.active = true
    }

    func apply(event: AnnotationEvent) {
        guard !closed, relay.active, event.sessionID == scene.snapshot?.sessionID else { return }
        scene.apply(event: event)
    }

    func reject(commandID: UUID, reason: AnnotationRejection) {
        guard !closed, relay.active else { return }
        scene.reject(commandID: commandID, reason: reason)
    }

    /// `contentRect` must use the supplied captured surface's pixel coordinates.
    /// A decoder may resize that surface; the view projects its content fraction
    /// into the actual displayed image. No desktop location is needed by viewers.
    func apply(metadata: CapturedFrameMetadata, sessionID: UUID, frameSize: CGSize) {
        guard !closed, relay.active, sessionID == scene.snapshot?.sessionID else { return }
        if let previous = scene.captureMetadata, metadata.captureTimeNanos < previous.captureTimeNanos { return }
        scene.updateCaptureMetadata(metadata, frameSize: frameSize)
        if scene.isPresenter {
            if overlay == nil { overlay = makeOverlay(scene) }
            overlay?.update(metadata: metadata)
        }
    }

    func updateParticipants(_ names: [String: String]) {
        guard !closed else { return }
        // Keep presentation state bounded even if a caller passes stale members.
        scene.authorNames = Dictionary(uniqueKeysWithValues: names.keys.sorted().prefix(128).map {
            ($0, String(names[$0, default: "Participant"].prefix(128)))
        })
    }

    func toggleAnnotations() {
        guard !closed else { return }
        scene.toggleAnnotations()
    }

    func close() {
        guard !closed else { return }
        closed = true
        relay.active = false
        overlay?.close()
        overlay = nil
        scene.reset()
        scene.authorNames = [:]
    }
}
