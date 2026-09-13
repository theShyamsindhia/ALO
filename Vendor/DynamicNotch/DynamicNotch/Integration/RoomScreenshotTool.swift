import SwiftUI
internal import AppKit
import UniformTypeIdentifiers

struct RoomScreenshotTool: View {
    @ObservedObject var model: ScreenshotViewModel
    @ObservedObject var settings: ScreenRecordingSettingsStore
    let shelf: FileTrayViewModel
    let staging: RoomToolStaging
    let onShare: ([URL]) -> Void
    @State private var chosen: ScreenshotModel?
    @State private var text: String?
    @State private var notice: String?
    @State private var working = false
    @State private var operation: Task<Void, Never>?
    private var screenshot: ScreenshotModel? { chosen ?? model.latestScreenshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show new screenshots here", isOn: $settings.isScreenshotActivityEnabled)
            Text("Capture with ⇧⌘4, or choose an existing image. Text extraction runs on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose image…", action: chooseImage)
                if chosen != nil, model.latestScreenshot != nil {
                    Button("Use latest capture") { chosen = nil }
                }
            }.disabled(working)
            if let screenshot {
                Image(nsImage: screenshot.image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .frame(height: 140).accessibilityLabel("Screenshot preview")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
                    actions(screenshot)
                }.disabled(working)
                if working { ProgressView("Preparing…") }
                if let text {
                    if text.isEmpty {
                        Text("No readable text found.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(text).font(.callout).textSelection(.enabled)
                        Button("Copy text") {
                            NSPasteboard.general.clearContents()
                            notice = NSPasteboard.general.setString(text, forType: .string) ? "Text copied" : "Could not copy text"
                        }
                    }
                }
            } else {
                ContentUnavailableView("No screenshot yet", systemImage: "viewfinder",
                    description: Text("Choose an image or turn on screenshot monitoring."))
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: screenshot?.id) { _, _ in operation?.cancel(); working = false; text = nil; notice = nil }
        .onDisappear { operation?.cancel() }
    }

    @ViewBuilder private func actions(_ screenshot: ScreenshotModel) -> some View {
        Button("Copy image") {
            notice = model.copyPreviewImage(screenshot.image) ? "Image copied" : "Could not copy image"
        }
        Button("Extract text") {
            working = true; notice = nil
            operation = Task { @MainActor in
                let result = await OCRService.shared.recognizeText(in: screenshot.image, languages: [])
                guard !Task.isCancelled else { return }
                text = result; working = false
            }
        }
        Button("Keep privately") { prepare(screenshot, share: false) }
        Button("Share…") { prepare(screenshot, share: true) }
    }

    private func prepare(_ screenshot: ScreenshotModel, share: Bool) {
        guard let data = screenshot.image.tiffRepresentation else { notice = "Could not prepare the image"; return }
        working = true; notice = nil
        operation = Task { @MainActor in
            guard !Task.isCancelled else { return }
            do {
                let url = try await staging.stageTIFF(data, id: screenshot.id)
                guard !Task.isCancelled else { return }
                if share {
                    working = false
                    onShare([url])
                } else {
                    try await shelf.addToLocalShelf([url])
                    guard !Task.isCancelled else { return }
                    notice = "Kept in My shelf"; working = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                notice = error.localizedDescription; working = false
            }
        }
    }

    private func chooseImage() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false
        picker.begin { response in
            guard response == .OK, let url = picker.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= 32 * 1_024 * 1_024,
                  let image = NSImage(contentsOf: url) else {
                notice = "Choose a readable image up to 32 MB."; return
            }
            chosen = ScreenshotModel(image: image, fileURL: url, tempFileURL: nil, targetDestinationURL: nil,
                fileName: url.lastPathComponent, recognizedText: "", isRecognizing: false, timestamp: Date())
        }
    }
}
