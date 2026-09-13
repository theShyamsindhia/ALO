import SwiftUI
import UniformTypeIdentifiers
internal import AppKit

struct LocalFileShelfView: View {
    @ObservedObject var model: FileTrayViewModel
    @State private var error: String?
    @State private var importing = false
    @State private var targeted = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Only on this Mac").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Keep files…") {
                        let picker = NSOpenPanel()
                        picker.allowsMultipleSelection = true; picker.canChooseDirectories = false
                        picker.prompt = "Keep privately"
                        picker.begin { response in if response == .OK { add(picker.urls) } }
                    }.disabled(importing)
                }
                Text("Nothing here is shared. Drag a file onto a person or the room shelf when you're ready.")
                    .font(.caption).foregroundStyle(.secondary)
                if importing { ProgressView("Keeping a private copy…").controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if model.localShelfItems.isEmpty && !importing {
                    Text("Drop files here to keep a private copy.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                }
                RoomNotchTray {
                ForEach(model.localShelfItems) { item in
                    RoomNotchTile(item.displayName, action: {
                        if let url = item.localURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }) {
                        Image(nsImage: item.icon).resizable().scaledToFit()
                    }
                    .overlay(alignment: .topTrailing) {
                        Button { model.removeFromLocalShelf(item) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).accessibilityLabel("Remove private copy of \(item.displayName)")
                            .padding(5)
                    }
                        .onDrag { item.itemProvider ?? NSItemProvider() }
                }
                }.frame(height: 100)
            }.controlSize(.small)
        }
        .background(targeted ? Color.accentColor.opacity(0.1) : .clear)
        .onAppear { model.activate() }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            guard !importing else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                            continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                        }
                    }
                    if let url, url.isFileURL { urls.append(url) }
                }
                add(urls)
            }
            return true
        }
    }
    private func add(_ urls: [URL]) {
        guard !urls.isEmpty, !importing else { return }
        importing = true; error = nil
        Task {
            defer { importing = false }
            do { try await model.addToLocalShelf(urls) }
            catch { self.error = "Could not keep this file: \(error.localizedDescription)" }
        }
    }
}
