import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Network
import SwiftUI
import UniformTypeIdentifiers
import ALOCore

enum DiagnosticCheckID: String, CaseIterable, Hashable, Sendable {
    case screenPermission
    case screenPicker
    case systemAudio
    case microphone
    case output
    case network
    case roomSync

    var title: String {
        switch self {
        case .screenPermission: "Screen Recording access"
        case .screenPicker: "Display and window picker"
        case .systemAudio: "System audio capture"
        case .microphone: "Microphone input"
        case .output: "Speaker output"
        case .network: "Peer and network reachability"
        case .roomSync: "Room synchronization"
        }
    }

    var symbol: String {
        switch self {
        case .screenPermission: "rectangle.inset.filled.and.person.filled"
        case .screenPicker: "rectangle.on.rectangle"
        case .systemAudio: "waveform"
        case .microphone: "mic"
        case .output: "speaker.wave.2"
        case .network: "network"
        case .roomSync: "clock.arrow.2.circlepath"
        }
    }
}

enum DiagnosticOutcome: String, Sendable, Equatable {
    case idle
    case running
    case passed
    case warning
    case failed

    var label: String {
        switch self {
        case .idle: "Not tested"
        case .running: "Testing…"
        case .passed: "Ready"
        case .warning: "Needs attention"
        case .failed: "Not ready"
        }
    }
}

struct DiagnosticCheckResult: Sendable, Equatable {
    let outcome: DiagnosticOutcome
    let detail: String
    let checkedAt: Date?

    static let idle = DiagnosticCheckResult(outcome: .idle, detail: "Run this check when you need it.", checkedAt: nil)
    static let running = DiagnosticCheckResult(outcome: .running, detail: "Checking this Mac…", checkedAt: nil)
}

struct ReceiverTimingDiagnostics: Sendable, Equatable {
    let roundTripMilliseconds: Double?
    let clockOffsetMilliseconds: Double?
    let jitterMilliseconds: Double
    let recommendedBufferMilliseconds: Double
    let outputLatencyMilliseconds: Double
    let renderHeadroomMilliseconds: Double
    let outputSampleRate: Double?
    let outputChannelCount: UInt32?
    let latenessMilliseconds: Double
    let latePacketCount: UInt64
    let resyncCount: UInt64
    var currentDriftMilliseconds: Double? = nil
    var driftMeasurementAgeMilliseconds: Double? = nil
    var video: VideoPresentationTimingSnapshot? = nil
    var videoEnabled = false
    var activePlayoutBufferMilliseconds: Double? = nil
    var automaticSyncState: String? = nil
}

struct HostListenerTimingDiagnostics: Sendable, Equatable {
    let peerID: String
    let isTimingEligible: Bool
    let reportAgeMilliseconds: Double?
    let recommendedBufferMilliseconds: Double
    let hardwareFloorMilliseconds: Double
    var audioEnqueued: UInt64 = 0
    var audioSent: UInt64 = 0
    var audioExpiredWait: UInt64 = 0
    var audioExpiredAge: UInt64 = 0
    var audioAdmissionRejected: UInt64 = 0
    var audioReplaced: UInt64 = 0
    var audioDiscardedBoundary: UInt64 = 0
    var driftMilliseconds: Double? = nil
    var driftSampleAgeMilliseconds: Double? = nil
    var playbackReportAgeMilliseconds: Double? = nil
    var latenessMilliseconds: Double = 0
    var latePacketCount: UInt64 = 0
    var resyncCount: UInt64 = 0
    var screenTiming: PlaybackScreenTimingReport? = nil
}

struct HostTimingDiagnostics: Sendable, Equatable {
    let listenerCount: Int
    let reportingListenerCount: Int
    let groupBufferMilliseconds: Double
    let maximumLatenessMilliseconds: Double
    let totalResyncCount: UInt64
    var roomTimingChangeCount: UInt64 = 0
    var videoEnabled = false
    var listeners: [HostListenerTimingDiagnostics] = []
}

struct SessionTimingDiagnostics: Sendable, Equatable {
    let receiver: ReceiverTimingDiagnostics?
    let host: HostTimingDiagnostics?
}

struct DiagnosticRoomContext: Sendable, Equatable {
    private static let driftWarningMilliseconds = Double(SynchronizedPlayer.hardResyncThresholdNanos) / 1_000_000
    enum Role: String, Sendable {
        case none
        case broadcaster
        case listener
    }

    let isActive: Bool
    let role: Role
    let participantCount: Int
    let remotePeerCount: Int
    let syncLabel: String
    let audioIsRendering: Bool
    let hasBroadcaster: Bool
    let timing: SessionTimingDiagnostics?

