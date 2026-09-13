import SwiftUI
import ALONetworking
import ALONotchRuntime

enum RoomCanvasGeometry {
    static func imageRect(image: CGSize, available: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / image.width, available.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
    static func point(_ point: CGPoint, in rect: CGRect) -> AnnotationPoint? {
        guard rect.width > 0, rect.height > 0, point.x.isFinite, point.y.isFinite else { return nil }
        return .init(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                     y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
}

struct NotchRoomCanvas: View {
    @ObservedObject var controller: RoomCanvasController
    let participants: [RoomParticipant]
    var onSessionChanged: (Bool) -> Void = { _ in }
    @State private var ink = "blue"
    @State private var confirmation: Confirmation?
    private enum Confirmation: String, Identifiable {
        case end, clear, replace
        var id: String { rawValue }
    }
    private struct Stroke {
        let id: UUID
        let color: String
        var points: [AnnotationPoint]
        var sent = 1
        var lastSend: UInt64
        var ended = false
    }
    @State private var strokes: [UUID: Stroke] = [:]
    @State private var activeStroke: UUID?

    var body: some View {
        VStack(spacing: 8) {
            if let notice = controller.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button { controller.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss canvas notice")
                }
            }
            if controller.state == .ended {
                ContentUnavailableView("Canvas ended", systemImage: "pencil.and.outline",
                    description: Text("The owner closed this canvas."))
                Button("Back to canvases") { controller.leave() }
            } else if controller.state == nil && controller.snapshot == nil {
                discovery
            } else {
                session
            }
        }
        .padding(.horizontal, 8)
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            switch confirmation {
            case .end: Button("End for everyone", role: .destructive) { resetInk(); controller.leave() }
            case .clear: Button("Clear everyone's drawings", role: .destructive) { resetInk(); controller.submit(.clear) }
            case .replace: Button("Choose replacement image…") { resetInk(); controller.chooseImage() }
            case nil: EmptyView()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The shared image and drawings are temporary. This cannot be undone.") }
        .onChange(of: controller.snapshot?.annotations.sessionID) { _, _ in resetInk() }
        .onChange(of: controller.snapshot?.revision) { _, _ in
            let complete = Set((controller.snapshot?.annotations.objects ?? []).filter(\.isComplete).map(\.id))
            strokes = strokes.filter { !$0.value.ended || !complete.contains($0.key) }
        }
        .onChange(of: controller.rejectionID) { _, _ in resetInk() }
        .onChange(of: controller.canDraw) { _, enabled in if !enabled { finishStroke(); resetInk() } }
        .onDisappear { finishStroke() }
        .onAppear { onSessionChanged(controller.snapshot != nil || controller.state != nil) }
        .onChange(of: controller.snapshot != nil || controller.state != nil) { _, active in onSessionChanged(active) }
        .accessibilityIdentifier("ALO.Notch.Canvas")
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .end: "End this canvas for everyone?"
        case .clear: "Clear everyone's drawings?"
        case .replace: "Replace the image and clear all drawings?"
        case nil: "Canvas"
        }
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 8) {
                Text("Drop an image to draw together, or join someone below.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.isPreparing { ProgressView("Preparing image…").controlSize(.small) }
                RoomNotchTray {
                  RoomNotchTile("Open image", action: { controller.chooseImage() }) { Image(systemName: "photo") }
                    .disabled(controller.isPreparing)
                    .help("Start a temporary shared canvas. Your original image stays unchanged.")
                let available = participants.filter { $0.canvas != nil && $0.id != controller.localID.uuidString }
                    ForEach(available) { person in
                        if let advertisement = person.canvas, let owner = UUID(uuidString: person.id) {
                                RoomNotchTile(person.name, action: { controller.join(ownerID: owner, advertisement: advertisement) }) {
                                    Image(systemName: "pencil.and.outline")
                                }.help(advertisement.imageName)
                                    .accessibilityLabel("Join \(person.name)'s canvas")
                                    .disabled(controller.isPreparing)
                        }
                    }
                }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .dropDestination(for: URL.self) { urls, _ in
            guard !controller.isPreparing, urls.count == 1, let url = urls.first else { return false }
            controller.prepare(url); return true
        }
    }

    private var session: some View {
        VStack(spacing: 8) {
            HStack {
                Text(controller.snapshot?.image.name ?? "Shared canvas").font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Button(controller.isHosting ? "End…" : "Leave") {
                    if controller.isHosting { confirmation = .end } else { resetInk(); controller.leave() }
                }
            }
            if let snapshot = controller.snapshot {
                ScrollView(.horizontal) {
                    Text(snapshot.participants.sorted(by: { $0.uuidString < $1.uuidString }).map { name($0) }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.scrollIndicators(.hidden)
                HStack(spacing: 10) {
                    Picker("Ink color", selection: $ink) {
                        ForEach(AnnotationAuthority.colors, id: \.self) { Text($0.capitalized).tag($0) }
                    }.labelsHidden().frame(width: 90).disabled(!controller.canDraw || activeStroke != nil)
                    Button { controller.submit(.undo) } label: { Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 24) }
                        .disabled(!controller.canDraw || !strokes.isEmpty).help("Undo your last drawing").accessibilityLabel("Undo your last drawing")
                    Spacer(minLength: 0)
                    if controller.isHosting { ownerMenu(snapshot.annotations.policy) }
                }
            }
            if let image = controller.image, let snapshot = controller.snapshot {
                surface(image, snapshot: snapshot)
            } else {
                Spacer(minLength: 12)
                if case .interrupted = controller.state {} else { ProgressView("Preparing shared image…").controlSize(.small) }
                Spacer(minLength: 12)
            }
            if case .interrupted(let reason) = controller.state {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if !controller.isHosting { Button("Reconnect") { resetInk(); controller.retry() } }
            } else if controller.state == .connecting {
                ProgressView("Connecting to canvas…").controlSize(.small)
            } else if case .loadingImage(let progress) = controller.state {
                ProgressView("Receiving image", value: progress).font(.caption)
            } else {
                Text(controller.isPreparing ? "Preparing replacement…" : controller.snapshot?.annotations.policy.paused == true ? "Drawing paused by the owner" : controller.canDraw ? "Draw on the image · Undo affects only your work" : "View only · The owner controls drawing access")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func ownerMenu(_ policy: AnnotationPolicy) -> some View {
        Menu {
            Toggle("Everyone can draw", isOn: Binding(get: { policy.permission == .everyone }, set: { enabled in
                var next = policy; next.permission = enabled ? .everyone : .presenterOnly
                if enabled { next.disabledIDs.removeAll() }
                controller.setPolicy(next)
            }))
            Toggle("Pause drawing", isOn: Binding(get: { policy.paused }, set: { var next = policy; next.paused = $0; controller.setPolicy(next) }))
            Section("People") {
                ForEach(Array(controller.snapshot?.participants ?? []).filter { $0 != controller.localID }.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    Toggle(name(id), isOn: Binding(get: {
                        !policy.disabledIDs.contains(id.uuidString) && (policy.permission == .everyone || (policy.permission == .approved && policy.approvedIDs.contains(id.uuidString)))
                    }, set: { enabled in
                        var next = policy
                        if enabled {
                            if next.permission == .presenterOnly { next.permission = .approved }
                            next.approvedIDs.insert(id.uuidString); next.disabledIDs.remove(id.uuidString)
                        } else {
                            next.approvedIDs.remove(id.uuidString); next.disabledIDs.insert(id.uuidString)
                        }
                        controller.setPolicy(next)
                    }))
                }
            }
            Divider()
            Button("Change image…") { confirmation = .replace }.disabled(controller.isPreparing)
            Button("Clear drawings…", role: .destructive) { confirmation = .clear }
        } label: { Label("People", systemImage: "person.2") }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func surface(_ image: CGImage, snapshot: RoomCanvasSnapshot) -> some View {
        GeometryReader { geometry in
            let rect = RoomCanvasGeometry.imageRect(image: CGSize(width: image.width, height: image.height), available: geometry.size)
            Canvas { context, _ in
                context.draw(Image(decorative: image, scale: 1), in: rect)
                for object in snapshot.annotations.objects where strokes[object.id] == nil {
                    draw(object.points, color: object.color, width: object.width, in: rect, context: &context)
                }
                for stroke in strokes.values { draw(stroke.points, color: stroke.color, width: 0.006, in: rect, context: &context) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard controller.canDraw else { return }
                if activeStroke == nil {
                    guard rect.contains(value.startLocation), strokes.count < 8,
                          let point = RoomCanvasGeometry.point(value.startLocation, in: rect) else { return }
                    let id = UUID(); activeStroke = id
                    strokes[id] = Stroke(id: id, color: ink, points: [point], lastSend: MonotonicClock.nowNanos())
                    controller.submit(.beginDrawing(id: id, tool: .pencil, points: [point], color: ink, width: 0.006))
                }
                guard let id = activeStroke, var stroke = strokes[id], stroke.points.count < AnnotationAuthority.maximumPoints,
                      let point = RoomCanvasGeometry.point(value.location, in: rect), point != stroke.points.last else { return }
                stroke.points.append(point); strokes[id] = stroke
                let now = MonotonicClock.nowNanos()
                if now - min(now, stroke.lastSend) >= 50_000_000 { flush(id, now: now) }
            }.onEnded { _ in finishStroke() })
            .accessibilityLabel("Shared image: \(snapshot.image.name). \(snapshot.annotations.objects.count) drawings.")
        }.frame(minHeight: 120)
    }

    private func draw(_ points: [AnnotationPoint], color: String, width: Double, in rect: CGRect, context: inout GraphicsContext) {
        guard let first = points.first else { return }
        let point = CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height)
        let thickness = max(1, min(rect.width, rect.height) * width)
        let colors: [String: Color] = ["red": .red, "orange": .orange, "yellow": .yellow, "green": .green, "blue": .blue, "purple": .purple, "white": .white, "black": .black]
        var path = Path()
        if points.count == 1 {
            path.addEllipse(in: CGRect(x: point.x - thickness / 2, y: point.y - thickness / 2, width: thickness, height: thickness))
            context.fill(path, with: .color(colors[color] ?? .blue))
        } else {
            path.move(to: point)
            for p in points.dropFirst() { path.addLine(to: CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)) }
            context.stroke(path, with: .color(colors[color] ?? .blue), style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
        }
    }

    private func flush(_ id: UUID, now: UInt64) {
        guard var stroke = strokes[id], stroke.sent < stroke.points.count else { return }
        controller.submit(.appendDrawing(id: id, points: Array(stroke.points.dropFirst(stroke.sent))))
        stroke.sent = stroke.points.count; stroke.lastSend = now; strokes[id] = stroke
    }
    private func finishStroke() {
        guard let id = activeStroke else { return }
        flush(id, now: MonotonicClock.nowNanos()); controller.submit(.endDrawing(id: id))
        strokes[id]?.ended = true; activeStroke = nil
    }
    private func resetInk() { strokes.removeAll(); activeStroke = nil }
    private func name(_ id: UUID) -> String {
        id == controller.localID ? "You" : participants.first(where: { $0.id == id.uuidString })?.name ?? "Participant"
    }
}
