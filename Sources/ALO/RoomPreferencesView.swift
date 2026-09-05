import SwiftUI

/// Local preferences and diagnostics stay out of the compact playback surface.
struct RoomPreferencesView: View {
    @ObservedObject var model: ALOViewModel
    @ObservedObject private var lyrics: LyricsController
    @State private var showsAbout = false
    @State private var selectedSection = SettingsSection.audio

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case audio = "Audio"
        case playback = "Playback"
        case interface = "Interface"

        var id: Self { self }

        var summary: String {
            switch self {
            case .audio: "Choose what you share and hear"
            case .playback: "Keep this Mac aligned with the room"
            case .interface: "Choose which controls stay visible"
            }
        }
    }

    init(model: ALOViewModel) {
        self.model = model
        lyrics = model.lyrics
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Room settings")
                        .font(.system(size: 15, weight: .semibold))
                    Text(selectedSection.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Settings section", selection: $selectedSection) {
                    ForEach(SettingsSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 13)

            Divider()

            ScrollView {
                Group {
                    switch selectedSection {
                    case .audio:
                        audioSettings
                    case .playback:
                        playbackSettings
                    case .interface:
                        interfaceSettings
                    }
                }
                .id(selectedSection)
                .padding(16)
            }
            .scrollIndicators(.never)
            .frame(height: 340)

            Divider()

            connectionFooter
                .padding(.horizontal, 16)
                .frame(height: 38)
        }
        .font(.system(size: 12))
        .frame(width: 360)
        .onAppear {
            model.refreshVoiceInputs()
            model.refreshAudioSourceApplications()
        }
    }

    private var audioSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            preferenceSection("Sources", systemImage: "waveform") {
                sourcePicker(
                    title: "Microphone",
                    help: "Choose the microphone used for Talk and Open Line on this Mac.",
                    refreshHelp: "Refresh microphones",
                    refresh: model.refreshVoiceInputs
                ) {
                    Picker("Microphone", selection: microphoneSelection) {
                        Text(systemDefaultMicrophoneLabel).tag("")
                        ForEach(model.voiceInputDevices) { input in
                            Text(input.menuName).tag(input.id)
                        }
                    }
                }

                sourcePicker(
                    title: "Shared audio",
                    help: "Share all system audio or only audio from one currently audible app.",
                    refreshHelp: "Refresh audible apps",
                    refresh: model.refreshAudioSourceApplications
                ) {
                    Picker("Shared audio", selection: audioSourceSelection) {
                        Text("All system audio").tag("")
                        if let selectedID = model.selectedAudioSourceBundleID,
                           !model.audioSourceApplications.contains(where: { $0.bundleIdentifier == selectedID }) {
                            Text("\(model.selectedAudioSourceName ?? "Selected app") · unavailable").tag(selectedID)
                        }
                        ForEach(model.audioSourceApplications) { application in
                            Text(application.name).tag(application.bundleIdentifier)
                        }
                    }
                    .disabled(model.isHost)
                }

                if model.isHost {
                    guidance("Stop broadcasting to change the shared-audio source.")
                } else if model.audioSourceApplications.isEmpty {
                    guidance("Play audio in an app, then refresh the list.")
                }
            }

            Divider()

            preferenceSection("What you hear", systemImage: "speaker.wave.2") {
                Toggle("Incoming voice", isOn: incomingVoiceEnabled)
                Toggle("Room media", isOn: incomingMediaEnabled)
            }

            Divider()

            preferenceSection("Voice", systemImage: "mic") {
                Toggle(isOn: Binding(get: { model.musicDuckingEnabled }, set: model.setMusicDuckingEnabled)) {
                    settingLabel("Lower room music while people speak",
                                 help: "Reduces incoming room music while someone is speaking.")
                }

                statusLine(model.microphoneAudienceSummary, color: microphoneStatusColor)

                DisclosureGroup("Test microphone") {
                    MicrophoneTestPanel(
                        selectedInputUID: model.selectedVoiceInputUID,
                        unavailable: model.walkieTalking || model.walkieStarting || model.openLineState.isSendingMicrophone || model.isHost,
                        showsTitle: false
                    )
                    .padding(.top, 8)
                }

                Button(action: model.silenceMicrophone) {
                    Label("Turn microphone off", systemImage: "mic.slash")
                }
                .controlSize(.small)
            }
        }
    }

    private var playbackSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            preferenceSection("Synchronization", systemImage: "arrow.triangle.2.circlepath") {
                Toggle(isOn: Binding(get: { model.automaticAudioSync }, set: model.setAutomaticAudioSync)) {
                    settingLabel("Keep this Mac in sync automatically",
                                 help: "Corrects drift above 40 ms after one second, with eight seconds between corrections. Other Macs keep their own setting.")
                }

                Button(action: model.syncThisMac) {
                    Label("Sync this Mac now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(!model.hasBroadcaster || model.currentParticipantID == nil || model.mediaSwitchBusy)

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 7) {
                        if let timing = model.localAudioTiming {
                            metric("Network round trip", timing.roundTripMilliseconds)
                            metric("Room playback delay", timing.activePlayoutBufferMilliseconds)
                            metric("Output delay", timing.outputLatencyMilliseconds)
                            if let age = timing.driftMeasurementAgeMilliseconds, age <= 1500 {
                                metric("Current drift", timing.currentDriftMilliseconds)
                            } else {
                                Text("Current drift · measuring…")
                            }
                            Text("Automatic sync · \(timing.automaticSyncState ?? "waiting")")
                        } else {
                            Text("Timing appears while this Mac is receiving audio.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                } label: {
                    settingLabel("Timing details",
                                 help: "Network delay and playback drift are separate. Sync corrects alignment; it cannot reduce network latency.")
                }
            }

            Divider()

            preferenceSection("Player", systemImage: "quote.bubble") {
                Toggle(isOn: $lyrics.enabled) {
                    settingLabel("Show lyrics below the player", help: LyricsController.privacyNotice)
                }
            }
        }
    }

    private var interfaceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            preferenceSection("Room controls", systemImage: "rectangle.on.rectangle") {
                Toggle("Show Talk bar", isOn: talkBarVisible)
                Toggle("Show media bar", isOn: mediaBarVisible)
            }

            Divider()

            preferenceSection("Tools", systemImage: "wrench.and.screwdriver") {
                navigationButton("Shortcut Mapper", systemImage: "keyboard", action: model.showShortcutMapper)
                navigationButton("Diagnostics", systemImage: "waveform.path.ecg", action: model.showDiagnostics)
                navigationButton("App settings", systemImage: "gearshape", action: model.showAppSettings)
                navigationButton("About ALO", systemImage: "info.circle") { showsAbout = true }
                    .popover(isPresented: $showsAbout, arrowEdge: .trailing) {
                        AboutALOView(model: model)
                    }
            }
        }
    }

    private var connectionFooter: some View {
        HStack(spacing: 7) {
            Circle().fill(connectionStatusColor).frame(width: 7, height: 7)
            Text(model.connectionSummary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            infoIcon(model.activePrivateInviteKey == nil
                     ? "Public room · discoverable nearby"
                     : "Private room · invite key required")
        }
        .font(.caption)
    }

    private var microphoneSelection: Binding<String> {
        Binding(
            get: { model.selectedVoiceInputUID ?? "" },
            set: { model.selectVoiceInput($0.isEmpty ? nil : $0) }
        )
    }

    private var audioSourceSelection: Binding<String> {
        Binding(
            get: { model.selectedAudioSourceBundleID ?? "" },
            set: { bundleIdentifier in
                guard !bundleIdentifier.isEmpty else {
                    model.selectAudioSource(nil)
                    return
                }
                guard let application = model.audioSourceApplications.first(where: {
                    $0.bundleIdentifier == bundleIdentifier
                }) else { return }
                model.selectAudioSource(application)
            }
        )
    }

    private var incomingVoiceEnabled: Binding<Bool> {
        Binding(
            get: { !model.incomingCallsMuted },
            set: { shouldHear in
                if shouldHear == model.incomingCallsMuted { model.toggleIncomingCallsMute() }
            }
        )
    }

    private var incomingMediaEnabled: Binding<Bool> {
        Binding(
            get: { !model.incomingMediaMuted },
            set: { shouldHear in
                if shouldHear == model.incomingMediaMuted { model.toggleIncomingMediaMute() }
            }
        )
    }

    private var talkBarVisible: Binding<Bool> {
        Binding(
            get: { !model.walkieBarHidden },
            set: { shouldShow in
                guard shouldShow == model.walkieBarHidden else { return }
                shouldShow ? model.showWalkieBar() : model.hideWalkieBar()
            }
        )
    }

    private var mediaBarVisible: Binding<Bool> {
        Binding(
            get: { !model.floatingBarHidden },
            set: { shouldShow in
                guard shouldShow == model.floatingBarHidden else { return }
                shouldShow ? model.showFloatingBar() : model.hideFloatingBar()
            }
        )
    }

    private var systemDefaultMicrophoneLabel: String {
        VoiceInputCatalog.automaticInputName().map { "Automatic — \($0)" }
            ?? "Automatic Microphone"
    }

    private var microphoneStatusColor: Color {
        model.microphoneAudienceSummary.localizedCaseInsensitiveContains("off") ? .secondary : .green
    }

    private var connectionStatusColor: Color {
        model.phase == .live ? .green : .orange
    }

    private func preferenceSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourcePicker<Content: View>(
        title: String,
        help: String,
        refreshHelp: String,
        refresh: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                settingLabel(title, help: help)
                Spacer()
                Button(action: refresh) {
                    Label(refreshHelp, systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(refreshHelp)
                .accessibilityLabel(refreshHelp)
            }
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func guidance(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func navigationButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private func settingLabel(_ title: String, help: String) -> some View {
        HStack(spacing: 7) {
            Text(title)
            infoIcon(help)
        }
    }

    private func infoIcon(_ help: String) -> some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityLabel(help)
    }

    private func metric(_ title: String, _ value: Double?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.map { String(format: "%.0f ms", $0) } ?? "Measuring…").monospacedDigit()
        }
    }
}

private struct AboutALOView: View {
    @ObservedObject var model: ALOViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ALO").font(.title2.bold())
                    Text(versionDescription).foregroundStyle(.secondary)
                    if let available = model.availableUpdateVersion {
                        Label("ALO \(available) is available", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
            }

            Divider()

            Button(model.availableUpdateVersion == nil ? "Check for Updates" : "Check Again") {
                model.checkForUpdates()
            }
            .disabled(!model.canCheckForUpdates)
            .help(model.canCheckForUpdates
                  ? "Check the official ALO GitHub release for a newer signed version"
                  : "Update checks are available in packaged builds")

            Text(model.canCheckForUpdates
                 ? "Updates are downloaded from the official ALO GitHub releases and verified before installation."
                 : "This development build cannot install app updates automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .padding(18)
        .frame(width: 310)
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? (model.canCheckForUpdates ? "—" : "Development")
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else { return "Version \(version)" }
        return "Version \(version) · Build \(build)"
    }
}