    var result: DiagnosticCheckResult {
        guard isActive else {
            return DiagnosticCheckResult(
                outcome: .warning,
                detail: "Open a room to inspect its live clock and synchronization state.",
                checkedAt: Date()
            )
        }
        var parts = ["\(role.rawValue.capitalized), \(remotePeerCount) remote peer\(remotePeerCount == 1 ? "" : "s")", syncLabel]
        if let receiver = timing?.receiver {
            if let roundTrip = receiver.roundTripMilliseconds {
                parts.append("RTT \(Self.milliseconds(roundTrip))")
            }
            if let clockOffset = receiver.clockOffsetMilliseconds {
                parts.append("clock offset \(Self.signedMilliseconds(clockOffset))")
            }
            parts.append("buffer \(Self.milliseconds(receiver.recommendedBufferMilliseconds))")
            parts.append("jitter \(Self.milliseconds(receiver.jitterMilliseconds))")
            parts.append(
                "output \(Self.milliseconds(receiver.outputLatencyMilliseconds)) + \(Self.milliseconds(receiver.renderHeadroomMilliseconds)) render"
            )
            if let sampleRate = receiver.outputSampleRate,
               let channels = receiver.outputChannelCount {
                parts.append("\(Int(sampleRate.rounded())) Hz/\(channels) ch")
            }
            parts.append("lateness \(Self.milliseconds(receiver.latenessMilliseconds))")
            parts.append("late \(receiver.latePacketCount), resyncs \(receiver.resyncCount)")
            if let drift = receiver.currentDriftMilliseconds,
               let age = receiver.driftMeasurementAgeMilliseconds {
                parts.append("render drift \(Self.milliseconds(drift)), sample age \(Self.milliseconds(age))")
            } else {
                parts.append("render drift not currently measured")
            }
            if let video = receiver.video, video.presentedCount > 0 || video.pendingCount > 0 {
                let miss = video.latestDeadlineMissNanos.map { Self.milliseconds(Double($0) / 1_000_000) } ?? "not measured"
                parts.append("screen deadline miss at UI handoff \(miss), peak \(Self.milliseconds(Double(video.maximumDeadlineMissNanos) / 1_000_000)), \(video.pendingCount) pending")
                parts.append("UI handoff timing is not a physical display or lip-sync measurement")
            }
            if receiver.videoEnabled, receiver.video?.latestHandoffAtNanos == nil {
                parts.append("Screen sharing is enabled, but no screen frame has reached the UI yet")
            }
        }
        if let host = timing?.host {
            parts.append("room buffer \(Self.milliseconds(host.groupBufferMilliseconds))")
            parts.append("\(host.reportingListenerCount)/\(host.listenerCount) listeners reporting")
            parts.append("max lateness \(Self.milliseconds(host.maximumLatenessMilliseconds))")
            parts.append("resyncs \(host.totalResyncCount)")
            parts.append("room timing changes \(host.roomTimingChangeCount)")
            for (index, listener) in host.listeners.enumerated() {
                let age = listener.reportAgeMilliseconds.map(Self.milliseconds) ?? "not reported"
                parts.append("listener \(index + 1): network \(Self.milliseconds(listener.recommendedBufferMilliseconds)), hardware floor \(Self.milliseconds(listener.hardwareFloorMilliseconds)), network vote \(listener.isTimingEligible ? "eligible" : "late join"), report age \(age)")
                parts.append("audio packets: \(listener.audioSent)/\(listener.audioEnqueued) submitted, wait expired \(listener.audioExpiredWait), capture expired \(listener.audioExpiredAge), local-send budget rejected \(listener.audioAdmissionRejected), congestion replaced \(listener.audioReplaced), transition discarded \(listener.audioDiscardedBoundary)")
                if let drift = listener.driftMilliseconds {
                    let sampleAge = listener.driftSampleAgeMilliseconds.map(Self.milliseconds) ?? "unknown"
                    let reportAge = listener.playbackReportAgeMilliseconds.map(Self.milliseconds) ?? "unknown"
                    parts.append("listener \(index + 1) render drift \(Self.milliseconds(drift)), sample age \(sampleAge), playback report age \(reportAge)")
                } else {
                    parts.append("listener \(index + 1) render drift not reported; playback may be idle or the peer may need updating")
                }
                if host.videoEnabled {
                    if let screen = listener.screenTiming {
                        let miss = screen.latestDeadlineMissNanos.map { Self.milliseconds(Double($0) / 1_000_000) } ?? "not measured"
                        let pending = screen.oldestPendingDeadlineMissNanos.map { Self.milliseconds(Double($0) / 1_000_000) } ?? "none"
                        parts.append("listener \(index + 1) screen UI handoff miss \(miss), pending deadline miss \(pending)")
                    } else {
                        parts.append("listener \(index + 1) screen timing unverified; peer may need updating")
                    }
                }
            }
            if host.videoEnabled { parts.append("Remote UI handoff timing is not a physical display or lip-sync measurement") }
            if host.listenerCount == 0 { parts.append("No listeners available to verify remote playback") }
        }
        // A connected clock is not evidence of timely rendering. Unknown or
        // stale samples remain a warning; historical counters alone do not fail
        // a recovered stream, and a static screen is not inferred to be stalled.
        var ready = hasBroadcaster
        if let receiver = timing?.receiver {
            ready = ready && audioIsRendering && receiver.roundTripMilliseconds != nil
                && Self.isFreshDrift(receiver.currentDriftMilliseconds, age: receiver.driftMeasurementAgeMilliseconds)
                && receiver.latenessMilliseconds < Self.driftWarningMilliseconds
            if let video = receiver.video, Self.videoIsCurrentlyLate(video) { ready = false }
            if receiver.videoEnabled, receiver.video?.latestHandoffAtNanos == nil { ready = false }
        } else if role == .listener {
            ready = false
        }
        if role == .broadcaster {
            if let host = timing?.host {
                ready = ready && host.listenerCount > 0
                    && host.reportingListenerCount == host.listenerCount
                    && host.listeners.count == host.listenerCount
                    && host.maximumLatenessMilliseconds < Self.driftWarningMilliseconds
                    && host.listeners.allSatisfy { listener in
                        guard let reportAge = listener.playbackReportAgeMilliseconds,
                              reportAge.isFinite, reportAge >= 0, reportAge <= 2_500 else { return false }
                        return Self.isFreshDrift(listener.driftMilliseconds, age: listener.driftSampleAgeMilliseconds)
                            && (!host.videoEnabled || Self.remoteScreenIsVerified(listener.screenTiming,
                                reportAgeNanos: UInt64(reportAge * 1_000_000)))
                    }
            } else { ready = false }
        }
        if !ready { parts.append("Timely playback is not currently verified; inspect drift, playback state, and sample age") }
        return DiagnosticCheckResult(
            outcome: ready ? .passed : .warning,
            detail: parts.joined(separator: " · "),
            checkedAt: Date()
        )
    }

