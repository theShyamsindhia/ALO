import AppKit
import SwiftUI
import AVKit
import ImageIO

enum SharedMediaKind {
    case image, movie, audio
    static func candidate(_ name: String) -> Self? {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff": return .image
        case "mp4", "mov", "m4v": return .movie
        case "mp3", "m4a", "wav", "aiff", "flac", "aac": return .audio
        default: return nil
        }
    }
    static func validate(_ url: URL) async -> Self? {
        guard let candidate = candidate(url.lastPathComponent) else { return nil }
        if candidate == .image {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16000, height <= 16000,
                  Int64(width) * Int64(height) <= 40_000_000,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
            return .image
        }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }
        let videos = try? await asset.loadTracks(withMediaType: .video)
        if videos?.isEmpty == false { return .movie }
        let audio = try? await asset.loadTracks(withMediaType: .audio)
        return audio?.isEmpty == false ? .audio : nil
    }
}

private final class MediaPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SharedMediaWindow: NSObject, NSWindowDelegate, ObservableObject {
    let url: URL
    let sender: String
    let kind: SharedMediaKind
    let player: AVPlayer?
    @Published var editingImage: NSImage?
    @Published var strokes: [[CGPoint]] = []
    @Published var pinned = true
    @Published var error: String?
    @Published var preparingAnnotation = false
    private var panel: NSPanel!
    private let sendBack: (URL) -> Void
    private let closed: () -> Void
    private var generatedFiles: [URL] = []

    init(url: URL, sender: String, kind: SharedMediaKind, sendBack: @escaping (URL) -> Void, closed: @escaping () -> Void) {
        self.url = url; self.sender = sender; self.kind = kind
        self.sendBack = sendBack; self.closed = closed
        player = kind == .image ? nil : AVPlayer(url: url)
        super.init()
        panel = MediaPopupPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: kind == .audio ? 220 : 440),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.hasShadow = true; panel.minSize = NSSize(width: 360, height: 200)
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.title = "\(url.lastPathComponent) from \(sender)"
        panel.contentView = NSHostingView(rootView: SharedMediaView(model: self))
        panel.center(); panel.orderFrontRegardless()
    }
    func close() { panel.close() }
    func windowWillClose(_ notification: Notification) {
        player?.pause()
        closed()
    }
    func togglePin() { pinned.toggle(); panel.level = pinned ? .floating : .normal }
    func move(to screen: NSScreen) {
        let bounds = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(frame.width, bounds.width)
        frame.size.height = min(frame.height, bounds.height)
        frame.origin = CGPoint(x: bounds.midX - frame.width / 2, y: bounds.midY - frame.height / 2)
        panel.setFrame(frame, display: true, animate: true)
        panel.orderFrontRegardless()
    }
    func save() {
        do {
            let source = editingImage == nil ? url : try annotatedURL()
            let picker = NSSavePanel(); picker.nameFieldStringValue = source.lastPathComponent
            picker.begin { response in
                guard response == .OK, let target = picker.url else { return }
                do {
                    // The save panel obtained explicit overwrite approval.
                    let data = try Data(contentsOf: source, options: .mappedIfSafe)
                    try data.write(to: target, options: .atomic)
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func annotate() {
        guard !preparingAnnotation else { return }
        if kind == .image { editingImage = NSImage(contentsOf: url); return }
        guard kind == .movie, let player else { return }
        player.pause(); preparingAnnotation = true
        let time = player.currentTime()
        Task {
            defer { preparingAnnotation = false }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 2560, height: 2560)
            do {
                let frame = try await generator.image(at: time)
                editingImage = NSImage(cgImage: frame.image, size: .zero)
            } catch { self.error = "Couldn’t capture this frame: \(error.localizedDescription)" }
        }
    }
    func returnImage() {
        do { sendBack(try annotatedURL()) }
        catch { self.error = error.localizedDescription }
    }
    private func annotatedURL() throws -> URL {
        guard let image = editingImage else { throw CocoaError(.fileReadCorruptFile) }
        let scale = min(1, 2560 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered = NSImage(size: size, flipped: true) { rect in
            image.draw(in: rect)
            NSColor.systemRed.setStroke()
            for stroke in self.strokes where !stroke.isEmpty {
                let path = NSBezierPath(); path.lineWidth = max(2, size.width / 240); path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.move(to: CGPoint(x: stroke[0].x * size.width, y: stroke[0].y * size.height))
                for point in stroke.dropFirst() { path.line(to: CGPoint(x: point.x * size.width, y: point.y * size.height)) }
                path.stroke()
            }
            return true
        }
        guard let tiff = rendered.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let target = url.deletingLastPathComponent().appendingPathComponent("Annotation-\(UUID().uuidString.prefix(8)).png")
        try png.write(to: target, options: .atomic)
        generatedFiles.append(target)
        return target
    }
}

private struct SharedMediaView: View {
    @ObservedObject var model: SharedMediaWindow
    @State private var hovering = false
    @State private var drawing = false
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = model.editingImage {
                    GeometryReader { geometry in
                        let size = fitted(image.size, in: geometry.size)
                        ZStack {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            Canvas { context, bounds in
                                for stroke in model.strokes {
                                    var path = Path()
                                    for (index, point) in stroke.enumerated() {
                                        let position = CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
                                        if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                                    }
                                    context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                                }
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                if !drawing { model.strokes.append([]); drawing = true }
                                let point = CGPoint(x: min(1, max(0, value.location.x / size.width)), y: min(1, max(0, value.location.y / size.height)))
                                model.strokes[model.strokes.count - 1].append(point)
                            }.onEnded { _ in drawing = false })
                        }.frame(width: size.width, height: size.height)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                } else if model.kind == .image, let image = NSImage(contentsOf: model.url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if let player = model.player {
                    VideoPlayer(player: player)
                }
            }
            HStack(spacing: 12) {
                Text(model.sender).font(.caption).lineLimit(1)
                Spacer()
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                control("Save media", "square.and.arrow.down", model.save)
                if model.kind != .audio {
                    if model.editingImage != nil {
                        control("Undo stroke", "arrow.uturn.backward") { if !model.strokes.isEmpty { model.strokes.removeLast() } }
                        control("Send image back", "arrowshape.turn.up.left.fill", model.returnImage)
                        control("Done annotating", "checkmark") { model.editingImage = nil; model.strokes = [] }
                    } else {
                        control("Annotate image or current frame", "pencil.tip.crop.circle", model.annotate)
                            .disabled(model.preparingAnnotation)
                    }
                }
                Menu {
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                        Button(screen.localizedName) { model.move(to: screen) }
                    }
                } label: { Image(systemName: "display") }
                    .menuStyle(.borderlessButton).fixedSize().help("Show on display")
                control(model.pinned ? "Unpin window" : "Pin window", model.pinned ? "pin.fill" : "pin", model.togglePin)
                control("Close media", "xmark", model.close)
            }
            .padding(10).background(.ultraThinMaterial)
            .opacity(hovering || model.editingImage != nil || model.error != nil ? 1 : 0)
            .frame(height: 44)
            MediaDragHandle().frame(height: 18).help("Drag to move media window")
        }
        .background(.black.opacity(0.94)).clipShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering = $0 }
    }
    private func control(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 24, height: 24) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private func fitted(_ image: CGSize, in bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / max(1, image.width), bounds.height / max(1, image.height))
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

private struct MediaDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Handle() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class Handle: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 38, y: bounds.midY - 2, width: 76, height: 4), xRadius: 2, yRadius: 2).fill()
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
