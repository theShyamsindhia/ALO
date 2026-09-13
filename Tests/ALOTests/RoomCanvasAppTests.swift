import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Network
import Testing
import ALOIdentity
import ALORooms
@testable import ALONetworking
@testable import ALO

@Suite("Canvas app integration", .serialized) @MainActor
struct RoomCanvasAppTests {
    @Test func realControllersDiscoverJoinDrawReplaceAndEndAcrossAuthenticatedMesh() async throws {
        let fixture = try CanvasAppNetwork()
        defer { fixture.stop() }
        let source = try fixture.imageFile(name: "First.png", width: 640, height: 400)
        fixture.host.prepare(source)
        try await canvasEventually { fixture.host.canDraw }
        try await canvasEventually {
            fixture.viewerState.read { $0.participants.first(where: { $0.id == fixture.hostID.uuidString })?.canvas != nil }
        }
        let advertisement = try #require(fixture.viewerState.read { $0.participants.first(where: { $0.id == fixture.hostID.uuidString })?.canvas })
        fixture.viewer.join(ownerID: fixture.hostID, advertisement: advertisement)
        try await canvasEventually { fixture.viewer.canDraw }
        #expect(fixture.viewer.image?.width == 640 && fixture.viewer.image?.height == 400)
        #expect(fixture.host.snapshot?.participants.count == 2)
        let a = UUID(), b = UUID()
        fixture.host.submit(.beginDrawing(id: a, tool: .pencil, points: [.init(x: 0.2, y: 0.3)], color: "blue", width: 0.006))
        fixture.host.submit(.endDrawing(id: a))
        fixture.viewer.submit(.beginDrawing(id: b, tool: .pencil, points: [.init(x: 0.7, y: 0.6)], color: "red", width: 0.006))
        fixture.viewer.submit(.endDrawing(id: b))
        try await canvasEventually { fixture.viewer.snapshot?.annotations.objects.filter(\.isComplete).count == 2 }
        fixture.viewer.submit(.undo)
        try await canvasEventually { fixture.host.snapshot?.annotations.objects.map(\.id) == [a] }
        // Cut a real authenticated canvas connection, leaving room control up.
        // Rejoining must recover the same image/stroke, not start a blank canvas.
        let firstConnection = try #require(fixture.viewerState.read { $0.canvasChannels.last })
        firstConnection.cancel()
        try await canvasEventually { fixture.viewer.state != .ready }
        #expect(!fixture.viewer.canDraw && fixture.viewer.image != nil)
        try await canvasEventually {
            fixture.viewerState.read { $0.canvasChannels.count > 1 } && fixture.viewer.canDraw
        }
        #expect(fixture.viewer.snapshot?.canvasID == advertisement.canvasID)
        #expect(fixture.viewer.snapshot?.annotations.objects.map(\.id) == [a])
        #expect(fixture.host.snapshot?.participants.count == 2)
        fixture.host.setPolicy(.init(permission: .everyone, paused: true))
        try await canvasEventually { fixture.viewer.snapshot?.annotations.policy.paused == true }
        #expect(!fixture.viewer.canDraw && !fixture.host.canDraw)
        fixture.host.setPolicy(.init(permission: .everyone))
        try await canvasEventually { fixture.viewer.canDraw && fixture.host.canDraw }
        let replacement = try fixture.imageFile(name: "Second.png", width: 320, height: 320)
        fixture.host.prepare(replacement)
        try await canvasEventually { fixture.viewer.image?.width == 320 && fixture.viewer.image?.height == 320 }
        #expect(fixture.viewer.snapshot?.canvasID == advertisement.canvasID)
        #expect(fixture.viewer.snapshot?.annotations.objects.isEmpty == true)
        #expect(fixture.host.snapshot?.participants.count == 2)
        fixture.viewer.leave()
        try await canvasEventually { fixture.host.snapshot?.participants.count == 1 }
        #expect(fixture.host.canDraw && fixture.viewer.image == nil)
        fixture.viewer.join(ownerID: fixture.hostID, advertisement: advertisement)
        try await canvasEventually { fixture.viewer.canDraw }
        fixture.host.leave()
        try await canvasEventually { fixture.viewer.state == .ended }
        #expect(fixture.viewer.snapshot == nil && fixture.viewer.image == nil)
        #expect(try Data(contentsOf: source).count > 0)
    }

