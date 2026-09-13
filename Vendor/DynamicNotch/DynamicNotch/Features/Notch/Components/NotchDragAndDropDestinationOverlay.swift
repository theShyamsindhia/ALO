import SwiftUI

struct NotchDragAndDropDestinationOverlay: View {
    @ObservedObject var airDropViewModel: AirDropNotchViewModel
    @ObservedObject var airDropController: NotchAirDropController
    @ObservedObject var settingsViewModel: SettingsViewModel
    
    var body: some View {
        if let runtime = EmbeddedNotchRuntime.activeInstance {
            EmbeddedRoomDragGate(runtime: runtime, fallback: AnyView(originalDestination))
        } else {
            originalDestination
        }
    }

    private var originalDestination: some View {
        DragAndDropDestinationView(
            isTargeted: $airDropController.isTargeted,
            targetedDropTarget: Binding(
                get: { airDropViewModel.targetedDropTarget },
                set: { airDropViewModel.setTargetedDropTarget($0) }
            ),
            mode: settingsViewModel.mediaAndFiles.dragAndDropActivityMode,
            onDropPasteboard: { target, pasteboard in
                switch target {
                case .airDrop:
                    guard settingsViewModel.mediaAndFiles.dragAndDropActivityMode.showsAirDrop,
                          settingsViewModel.mediaAndFiles.isAirDropLiveActivityEnabled else {
                        return false
                    }
                    
                    return airDropController.handlePasteboardDrop(pasteboard)
                case .tray:
                    guard settingsViewModel.mediaAndFiles.dragAndDropActivityMode.showsTray,
                          settingsViewModel.mediaAndFiles.isTrayLiveActivityEnabled else {
                        return false
                    }
                    
                    return airDropController.handleTrayDrop(
                        pasteboard,
                        mode: settingsViewModel.mediaAndFiles.fileTrayUsageMode
                    )
                }
            }
        )
    }
}

private struct EmbeddedRoomDragGate: View {
    @ObservedObject var runtime: EmbeddedNotchRuntime
    let fallback: AnyView
    var body: some View {
        if runtime.roomSharingAvailable {
            if !runtime.isRoomInteractionVisible {
                RoomEntryDropDestination(entered: { runtime.onRoomFilesDragEntered?() },
                    dropped: { runtime.onRoomFilesStaged?($0) })
            }
        } else {
            fallback
        }
    }
}

private struct RoomEntryDropDestination: NSViewRepresentable {
    let entered: () -> Void
    let dropped: ([URL]) -> Void
    func makeNSView(context: Context) -> RoomEntryDropView { RoomEntryDropView() }
    func updateNSView(_ view: RoomEntryDropView, context: Context) {
        view.entered = entered; view.dropped = dropped
    }
}

final class RoomEntryDropView: NSView {
    // AppKit releases this ARC-only callback owner outside Swift tasks.
    nonisolated deinit {}

    var entered: () -> Void = {}
    var dropped: ([URL]) -> Void = { _ in }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel, .mouseMoved:
            return nil
        default: return super.hitTest(point)
        }
    }
    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        entered()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { urls(sender).isEmpty ? [] : .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !urls(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard !files.isEmpty else { return false }
        dropped(files)
        return true
    }
}
