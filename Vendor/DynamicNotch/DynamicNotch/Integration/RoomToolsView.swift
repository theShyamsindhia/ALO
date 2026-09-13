import SwiftUI
internal import AppKit
internal import EventKit

enum RoomTool: String, CaseIterable, Identifiable {
    case screenshots = "Screenshots & text", converter = "Convert a file", downloads = "Downloads"
    case camera = "Camera mirror", countdown = "Countdown", systemTimer = "Clock timer"
    case calendar = "Calendar", statistics = "CPU & memory"
    var id: String { rawValue }
    var trayLabel: String {
        switch self {
        case .screenshots: "Screenshots"
        case .converter: "Convert"
        case .camera: "Camera"
        case .systemTimer: "Clock"
        case .statistics: "CPU & memory"
        default: rawValue
        }
    }
    var symbol: String {
        switch self {
        case .screenshots: "viewfinder"
        case .converter: "arrow.triangle.2.circlepath"
        case .downloads: "arrow.down.circle"
        case .camera: "web.camera"
        case .countdown: "timer"
        case .systemTimer: "clock"
        case .calendar: "calendar"
        case .statistics: "cpu"
        }
    }
    var detail: String {
        switch self {
        case .screenshots: "Preview, copy, extract text or share"
        case .converter: "Choose an output format and quality"
        case .downloads: "See observed downloads and room transfers"
        case .camera: "A private preview, never broadcast"
        case .countdown: "Start a timer on this Mac"
        case .systemTimer: "Monitor a timer from Apple Clock"
        case .calendar: "Upcoming events, with your permission"
        case .statistics: "Live usage while this tool is open"
        }
    }
}

struct RoomToolsView: View {
    let container: AppContainer
    let staging: RoomToolStaging
    let onShare: ([URL]) -> Void
    let onTransfers: () -> Void
    let onStartTimer: () -> Void
    var isPresented = true
    @State var selected: RoomTool?
    var onSelectionChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected {
                HStack {
                    Button { self.selected = nil } label: { Label("Tools", systemImage: "chevron.left") }
                    Spacer()
                    Label(selected.rawValue, systemImage: selected.symbol).font(.system(size: 12, weight: .semibold))
                }.controlSize(.small)
                ScrollView {
                    tool(selected).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
            } else {
                RoomNotchTray {
                        ForEach(RoomTool.allCases) { tool in
                            RoomNotchTile(tool.trayLabel, action: { selected = tool }) {
                                Image(systemName: tool.symbol)
                            }.help(tool.detail).accessibilityLabel(tool.rawValue).accessibilityHint(tool.detail)
                        }
                }
            }
        }
        .controlSize(.small)
        .onAppear { onSelectionChanged(selected != nil) }
        .onChange(of: selected) { _, value in onSelectionChanged(value != nil) }
    }

    @ViewBuilder private func tool(_ tool: RoomTool) -> some View {
        switch tool {
        case .screenshots:
            RoomScreenshotTool(model: container.screenshotViewModel, settings: container.settingsViewModel.screenRecording,
                shelf: container.fileTrayViewModel, staging: staging, onShare: onShare)
        case .converter:
            RoomConverterTool(model: container.fileConverterViewModel, onShare: onShare)
        case .downloads:
            RoomDownloadsTool(model: container.downloadViewModel, settings: container.settingsViewModel.mediaAndFiles,
                onTransfers: onTransfers)
        case .camera: RoomCameraTool(isPresented: isPresented)
        case .countdown:
            RoomCountdownTool(model: container.localTimerViewModel, settings: container.settingsViewModel.mediaAndFiles,
                onStart: onStartTimer)
        case .systemTimer:
            RoomClockTimerTool(model: container.timerViewModel, settings: container.settingsViewModel.mediaAndFiles)
        case .calendar:
            RoomCalendarTool(model: container.calendarViewModel, settings: container.settingsViewModel.calendar)
        case .statistics: RoomStatisticsTool(isPresented: isPresented)
        }
    }
}

