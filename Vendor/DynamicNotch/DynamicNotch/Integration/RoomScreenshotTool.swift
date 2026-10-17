import SwiftUI
internal import AppKit
import UniformTypeIdentifiers

struct RoomScreenshotTool: View {
    @ObservedObject var model: ScreenshotViewModel
    @ObservedObject var settings: ScreenRecordingSettingsStore
    let shelf: FileTrayViewModel
    let staging: RoomToolStaging
    let onShare: ([URL]) -> Void
    @Binding var chosen: ScreenshotModel?
    @State private var text: String?
    @State private var notice: String?
    @State private var working = false
    @State private var operation: Task<Void, Never>?
    private var screenshot: ScreenshotModel? { chosen ?? model.latestScreenshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let screenshot {
                HStack(spacing: 8) {
                    Text(screenshot.fileName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(action: captureInteractiveRegion) {
                        Label("Capture", systemImage: "viewfinder")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(working)

                    Button(action: pasteFromClipboard) {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(working)

                    Button(action: chooseImage) {
                        Label("Choose image…", systemImage: "photo")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(working)
                    .accessibilityIdentifier("ALO.Tools.ChooseImage")
                }

                HStack(spacing: 12) {
                    Image(nsImage: screenshot.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 136)
                        .padding(8)
                        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityLabel("Screenshot preview")
                        .accessibilityIdentifier("ALO.Tools.ScreenshotPreview")

                    VStack(alignment: .leading, spacing: 6) {
                        actions(screenshot)
                    }
                    .frame(width: 126)
                    .disabled(working)
                }

                if working {
                    ProgressView("Preparing…").controlSize(.small)
                }
                if let text {
                    if text.isEmpty {
                        Text("No readable text found.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Text(text)
                                .font(.system(size: 11))
                                .lineLimit(2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Copy text") {
                                NSPasteboard.general.clearContents()
                                notice = NSPasteboard.general.setString(text, forType: .string) ? "Text copied" : "Could not copy text"
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.1), in: Capsule())
                        }
                        .padding(8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Capture a screen region, paste from clipboard, or open an image to extract text or share")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        RoomNotchTile("Capture", flexibleWidth: true, action: captureInteractiveRegion) {
                            Image(systemName: "viewfinder")
                        }
                        .disabled(working)
                        .help("Select a screen region to capture")

                        RoomNotchTile("Paste", flexibleWidth: true, action: pasteFromClipboard) {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .disabled(working)
                        .help("Inspect image from clipboard")

                        RoomNotchTile("Choose image…", flexibleWidth: true, action: chooseImage) {
                            Image(systemName: "photo")
                        }
                        .disabled(working)
                        .help("Open an image file from Finder")
                        .accessibilityIdentifier("ALO.Tools.ChooseImage")
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.75)
                }
            }
            if let notice {
                Text(notice).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: screenshot?.id) { _, _ in operation?.cancel(); working = false; text = nil; notice = nil }
        .onDisappear { operation?.cancel() }
    }

    @ViewBuilder private func actions(_ screenshot: ScreenshotModel) -> some View {
        screenshotActionButton("Copy image", symbol: "doc.on.doc") {
            notice = model.copyPreviewImage(screenshot.image) ? "Image copied" : "Could not copy image"
        }
        screenshotActionButton("Extract text", symbol: "text.viewfinder") {
            working = true; notice = nil
            operation = Task { @MainActor in
                let result = await OCRService.shared.recognizeText(in: screenshot.image, languages: [])
                guard !Task.isCancelled else { return }
                text = result; working = false
            }
        }
        screenshotActionButton("Keep privately", symbol: "tray.and.arrow.down") {
            prepare(screenshot, share: false)
        }
        screenshotActionButton("Share…", symbol: "paperplane.fill") {
            prepare(screenshot, share: true)
        }
    }

    private func screenshotActionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).frame(width: 14)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
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

    private func pasteFromClipboard() {
        guard let image = NSImage(pasteboard: .general) else {
            notice = "No image found on the clipboard."
            return
        }
        chosen = ScreenshotModel(
            image: image,
            fileURL: nil,
            tempFileURL: nil,
            targetDestinationURL: nil,
            fileName: "Clipboard capture",
            recognizedText: "",
            isRecognizing: false,
            timestamp: Date()
        )
    }

    private func captureInteractiveRegion() {
        working = true
        notice = nil
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-c"]
            try? process.run()
            process.waitUntilExit()
            let succeeded = process.terminationStatus == 0
            await MainActor.run {
                working = false
                if succeeded, let image = NSImage(pasteboard: .general) {
                    chosen = ScreenshotModel(
                        image: image,
                        fileURL: nil,
                        tempFileURL: nil,
                        targetDestinationURL: nil,
                        fileName: "Screen capture",
                        recognizedText: "",
                        isRecognizing: false,
                        timestamp: Date()
                    )
                }
            }
        }
    }

    private func chooseImage() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
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
