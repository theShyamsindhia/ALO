import SwiftUI
internal import AppKit
import UniformTypeIdentifiers

struct RoomConverterTool: View {
    @ObservedObject var model: FileConverterViewModel
    let onShare: ([URL]) -> Void
    @Binding var options: FileConverterConversionOptions
    @State private var selectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item = model.item {
                HStack(spacing: 10) {
                    Image(nsImage: item.icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Text("Converts a copy · Original stays untouched")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: chooseFile) {
                        Text("Change…")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isConverting)
                }
                .padding(10)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Picker("Format", selection: $model.selectedFormat) {
                            ForEach(model.availableFormats) { format in Text(format.title).tag(format) }
                        }
                        Picker("Save", selection: $options.outputLocation) {
                            Text("Beside original").tag(FileConverterOutputLocation.sameFolder)
                            Text("Downloads").tag(FileConverterOutputLocation.downloads)
                            Text("Ask…").tag(FileConverterOutputLocation.askEveryTime)
                        }
                    }
                    if model.selectedFormat.usesLossyImageQuality {
                        HStack(spacing: 8) {
                            Text("Quality \(Int(options.imageQuality * 100))%")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Slider(value: $options.imageQuality, in: 0.1...1)
                                .accessibilityLabel("Image quality")
                        }
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
                }
                .padding(10)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(model.isConverting)

                HStack(spacing: 8) {
                    switch model.status {
                    case .idle:
                        Button {
                            model.convert(options: options)
                        } label: {
                            Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11.5, weight: .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    case .converting:
                        ProgressView("Converting…").controlSize(.small)
                    case .converted(let url):
                        Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                            .lineLimit(1)
                        Spacer()
                        Button("Finder") { model.revealConvertedFile() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.1), in: Capsule())
                        Button("Share…") { onShare([url]) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.1), in: Capsule())
                        Button("Again") { model.convert(options: options) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1)
                        Spacer()
                        Button("Retry") { model.convert(options: options) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                }
            } else {
                Button(action: chooseFile) {
                    VStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                        Text("Choose a file…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Or drop an image, video, or audio file · Converts a copy, leaving your original untouched")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.09), lineWidth: 0.75)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isConverting)
            }
            if let selectionError { Text(selectionError).font(.caption).foregroundStyle(.orange).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isConverting, let url = urls.first else { return false }
            return select(url)
        }
    }

    private func chooseFile() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image, .movie, .audio]
        picker.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
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
