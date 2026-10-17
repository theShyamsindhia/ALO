import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ALOCore
import ALONetworking

enum RoomCanvasToolMode: String, CaseIterable, Identifiable {
    case select = "Select"
    case hand = "Pan"
    case rectangle = "Box"
    case ellipse = "Circle"
    case arrow = "Arrow"
    case pen = "Pen"
    case stamp = "Stamp"

    var id: String { rawValue }

    var shortcutLabel: String {
        switch self {
        case .select: "V"
        case .hand: "H"
        case .rectangle: "R"
        case .ellipse: "O"
        case .arrow: "A"
        case .pen: "P"
        case .stamp: "S"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.draw"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .stamp: "star.fill"
        }
    }

    var annotationTool: AnnotationTool? {
        switch self {
        case .select, .hand, .stamp: nil
        case .pen: .pencil
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        }
    }
}

@MainActor
final class RoomCanvasController: ObservableObject {
    static let blankBoardImageName = "Shared board.png"

    nonisolated let bridge: RoomCanvasBridge
    let localID: UUID
    @Published private(set) var snapshot: RoomCanvasSnapshot?
    @Published private(set) var image: CGImage?
    @Published private(set) var state: RoomCanvasViewerState?
    @Published private(set) var isHosting = false
    @Published private(set) var isPreparing = false
    @Published private(set) var rejectionID = UUID()
    @Published var notice: String?

    // Shared Figma-style canvas tool & viewport state
    @Published var activeTool: RoomCanvasToolMode = .rectangle
    @Published var selectedObjectID: UUID?
    @Published var isSpacePanning = false
    @Published var inkColor: String = "blue"
    @Published var strokeWidth: Double = 0.006
    @Published var selectedStamp: AnnotationStickerID = .star
    @Published var zoomScale: CGFloat = 1.0
    @Published var panOffset: CGSize = .zero
    @Published private(set) var isPoppedOut = false
    @Published var participants: [RoomParticipant] = []

    var onPopoutChanged: (Bool) -> Void = { _ in }
    private let imageIO = RoomCanvasImageIO()
    private var generation = UUID()
    private var preparationID = UUID()
    private var selected: (owner: UUID, canvas: UUID)?
    private var active = true
    private var popoutPanel: RoomCanvasPopoutPanel?

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

    var isBlankBoard: Bool {
        snapshot?.image.name == Self.blankBoardImageName
    }

    var selectedObject: AnnotationObject? {
        guard let selectedObjectID else { return nil }
        return snapshot?.annotations.objects.first(where: { $0.id == selectedObjectID })
    }

    func setSelectedCornerRadius(_ normalizedRadius: Double) {
        guard canDraw, let object = selectedObject, object.tool == .rectangle else { return }
        let clamped = min(0.5, max(0, normalizedRadius))
        submit(.updateShape(id: object.id, points: object.points, cornerRadius: clamped, editID: UUID()))
    }

    func deleteSelectedObject() {
        guard canDraw, let object = selectedObject else { return }
        submit(.deleteObject(id: object.id))
        selectedObjectID = nil
    }

    func pan(by delta: CGSize) {
        panOffset = CGSize(
            width: min(2_400, max(-2_400, panOffset.width + delta.width)),
            height: min(2_400, max(-2_400, panOffset.height + delta.height))
        )
    }

    func zoom(to targetScale: CGFloat, anchor: CGPoint? = nil, in viewportSize: CGSize = .zero) {
        let clamped = min(4.0, max(0.35, targetScale))
        let oldScale = zoomScale
        guard abs(clamped - oldScale) > 0.0005 else { return }
        if let anchor, viewportSize.width > 0, viewportSize.height > 0 {
            let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            let ratio = clamped / oldScale
            let nextPanX = (anchor.x - center.x) * (1 - ratio) + panOffset.width * ratio
            let nextPanY = (anchor.y - center.y) * (1 - ratio) + panOffset.height * ratio
            panOffset = CGSize(
                width: min(2_400, max(-2_400, nextPanX)),
                height: min(2_400, max(-2_400, nextPanY))
            )
        }
        zoomScale = clamped
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
    func startBlankBoard(width: Int = 1_600, height: Int = 1_000) -> Task<Void, Never>? {
        guard active, !isPreparing, let png = Self.makeBlankBoardPNG(width: width, height: height) else { return nil }
        return prepare(bytes: png, name: Self.blankBoardImageName)
    }

    @discardableResult
    func pasteFromClipboard() -> Task<Void, Never>? {
        guard active, !isPreparing else { return nil }
        guard let nsImage = NSImage(pasteboard: .general),
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            notice = "No image found on the clipboard."
            return nil
        }
        return prepare(bytes: png, name: "Clipboard.png")
    }