    private static func isFreshDrift(_ drift: Double?, age: Double?) -> Bool {
        guard let drift, let age else { return false }
        return drift.isFinite && drift >= 0 && drift < driftWarningMilliseconds
            && age.isFinite && age >= 0 && age <= 500
    }

    private static func videoIsCurrentlyLate(_ video: VideoPresentationTimingSnapshot) -> Bool {
        let threshold = SynchronizedPlayer.hardResyncThresholdNanos
        if let deadline = video.oldestPendingDeadlineNanos, video.measuredAtNanos >= deadline,
           video.measuredAtNanos - deadline >= threshold { return true }
        guard let handoff = video.latestHandoffAtNanos, let miss = video.latestDeadlineMissNanos,
              video.measuredAtNanos >= handoff, video.measuredAtNanos - handoff <= 2_000_000_000 else { return false }
        return miss >= threshold
    }

    private static func remoteScreenIsVerified(_ screen: PlaybackScreenTimingReport?, reportAgeNanos: UInt64) -> Bool {
        guard let screen else { return false }
        let threshold = SynchronizedPlayer.hardResyncThresholdNanos
        if let pending = screen.oldestPendingDeadlineMissNanos, pending >= threshold { return false }
        guard let handoffAge = screen.latestHandoffAgeNanos,
              let miss = screen.latestDeadlineMissNanos else { return false }
        // Add only elapsed time on this host since receipt, never subtract the
        // peer's absolute measuredAtNanos from this Mac's monotonic clock.
        let age = handoffAge.addingReportingOverflow(reportAgeNanos)
        guard !age.overflow else { return false }
        // A static screen with no overdue work is not inferred to be stalled.
        return age.partialValue > 2_000_000_000 || miss < threshold
    }

    private static func milliseconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    private static func signedMilliseconds(_ value: Double) -> String {
        String(format: "%+.1f ms", value)
    }
}

struct DiagnosticReportContext: Sendable {
    let generatedAt: Date
    let appVersion: String
    let appBuild: String
    let operatingSystem: String
    let architecture: String
    let room: DiagnosticRoomContext
    let microphoneSelection: String
    var recentSyncEvents: [DiagnosticCheckResult] = []
}