    @Test func leavingDuringPreparationCannotPublishAStaleCanvas() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-canvas-stale-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("image.png")
        try canvasPNG(width: 1_000, height: 500).write(to: file)
        let controller = RoomCanvasController(roomID: UUID(), localID: UUID(), isPublic: false)
        defer { controller.stop() }
        let preparation = try #require(controller.prepare(file))
        controller.leave() // Main-actor task cannot complete before this invalidation.
        await preparation.value // Observe actual IO completion, not an arbitrary number of yields.
        #expect(controller.snapshot == nil && controller.image == nil && !controller.isPreparing)
    }

    @Test func imageGeometryAlignsAcrossAspectRatiosAndClampsDrawingToTheImage() {
        let wide = RoomCanvasGeometry.imageRect(image: CGSize(width: 800, height: 400), available: CGSize(width: 300, height: 300))
        #expect(wide == CGRect(x: 0, y: 75, width: 300, height: 150))
        #expect(RoomCanvasGeometry.point(CGPoint(x: 150, y: 150), in: wide) == .init(x: 0.5, y: 0.5))
        #expect(RoomCanvasGeometry.point(CGPoint(x: -20, y: 500), in: wide) == .init(x: 0, y: 1))
        #expect(RoomCanvasGeometry.point(.zero, in: .zero) == nil)
        let tall = RoomCanvasGeometry.imageRect(image: CGSize(width: 400, height: 800), available: CGSize(width: 300, height: 300))
        #expect(tall == CGRect(x: 75, y: 0, width: 150, height: 300))
    }

    @Test func renderNativeCanvasDiscoveryDrawingAndPausedStatesAtBothWidths() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-canvas-render-source-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Room concept.png")
        try canvasPNG(width: 640, height: 400).write(to: file)
        let controller = RoomCanvasController(roomID: UUID(), localID: UUID(), isPublic: false)
        defer { controller.stop() }
        var person = RoomParticipant(id: UUID().uuidString, name: "Raj — a longer participant name")
        person.canvas = .init(canvasID: UUID(), imageName: "Shared interface exploration.png")
        for state in ["discovery", "drawing", "paused"] {
            if state == "drawing" {
                controller.prepare(file)
                try await canvasEventually { controller.canDraw }
                let id = UUID()
                controller.submit(.beginDrawing(id: id, tool: .pencil,
                    points: [.init(x: 0.2, y: 0.7), .init(x: 0.4, y: 0.3), .init(x: 0.7, y: 0.6)], color: "blue", width: 0.008))
                controller.submit(.endDrawing(id: id))
                try await canvasEventually { controller.snapshot?.annotations.objects.first?.isComplete == true }
            } else if state == "paused" {
                controller.setPolicy(.init(permission: .everyone, paused: true))
                try await canvasEventually { controller.snapshot?.annotations.policy.paused == true }
            }
            for width in [360.0, 540.0] {
                let view = NotchRoomCanvas(controller: controller, participants: [person])
                    .padding(12).frame(width: width, height: 400).background(Color.black).preferredColorScheme(.dark)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 1_500)
                if let output = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
                    let folder = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try png.write(to: folder.appendingPathComponent("canvas-\(Int(width))-\(state).png"))
                }
                window.close()
                try await renderInNotch(VStack(spacing: 10) {
                    Label("Canvas", systemImage: "pencil.and.outline").font(.system(size: 12, weight: .semibold))
                    NotchRoomCanvas(controller: controller, participants: [person])
                }, name: "notch-canvas-\(Int(width))-\(state)",
                   size: CGSize(width: width, height: state == "discovery" ? 220 : 400))
            }
        }
    }
}

