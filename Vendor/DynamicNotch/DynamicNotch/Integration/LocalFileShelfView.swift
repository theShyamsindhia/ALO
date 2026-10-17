import SwiftUI
import UniformTypeIdentifiers
internal import AppKit

struct LocalFileShelfView: View {
    @ObservedObject var model: FileTrayViewModel
    @State private var error: String?
    @State private var importing = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Only on this Mac · Drag out when ready", systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: chooseFiles) {
                    Label("Keep files…", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(importing)
            }

            if importing {
                ProgressView("Keeping a private copy…").controlSize(.small)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }

            if model.localShelfItems.isEmpty && !importing {
                Button(action: chooseFiles) {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                        Text("Drop files here or click to keep a private copy")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("Nothing here is shared until you drag it to a person or the room shelf.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.white.opacity(targeted ? 0.12 : 0.06))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                targeted ? Color.accentColor.opacity(0.8) : .white.opacity(0.09),
                                lineWidth: 0.75
                            )
                    }
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(model.localShelfItems) { item in
                            RoomNotchTile(item.displayName, action: {
                                if let url = item.localURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }) {
                                Image(nsImage: item.icon).resizable().scaledToFit()
                            }
                            .overlay(alignment: .topTrailing) {
                                Button { model.removeFromLocalShelf(item) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.65))
                                        .background(Circle().fill(.black.opacity(0.3)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove private copy of \(item.displayName)")
                                .padding(5)
                            }
                            .onDrag { item.itemProvider ?? NSItemProvider() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 96, alignment: .leading)
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private func chooseFiles() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.prompt = "Keep privately"
        picker.begin { response in if response == .OK { add(picker.urls) } }
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