struct RoomCountdownTool: View {
    @ObservedObject var model: LocalTimerViewModel
    @ObservedObject var settings: MediaAndFilesSettingsStore
    let onStart: () -> Void
    @State private var minutes = 15
    @State private var seconds = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your timer continues when you close this view. Turning off Notch cancels it.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Play a sound when finished", isOn: $settings.isTimerSoundEnabled)
                .onChange(of: settings.isTimerSoundEnabled) { _, enabled in
                    if !enabled { TimerSoundPlayer.shared.stop() }
                }
            if model.state == .stopped {
                Stepper("\(minutes) minutes", value: $minutes, in: 0...120)
                Stepper("\(seconds) seconds", value: $seconds, in: 0...59)
                Button("Start countdown") {
                    onStart()
                    model.start(hours: 0, minutes: minutes, seconds: seconds, repeatsCompletionSound: false)
                }.disabled(minutes == 0 && seconds == 0)
            } else {
                Text(model.formattedRemainingTime).font(.largeTitle.monospacedDigit())
                HStack {
                    Button(model.state == .paused ? "Resume" : "Pause") {
                        if model.state == .paused { model.resume() } else { model.pause() }
                    }
                    Button("Cancel", role: .cancel) { model.stop() }
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Only you can see this preview. The camera stops when you leave this tool.")
                .font(.caption).foregroundStyle(.secondary)
            if requested {
                switch model.cameraState {
                case .ready:
                    CameraPreviewView(previewLayer: model.previewLayer)
                        .frame(height: 200).scaleEffect(x: mirrored ? -1 : 1, y: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Toggle("Mirror preview", isOn: $mirrored)
                case .unknown: ProgressView("Starting camera…")
                case .unavailable:
                    Text("Camera unavailable. Check Camera access for ALO in System Settings, then try again.")
                        .foregroundStyle(.secondary)
                }
                Button("Stop camera") { requested = false; model.stopSession() }
            } else {
                Button("Start camera") { requested = true; model.checkPermissions(); model.startSession() }
            }
        }
        .onChange(of: model.cameraState) { _, state in
            if requested && state == .ready { model.startSession() }
        }
        .onDisappear { requested = false; model.stopSession() }
        .onChange(of: isPresented) { _, visible in
            if !visible { requested = false; model.stopSession() }
        }
    }
}

struct RoomStatisticsTool: View {
    var isPresented = true
    @StateObject private var model = SystemStatsViewModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("CPU", value: String(format: "%.1f%%", model.cpuUsage))
            ProgressView(value: model.cpuUsage, total: 100).accessibilityLabel("CPU usage")
            LabeledContent("Memory", value: String(format: "%.1f / %.1f GB", model.memoryUsedGB, model.memoryTotalGB))
            ProgressView(value: model.memoryUsagePercent, total: 100).accessibilityLabel("Memory usage")
            Text("Updates while this tool is open. These are this Mac’s totals, not room or per-app statistics.")
                .font(.caption).foregroundStyle(.secondary)
        }.monospacedDigit()
            .onAppear { if isPresented { model.startMonitoring() } }
            .onDisappear { model.stopMonitoring() }
            .onChange(of: isPresented) { _, visible in
                if visible { model.startMonitoring() } else { model.stopMonitoring() }
            }
    }
}

struct RoomCalendarTool: View {
    @ObservedObject var model: CalendarViewModel
    @ObservedObject var settings: CalendarSettingsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show upcoming calendar events", isOn: $settings.isCalendarLiveActivityEnabled)
            Toggle("Hide event details", isOn: $settings.isPrivacyModeEnabled)
                .disabled(!settings.isCalendarLiveActivityEnabled)
            if settings.isCalendarLiveActivityEnabled {
                if model.authorizationStatus == .notDetermined {
                    Button("Allow calendar access…") { model.requestAccess() }
                } else if model.authorizationStatus != .fullAccess {
                    Text("Allow Calendar access for ALO in System Settings to show events.").foregroundStyle(.secondary)
                } else if model.events.isEmpty {
                    Text("No upcoming events in your selected calendars.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.events, id: \.eventIdentifier) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.displayTitle(for: event)).font(.callout.weight(.medium))
                            Text(event.startDate, format: .dateTime.weekday().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                        Divider()
                    }
                }
                Button("Refresh") { model.refreshAuthorization() }
            }
            Text("Calendar data stays on this Mac.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RoomClockTimerTool: View {
    @ObservedObject var model: TimerViewModel
    @ObservedObject var settings: MediaAndFilesSettingsStore
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Monitor Apple Clock timers", isOn: $settings.isTimerLiveActivityEnabled)
            Text("This is separate from ALO’s countdown. Clock detection depends on macOS compatibility and may require Accessibility access.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.isTimerLiveActivityEnabled, let snapshot = model.snapshot {
                Text(snapshot.title).font(.headline)
                Text(model.formattedTime).font(.largeTitle.monospacedDigit())
                HStack {
                    Button(snapshot.isPaused ? "Resume" : "Pause") { control(stop: false) }
                    Button("Stop") { control(stop: true) }
                }.disabled(busy)
            } else if settings.isTimerLiveActivityEnabled {
                Text("No Clock timer detected. Start one in Clock, or use Countdown here.").foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func control(stop: Bool) {
        busy = true; error = nil
        Task { @MainActor in
            let succeeded = await (stop ? model.stopTimer() : model.togglePauseResume())
            busy = false
            if !succeeded { error = "Clock could not be controlled. Use the Clock app directly." }
        }
    }
}

struct RoomDownloadsTool: View {
    @ObservedObject var model: DownloadViewModel
    @ObservedObject var settings: MediaAndFilesSettingsStore
    let onTransfers: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Open ALO room transfers", action: onTransfers)
            Divider()
            Toggle("Observe downloads on this Mac", isOn: $settings.isDownloadsLiveActivityEnabled)
            Text("Observes growing files in Downloads, Desktop, Documents, Movies, Music and Pictures. Progress may be estimated; this is not a complete browser download history.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.isDownloadsLiveActivityEnabled && model.activeDownloads.isEmpty {
                Text("No active downloads detected.").foregroundStyle(.secondary)
            }
            ForEach(model.activeDownloads) { download in
                VStack(alignment: .leading, spacing: 6) {
                    Text(download.displayName).font(.callout.weight(.medium)).lineLimit(2)
                    ProgressView(value: min(1, max(0, download.progress)))
                    Text("\(download.directoryName) · \(ByteCountFormatter.string(fromByteCount: download.byteCount, countStyle: .file)) received")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([download.url]) }
                }.padding(.vertical, 6)
            }
        }
    }
}
