import AppKit
import Combine
import SwiftUI
import ALOCore

private final class AnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
}

/// A presenter-only desktop surface. The session owns this controller and feeds
/// capture metadata into it; creating it never starts capture or asks for access.
@MainActor
final class AnnotationOverlayController: AnnotationOverlayPresenting {
    let model: AnnotationSceneModel
    private let overlay: AnnotationPanel
    private let palette: AnnotationPanel
    private var metadata: CapturedFrameMetadata?
    private var subscriptions = Set<AnyCancellable>()
    private var keyboardMonitor: Any?
    private var palettePlaced = false
    private var visibilityUpdatePending = false

    init(model: AnnotationSceneModel) {
        self.model = model
        overlay = AnnotationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        palette = AnnotationPanel(contentRect: CGRect(x: 0, y: 0, width: 120, height: 40),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        for panel in [overlay, palette] {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.sharingType = .none
            panel.level = .floating
        }
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isMovable = false
        palette.hasShadow = true
        palette.isMovableByWindowBackground = true
        palette.title = "Screen annotation tools"
        overlay.setAccessibilityLabel("Shared-screen annotations")
        palette.setAccessibilityLabel("Screen annotation tools")
        overlay.contentView = NSHostingView(rootView: DesktopAnnotationSurface(model: model))
        palette.contentView = NSHostingView(rootView: AnnotationControlsView(model: model,
            onExpansionChanged: { [weak self] expanded in self?.resizePalette(expanded: expanded) }))
        model.objectWillChange.sink { [weak self] _ in
            guard let self, !self.visibilityUpdatePending else { return }
            self.visibilityUpdatePending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.visibilityUpdatePending = false
                self.refreshVisibility()
            }
        }.store(in: &subscriptions)
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    func update(metadata: CapturedFrameMetadata) {
        self.metadata = metadata
        let unavailable: String?
        if !metadata.desktopOverlaySupported {
            unavailable = "Desktop annotations are unavailable for this display selection. Share a single window, or update macOS."
        } else if !metadata.isInteractive || (model.captureMetadata != nil && model.inputUnavailableReason != nil) {
            unavailable = "The shared content is unavailable. Restore the shared window to annotate."
        } else {
            unavailable = nil
        }
        if model.inputUnavailableReason != unavailable {
            model.inputUnavailableReason = unavailable
            if unavailable != nil { model.escape() }
        }
        refreshVisibility()
    }

    func hide() {
        metadata = nil
        model.escape()
        overlay.ignoresMouseEvents = true
        overlay.orderOut(nil)
        palette.orderOut(nil)
    }

    func close() {
        hide()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        subscriptions.removeAll()
        overlay.close()
        palette.close()
    }

    private func refreshVisibility() {
        guard let metadata, metadata.isInteractive, model.snapshot != nil,
              let screenRect = metadata.screenRect,
              let primary = NSScreen.screens.first,
              let frame = AnnotationGeometry.appKitRect(from: screenRect, primaryDisplayHeight: primary.frame.height),
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else {
            overlay.ignoresMouseEvents = true
            overlay.orderOut(nil)
            palette.orderOut(nil)
            return
        }
        let needsOverlay = model.acceptsInput || !(model.snapshot?.objects.isEmpty ?? true)
            || !model.optimisticStickers.isEmpty
        if needsOverlay, overlay.frame != frame { overlay.setFrame(frame, display: true) }
        overlay.ignoresMouseEvents = !model.acceptsInput
        if needsOverlay {
            if !overlay.isVisible { overlay.orderFrontRegardless() }
        } else if overlay.isVisible { overlay.orderOut(nil) }
        if !palettePlaced {
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? primary
            let safe = screen.visibleFrame
            let size = palette.frame.size
            palette.setFrameOrigin(CGPoint(x: min(max(frame.midX - size.width / 2, safe.minX), safe.maxX - size.width),
                                           y: safe.maxY - size.height - 20))
            palettePlaced = true
        }
        if !palette.isVisible { palette.orderFrontRegardless() }
    }

    private func resizePalette(expanded: Bool) {
        let size = expanded ? CGSize(width: 550, height: 120) : CGSize(width: 120, height: 40)
        let previous = palette.frame
        guard previous.size != size else { return }
        let safe = palette.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? previous
        let origin = CGPoint(x: min(max(previous.minX, safe.minX), safe.maxX - size.width),
                             y: max(safe.minY, previous.maxY - size.height))
        palette.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === overlay || event.window === palette else { return false }
        if event.keyCode == 53 { model.escape(); return true }
        // Search fields keep standard editing and clipboard shortcuts.
        if event.window?.firstResponder is NSTextView { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            model.undo(); return true
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 51 || event.keyCode == 117 { model.deleteSelection(); return true }
        if let id = model.selectedObjectID {
            switch event.keyCode {
            case 123: model.nudgeSticker(id, dx: -0.01, dy: 0); return true
            case 124: model.nudgeSticker(id, dx: 0.01, dy: 0); return true
            case 125: model.nudgeSticker(id, dx: 0, dy: 0.01); return true
            case 126: model.nudgeSticker(id, dx: 0, dy: -0.01); return true
            default: break
            }
        }
        if model.inputAvailable, let key = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = AnnotationSceneModel.Tool.allCases.first(where: { $0.shortcut == key }) {
            model.tool = tool
            model.annotationEnabled = true
            return true
        }
        return false
    }
}

@MainActor
private struct DesktopAnnotationSurface: View {
    @ObservedObject var model: AnnotationSceneModel
    var body: some View {
        GeometryReader { geometry in
            AnnotationSceneView(model: model, contentRect: CGRect(origin: .zero, size: geometry.size))
        }
    }
}