private final class CanvasMeshState: @unchecked Sendable {
    struct State {
        var port: NWEndpoint.Port?
        var participants: [RoomParticipant] = []
        var canvasChannels: [SecurePeerChannel] = []
    }
    private let lock = NSLock()
    private var state = State()
    func update(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
    func read<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
}

@MainActor private final class CanvasAppNetwork {
    let hostID: UUID, viewerID: UUID
    let host: RoomCanvasController, viewer: RoomCanvasController
    let hostMesh: MeshControlPlane, viewerMesh: MeshControlPlane
    let hostState = CanvasMeshState(), viewerState = CanvasMeshState()
    let directory: URL
    init() throws {
        let room = RoomConfiguration.secure(name: "Canvas app test", isPrivate: true)
        let roomID = try #require(UUID(uuidString: room.id))
        let owner = UserIdentity.ephemeral(), a = try InstallationIdentity.ephemeral(), b = try InstallationIdentity.ephemeral()
        hostID = a.publicIdentity.nodeID; viewerID = b.publicIdentity.nodeID
        let base = try NetworkManifest.create(name: "Canvas test network", owner: owner)
        let manifest = try base.addingChannel(.init(id: roomID, name: "Canvas", visibility: .privateMembers), signedBy: owner)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-canvas-app-\(UUID())")
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        func authorization(_ identity: InstallationIdentity) throws -> NetworkChannelAuthorization {
            let repository = NetworkRepository(directoryURL: directory.appendingPathComponent(identity.publicIdentity.nodeID.uuidString))
            try repository.accept(manifest, for: owner.publicIdentity)
            return try NetworkChannelAuthorization(policy: NetworkPolicyCenter(repository: repository, networkID: manifest.id),
                channelID: roomID, localDevice: DeviceIdentityBinding(user: owner, deviceName: "Canvas test", generation: 1,
                    installationPublicKeyHash: identity.publicIdentity.publicKeyHash))
        }
        host = RoomCanvasController(roomID: roomID, localID: hostID, isPublic: false)
        viewer = RoomCanvasController(roomID: roomID, localID: viewerID, isPublic: false)
        let hostBridge = host.bridge, viewerBridge = viewer.bridge, aState = hostState, bState = viewerState
        hostMesh = MeshControlPlane(room: room, nodeID: hostID.uuidString, displayName: "Host",
            listenerReadyHandler: { port in aState.update { $0.port = port } }, replicaHandler: { _ in },
            participantsHandler: { people in aState.update { $0.participants = people } },
            installationIdentity: a, peerPins: MemoryPeerPinStore(), secureCapabilities: [.desktop, .roomCanvas],
            networkAuthorization: try authorization(a), incomingMediaChannelHandler: hostBridge.receive)
        viewerMesh = MeshControlPlane(room: room, nodeID: viewerID.uuidString, displayName: "Viewer",
            listenerReadyHandler: { port in bState.update { $0.port = port } }, replicaHandler: { _ in },
            participantsHandler: { people in bState.update { $0.participants = people } },
            installationIdentity: b, peerPins: MemoryPeerPinStore(), secureCapabilities: [.desktop, .roomCanvas],
            networkAuthorization: try authorization(b), incomingMediaChannelHandler: viewerBridge.receive)
        for (controller, mesh) in [(host, hostMesh), (viewer, viewerMesh)] {
            let connectionState = controller === host ? aState : bState
            controller.bridge.configure(open: { [weak mesh] id, completion in
                guard let mesh else { completion(.failure(SecurePeerChannelError.cancelled)); return }
                mesh.openPeerChannel(to: id, role: .roomCanvas) { result in
                    if case .success(let (channel, _)) = result {
                        connectionState.update { $0.canvasChannels.append(channel) }
                    }
                    completion(result)
                }
            }, advertise: { [weak mesh] in mesh?.publishCanvas($0) })
        }
        try hostMesh.start(advertise: false); try viewerMesh.start(advertise: false)
        let viewerMesh = viewerMesh, hostID = hostID
        Task { [weak self] in
            guard let self else { return }
            try await canvasEventually { self.hostState.read { $0.port != nil } }
            if let port = self.hostState.read({ $0.port }) {
                viewerMesh.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: hostID.uuidString)
            }
        }
    }
    func imageFile(name: String, width: Int, height: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try canvasPNG(width: width, height: height).write(to: url)
        return url
    }
    func stop() {
        host.stop(); viewer.stop(); hostMesh.stop(); viewerMesh.stop()
        // Network repositories can still be referenced by queued close callbacks.
        // Leave this named test directory for process-lifetime cleanup/inspection.
    }
}

@MainActor private func canvasEventually(_ condition: () -> Bool) async throws {
    for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
    try #require(condition(), "Canvas did not reach its expected app state within ten seconds")
}

private func canvasPNG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.93, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.5, green: 0.65, blue: 0.55, alpha: 1))
    context.fill(CGRect(x: 30, y: 30, width: max(1, width / 3), height: max(1, height - 60)))
    let data = NSMutableData(), image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}
