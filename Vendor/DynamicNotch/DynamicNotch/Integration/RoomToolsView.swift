import SwiftUI
internal import AppKit

enum RoomTool: String, CaseIterable, Identifiable {
    case screenshots = "Screenshots & text"
    case converter = "Convert a file"
    case countdown = "Countdown"
    case camera = "Camera mirror"

    var id: String { rawValue }

    var trayLabel: String {
        switch self {
        case .screenshots: "Screenshots"
        case .converter: "Convert"
        case .countdown: "Countdown"
        case .camera: "Camera"
        }
    }

    var symbol: String {
        switch self {
        case .screenshots: "viewfinder"
        case .converter: "arrow.triangle.2.circlepath"
        case .countdown: "timer"
        case .camera: "web.camera"
        }
    }

    var detail: String {
        switch self {
        case .screenshots: "Capture, paste, extract text or share"
        case .converter: "Choose an output format and quality"
        case .countdown: "Start a quick timer on this Mac"
        case .camera: "A private mirror preview, never broadcast"
        }
    }
}

@MainActor
final class RoomToolSession: ObservableObject {
    nonisolated deinit {}

    @Published var selected: RoomTool?
    @Published var screenshot: ScreenshotModel?
    @Published var conversionOptions = FileConverterConversionOptions()

    init(selected: RoomTool? = nil) { self.selected = selected }
}

struct RoomToolsView: View {
    let container: AppContainer
    let staging: RoomToolStaging
    let onShare: ([URL]) -> Void
    let onTransfers: () -> Void
    let onStartTimer: () -> Void
    var isPresented = true
    @ObservedObject var session: RoomToolSession
    var showsHeader = true
    var onSelectionChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selected = session.selected {
                if showsHeader {
                    HStack(spacing: 8) {
                        Button { session.selected = nil } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(width: 22, height: 22)
                                    .background(.white.opacity(0.1), in: Circle())
                                Text(selected.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Back to all tools")
                        Spacer()
                    }
                }
                tool(selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(spacing: 10) {
                    ForEach(RoomTool.allCases) { tool in
                        RoomNotchTile(tool.trayLabel, flexibleWidth: true, action: { session.selected = tool }) {
                            Image(systemName: tool.symbol)
                        }
                        .help(tool.detail)
                        .accessibilityLabel(tool.rawValue)
                        .accessibilityHint(tool.detail)
                        .accessibilityIdentifier("ALO.Tools.\(tool.id)")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 88, alignment: .top)
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { onSelectionChanged(session.selected != nil) }
        .onChange(of: session.selected) { _, value in onSelectionChanged(value != nil) }
    }

    @ViewBuilder private func tool(_ tool: RoomTool) -> some View {
        switch tool {
        case .screenshots:
            RoomScreenshotTool(
                model: container.screenshotViewModel,
                settings: container.settingsViewModel.screenRecording,
                shelf: container.fileTrayViewModel,
                staging: staging,
                onShare: onShare,
                chosen: $session.screenshot
            )
        case .converter:
            RoomConverterTool(
                model: container.fileConverterViewModel,
                onShare: onShare,
                options: $session.conversionOptions
            )
        case .countdown:
            RoomCountdownTool(
                model: container.localTimerViewModel,
                settings: container.settingsViewModel.mediaAndFiles,
                onStart: onStartTimer
            )
        case .camera:
            RoomCameraTool(isPresented: isPresented)
        }
    }
}

struct RoomCountdownTool: View {
    @ObservedObject var model: LocalTimerViewModel
    @ObservedObject var settings: MediaAndFilesSettingsStore
    let onStart: () -> Void
    @State private var minutes = 15
    @State private var seconds = 0

    private let presets = [1, 5, 10, 15, 25, 45]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.state == .stopped ? String(format: "%02d:%02d", minutes, seconds) : model.formattedRemainingTime)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("Continues in the notch when closed · Local to this Mac")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.state == .stopped {
                    Button {
                        onStart()
                        model.start(hours: 0, minutes: minutes, seconds: seconds, repeatsCompletionSound: false)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(minutes == 0 && seconds == 0)
                } else {
                    HStack(spacing: 6) {
                        Button {
                            if model.state == .paused { model.resume() } else { model.pause() }
                        } label: {
                            Text(model.state == .paused ? "Resume" : "Pause")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(role: .cancel) { model.stop() } label: {
                            Text("Cancel")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.75)
            }

            if model.state == .stopped {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            minutes = preset
                            seconds = 0
                        } label: {
                            Text("\(preset)m")
                                .font(.system(size: 11, weight: minutes == preset && seconds == 0 ? .semibold : .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    minutes == preset && seconds == 0
                                        ? Color.accentColor.opacity(0.38)
                                        : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        if minutes > 0 { minutes -= 1 }
                    } label: {
                        Text("−1m")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        if minutes < 120 { minutes += 1 }
                    } label: {
                        Text("+1m")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        let total = min(120 * 60, minutes * 60 + seconds + 15)
                        minutes = total / 60
                        seconds = total % 60
                    } label: {
                        Text("+15s")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        seconds = 0
                    } label: {
                        Text(":00")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct RoomCameraTool: View {
    var isPresented = true
    @StateObject private var model = CameraViewModel()
    @State private var requested = false
    @State private var mirrored = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if requested {
                switch model.cameraState {
                case .ready:
                    ZStack(alignment: .bottom) {
                        CameraPreviewView(previewLayer: model.previewLayer)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minHeight: 164)
                            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        HStack(spacing: 8) {
                            Button {
                                mirrored.toggle()
                            } label: {
                                Label(mirrored ? "Mirrored" : "Normal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 5)
                                    .background(.black.opacity(0.62), in: Capsule())
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button("Stop") { requested = false; model.stopSession() }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.62), in: Capsule())
                        }
                        .padding(10)
                    }
                case .unknown:
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Starting camera…").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { requested = false; model.stopSession() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                case .unavailable:
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash.fill").font(.title3).foregroundStyle(.secondary)
                        Text("Camera unavailable. Check Camera access for ALO in System Settings.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Close") { requested = false; model.stopSession() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            } else {
                Button {
                    requested = true
                    model.checkPermissions()
                    model.startSession()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "web.camera")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                        Text("Open camera mirror")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Private preview on this Mac · Never shared with the room")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.09), lineWidth: 0.75)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.cameraState) { _, state in
            if requested && state == .ready { model.startSession() }
        }
        .onDisappear { requested = false; model.stopSession() }
        .onChange(of: isPresented) { _, visible in
            if !visible { requested = false; model.stopSession() }
        }
    }
}
