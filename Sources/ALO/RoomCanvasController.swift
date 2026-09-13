import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ALONetworking

@MainActor
final class RoomCanvasController: ObservableObject {
    nonisolated let bridge: RoomCanvasBridge
    let localID: UUID
    @Published private(set) var snapshot: RoomCanvasSnapshot?
    @Published private(set) var image: CGImage?
    @Published private(set) var state: RoomCanvasViewerState?
    @Published private(set) var isHosting = false
    @Published private(set) var isPreparing = false
    @Published private(set) var rejectionID = UUID()
    @Published var notice: String?
    private let imageIO = RoomCanvasImageIO()
    private var generation = UUID()
    private var preparationID = UUID()
    private var selected: (owner: UUID, canvas: UUID)?
    private var active = true

    init(roomID: UUID, localID: UUID, isPublic: Bool) {
        self.localID = localID
        bridge = RoomCanvasBridge(roomID: roomID, localID: localID, isPublic: isPublic)
        bridge.observe { [weak self] event, token in
            DispatchQueue.main.async { self?.apply(event, generation: token) }
        }
    }

    var canDraw: Bool {
        guard active, !isPreparing, state == .ready, image != nil, let snapshot else { return false }
        let policy = snapshot.annotations.policy
        guard !policy.paused else { return false }
        if snapshot.ownerID == localID { return true }
        guard !policy.disabledIDs.contains(localID.uuidString) else { return false }
        return policy.permission == .everyone || (policy.permission == .approved && policy.approvedIDs.contains(localID.uuidString))
    }

    func chooseImage() {
        guard active, !isPreparing else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.prompt = isHosting ? "Replace image" : "Open canvas"
        picker.message = "Share a still image with people in this room. Your original stays unchanged."
        picker.begin { [weak self] result in
            guard result == .OK, let url = picker.url else { return }
            self?.prepare(url)
        }
    }

    @discardableResult
    func prepare(_ url: URL) -> Task<Void, Never>? {
        guard active else { return nil }
        let replacing = isHosting && snapshot != nil
        if !replacing { leave(); generation = UUID() }
        let token = generation, preparation = UUID()
        preparationID = preparation; isPreparing = true; notice = nil
        return Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await imageIO.prepare(fileURL: url)
                guard active, generation == token, preparationID == preparation else { return }
                if replacing { bridge.replaceImage(prepared, generation: token) }
                else { bridge.host(prepared, generation: token) }
                isPreparing = false
            } catch {
                guard active, generation == token, preparationID == preparation else { return }
                isPreparing = false; notice = error.localizedDescription
            }
        }
    }

    func join(ownerID: UUID, advertisement: RoomCanvasAdvertisement) {
        guard active, ownerID != localID, advertisement.isValid else { return }
        leave(); generation = UUID()
        selected = (ownerID, advertisement.canvasID)
        state = .connecting
        bridge.join(ownerID: ownerID, canvasID: advertisement.canvasID, generation: generation)
    }

    func retry() {
        guard let selected else { return }
        join(ownerID: selected.owner, advertisement: .init(canvasID: selected.canvas, imageName: "Shared image.png"))
    }

    func submit(_ action: AnnotationAction) {
        guard active, snapshot != nil else { return }
        // Owner moderation is available while drawing is paused. Gesture-end
        // cleanup remains allowed when a view disappears or loses permission.
        switch action {
        case .setPolicy, .clear: guard isHosting else { return }
        case .endDrawing: break
        default: guard canDraw else { return }
        }
        bridge.submit(action, generation: generation)
    }

    func setPolicy(_ policy: AnnotationPolicy) { submit(.setPolicy(policy)) }

    func leave() {
        bridge.leave(generation: generation)
        generation = UUID(); preparationID = UUID(); selected = nil
        snapshot = nil; image = nil; state = nil; isHosting = false; isPreparing = false; notice = nil
    }

    func stop() { leave(); active = false; bridge.stop() }

    private func apply(_ event: RoomCanvasAppEvent, generation token: UUID) {
        guard active, generation == token else { return }
        switch event {
        case .snapshot(let next, let hosting):
            if snapshot?.image != next?.image { image = nil }
            snapshot = next; isHosting = hosting
        case .image(let bytes, let descriptor):
            guard let bytes, let descriptor else { image = nil; return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let decoded = try await imageIO.decode(.init(descriptor: descriptor, bytes: bytes))
                    guard active, generation == token, snapshot?.image == descriptor else { return }
                    image = decoded
                } catch {
                    guard active, generation == token, snapshot?.image == descriptor else { return }
                    image = nil; notice = error.localizedDescription
                    bridge.rejectImage(generation: token, reason: error.localizedDescription)
                }
            }
        case .state(let state): self.state = state
        case .rejection(let reason):
            rejectionID = UUID()
            switch reason {
            case .paused: notice = "Drawing is paused."
            case .permissionDenied: notice = "The canvas owner controls who can draw."
            case .capacity: notice = "This canvas has reached its drawing limit. Undo a stroke or ask the owner to clear it."
            case .nothingToUndo: notice = "There is no earlier drawing of yours to undo."
            case .wrongSession, .noGesture: break // An image or permission change can end a gesture.
            default: notice = "That drawing change was not applied. Try again."
            }
        }
    }
}
