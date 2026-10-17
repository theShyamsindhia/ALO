import AppKit
import SwiftUI
import ALOCore
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

    static func boardRect(image: CGSize, available: CGSize, isBlankBoard: Bool) -> CGRect {
        let base = imageRect(image: image, available: available)
        guard isBlankBoard, base.width > 0, base.height > 0 else { return base }
        // Give blank boards a generous 2.2x virtual artboard so two-finger trackpad
        // panning has room in every direction right from the start.
        let expansion: CGFloat = 2.2
        let width = base.width * expansion
        let height = base.height * expansion
        return CGRect(
            x: (available.width - width) / 2,
            y: (available.height - height) / 2,
            width: width,
            height: height
        )
    }

    static func point(_ point: CGPoint, in rect: CGRect) -> AnnotationPoint? {
        guard rect.width > 0, rect.height > 0, point.x.isFinite, point.y.isFinite else { return nil }
        return .init(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                     y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
}

enum RoomCanvasPalette {
    static let selectionBlue = Color(red: 0.22, green: 0.58, blue: 1.0)

    static let colors: [(name: String, color: Color)] = [
        ("blue", Color(red: 0.24, green: 0.56, blue: 1.0)),
        ("purple", Color(red: 0.66, green: 0.42, blue: 1.0)),
        ("green", Color(red: 0.22, green: 0.84, blue: 0.52)),
        ("yellow", Color(red: 0.98, green: 0.80, blue: 0.20)),
        ("orange", Color(red: 1.0, green: 0.54, blue: 0.20)),
        ("red", Color(red: 1.0, green: 0.34, blue: 0.38)),
        ("white", .white),
        ("black", Color(white: 0.12))
    ]

    static func swiftUIColor(for token: String) -> Color {
        colors.first(where: { $0.name == token })?.color ?? Color(red: 0.24, green: 0.56, blue: 1.0)
    }

    static func stampSymbol(for id: AnnotationStickerID) -> String {
        switch id {
        case .star: "star.fill"
        case .heart: "heart.fill"
        case .thumbsUp: "hand.thumbsup.fill"
        case .question: "questionmark.circle.fill"
        case .check: "checkmark.circle.fill"
        }
    }

    static func stampColor(for id: AnnotationStickerID) -> Color {
        switch id {
        case .star: Color(red: 0.98, green: 0.80, blue: 0.20)
        case .heart: Color(red: 1.0, green: 0.34, blue: 0.44)
        case .thumbsUp: Color(red: 0.24, green: 0.56, blue: 1.0)
        case .question: Color(red: 0.66, green: 0.42, blue: 1.0)
        case .check: Color(red: 0.22, green: 0.84, blue: 0.52)
        }
    }
}

struct NotchRoomCanvas: View {
    @ObservedObject var controller: RoomCanvasController
    let participants: [RoomParticipant]
    var onSessionChanged: (Bool) -> Void = { _ in }
    @State private var confirmation: Confirmation?

    private enum Confirmation: String, Identifiable {
        case end, clear, replace
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 8) {
            if let notice = controller.notice {
                HStack(alignment: .center, spacing: 6) {
                    Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { controller.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss canvas notice")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.07), in: Capsule())
            }
            if controller.state == .ended {
                VStack(spacing: 8) {
                    Image(systemName: "pencil.and.outline").font(.title3).foregroundStyle(.secondary)
                    Text("Canvas ended").font(.system(size: 13, weight: .semibold))
                    Text("The owner closed this canvas.").font(.caption).foregroundStyle(.secondary)
                    Button("Back to canvases") { controller.leave() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.1), in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if controller.state == nil && controller.snapshot == nil {
                discovery
            } else if controller.isPoppedOut {
                poppedOutPlaceholder
            } else {
                session
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            switch confirmation {
            case .end: Button("End for everyone", role: .destructive) { controller.leave() }
            case .clear: Button("Clear everyone's drawings", role: .destructive) { controller.submit(.clear) }
            case .replace: Button("Choose replacement image…") { controller.chooseImage() }
            case nil: EmptyView()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The shared board and drawings are temporary. This cannot be undone.") }
        .onAppear {
            controller.participants = participants
            onSessionChanged(controller.snapshot != nil || controller.state != nil)
        }
        .onChange(of: participants) { _, updated in controller.participants = updated }
        .onChange(of: controller.snapshot != nil || controller.state != nil) { _, active in onSessionChanged(active) }
        .accessibilityIdentifier("ALO.Notch.Canvas")
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .end: "End this canvas for everyone?"
        case .clear: "Clear everyone's drawings?"
        case .replace: "Replace the backdrop and clear all drawings?"
        case nil: "Canvas"
        }
    }

    private var poppedOutPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Text("Canvas is popped out")
                .font(.system(size: 13, weight: .semibold))
            Text("Collaborate in the floating black canvas, or shrink it back into the notch.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button {
                    controller.shrinkToNotch()
                } label: {
                    Label("Shrink to notch", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    controller.popOut()
                } label: {
                    Text("Bring to front")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var discovery: some View {
        let available = participants.filter { $0.canvas != nil && $0.id != controller.localID.uuidString }
        return VStack(alignment: .leading, spacing: 8) {
            if controller.isPreparing {
                ProgressView("Preparing board…").controlSize(.small)
            }
            Text(available.isEmpty
                 ? "Start a live collaborative board or drop an image"
                 : "Join a live board in this room or start a new one")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                RoomNotchTile("New board", flexibleWidth: true, action: { controller.startBlankBoard() }) {
                    Image(systemName: "square.grid.3x3.topleft.filled")
                }
                .disabled(controller.isPreparing)
                .help("Start an instant dark collaborative board")

                if available.isEmpty {
                    RoomNotchTile("Paste", flexibleWidth: true, action: { controller.pasteFromClipboard() }) {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .disabled(controller.isPreparing)
                    .help("Start a board from an image on your clipboard")
                }

                RoomNotchTile("Open image", flexibleWidth: true, action: { controller.chooseImage() }) {
                    Image(systemName: "photo")
                }
                .disabled(controller.isPreparing)
                .help("Start a collaborative canvas on an image")

                ForEach(available.prefix(2)) { person in
                    if let advertisement = person.canvas, let owner = UUID(uuidString: person.id) {
                        RoomNotchTile(person.name, flexibleWidth: true, action: { controller.join(ownerID: owner, advertisement: advertisement) }) {
                            Image(systemName: "pencil.and.outline")
                        }
                        .help(advertisement.imageName)
                        .accessibilityLabel("Join \(person.name)'s canvas")
                        .disabled(controller.isPreparing)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            guard !controller.isPreparing, urls.count == 1, let url = urls.first else { return false }
            controller.prepare(url); return true
        }
    }

    private var session: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(boardDisplayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let snapshot = controller.snapshot {
                        Text(snapshot.participants.sorted(by: { $0.uuidString < $1.uuidString }).map { name($0) }.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(-1)

                Spacer(minLength: 4)

                if controller.zoomScale != 1.0 || controller.panOffset != .zero {
                    Button {
                        controller.resetViewport()
                    } label: {
                        Text("\(Int(controller.zoomScale * 100))%")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(.white.opacity(0.11), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Reset pan & zoom to 100%")
                }

                if let snapshot = controller.snapshot {
                    if controller.isHosting {
                        RoomCanvasOwnerMenu(controller: controller, participants: participants, policy: snapshot.annotations.policy,
                                            onReplaceImage: { confirmation = .replace }, onClear: { confirmation = .clear })
                    }

                    Button {
                        controller.popOut()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.11), in: Circle())
                            .overlay { Circle().strokeBorder(.white.opacity(0.09), lineWidth: 0.75) }
                    }
                    .buttonStyle(.plain)
                    .help("Pop out borderless resizable canvas")
                    .accessibilityLabel("Pop out canvas")
                }

                Button {
                    if controller.isHosting { confirmation = .end } else { controller.leave() }
                } label: {
                    Text(controller.isHosting ? "End…" : "Leave")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(.white.opacity(0.11), in: Capsule())
                        .overlay { Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.75) }
                }
                .buttonStyle(.plain)
            }
            .controlSize(.small)

            if let image = controller.image, let snapshot = controller.snapshot {
                ZStack(alignment: .bottom) {
                    RoomCanvasInteractiveSurface(
                        controller: controller,
                        image: image,
                        snapshot: snapshot,
                        allowsViewportTransform: true
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 0.75)
                    }

                    compactFigmaToolbar
                        .padding(.bottom, 8)
                }
            } else {
                Spacer(minLength: 12)
                if case .interrupted = controller.state {} else { ProgressView("Preparing shared board…").controlSize(.small) }
                Spacer(minLength: 12)
            }

            if case .interrupted(let reason) = controller.state {
                HStack {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if !controller.isHosting { Button("Reconnect") { controller.retry() }.controlSize(.small) }
                }
            } else if controller.state == .connecting {
                ProgressView("Connecting to canvas…").controlSize(.small)
            } else if case .loadingImage(let progress) = controller.state {
                ProgressView("Receiving board", value: progress).font(.caption)
            }
        }
    }

    private var compactFigmaToolbar: some View {
        HStack(spacing: 3) {
            ForEach(RoomCanvasToolMode.allCases) { tool in
                Button {
                    controller.activeTool = tool
                } label: {
                    Image(systemName: tool == .stamp ? RoomCanvasPalette.stampSymbol(for: controller.selectedStamp) : tool.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(controller.activeTool == tool ? .white : .white.opacity(0.68))
                        .frame(width: 23, height: 24)
                        .background(
                            controller.activeTool == tool ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!controller.canDraw && tool != .hand)
                .help("\(tool.rawValue) (\(tool.shortcutLabel))")
                .accessibilityLabel(tool.rawValue)
            }

            if let selected = controller.selectedObject, selected.tool == .rectangle {
                Button {
                    let next = selected.cornerRadius < 0.02 ? 0.14 : (selected.cornerRadius < 0.25 ? 0.5 : 0.0)
                    controller.setSelectedCornerRadius(next)
                } label: {
                    Text(selected.cornerRadius < 0.01 ? "R 0" : (selected.cornerRadius >= 0.45 ? "Pill" : "R \(Int(selected.cornerRadius * 100))"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(RoomCanvasPalette.selectionBlue.opacity(0.32), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Drag the inner corner dots on the rectangle to round corners, or click to cycle Sharp / Rounded / Pill")
            }

            Menu {
                Section("Ink Color") {
                    ForEach(RoomCanvasPalette.colors.filter { $0.name != "black" }, id: \.name) { item in
                        Button {
                            controller.inkColor = item.name
                        } label: {
                            Label(item.name.capitalized, systemImage: controller.inkColor == item.name ? "checkmark.circle.fill" : "circle.fill")
                        }
                    }
                }
                Section("Stamp") {
                    ForEach(AnnotationStickerID.allCases, id: \.self) { stamp in
                        Button {
                            controller.selectedStamp = stamp
                            controller.activeTool = .stamp
                        } label: {
                            Label(stamp.rawValue.capitalized, systemImage: RoomCanvasPalette.stampSymbol(for: stamp))
                        }
                    }
                }
            } label: {
                Circle()
                    .fill(RoomCanvasPalette.swiftUIColor(for: controller.inkColor))
                    .frame(width: 14, height: 14)
                    .overlay { Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1) }
                    .frame(width: 22, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Color & Stamp")

            Button {
                controller.submit(.undo)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 23, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!controller.canDraw)
            .help("Undo (⌘Z)")
            .accessibilityLabel("Undo your last drawing")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75) }
    }

    private var boardDisplayTitle: String {
        guard let name = controller.snapshot?.image.name else { return "Shared canvas" }
        return name == RoomCanvasController.blankBoardImageName ? "Live board" : name
    }

    private func name(_ id: UUID) -> String {
        id == controller.localID ? "You" : participants.first(where: { $0.id == id.uuidString })?.name ?? "Participant"
    }
}

/// Borderless, pure-black, resizable Figma-like pop-out canvas window view.
struct RoomPopoutCanvasView: View {
    @ObservedObject var controller: RoomCanvasController
    @State private var confirmation: PopoutConfirmation?

    private enum PopoutConfirmation: String, Identifiable {
        case end, clear
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            // Pure borderless black canvas base
            Color(red: 0.024, green: 0.024, blue: 0.032)

            if let image = controller.image, let snapshot = controller.snapshot {
                RoomCanvasInteractiveSurface(
                    controller: controller,
                    image: image,
                    snapshot: snapshot,
                    allowsViewportTransform: true
                )
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Syncing board…").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }

            // Floating HUD overlays (no borders, just floating controls on the black canvas)
            VStack(spacing: 0) {
                ZStack {
                    WindowDragHandle()
                        .frame(maxWidth: .infinity, maxHeight: 52)

                    HStack(spacing: 10) {
                        // Top-left: Board identity, collaborators, & backdrop actions
                        HStack(spacing: 8) {
                            Circle()
                                .fill(controller.canDraw ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)

                            Text(controller.isBlankBoard ? "Live board" : (controller.snapshot?.image.name ?? "Canvas"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            if let snapshot = controller.snapshot {
                                Text("· \(snapshot.participants.count) in board")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)

                                if controller.isHosting {
                                    RoomCanvasOwnerMenu(
                                        controller: controller,
                                        participants: controller.participants,
                                        policy: snapshot.annotations.policy,
                                        onReplaceImage: { controller.chooseImage() },
                                        onClear: { confirmation = .clear }
                                    )
                                }
                            }

                            if controller.isHosting {
                                Button {
                                    controller.chooseImage()
                                } label: {
                                    Label("Image", systemImage: "photo")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.white.opacity(0.09), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Load or replace backdrop image")

                                Button {
                                    controller.pasteFromClipboard()
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(width: 24, height: 24)
                                        .background(.white.opacity(0.09), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Paste image from clipboard onto board")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.75), in: Capsule())
                        .overlay { Capsule().strokeBorder(.white.opacity(0.11), lineWidth: 0.75) }

                        Spacer(minLength: 12)

                        // Top-right: Zoom pill + Shrink to Notch + End/Leave
                        HStack(spacing: 6) {
                            HStack(spacing: 2) {
                                Button {
                                    controller.zoom(to: controller.zoomScale - 0.25)
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 10, weight: .bold))
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .help("Zoom out (or pinch on trackpad)")

                                Button {
                                    controller.resetViewport()
                                } label: {
                                    Text("\(Int(controller.zoomScale * 100))%")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .monospacedDigit()
                                        .frame(minWidth: 38)
                                }
                                .buttonStyle(.plain)
                                .help("Reset pan & zoom to 100% (⌘0)")

                                Button {
                                    controller.zoom(to: controller.zoomScale + 0.25)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .bold))
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .help("Zoom in (or pinch on trackpad)")
                            }
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.75), in: Capsule())
                            .overlay { Capsule().strokeBorder(.white.opacity(0.11), lineWidth: 0.75) }

                            Button {
                                controller.shrinkToNotch()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("Shrink")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .frame(height: 28)
                                .background(.black.opacity(0.78), in: Capsule())
                                .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75) }
                            }
                            .buttonStyle(.plain)
                            .help("Shrink canvas back into the notch")
                            .accessibilityLabel("Shrink canvas to notch")

                            Button {
                                if controller.isHosting { confirmation = .end } else { controller.leave() }
                            } label: {
                                Text(controller.isHosting ? "End" : "Leave")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(.black.opacity(0.75), in: Capsule())
                                    .overlay { Capsule().strokeBorder(.white.opacity(0.11), lineWidth: 0.75) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }

                Spacer(minLength: 0)

                // Bottom Figma Dock + Contextual Shape Inspector
                VStack(spacing: 8) {
                    if let selected = controller.selectedObject, selected.tool == .rectangle {
                        HStack(spacing: 10) {
                            Label("Corner radius", systemImage: "button.roundedtop.horizontal")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))

                            ForEach([(0.0, "Sharp"), (0.08, "8"), (0.20, "20"), (0.50, "Pill")], id: \.1) { preset in
                                let isSelected = abs(selected.cornerRadius - preset.0) < 0.03
                                Button {
                                    controller.setSelectedCornerRadius(preset.0)
                                } label: {
                                    Text(preset.1)
                                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                                        .foregroundStyle(isSelected ? .white : .white.opacity(0.7))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            isSelected ? RoomCanvasPalette.selectionBlue : Color.white.opacity(0.08),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }

                            Text("or drag inner corner dots")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.48))

                            Button {
                                controller.deleteSelectedObject()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.red.opacity(0.9))
                                    .frame(width: 24, height: 24)
                                    .background(.white.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Delete selected shape (Delete)")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.84), in: Capsule())
                        .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75) }
                    } else if controller.activeTool == .stamp {
                        HStack(spacing: 6) {
                            ForEach(AnnotationStickerID.allCases, id: \.self) { stamp in
                                Button {
                                    controller.selectedStamp = stamp
                                } label: {
                                    Image(systemName: RoomCanvasPalette.stampSymbol(for: stamp))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(RoomCanvasPalette.stampColor(for: stamp))
                                        .frame(width: 28, height: 28)
                                        .background(
                                            controller.selectedStamp == stamp
                                                ? Color.white.opacity(0.18)
                                                : Color.white.opacity(0.06),
                                            in: Circle()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.82), in: Capsule())
                        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.75) }
                    }

                    HStack(spacing: 6) {
                        // Tool modes
                        HStack(spacing: 4) {
                            ForEach(RoomCanvasToolMode.allCases) { tool in
                                Button {
                                    controller.activeTool = tool
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: tool == .stamp ? RoomCanvasPalette.stampSymbol(for: controller.selectedStamp) : tool.symbol)
                                            .font(.system(size: 11.5, weight: .semibold))
                                        Text(tool.rawValue)
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundStyle(controller.activeTool == tool ? .white : .white.opacity(0.72))
                                    .padding(.horizontal, 9)
                                    .frame(height: 28)
                                    .background(
                                        controller.activeTool == tool ? Color.accentColor : Color.white.opacity(0.06),
                                        in: Capsule()
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!controller.canDraw && tool != .hand)
                                .help("\(tool.rawValue) (\(tool.shortcutLabel)) · Two-finger swipe to pan")
                            }
                        }

                        // Color swatches
                        HStack(spacing: 5) {
                            ForEach(RoomCanvasPalette.colors.filter { $0.name != "black" }, id: \.name) { item in
                                Button {
                                    controller.inkColor = item.name
                                } label: {
                                    Circle()
                                        .fill(item.color)
                                        .frame(width: 16, height: 16)
                                        .overlay {
                                            Circle()
                                                .strokeBorder(.white, lineWidth: controller.inkColor == item.name ? 2 : 0.5)
                                        }
                                        .scaleEffect(controller.inkColor == item.name ? 1.12 : 1.0)
                                }
                                .buttonStyle(.plain)
                                .disabled(!controller.canDraw)
                            }
                        }
                        .padding(.horizontal, 6)

                        // Stroke thickness cycle
                        Button {
                            if controller.strokeWidth < 0.005 { controller.strokeWidth = 0.006 }
                            else if controller.strokeWidth < 0.01 { controller.strokeWidth = 0.012 }
                            else { controller.strokeWidth = 0.003 }
                        } label: {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(.white)
                                    .frame(
                                        width: controller.strokeWidth < 0.005 ? 4 : (controller.strokeWidth < 0.01 ? 6 : 9),
                                        height: controller.strokeWidth < 0.005 ? 4 : (controller.strokeWidth < 0.01 ? 6 : 9)
                                    )
                            }
                            .frame(width: 26, height: 28)
                            .background(.white.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Cycle stroke thickness")

                        // Undo & Clear
                        Button {
                            controller.submit(.undo)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))
                                .frame(width: 28, height: 28)
                                .background(.white.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!controller.canDraw)
                        .help("Undo your last action (⌘Z)")

                        if controller.isHosting {
                            Button {
                                confirmation = .clear
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(width: 28, height: 28)
                                    .background(.white.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Clear board")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.84), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75) }
                }
                .padding(.bottom, 14)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            WindowResizeGrip()
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .confirmationDialog(
            confirmation == .end ? "End this canvas for everyone?" : "Clear everyone's drawings?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
        ) {
            switch confirmation {
            case .end:
                Button("End for everyone", role: .destructive) { controller.leave() }
            case .clear:
                Button("Clear everyone's drawings", role: .destructive) { controller.submit(.clear) }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) {}
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !controller.isPreparing, urls.count == 1, let url = urls.first else { return false }
            controller.prepare(url)
            return true
        }
    }
}

private struct RoomCanvasOwnerMenu: View {
    @ObservedObject var controller: RoomCanvasController
    let participants: [RoomParticipant]
    let policy: AnnotationPolicy
    let onReplaceImage: () -> Void
    let onClear: () -> Void

    var body: some View {
        Menu {
            Toggle("Everyone can edit", isOn: Binding(get: { policy.permission == .everyone }, set: { enabled in
                var next = policy; next.permission = enabled ? .everyone : .presenterOnly
                if enabled { next.disabledIDs.removeAll() }
                controller.setPolicy(next)
            }))
            Toggle("Pause editing", isOn: Binding(get: { policy.paused }, set: { var next = policy; next.paused = $0; controller.setPolicy(next) }))
            Section("Collaborators") {
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
            Button("New blank board") { controller.startBlankBoard() }.disabled(controller.isPreparing)
            Button("Paste clipboard image") { controller.pasteFromClipboard() }.disabled(controller.isPreparing)
            Button("Change backdrop image…", action: onReplaceImage).disabled(controller.isPreparing)
            Button("Clear board…", role: .destructive, action: onClear)
        } label: {
            Image(systemName: "person.2")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.11), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Collaborator permissions & board options")
    }

    private func name(_ id: UUID) -> String {
        id == controller.localID ? "You" : participants.first(where: { $0.id == id.uuidString })?.name ?? "Participant"
    }
}

struct RoomCanvasInteractiveSurface: View {
    @ObservedObject var controller: RoomCanvasController
    let image: CGImage
    let snapshot: RoomCanvasSnapshot
    let allowsViewportTransform: Bool

    private enum CornerIndex: Int, CaseIterable {
        case topLeft = 0, topRight = 1, bottomRight = 2, bottomLeft = 3
    }

    private enum ShapeTransformKind {
        case moveBody
        case resizeCorner(CornerIndex)
        case roundCorners(CornerIndex)
        case moveEndpoint(Int)
    }

    private struct ActiveShapeEdit {
        let objectID: UUID
        let editID: UUID
        let kind: ShapeTransformKind
        let initialPoints: [AnnotationPoint]
        let initialCornerRadius: Double
        let startLocation: CGPoint
        var currentPoints: [AnnotationPoint]
        var currentCornerRadius: Double
        var lastSendNanos: UInt64
        var hudBadge: String?
    }

    private struct ActiveStroke {
        let id: UUID
        let tool: AnnotationTool
        let color: String
        let width: Double
        var points: [AnnotationPoint]
        var sentCount = 1
        var lastSentPoint: AnnotationPoint?
        var lastSendNanos: UInt64
        var ended = false
    }

    private struct DraggedSticker {
        let objectID: UUID
        var position: AnnotationPoint
        var lastSendNanos: UInt64
    }

    @State private var strokes: [UUID: ActiveStroke] = [:]
    @State private var activeStrokeID: UUID?
    @State private var draggedSticker: DraggedSticker?
    @State private var activeShapeEdit: EditStateWrapper?
    @State private var dragStartPanOffset: CGSize?

    // Value wrapper so SwiftUI updates smoothly
    private struct EditStateWrapper {
        var edit: ActiveShapeEdit
    }

    var body: some View {
        GeometryReader { geometry in
            let baseRect = RoomCanvasGeometry.boardRect(
                image: CGSize(width: image.width, height: image.height),
                available: geometry.size,
                isBlankBoard: controller.isBlankBoard
            )
            let rect = transformedRect(baseRect, in: geometry.size)

            ZStack {
                Canvas { context, size in
                    // Pure dark obsidian canvas surface + panning/zooming Figma dot grid
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(Color(red: 0.03, green: 0.03, blue: 0.04))
                    )
                    drawDotGrid(in: size, context: &context)

                    if !controller.isBlankBoard {
                        context.draw(Image(decorative: image, scale: 1), in: rect)
                    } else {
                        // Subtle artboard boundary when zoomed out
                        context.stroke(
                            Path(roundedRect: rect, cornerRadius: 12),
                            with: .color(.white.opacity(0.05)),
                            lineWidth: 1
                        )
                    }

                    for object in snapshot.annotations.objects where strokes[object.id] == nil {
                        let rendered = effectiveObject(object)
                        drawObject(rendered, in: rect, context: &context)
                    }

                    for stroke in strokes.values {
                        let preview = AnnotationObject(
                            id: stroke.id,
                            authorID: controller.localID.uuidString,
                            tool: stroke.tool,
                            points: stroke.points,
                            color: stroke.color,
                            width: stroke.width,
                            cornerRadius: 0,
                            isComplete: stroke.ended
                        )
                        drawObject(preview, in: rect, context: &context)
                    }

                    // Draw Figma selection frame, resize handles, and inner corner-radius handles
                    if let selectedID = controller.selectedObjectID,
                       let rawSelected = snapshot.annotations.objects.first(where: { $0.id == selectedID }) {
                        let selected = effectiveObject(rawSelected)
                        drawSelectionHandles(for: selected, in: rect, context: &context)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handlePointerChanged(value, in: rect)
                        }
                        .onEnded { value in
                            handlePointerEnded(value, in: rect)
                        }
                )
                .background {
                    CanvasTrackpadBridge(
                        controller: controller,
                        viewportSize: geometry.size
                    )
                }
            }
            .accessibilityLabel("Shared image: \(snapshot.image.name). \(snapshot.annotations.objects.count) drawings.")
        }
        .frame(minHeight: 120)
        .onChange(of: controller.snapshot?.annotations.sessionID) { _, _ in resetLocalState() }
        .onChange(of: controller.snapshot?.revision) { _, _ in
            let complete = Set((controller.snapshot?.annotations.objects ?? []).filter(\.isComplete).map(\.id))
            strokes = strokes.filter { !$0.value.ended || !complete.contains($0.key) }
        }
        .onChange(of: controller.rejectionID) { _, _ in resetLocalState() }
        .onChange(of: controller.canDraw) { _, enabled in
            if !enabled { finishActiveInteraction(); resetLocalState() }
        }
        .onDisappear { finishActiveInteraction() }
    }

    private func effectiveObject(_ object: AnnotationObject) -> AnnotationObject {
        var copy = object
        if let dragged = draggedSticker, dragged.objectID == object.id {
            copy.points = [dragged.position]
        }
        if let edit = activeShapeEdit?.edit, edit.objectID == object.id {
            copy.points = edit.currentPoints
            copy.cornerRadius = edit.currentCornerRadius
        }
        return copy
    }

    private func transformedRect(_ base: CGRect, in container: CGSize) -> CGRect {
        guard allowsViewportTransform, controller.zoomScale != 1.0 || controller.panOffset != .zero else {
            return base
        }
        let scale = controller.zoomScale
        let width = base.width * scale
        let height = base.height * scale
        let x = container.width / 2 - (container.width / 2 - base.minX) * scale + controller.panOffset.width
        let y = container.height / 2 - (container.height / 2 - base.minY) * scale + controller.panOffset.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Pointer & Handle Interactions

    private func handlePointerChanged(_ value: DragGesture.Value, in rect: CGRect) {
        // 1. Hand tool or Spacebar-panning always pans the canvas
        if controller.activeTool == .hand || controller.isSpacePanning {
            if dragStartPanOffset == nil {
                dragStartPanOffset = controller.panOffset
            }
            if let startPan = dragStartPanOffset {
                controller.panOffset = CGSize(
                    width: min(2_400, max(-2_400, startPan.width + value.translation.width)),
                    height: min(2_400, max(-2_400, startPan.height + value.translation.height))
                )
            }
            return
        }

        guard controller.canDraw else { return }

        // 2. Continue an active shape handle / body manipulation if one is in progress
        if var wrapper = activeShapeEdit {
            updateActiveShapeEdit(&wrapper.edit, value: value, in: rect)
            activeShapeEdit = wrapper
            return
        }

        // 3. Before starting a new stroke/shape, check if the user grabbed a handle
        //    (corner-radius dot or corner resize square) on the currently selected object!
        if activeStrokeID == nil, draggedSticker == nil,
           let selectedID = controller.selectedObjectID,
           let selected = snapshot.annotations.objects.first(where: { $0.id == selectedID }),
           let handleKind = hitTestSelectionHandle(for: selected, at: value.startLocation, in: rect) {
            let edit = ActiveShapeEdit(
                objectID: selected.id,
                editID: UUID(),
                kind: handleKind,
                initialPoints: selected.points,
                initialCornerRadius: selected.cornerRadius,
                startLocation: value.startLocation,
                currentPoints: selected.points,
                currentCornerRadius: selected.cornerRadius,
                lastSendNanos: MonotonicClock.nowNanos(),
                hudBadge: nil
            )
            var wrapper = EditStateWrapper(edit: edit)
            updateActiveShapeEdit(&wrapper.edit, value: value, in: rect)
            activeShapeEdit = wrapper
            return
        }

        // 4. Tool-specific interaction
        switch controller.activeTool {
        case .hand, .stamp:
            return

        case .select:
            if draggedSticker == nil {
                guard let startPoint = RoomCanvasGeometry.point(value.startLocation, in: rect) else { return }
                if let hitSticker = hitTestSticker(at: startPoint) {
                    controller.selectedObjectID = hitSticker.id
                    let now = MonotonicClock.nowNanos()
                    draggedSticker = DraggedSticker(objectID: hitSticker.id, position: startPoint, lastSendNanos: now)
                    controller.submit(.acquireSticker(id: hitSticker.id))
                } else if let hitShape = hitTestShape(at: startPoint, in: rect) {
                    controller.selectedObjectID = hitShape.id
                    let edit = ActiveShapeEdit(
                        objectID: hitShape.id,
                        editID: UUID(),
                        kind: .moveBody,
                        initialPoints: hitShape.points,
                        initialCornerRadius: hitShape.cornerRadius,
                        startLocation: value.startLocation,
                        currentPoints: hitShape.points,
                        currentCornerRadius: hitShape.cornerRadius,
                        lastSendNanos: MonotonicClock.nowNanos(),
                        hudBadge: nil
                    )
                    var wrapper = EditStateWrapper(edit: edit)
                    updateActiveShapeEdit(&wrapper.edit, value: value, in: rect)
                    activeShapeEdit = wrapper
                    return
                } else {
                    controller.selectedObjectID = nil
                    return
                }
            }
            guard var dragged = draggedSticker,
                  let point = RoomCanvasGeometry.point(value.location, in: rect) else { return }
            dragged.position = point
            let now = MonotonicClock.nowNanos()
            if now - min(now, dragged.lastSendNanos) >= 50_000_000,
               let lease = snapshot.annotations.leases.first(where: {
                   $0.objectID == dragged.objectID && $0.actorID == controller.localID.uuidString
               }) {
                controller.submit(.moveSticker(id: dragged.objectID, leaseID: lease.id, position: point))
                dragged.lastSendNanos = now
            }
            draggedSticker = dragged

        case .pen, .arrow, .rectangle, .ellipse:
            guard let tool = controller.activeTool.annotationTool else { return }
            if activeStrokeID == nil {
                guard rect.contains(value.startLocation), strokes.count < 8,
                      let point = RoomCanvasGeometry.point(value.startLocation, in: rect) else { return }
                let id = UUID()
                activeStrokeID = id
                controller.selectedObjectID = nil
                strokes[id] = ActiveStroke(
                    id: id,
                    tool: tool,
                    color: controller.inkColor,
                    width: controller.strokeWidth,
                    points: [point],
                    sentCount: 1,
                    lastSentPoint: point,
                    lastSendNanos: MonotonicClock.nowNanos()
                )
                controller.submit(.beginDrawing(
                    id: id,
                    tool: tool,
                    points: [point],
                    color: controller.inkColor,
                    width: controller.strokeWidth
                ))
            }
            guard let id = activeStrokeID,
                  var stroke = strokes[id],
                  var point = RoomCanvasGeometry.point(value.location, in: rect) else { return }

            if stroke.tool == .pencil {
                guard stroke.points.count < AnnotationAuthority.maximumPoints,
                      point != stroke.points.last else { return }
                stroke.points.append(point)
            } else {
                if NSEvent.modifierFlags.contains(.shift), let start = stroke.points.first {
                    point = shiftConstrainedPoint(from: start, to: point, tool: stroke.tool, in: rect)
                }
                stroke.points = [stroke.points[0], point]
            }
            strokes[id] = stroke
            let now = MonotonicClock.nowNanos()
            if now - min(now, stroke.lastSendNanos) >= 50_000_000 {
                flushStroke(id, now: now)
            }
        }
    }

    private func handlePointerEnded(_ value: DragGesture.Value, in rect: CGRect) {
        if dragStartPanOffset != nil {
            dragStartPanOffset = nil
            return
        }

        guard controller.canDraw else { return }

        if let wrapper = activeShapeEdit {
            let edit = wrapper.edit
            if edit.currentPoints != edit.initialPoints || abs(edit.currentCornerRadius - edit.initialCornerRadius) > 0.0005 {
                controller.submit(.updateShape(
                    id: edit.objectID,
                    points: edit.currentPoints,
                    cornerRadius: edit.currentCornerRadius,
                    editID: edit.editID
                ))
            }
            activeShapeEdit = nil
            return
        }

        switch controller.activeTool {
        case .hand:
            return

        case .stamp:
            guard rect.contains(value.location),
                  let point = RoomCanvasGeometry.point(value.location, in: rect) else { return }
            let id = UUID()
            controller.submit(.placeSticker(
                id: id,
                stickerID: controller.selectedStamp,
                position: point,
                ttl: .threeHundred
            ))
            controller.selectedObjectID = id

        case .select:
            if let dragged = draggedSticker {
                if let lease = snapshot.annotations.leases.first(where: {
                    $0.objectID == dragged.objectID && $0.actorID == controller.localID.uuidString
                }) {
                    controller.submit(.moveSticker(id: dragged.objectID, leaseID: lease.id, position: dragged.position))
                    controller.submit(.releaseSticker(id: dragged.objectID, leaseID: lease.id))
                }
                draggedSticker = nil
            } else if hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y) < 5,
                      let point = RoomCanvasGeometry.point(value.location, in: rect) {
                if let hit = hitTestShape(at: point, in: rect) ?? hitTestSticker(at: point) {
                    controller.selectedObjectID = hit.id
                } else {
                    controller.selectedObjectID = nil
                }
            }

        case .pen, .arrow, .rectangle, .ellipse:
            if let id = activeStrokeID, let stroke = strokes[id] {
                let wasTinyClick = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y) < 4
                finishActiveStroke()
                if stroke.tool != .pencil {
                    if wasTinyClick, let point = RoomCanvasGeometry.point(value.location, in: rect),
                       let existing = hitTestShape(at: point, in: rect), existing.id != id {
                        controller.selectedObjectID = existing.id
                    } else {
                        // Auto-select the newly drawn shape so its corner-radius & resize handles appear immediately!
                        controller.selectedObjectID = id
                    }
                }
            }
        }
    }

    // MARK: - Figma Corner-Radius & Resize Math

    private func updateActiveShapeEdit(_ edit: inout ActiveShapeEdit, value: DragGesture.Value, in rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }

        switch edit.kind {
        case .moveBody:
            let dx = Double(value.translation.width / rect.width)
            let dy = Double(value.translation.height / rect.height)
            guard !edit.initialPoints.isEmpty else { return }
            let xs = edit.initialPoints.map(\.x)
            let ys = edit.initialPoints.map(\.y)
            let clampedDX = min(1 - (xs.max() ?? 1), max(-(xs.min() ?? 0), dx))
            let clampedDY = min(1 - (ys.max() ?? 1), max(-(ys.min() ?? 0), dy))
            edit.currentPoints = edit.initialPoints.map {
                AnnotationPoint(x: min(1, max(0, $0.x + clampedDX)), y: min(1, max(0, $0.y + clampedDY)))
            }
            edit.hudBadge = nil

        case .moveEndpoint(let index):
            guard edit.initialPoints.count == 2,
                  var point = RoomCanvasGeometry.point(value.location, in: rect) else { return }
            let anchor = edit.initialPoints[1 - index]
            if NSEvent.modifierFlags.contains(.shift) {
                point = shiftConstrainedPoint(from: anchor, to: point, tool: .arrow, in: rect)
            }
            var updated = edit.initialPoints
            updated[index] = point
            edit.currentPoints = updated
            edit.hudBadge = nil

        case .resizeCorner(let corner):
            guard edit.initialPoints.count >= 2,
                  let pointer = RoomCanvasGeometry.point(value.location, in: rect) else { return }
            let p0 = edit.initialPoints[0]
            let p1 = edit.initialPoints[edit.initialPoints.count - 1]
            let minX = min(p0.x, p1.x), maxX = max(p0.x, p1.x)
            let minY = min(p0.y, p1.y), maxY = max(p0.y, p1.y)

            let anchor: AnnotationPoint
            switch corner {
            case .topLeft: anchor = AnnotationPoint(x: maxX, y: maxY)
            case .topRight: anchor = AnnotationPoint(x: minX, y: maxY)
            case .bottomRight: anchor = AnnotationPoint(x: minX, y: minY)
            case .bottomLeft: anchor = AnnotationPoint(x: maxX, y: minY)
            }

            var moving = pointer
            if NSEvent.modifierFlags.contains(.shift) {
                moving = shiftConstrainedPoint(from: anchor, to: pointer, tool: .rectangle, in: rect)
            }
            edit.currentPoints = [anchor, moving]
            let wPx = Int(round(abs(moving.x - anchor.x) * rect.width))
            let hPx = Int(round(abs(moving.y - anchor.y) * rect.height))
            edit.hudBadge = "\(wPx) × \(hPx)"

        case .roundCorners(let corner):
            guard edit.initialPoints.count >= 2 else { return }
            let box = screenBoundingBox(for: edit.initialPoints, in: rect)
            let shortSide = min(box.width, box.height)
            guard shortSide > 4 else { return }

            let cornerPoint: CGPoint
            switch corner {
            case .topLeft: cornerPoint = CGPoint(x: box.minX, y: box.minY)
            case .topRight: cornerPoint = CGPoint(x: box.maxX, y: box.minY)
            case .bottomRight: cornerPoint = CGPoint(x: box.maxX, y: box.maxY)
            case .bottomLeft: cornerPoint = CGPoint(x: box.minX, y: box.maxY)
            }

            let dx = max(0, (corner == .topLeft || corner == .bottomLeft)
                         ? (value.location.x - cornerPoint.x)
                         : (cornerPoint.x - value.location.x))
            let dy = max(0, (corner == .topLeft || corner == .topRight)
                         ? (value.location.y - cornerPoint.y)
                         : (cornerPoint.y - value.location.y))
            let inwardDist = min(dx, dy) > 0 ? (dx + dy) * 0.5 : max(dx, dy) * 0.5
            let rawNormalized = Double(inwardDist / shortSide)
            // Snap cleanly to 0 (sharp 90° corners) when dragged near the corner
            let snapped = inwardDist < 4.5 ? 0.0 : min(0.5, max(0.0, rawNormalized))
            edit.currentCornerRadius = snapped
            let radiusPx = Int(round(snapped * Double(shortSide)))
            edit.hudBadge = radiusPx == 0 ? "Sharp (0)" : "Radius \(radiusPx)"
        }

        let now = MonotonicClock.nowNanos()
        if now - min(now, edit.lastSendNanos) >= 50_000_000 {
            controller.submit(.updateShape(
                id: edit.objectID,
                points: edit.currentPoints,
                cornerRadius: edit.currentCornerRadius,
                editID: edit.editID
            ))
            edit.lastSendNanos = now
        }
    }

    private func shiftConstrainedPoint(from start: AnnotationPoint, to end: AnnotationPoint, tool: AnnotationTool, in rect: CGRect) -> AnnotationPoint {
        let startPx = CGPoint(x: rect.minX + start.x * rect.width, y: rect.minY + start.y * rect.height)
        let endPx = CGPoint(x: rect.minX + end.x * rect.width, y: rect.minY + end.y * rect.height)
        let dx = endPx.x - startPx.x
        let dy = endPx.y - startPx.y

        if tool == .arrow {
            let angle = atan2(dy, dx)
            let snappedAngle = (angle / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            let snappedPx = CGPoint(x: startPx.x + cos(snappedAngle) * length, y: startPx.y + sin(snappedAngle) * length)
            return RoomCanvasGeometry.point(snappedPx, in: rect) ?? end
        } else {
            let side = max(abs(dx), abs(dy))
            let snappedPx = CGPoint(
                x: startPx.x + (dx >= 0 ? side : -side),
                y: startPx.y + (dy >= 0 ? side : -side)
            )
            return RoomCanvasGeometry.point(snappedPx, in: rect) ?? end
        }
    }

    private func screenBoundingBox(for points: [AnnotationPoint], in rect: CGRect) -> CGRect {
        guard let first = points.first else { return .zero }
        let last = points.last ?? first
        let a = CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height)
        let b = CGPoint(x: rect.minX + last.x * rect.width, y: rect.minY + last.y * rect.height)
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: max(2, abs(b.x - a.x)),
            height: max(2, abs(b.y - a.y))
        )
    }

    private func cornerRadiusHandlePositions(for box: CGRect, cornerRadius: Double) -> [(CornerIndex, CGPoint)] {
        let shortSide = min(box.width, box.height)
        guard shortSide >= 24 else { return [] }
        let radiusPx = CGFloat(cornerRadius) * shortSide
        let inset = min(shortSide * 0.42, max(12, radiusPx))
        return [
            (.topLeft, CGPoint(x: box.minX + inset, y: box.minY + inset)),
            (.topRight, CGPoint(x: box.maxX - inset, y: box.minY + inset)),
            (.bottomRight, CGPoint(x: box.maxX - inset, y: box.maxY - inset)),
            (.bottomLeft, CGPoint(x: box.minX + inset, y: box.maxY - inset))
        ]
    }

    private func outerCornerPositions(for box: CGRect) -> [(CornerIndex, CGPoint)] {
        [
            (.topLeft, CGPoint(x: box.minX, y: box.minY)),
            (.topRight, CGPoint(x: box.maxX, y: box.minY)),
            (.bottomRight, CGPoint(x: box.maxX, y: box.maxY)),
            (.bottomLeft, CGPoint(x: box.minX, y: box.maxY))
        ]
    }

    private func hitTestSelectionHandle(for object: AnnotationObject, at location: CGPoint, in rect: CGRect) -> ShapeTransformKind? {
        switch object.tool {
        case .rectangle:
            let box = screenBoundingBox(for: object.points, in: rect)
            // 1. Check inner corner-radius handles first
            for (corner, center) in cornerRadiusHandlePositions(for: box, cornerRadius: object.cornerRadius) {
                if hypot(location.x - center.x, location.y - center.y) <= 10 {
                    return .roundCorners(corner)
                }
            }
            // 2. Check outer corner resize handles
            for (corner, pt) in outerCornerPositions(for: box) {
                if hypot(location.x - pt.x, location.y - pt.y) <= 10 {
                    return .resizeCorner(corner)
                }
            }
            return nil

        case .ellipse:
            let box = screenBoundingBox(for: object.points, in: rect)
            for (corner, pt) in outerCornerPositions(for: box) {
                if hypot(location.x - pt.x, location.y - pt.y) <= 10 {
                    return .resizeCorner(corner)
                }
            }
            return nil

        case .arrow:
            guard object.points.count == 2 else { return nil }
            for index in 0..<2 {
                let p = object.points[index]
                let screenPt = CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                if hypot(location.x - screenPt.x, location.y - screenPt.y) <= 10 {
                    return .moveEndpoint(index)
                }
            }
            return nil

        default:
            return nil
        }
    }

    private func hitTestSticker(at point: AnnotationPoint) -> AnnotationObject? {
        snapshot.annotations.objects.reversed().first { object in
            guard object.tool == .sticker, let center = object.points.first else { return false }
            return hypot(center.x - point.x, center.y - point.y) <= 0.055
        }
    }

    private func hitTestShape(at point: AnnotationPoint, in rect: CGRect) -> AnnotationObject? {
        let screenPt = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        return snapshot.annotations.objects.reversed().first { object in
            guard object.tool != .sticker else { return false }
            if object.tool == .rectangle || object.tool == .ellipse {
                let box = screenBoundingBox(for: object.points, in: rect).insetBy(dx: -8, dy: -8)
                return box.contains(screenPt)
            }
            if object.tool == .arrow, object.points.count >= 2 {
                let a = CGPoint(x: rect.minX + object.points[0].x * rect.width, y: rect.minY + object.points[0].y * rect.height)
                let b = CGPoint(x: rect.minX + object.points[object.points.count - 1].x * rect.width,
                                y: rect.minY + object.points[object.points.count - 1].y * rect.height)
                return distanceFromPoint(screenPt, toSegment: (a, b)) <= 10
            }
            return object.points.contains {
                let pt = CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
                return hypot(pt.x - screenPt.x, pt.y - screenPt.y) <= 10
            }
        }
    }

    private func distanceFromPoint(_ p: CGPoint, toSegment segment: (CGPoint, CGPoint)) -> CGFloat {
        let (v, w) = segment
        let l2 = pow(w.x - v.x, 2) + pow(w.y - v.y, 2)
        if l2 == 0 { return hypot(p.x - v.x, p.y - v.y) }
        let t = max(0, min(1, ((p.x - v.x) * (w.x - v.x) + (p.y - v.y) * (w.y - v.y)) / l2))
        let projection = CGPoint(x: v.x + t * (w.x - v.x), y: v.y + t * (w.y - v.y))
        return hypot(p.x - projection.x, p.y - projection.y)
    }

    private func flushStroke(_ id: UUID, now: UInt64) {
        guard var stroke = strokes[id] else { return }
        if stroke.tool == .pencil {
            guard stroke.sentCount < stroke.points.count else { return }
            controller.submit(.appendDrawing(id: id, points: Array(stroke.points.dropFirst(stroke.sentCount))))
            stroke.sentCount = stroke.points.count
            stroke.lastSendNanos = now
            strokes[id] = stroke
        } else if let endPoint = stroke.points.last, stroke.points.count >= 2, endPoint != stroke.lastSentPoint {
            controller.submit(.appendDrawing(id: id, points: [endPoint]))
            stroke.lastSentPoint = endPoint
            stroke.lastSendNanos = now
            strokes[id] = stroke
        }
    }

    private func finishActiveStroke() {
        guard let id = activeStrokeID else { return }
        flushStroke(id, now: MonotonicClock.nowNanos())
        controller.submit(.endDrawing(id: id))
        strokes[id]?.ended = true
        activeStrokeID = nil
    }

    private func finishActiveInteraction() {
        finishActiveStroke()
        if let dragged = draggedSticker {
            if let lease = snapshot.annotations.leases.first(where: {
                $0.objectID == dragged.objectID && $0.actorID == controller.localID.uuidString
            }) {
                controller.submit(.releaseSticker(id: dragged.objectID, leaseID: lease.id))
            }
            draggedSticker = nil
        }
        activeShapeEdit = nil
        dragStartPanOffset = nil
    }

    private func resetLocalState() {
        strokes.removeAll()
        activeStrokeID = nil
        draggedSticker = nil
        activeShapeEdit = nil
        dragStartPanOffset = nil
    }

    // MARK: - Rendering

    private func drawDotGrid(in size: CGSize, context: inout GraphicsContext) {
        let baseStep: CGFloat = 24
        let step = max(14, min(64, baseStep * controller.zoomScale))
        let offsetX = controller.panOffset.width.truncatingRemainder(dividingBy: step)
        let offsetY = controller.panOffset.height.truncatingRemainder(dividingBy: step)
        let startX = offsetX >= 0 ? offsetX : offsetX + step
        let startY = offsetY >= 0 ? offsetY : offsetY + step

        var path = Path()
        for y in stride(from: startY, to: size.height, by: step) {
            for x in stride(from: startX, to: size.width, by: step) {
                path.addEllipse(in: CGRect(x: x - 0.85, y: y - 0.85, width: 1.7, height: 1.7))
            }
        }
        context.fill(path, with: .color(.white.opacity(0.10)))
    }

    private func drawObject(_ object: AnnotationObject, in rect: CGRect, context: inout GraphicsContext) {
        guard let first = object.points.first else { return }
        let start = CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height)
        let thickness = max(1.5, min(rect.width, rect.height) * object.width)
        let color = RoomCanvasPalette.swiftUIColor(for: object.color)

        switch object.tool {
        case .pencil:
            var path = Path()
            if object.points.count == 1 {
                path.addEllipse(in: CGRect(x: start.x - thickness / 2, y: start.y - thickness / 2, width: thickness, height: thickness))
                context.fill(path, with: .color(color))
            } else {
                path.move(to: start)
                for p in object.points.dropFirst() {
                    path.addLine(to: CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height))
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
            }

        case .arrow:
            let last = object.points.last ?? first
            let end = CGPoint(x: rect.minX + last.x * rect.width, y: rect.minY + last.y * rect.height)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            if length > 4 {
                let angle = atan2(dy, dx)
                let headLength = max(9, thickness * 3.2)
                let wing1 = CGPoint(
                    x: end.x - headLength * cos(angle - .pi / 6),
                    y: end.y - headLength * sin(angle - .pi / 6)
                )
                let wing2 = CGPoint(
                    x: end.x - headLength * cos(angle + .pi / 6),
                    y: end.y - headLength * sin(angle + .pi / 6)
                )
                path.move(to: wing1)
                path.addLine(to: end)
                path.addLine(to: wing2)
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))

        case .rectangle:
            let box = screenBoundingBox(for: object.points, in: rect)
            let shortSide = min(box.width, box.height)
            // Sharp by default (cornerRadius == 0); smoothly rounded up to pill (0.5 * shortSide)
            let radiusPx = CGFloat(min(0.5, max(0, object.cornerRadius))) * shortSide
            let shape = radiusPx < 0.5
                ? Path(box)
                : Path(roundedRect: box, cornerRadius: radiusPx, style: .continuous)
            context.fill(shape, with: .color(color.opacity(0.11)))
            context.stroke(
                shape,
                with: .color(color),
                style: StrokeStyle(lineWidth: thickness, lineCap: .square, lineJoin: radiusPx < 0.5 ? .miter : .round)
            )

        case .ellipse:
            let box = screenBoundingBox(for: object.points, in: rect)
            let shape = Path(ellipseIn: box)
            context.fill(shape, with: .color(color.opacity(0.11)))
            context.stroke(shape, with: .color(color), style: StrokeStyle(lineWidth: thickness))

        case .sticker:
            let stamp = object.stickerID ?? .star
            let badgeRadius = max(13, min(rect.width, rect.height) * 0.036)
            let badgeRect = CGRect(
                x: start.x - badgeRadius,
                y: start.y - badgeRadius,
                width: badgeRadius * 2,
                height: badgeRadius * 2
            )
            let badgePath = Path(ellipseIn: badgeRect)
            context.fill(badgePath, with: .color(.black.opacity(0.75)))
            context.stroke(badgePath, with: .color(RoomCanvasPalette.stampColor(for: stamp).opacity(0.85)), lineWidth: 1.5)
            let symbol = Text(Image(systemName: RoomCanvasPalette.stampSymbol(for: stamp)))
                .font(.system(size: badgeRadius * 1.05, weight: .bold))
                .foregroundStyle(RoomCanvasPalette.stampColor(for: stamp))
            context.draw(symbol, at: start, anchor: .center)
        }
    }

    private func drawSelectionHandles(for object: AnnotationObject, in rect: CGRect, context: inout GraphicsContext) {
        let accent = RoomCanvasPalette.selectionBlue

        switch object.tool {
        case .rectangle, .ellipse:
            let box = screenBoundingBox(for: object.points, in: rect)
            // Selection bounding frame
            context.stroke(Path(box), with: .color(accent.opacity(0.85)), lineWidth: 1)

            // 4 Outer corner resize handles (Figma white squares with blue border)
            for (_, cornerPt) in outerCornerPositions(for: box) {
                let handleRect = CGRect(x: cornerPt.x - 4, y: cornerPt.y - 4, width: 8, height: 8)
                context.fill(Path(handleRect), with: .color(.white))
                context.stroke(Path(handleRect), with: .color(accent), lineWidth: 1.5)
            }

            // 4 Inner corner-radius handles for rectangles (Figma circular dots inset from corners)
            if object.tool == .rectangle {
                for (_, radiusPt) in cornerRadiusHandlePositions(for: box, cornerRadius: object.cornerRadius) {
                    let dotRect = CGRect(x: radiusPt.x - 4.2, y: radiusPt.y - 4.2, width: 8.4, height: 8.4)
                    let dotPath = Path(ellipseIn: dotRect)
                    context.fill(dotPath, with: .color(.white))
                    context.stroke(dotPath, with: .color(accent), lineWidth: 1.75)
                }
            }

            // Live Figma HUD badge below the shape while resizing or rounding corners
            let badgeText: String
            if let activeBadge = activeShapeEdit?.edit.hudBadge {
                badgeText = activeBadge
            } else if object.tool == .rectangle {
                let shortSide = min(box.width, box.height)
                let rPx = Int(round(Double(shortSide) * object.cornerRadius))
                badgeText = rPx == 0 ? "\(Int(round(box.width))) × \(Int(round(box.height))) · Sharp" : "\(Int(round(box.width))) × \(Int(round(box.height))) · R \(rPx)"
            } else {
                badgeText = "\(Int(round(box.width))) × \(Int(round(box.height)))"
            }
            let badgeCenter = CGPoint(x: box.midX, y: box.maxY + 14)
            let pillWidth = CGFloat(max(54, badgeText.count * 6 + 14))
            let pillRect = CGRect(x: badgeCenter.x - pillWidth / 2, y: badgeCenter.y - 8, width: pillWidth, height: 16)
            context.fill(Path(roundedRect: pillRect, cornerRadius: 5), with: .color(accent))
            context.draw(
                Text(badgeText).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundStyle(.white),
                at: badgeCenter,
                anchor: .center
            )

        case .arrow:
            guard object.points.count == 2 else { return }
            for p in object.points {
                let pt = CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                let handleRect = CGRect(x: pt.x - 4.5, y: pt.y - 4.5, width: 9, height: 9)
                context.fill(Path(ellipseIn: handleRect), with: .color(.white))
                context.stroke(Path(ellipseIn: handleRect), with: .color(accent), lineWidth: 1.5)
            }

        default:
            break
        }
    }
}

/// AppKit trackpad & keyboard bridge for two-finger trackpad panning, cursor-centered pinch zoom,
/// Spacebar hand-panning, and single-key Figma tool shortcuts.
private struct CanvasTrackpadBridge: NSViewRepresentable {
    let controller: RoomCanvasController
    let viewportSize: CGSize

    func makeNSView(context: Context) -> TrackpadEventNSView {
        let view = TrackpadEventNSView()
        view.controller = controller
        view.viewportSize = viewportSize
        return view
    }

    func updateNSView(_ nsView: TrackpadEventNSView, context: Context) {
        nsView.controller = controller
        nsView.viewportSize = viewportSize
    }

    final class TrackpadEventNSView: NSView {
        weak var controller: RoomCanvasController?
        var viewportSize: CGSize = .zero
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitorIfNeeded()
            } else {
                removeMonitor()
            }
        }

        deinit {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func installMonitorIfNeeded() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .magnify, .smartMagnify, .keyDown, .keyUp]
            ) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        private func removeMonitor() {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }

        private func isCursorInsideCanvas(_ event: NSEvent) -> Bool {
            guard let window = self.window, event.window === window else { return false }
            let localPoint = convert(event.locationInWindow, from: nil)
            return bounds.contains(localPoint)
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let controller else { return event }

            switch event.type {
            case .scrollWheel:
                guard isCursorInsideCanvas(event) else { return event }
                let localPoint = convert(event.locationInWindow, from: nil)
                let localTopLeft = CGPoint(x: localPoint.x, y: bounds.height - localPoint.y)

                if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                    // Command/Option + two-finger scroll = smooth cursor-centered zoom
                    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.006 : event.scrollingDeltaY * 0.04
                    controller.zoom(to: controller.zoomScale * (1.0 + delta), anchor: localTopLeft, in: viewportSize)
                } else {
                    // Two-finger trackpad swipe = smooth pan across the canvas
                    let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
                    controller.pan(by: CGSize(
                        width: event.scrollingDeltaX * multiplier,
                        height: event.scrollingDeltaY * multiplier
                    ))
                }
                return nil

            case .magnify:
                guard isCursorInsideCanvas(event) else { return event }
                let localPoint = convert(event.locationInWindow, from: nil)
                let localTopLeft = CGPoint(x: localPoint.x, y: bounds.height - localPoint.y)
                controller.zoom(
                    to: controller.zoomScale * (1.0 + event.magnification),
                    anchor: localTopLeft,
                    in: viewportSize
                )
                return nil

            case .smartMagnify:
                guard isCursorInsideCanvas(event) else { return event }
                let localPoint = convert(event.locationInWindow, from: nil)
                let localTopLeft = CGPoint(x: localPoint.x, y: bounds.height - localPoint.y)
                let nextScale: CGFloat = abs(controller.zoomScale - 1.0) < 0.1 ? 2.0 : 1.0
                if nextScale == 1.0 {
                    controller.resetViewport()
                } else {
                    controller.zoom(to: nextScale, anchor: localTopLeft, in: viewportSize)
                }
                return nil

            case .keyDown:
                guard let window = self.window, window.isKeyWindow else { return event }
                // Don't hijack typing if a text field is focused
                if window.firstResponder is NSTextView { return event }

                if event.keyCode == 49 { // Spacebar = temporary hand pan
                    controller.isSpacePanning = true
                    return nil
                }
                if event.modifierFlags.contains(.command) {
                    if event.charactersIgnoringModifiers?.lowercased() == "z" {
                        controller.submit(.undo)
                        return nil
                    }
                    if event.charactersIgnoringModifiers == "0" {
                        controller.resetViewport()
                        return nil
                    }
                    return event
                }
                switch event.keyCode {
                case 51, 117: // Delete / Forward Delete
                    if controller.selectedObjectID != nil {
                        controller.deleteSelectedObject()
                        return nil
                    }
                case 53: // Escape
                    if controller.selectedObjectID != nil {
                        controller.selectedObjectID = nil
                        return nil
                    }
                default:
                    break
                }
                if let key = event.charactersIgnoringModifiers?.lowercased() {
                    switch key {
                    case "v": controller.activeTool = .select; return nil
                    case "h": controller.activeTool = .hand; return nil
                    case "r": controller.activeTool = .rectangle; return nil
                    case "o": controller.activeTool = .ellipse; return nil
                    case "a", "l": controller.activeTool = .arrow; return nil
                    case "p": controller.activeTool = .pen; return nil
                    case "s": controller.activeTool = .stamp; return nil
                    default: break
                    }
                }
                return event

            case .keyUp:
                if event.keyCode == 49 {
                    controller.isSpacePanning = false
                }
                return event

            default:
                return event
            }
        }
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableHeaderNSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableHeaderNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct WindowResizeGrip: View {
    @State private var initialFrame: NSRect?
    @State private var initialMouseLocation: NSPoint?

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for offset: CGFloat in [4, 8, 12] {
                path.move(to: CGPoint(x: size.width - offset, y: size.height - 2))
                path.addLine(to: CGPoint(x: size.width - 2, y: size.height - offset))
            }
            context.stroke(path, with: .color(.white.opacity(0.32)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
        .help("Drag to resize canvas")
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard let window = NSApp.keyWindow else { return }
                    let mouse = NSEvent.mouseLocation
                    if initialFrame == nil {
                        initialFrame = window.frame
                        initialMouseLocation = mouse
                    }
                    guard let startFrame = initialFrame, let startMouse = initialMouseLocation else { return }
                    let dx = mouse.x - startMouse.x
                    let dy = mouse.y - startMouse.y
                    let newWidth = max(window.minSize.width, startFrame.width + dx)
                    let newHeight = max(window.minSize.height, startFrame.height - dy)
                    let newOriginY = startFrame.maxY - newHeight
                    window.setFrame(
                        NSRect(x: startFrame.minX, y: newOriginY, width: newWidth, height: newHeight),
                        display: true
                    )
                }
                .onEnded { _ in
                    initialFrame = nil
                    initialMouseLocation = nil
                }
        )
    }
}
