import SwiftUI
internal import AppKit
import UniformTypeIdentifiers

struct RoomConverterTool: View {
    @ObservedObject var model: FileConverterViewModel
    let onShare: ([URL]) -> Void
    @State private var options = FileConverterConversionOptions()
    @State private var selectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Convert a copy. Your original stays unchanged.").font(.caption).foregroundStyle(.secondary)
            Button(model.item == nil ? "Choose a file…" : "Choose another file…", action: chooseFile)
                .disabled(model.isConverting)
            if let item = model.item {
                Text(item.displayName).font(.headline).lineLimit(2)
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Format", selection: $model.selectedFormat) {
                        ForEach(model.availableFormats) { format in Text(format.title).tag(format) }
                    }
                    Picker("Save output", selection: $options.outputLocation) {
                        Text("Beside the original").tag(FileConverterOutputLocation.sameFolder)
                        Text("Downloads").tag(FileConverterOutputLocation.downloads)
                        Text("Choose location…").tag(FileConverterOutputLocation.askEveryTime)
                    }
                    if model.selectedFormat.usesLossyImageQuality {
                        LabeledContent("Image quality", value: "\(Int(options.imageQuality * 100))%")
                        Slider(value: $options.imageQuality, in: 0.1...1).accessibilityLabel("Image quality")
                    }
                    if model.selectedFormat.mediaKind == .video {
                        Picker("Video quality", selection: $options.videoQuality) {
                            ForEach(FileConverterVideoQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    if model.selectedFormat.usesCompressedAudioBitrate {
                        Picker("Audio quality", selection: $options.audioQuality) {
                            ForEach(FileConverterAudioQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                }.disabled(model.isConverting)
                switch model.status {
                case .idle:
                    Button("Convert") { model.convert(options: options) }
                case .converting:
                    ProgressView("Converting… You can return to the conversation.")
                case .converted(let url):
                    Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle")
                        .font(.callout).lineLimit(2)
                    HStack {
                        Button("Show in Finder") { model.revealConvertedFile() }
                        Button("Share…") { onShare([url]) }
                    }
                    Button("Convert again") { model.convert(options: options) }
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.orange)
                    Button("Retry conversion") { model.convert(options: options) }
                }
            }
            if let selectionError { Text(selectionError).font(.caption).foregroundStyle(.orange) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isConverting, let url = urls.first else { return false }
            return select(url)
        }
    }

    private func chooseFile() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image, .movie, .audio]
        picker.canChooseDirectories = false
        picker.begin { response in
            guard response == .OK, let url = picker.url else { return }
            _ = select(url)
        }
    }

    private func select(_ url: URL) -> Bool {
        guard !model.isConverting else { return false }
        do { try model.setFile(url); selectionError = nil; return true }
        catch { selectionError = error.localizedDescription; return false }
    }
}