    @discardableResult
    func prepare(_ url: URL) -> Task<Void, Never>? {
        guard active else { return nil }
        let replacing = isHosting && snapshot != nil
        if !replacing { leave(closePopout: false); generation = UUID() }
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

    @discardableResult
    func prepare(bytes: Data, name: String) -> Task<Void, Never>? {
        guard active else { return nil }
        let replacing = isHosting && snapshot != nil
        if !replacing { leave(closePopout: false); generation = UUID() }
        let token = generation, preparation = UUID()
        preparationID = preparation; isPreparing = true; notice = nil
        return Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await imageIO.prepare(bytes: bytes, name: name)
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
        leave(closePopout: false); generation = UUID()
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
        case .setPolicy, .clear, .clearDrawings, .clearStickers: guard isHosting else { return }
        case .endDrawing, .releaseSticker: break
        default: guard canDraw else { return }
        }
        bridge.submit(action, generation: generation)
    }

    func setPolicy(_ policy: AnnotationPolicy) { submit(.setPolicy(policy)) }

    func resetViewport() {
        zoomScale = 1.0
        panOffset = .zero
    }

    func popOut() {
        guard active else { return }
        if let existing = popoutPanel {
            isPoppedOut = true
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            onPopoutChanged(true)
            return
        }
        let panel = RoomCanvasPopoutPanel(controller: self)
        popoutPanel = panel
        isPoppedOut = true
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onPopoutChanged(true)
    }

    func shrinkToNotch() {
        guard isPoppedOut || popoutPanel != nil else { return }
        isPoppedOut = false
        let panel = popoutPanel
        popoutPanel = nil
        panel?.orderOut(nil)
        panel?.close()
        onPopoutChanged(false)
    }

    func leave() {
        leave(closePopout: true)
    }

    private func leave(closePopout: Bool) {
        if closePopout { shrinkToNotch() }
        bridge.leave(generation: generation)
        generation = UUID(); preparationID = UUID(); selected = nil
        snapshot = nil; image = nil; state = nil; isHosting = false; isPreparing = false; notice = nil
        selectedObjectID = nil
        resetViewport()
    }

    func stop() {
        shrinkToNotch()
        leave(closePopout: false)
        active = false
        bridge.stop()
    }

    private func apply(_ event: RoomCanvasAppEvent, generation token: UUID) {
        guard active, generation == token else { return }
        switch event {
        case .snapshot(let next, let hosting):
            if snapshot?.image != next?.image { image = nil }
            snapshot = next; isHosting = hosting
            if let sel = selectedObjectID,
               next?.annotations.objects.contains(where: { $0.id == sel }) != true {
                selectedObjectID = nil
            }
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
        case .state(let state):
            self.state = state
            if state == .ended { shrinkToNotch() }
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

    private static func makeBlankBoardPNG(width: Int, height: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // Deep obsidian canvas background (#08080B)
        context.setFillColor(CGColor(srgbRed: 0.031, green: 0.031, blue: 0.043, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Subtle Figma-style dot grid baked into the shared board
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.11))
        let spacing = 32
        for y in stride(from: spacing, to: height, by: spacing) {
            for x in stride(from: spacing, to: width, by: spacing) {
                context.fillEllipse(in: CGRect(x: Double(x) - 1, y: Double(y) - 1, width: 2.2, height: 2.2))
            }
        }

        guard let cgImage = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

@MainActor
final class RoomCanvasPopoutPanel: NSPanel {
    init(controller: RoomCanvasController) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = min(980, max(680, screenFrame.width * 0.66))
        let height: CGFloat = min(660, max(460, screenFrame.height * 0.68))
        let origin = NSPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2
        )
        super.init(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 540, height: 380)

        let rootView = RoomPopoutCanvasView(controller: controller)
            .preferredColorScheme(.dark)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