enum DiagnosticRedactor {
    private static let replacements: [(String, String)] = [
        (#"/Users/[^/\s]+"#, "/Users/<redacted>"),
        (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<redacted-id>"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<redacted-ip>"),
        (#"\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b"#, "<redacted-address>"),
        (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted-email>"),
    ]

    static func redact(_ value: String) -> String {
        replacements.reduce(value) { partial, replacement in
            partial.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }
}

enum DiagnosticReportBuilder {
    static func build(
        context: DiagnosticReportContext,
        results: [DiagnosticCheckID: DiagnosticCheckResult]
    ) -> String {
        let timestamp = ISO8601DateFormatter().string(from: context.generatedAt)
        var lines = [
            "ALO Diagnostics",
            "Generated: \(timestamp)",
            "App: \(context.appVersion) (\(context.appBuild))",
            "macOS: \(context.operatingSystem)",
            "Architecture: \(context.architecture)",
            "",
            "Privacy: Room names, device names, peer identifiers, addresses, message content, media metadata, and access keys are not included.",
            "",
            "Current room",
            "- Active: \(context.room.isActive ? "yes" : "no")",
            "- Role: \(context.room.role.rawValue)",
            "- Participants: \(context.room.participantCount) total / \(context.room.remotePeerCount) remote",
            "- Broadcaster present: \(context.room.hasBroadcaster ? "yes" : "no")",
            "- Audio rendering: \(context.room.audioIsRendering ? "yes" : "no")",
            "- Sync state: \(context.room.syncLabel)",
            "- Microphone selection: \(context.microphoneSelection)",
            "",
            "Checks",
        ]
        for id in DiagnosticCheckID.allCases {
            let result = results[id] ?? .idle
            lines.append("- \(id.title): \(result.outcome.label) — \(DiagnosticRedactor.redact(result.detail))")
        }
        if !context.recentSyncEvents.isEmpty {
            lines.append("")
            lines.append("Recent synchronization transitions (up to 16)")
            for event in context.recentSyncEvents.suffix(16) {
                let time = event.checkedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown time"
                lines.append("- \(time): \(event.outcome.label) — \(DiagnosticRedactor.redact(event.detail))")
            }
        }
        return DiagnosticRedactor.redact(lines.joined(separator: "\n")) + "\n"
    }
}

@MainActor
final class DiagnosticsRunner: ObservableObject {
    @Published private(set) var results = Dictionary(
        uniqueKeysWithValues: DiagnosticCheckID.allCases.map { ($0, DiagnosticCheckResult.idle) }
    )
    @Published private(set) var reportNotice: String?
    private var screenPicker: ScreenContentPicker?

    func result(for id: DiagnosticCheckID) -> DiagnosticCheckResult {
        results[id] ?? .idle
    }

    func refreshPassivePermissions() {
        if CGPreflightScreenCaptureAccess() {
            set(.screenPermission, .passed, "Screen Recording access is available.")
        } else {
            set(.screenPermission, .warning, "Screen Recording access has not been granted.")
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            set(.microphone, .passed, "Microphone access is available. Run Test input to verify samples.")
        case .notDetermined:
            set(.microphone, .idle, "Microphone access will be requested when you test input.")
        case .denied, .restricted:
            set(.microphone, .failed, "Microphone access is off in Privacy & Security.")
        @unknown default:
            set(.microphone, .warning, "Microphone access could not be determined.")
        }
    }

    func testScreenPermission() {
        setRunning(.screenPermission)
        Task {
            if CGPreflightScreenCaptureAccess() {
                set(.screenPermission, .passed, "Screen Recording access is available.")
                return
            }
            let granted = await Task.detached(priority: .userInitiated) {
                CGRequestScreenCaptureAccess()
            }.value
            set(
                .screenPermission,
                granted ? .warning : .failed,
                granted
                    ? "Access was granted. Restart ALO before testing capture."
                    : "Access is off. Enable ALO under Screen & System Audio Recording."
            )
        }
    }

    func testScreenPicker() {
        setRunning(.screenPicker)
        let picker = ScreenContentPicker()
        screenPicker = picker
        Task {
            do {
                _ = try await picker.selectDisplayOrWindow()
                picker.deactivate()
                if screenPicker === picker { screenPicker = nil }
                set(.screenPicker, .passed, "A display or window was selected. No capture was started.")
            } catch is CancellationError {
                picker.deactivate()
                if screenPicker === picker { screenPicker = nil }
                set(.screenPicker, .warning, "The native picker opened and was cancelled. No capture was started.")
            } catch {
                picker.deactivate()
                if screenPicker === picker { screenPicker = nil }
                set(.screenPicker, .failed, "The native picker could not open: \(error.localizedDescription)")
            }
        }
    }

    func testSystemAudio() {
        setRunning(.systemAudio)
        Task {
            let counter = DiagnosticSampleCounter()
            let capture = SystemAudioCapture()
            do {
                try await capture.start { samples, _ in counter.record(samples.count) }
                try await Task.sleep(for: .milliseconds(450))
                try await capture.stop()
                let sampleCount = counter.count
                set(
                    .systemAudio,
                    .passed,
                    sampleCount > 0
                        ? "The capture stream opened and delivered \(sampleCount) samples."
                        : "The system-audio capture stream opened successfully; no audio was playing during the check."
                )
            } catch is CancellationError {
                try? await capture.stop()
                set(.systemAudio, .warning, "The system-audio check was cancelled.")
            } catch {
                try? await capture.stop()
                set(.systemAudio, .failed, "System audio could not start: \(error.localizedDescription)")
            }
        }
    }

    func testMicrophone(inputDeviceUID: String?, voiceCaptureIsActive: Bool) {
        guard !voiceCaptureIsActive else {
            set(.microphone, .warning, "End Talk or Open Line before testing the microphone independently.")
            return
        }
        setRunning(.microphone)
        Task {
            guard await WalkieTalkieMicrophone.requestAccess() else {
                set(.microphone, .failed, "Microphone access is off in Privacy & Security.")
                return
            }
            do {
                let snapshot = try await DiagnosticMicrophoneProbe.run(inputDeviceUID: inputDeviceUID)
                guard snapshot.packetCount > 0 else {
                    set(.microphone, .failed, "The input opened, but no microphone samples arrived.")
                    return
                }
                let level = snapshot.peak == 0 ? "silence" : "a live signal"
                set(.microphone, .passed, "Received \(snapshot.packetCount) audio packets and detected \(level).")
            } catch {
                set(.microphone, .failed, "Microphone input could not start: \(error.localizedDescription)")
            }
        }
    }

    func testOutput() {
        setRunning(.output)
        Task {
            do {
                try await DiagnosticOutputProbe.playTone()
                set(.output, .passed, "ALO played a short test tone through the current system output.")
            } catch {
                set(.output, .failed, "The output test could not play: \(error.localizedDescription)")
            }
        }
    }

    func testNetwork(room: DiagnosticRoomContext) {
        setRunning(.network)
        Task {
            let path = await DiagnosticNetworkProbe.status()
            guard path == .satisfied else {
                set(.network, .failed, "This Mac does not currently have an available network path.")
                return
            }
            if room.remotePeerCount > 0 {
                set(.network, .passed, "Network is available and \(room.remotePeerCount) remote room peer\(room.remotePeerCount == 1 ? " is" : "s are") reachable.")
            } else {
                set(.network, .warning, "Network is available, but no remote room peer is currently reachable.")
            }
        }
    }

    func testRoom(_ room: DiagnosticRoomContext) {
        results[.roomSync] = room.result
    }

    func acceptLiveRoomResult(_ result: DiagnosticCheckResult?, isActive: Bool = true,
                              isPaused: Bool = false, hasBroadcaster: Bool = true) {
        if let result {
            results[.roomSync] = result
        } else {
            let guidance: (DiagnosticOutcome, String)
            if !isActive {
                guidance = (.warning, "Open a room to inspect its live clock and synchronization state.")
            } else if isPaused {
                guidance = (.warning, "Playback is paused; resume to measure current synchronization.")
            } else if !hasBroadcaster {
                guidance = (.warning, "Waiting for a broadcaster; current synchronization is not yet measured.")
            } else {
                guidance = (.running, "Checking current synchronization; no fresh timing measurement is available yet.")
            }
            results[.roomSync] = DiagnosticCheckResult(outcome: guidance.0, detail: guidance.1, checkedAt: Date())
        }
    }

    func copyReport(context: DiagnosticReportContext) {
        let report = DiagnosticReportBuilder.build(context: context, results: results)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        reportNotice = "Diagnostic report copied"
    }

    func exportReport(context: DiagnosticReportContext) {
        let report = DiagnosticReportBuilder.build(context: context, results: results)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ALO-Diagnostics-\(formatter.string(from: context.generatedAt)).txt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                self?.reportNotice = "Diagnostic report exported"
            } catch {
                self?.reportNotice = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func openScreenSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    private func setRunning(_ id: DiagnosticCheckID) {
        results[id] = .running
        reportNotice = nil
    }

    private func set(_ id: DiagnosticCheckID, _ outcome: DiagnosticOutcome, _ detail: String) {
        results[id] = DiagnosticCheckResult(outcome: outcome, detail: detail, checkedAt: Date())
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class DiagnosticsWindowController {
    private let window: NSWindow

    init(model: ALOViewModel) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ALO Diagnostics"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 560)
        window.contentView = NSHostingView(rootView: DiagnosticsView(model: model))
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private struct DiagnosticsView: View {
    @ObservedObject var model: ALOViewModel
    @StateObject private var runner = DiagnosticsRunner()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    privacyNotice
                    section("Permissions & capture", ids: [.screenPermission, .screenPicker, .systemAudio])
                    microphoneSection
                    section("Playback & connection", ids: [.output, .network])
                    section("Current room", ids: [.roomSync])
                    roomSyncMonitorSection
                }
                .padding(24)
            }
            Divider()
            reportBar
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshVoiceInputs()
            runner.refreshPassivePermissions()
            runner.testRoom(model.diagnosticRoomContext())
        }
        .onReceive(model.$liveSyncHealth) { health in
            // Reuse the existing sample and cheap UI state; never start another
            // synchronous receiver/host snapshot on every published tick.
            runner.acceptLiveRoomResult(health.result, isActive: model.phase == .live,
                isPaused: model.nowPlaying.isPlaying == false, hasBroadcaster: model.hasBroadcaster)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "stethoscope")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Diagnostics")
                    .font(.title2.weight(.bold))
                Text("Test each part of an ALO room without sending audio or content to peers.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
            Menu {
                Button("Screen Recording settings", action: runner.openScreenSettings)
                Button("Microphone settings", action: runner.openMicrophoneSettings)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Open privacy settings")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var privacyNotice: some View {
        Label {
            Text("Reports exclude room and device names, peer IDs, network addresses, chats, media details, profile images, and private-room keys.")
                .font(.callout)
        } icon: {
            Image(systemName: "hand.raised.fill")
        }
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func section(_ title: String, ids: [DiagnosticCheckID]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(ids, id: \.self) { id in
                DiagnosticCheckCard(
                    id: id,
                    result: runner.result(for: id),
                    actionTitle: actionTitle(for: id),
                    action: { run(id) }
                )
            }
        }
    }

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("INPUT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Microphone", selection: Binding(
                    get: { model.selectedVoiceInputUID },
                    set: { model.selectVoiceInput($0) }
                )) {
                    Text("System Default\(VoiceInputCatalog.systemDefaultName().map { " — \($0)" } ?? "")")
                        .tag(String?.none)
                    ForEach(model.voiceInputDevices) { device in
                        if !device.isSystemDefault {
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }
            DiagnosticCheckCard(
                id: .microphone,
                result: runner.result(for: .microphone),
                actionTitle: "Test input",
                action: {
                    runner.testMicrophone(
                        inputDeviceUID: model.selectedVoiceInputUID,
                        voiceCaptureIsActive: voiceCaptureIsActive
                    )
                }
            )
        }
    }

    private var roomSyncMonitorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LIVE ALIGNMENT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Label(model.phase == .live ? "Live" : "Last room",
                      systemImage: model.phase == .live ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.phase == .live ? .green : .secondary)
            }
            RoomSyncMonitorCard(monitor: model.roomSyncMonitor, isRoomActive: model.phase == .live)
        }
    }

    private var reportBar: some View {
        HStack(spacing: 10) {
            if let notice = runner.reportNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("The report contains technical state only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy report", systemImage: "doc.on.doc") {
                runner.copyReport(context: reportContext)
            }
            Button("Export report…", systemImage: "square.and.arrow.up") {
                runner.exportReport(context: reportContext)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var voiceCaptureIsActive: Bool {
        if model.walkieTalking || model.walkieStarting { return true }
        switch model.openLineState {
        case .inviting, .connected: return true
        case .idle, .invited: return false
        }
    }

    private var reportContext: DiagnosticReportContext {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return DiagnosticReportContext(
            generatedAt: Date(),
            appVersion: version,
            appBuild: build,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            room: model.diagnosticRoomContext(),
            microphoneSelection: model.selectedVoiceInputUID == nil ? "system default" : "custom input",
            recentSyncEvents: model.liveSyncHealth.recentTransitions
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private func actionTitle(for id: DiagnosticCheckID) -> String {
        switch id {
        case .screenPermission: "Check access"
        case .screenPicker: "Open picker"
        case .systemAudio: "Test capture"
        case .microphone: "Test input"
        case .output: "Play sound"
        case .network: "Check peers"
        case .roomSync: "Refresh"
        }
    }

    private func run(_ id: DiagnosticCheckID) {
        switch id {
        case .screenPermission: runner.testScreenPermission()
        case .screenPicker: runner.testScreenPicker()
        case .systemAudio: runner.testSystemAudio()
        case .microphone:
            runner.testMicrophone(
                inputDeviceUID: model.selectedVoiceInputUID,
                voiceCaptureIsActive: voiceCaptureIsActive
            )
        case .output: runner.testOutput()
        case .network: runner.testNetwork(room: model.diagnosticRoomContext())
        case .roomSync: runner.testRoom(model.diagnosticRoomContext())
        }
    }
}

private struct DiagnosticCheckCard: View {
    let id: DiagnosticCheckID
    let result: DiagnosticCheckResult
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: id.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(outcomeColor)
                .frame(width: 36, height: 36)
                .background(outcomeColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(id.title).font(.headline)
                    Text(result.outcome.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(outcomeColor)
                }
                Text(result.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if result.outcome == .running {
                ProgressView().controlSize(.small).frame(width: 92)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .frame(minWidth: 92)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var outcomeColor: Color {
        switch result.outcome {
        case .idle: .secondary
        case .running: .accentColor
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

private struct RoomSyncMonitorCard: View {
    let monitor: RoomSyncMonitor
    let isRoomActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Playback alignment")
                        .font(.headline)
                    Text("Absolute render-clock drift over the last 90 seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                tolerancePill
            }

            if monitor.orderedTraces.isEmpty {
                ContentUnavailableView {
                    Label("Waiting for room timing", systemImage: "waveform.path.ecg")
                } description: {
                    Text(isRoomActive
                         ? "Start room audio to see each Mac's measured playback line."
                         : "Join a room and start audio to record live alignment.")
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                RoomSyncChart(monitor: monitor)
                    .frame(height: 210)
                traceLegend
                Divider()
                eventTimeline
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45), lineWidth: 1))
    }

    private var tolerancePill: some View {
        HStack(spacing: 6) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("Within 40 ms")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.green.opacity(0.10), in: Capsule())
        .help("ALO automatically realigns sustained playback drift at 40 milliseconds.")
    }

    private var traceLegend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 8) {
            ForEach(Array(monitor.orderedTraces.enumerated()), id: \.element.id) { index, trace in
                HStack(spacing: 7) {
                    Circle().fill(SyncTracePalette.color(at: index)).frame(width: 8, height: 8)
                    Text(trace.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(latestValue(trace))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(latestColor(trace))
                }
                .font(.caption.weight(trace.isLocal ? .semibold : .regular))
            }
        }
    }

    private var eventTimeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What changed near the drift")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Observed by ALO")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if monitor.events.isEmpty {
                Text("No timing changes have been recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(monitor.events.suffix(8).reversed())) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(for: event.kind))
                            .foregroundStyle(color(for: event.kind))
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.callout.weight(.semibold))
                            Text(event.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(event.occurredAt, style: .relative)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func latestValue(_ trace: RoomSyncTrace) -> String {
        guard let drift = trace.latest?.driftMilliseconds else { return "No sample" }
        let driftText = drift < 10 ? String(format: "%.1f ms", drift) : String(format: "%.0f ms", drift)
        guard let roundTrip = trace.latest?.roundTripMilliseconds else { return driftText }
        let roundTripText = roundTrip < 10
            ? String(format: "%.1f ms", roundTrip)
            : String(format: "%.0f ms", roundTrip)
        return "\(driftText) · RTT \(roundTripText)"
    }

    private func latestColor(_ trace: RoomSyncTrace) -> Color {
        guard let drift = trace.latest?.driftMilliseconds else { return .secondary }
        return drift >= RoomSyncMonitor.correctionThresholdMilliseconds ? .orange : .secondary
    }

    private func symbol(for kind: RoomSyncEvent.Kind) -> String {
        switch kind {
        case .notice: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .recovery: "checkmark.circle.fill"
        case .correction: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private func color(for kind: RoomSyncEvent.Kind) -> Color {
        switch kind {
        case .notice: .blue
        case .warning: .orange
        case .recovery: .green
        case .correction: .purple
        }
    }
}

private struct RoomSyncChart: View {
    let monitor: RoomSyncMonitor

    var body: some View {
        Canvas { context, size in
            guard let latest = monitor.latestSampleNanos else { return }
            let plot = CGRect(x: 42, y: 10, width: max(1, size.width - 54), height: max(1, size.height - 34))
            let windowNanos: UInt64 = 90_000_000_000
            let start = latest > windowNanos ? latest - windowNanos : 0
            let observedMaximum = monitor.orderedTraces
                .flatMap(\.samples)
                .compactMap(\.driftMilliseconds)
                .max() ?? 0
            let maximum = max(80, ceil(observedMaximum * 1.15 / 20) * 20)
            let threshold = RoomSyncMonitor.correctionThresholdMilliseconds

            let thresholdY = yPosition(threshold, maximum: maximum, plot: plot)
            let healthyBand = CGRect(x: plot.minX, y: thresholdY,
                                     width: plot.width, height: plot.maxY - thresholdY)
            context.fill(Path(healthyBand), with: .color(.green.opacity(0.07)))

            for value in [0.0, threshold, maximum] {
                let y = yPosition(value, maximum: maximum, plot: plot)
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(grid, with: .color(.secondary.opacity(value == threshold ? 0.35 : 0.18)),
                               style: StrokeStyle(lineWidth: value == threshold ? 1.2 : 1,
                                                  dash: value == threshold ? [4, 4] : []))
                let label = value == threshold ? "40" : String(format: "%.0f", value)
                context.draw(Text(label).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary), at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
            }

            for (index, trace) in monitor.orderedTraces.enumerated() {
                var path = Path()
                var hasPoint = false
                for sample in trace.samples where sample.sampledAtNanos >= start {
                    guard let drift = sample.driftMilliseconds else {
                        hasPoint = false
                        continue
                    }
                    let elapsed = sample.sampledAtNanos >= start ? sample.sampledAtNanos - start : 0
                    let x = plot.minX + plot.width * CGFloat(Double(elapsed) / Double(windowNanos))
                    let y = yPosition(drift, maximum: maximum, plot: plot)
                    if hasPoint { path.addLine(to: CGPoint(x: x, y: y)) }
                    else { path.move(to: CGPoint(x: x, y: y)); hasPoint = true }
                }
                context.stroke(path, with: .color(SyncTracePalette.color(at: index)),
                               style: StrokeStyle(lineWidth: trace.isLocal ? 2.6 : 2,
                                                  lineCap: .round, lineJoin: .round))
                if let sample = trace.samples.last, let drift = sample.driftMilliseconds {
                    let elapsed = sample.sampledAtNanos >= start ? sample.sampledAtNanos - start : 0
                    let point = CGPoint(x: plot.minX + plot.width * CGFloat(Double(elapsed) / Double(windowNanos)),
                                        y: yPosition(drift, maximum: maximum, plot: plot))
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                                 with: .color(SyncTracePalette.color(at: index)))
                }
            }

            context.draw(Text("90s ago").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.minX, y: plot.maxY + 15), anchor: .leading)
            context.draw(Text("now").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.maxX, y: plot.maxY + 15), anchor: .trailing)
            context.draw(Text("ms").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.minX - 8, y: plot.minY), anchor: .trailing)
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback alignment graph")
        .accessibilityValue(accessibilitySummary)
        .help("Each line is measured render-clock drift. Missing reports create gaps rather than a false zero line.")
    }

    private func yPosition(_ value: Double, maximum: Double, plot: CGRect) -> CGFloat {
        plot.maxY - plot.height * CGFloat(min(max(value, 0), maximum) / maximum)
    }

    private var accessibilitySummary: String {
        monitor.orderedTraces.map { trace in
            guard let drift = trace.latest?.driftMilliseconds else { return "\(trace.name), no current sample" }
            return "\(trace.name), \(Int(drift.rounded())) milliseconds drift"
        }.joined(separator: "; ")
    }
}

private enum SyncTracePalette {
    private static let colors: [Color] = [.blue, .purple, .pink, .cyan, .orange, .mint, .indigo, .yellow]
    static func color(at index: Int) -> Color { colors[index % colors.count] }
}

private final class DiagnosticSampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleCount = 0

    var count: Int { lock.withLock { sampleCount } }
    func record(_ count: Int) { lock.withLock { sampleCount += count } }
}

private struct DiagnosticMicrophoneSnapshot: Sendable {
    let packetCount: Int
    let peak: Int
}

private final class DiagnosticMicrophoneState: @unchecked Sendable {
    private let lock = NSLock()
    private var packetCount = 0
    private var peak = 0

    func record(_ data: Data) {
        let localPeak = data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).reduce(0) { value, sample in
                max(value, abs(Int(sample)))
            }
        }
        lock.withLock {
            packetCount += 1
            peak = max(peak, localPeak)
        }
    }

    func snapshot() -> DiagnosticMicrophoneSnapshot {
        lock.withLock { DiagnosticMicrophoneSnapshot(packetCount: packetCount, peak: peak) }
    }
}

private enum DiagnosticMicrophoneProbe {
    static func run(inputDeviceUID: String?) async throws -> DiagnosticMicrophoneSnapshot {
        let state = DiagnosticMicrophoneState()
        let microphone = WalkieTalkieMicrophone()
        let sessionID = UUID().uuidString
        try await microphone.start(
            sessionID: sessionID,
            inputDeviceUID: inputDeviceUID,
            handler: { state.record($0) },
            failureHandler: { _ in }
        )
        do {
            try await Task.sleep(for: .milliseconds(900))
        } catch {
            microphone.stop(sessionID: sessionID)
            throw error
        }
        microphone.stop(sessionID: sessionID)
        try? await Task.sleep(for: .milliseconds(40))
        return state.snapshot()
    }
}

private enum DiagnosticOutputProbe {
    static func playTone() async throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000),
           let channel = buffer.floatChannelData?[0]
        else { throw ALOError("ALO could not create the output test tone.") }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let envelope = min(1, Float(frame) / 1_200) * min(1, Float(Int(buffer.frameLength) - frame) / 1_200)
            channel[frame] = sin(Float(frame) * 2 * .pi * 523.25 / 48_000) * 0.16 * envelope
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
        await player.scheduleBuffer(buffer, at: nil, options: [])
        player.stop()
        engine.stop()
    }
}

private enum DiagnosticNetworkStatus: Sendable {
    case satisfied
    case unsatisfied
}

private final class DiagnosticContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}

private enum DiagnosticNetworkProbe {
    static func status() async -> DiagnosticNetworkStatus {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "in.werai.diagnostics.network")
            let gate = DiagnosticContinuationGate()
            monitor.pathUpdateHandler = { path in
                guard gate.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied ? .satisfied : .unsatisfied)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) {
                guard gate.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: .unsatisfied)
            }
        }
    }
}
