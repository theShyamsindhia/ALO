import SwiftUI

/// Local preferences and diagnostics stay out of the compact playback surface.
struct RoomPreferencesView: View {
    @ObservedObject var model: ALOViewModel
    @ObservedObject private var lyrics: LyricsController
    @State private var showsAbout = false

    init(model: ALOViewModel) {
        self.model = model
        lyrics = model.lyrics
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Room settings").font(.headline)

                sectionTitle("Playback on this Mac")
                Toggle(isOn: Binding(get: { model.automaticAudioSync }, set: model.setAutomaticAudioSync)) {
                    settingLabel("Automatically keep this Mac in sync",
                                 help: "Corrects drift above 40 ms after one second, with eight seconds between corrections. Other Macs keep their own setting.")
                }
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
                        Button("Sync this Mac now", action: model.syncThisMac)
                            .disabled(!model.hasBroadcaster || model.currentParticipantID == nil || model.mediaSwitchBusy)
                    }
                    .font(.caption)
                    .padding(.top, 8)
                } label: {
                    settingLabel("Audio timing",
                                 help: "Network delay and playback drift are separate. Sync corrects alignment; it cannot reduce network latency.")
                }

                Divider()

                sectionTitle("Voice and shared audio")
                Picker(selection: microphoneSelection) {
                    Text(systemDefaultMicrophoneLabel).tag("")
                    ForEach(model.voiceInputDevices) { input in
                        Text(input.menuName).tag(input.id)
                    }
                } label: {
                    settingLabel("Microphone input", help: "Choose the microphone used for Talk and Open Line on this Mac.")
                }
                .pickerStyle(.menu)

                Picker(selection: audioSourceSelection) {
                    Text("All system audio").tag("")
                    if let selectedID = model.selectedAudioSourceBundleID,
                       !model.audioSourceApplications.contains(where: { $0.bundleIdentifier == selectedID }) {
                        Text("\(model.selectedAudioSourceName ?? "Selected app") · unavailable").tag(selectedID)
                    }
                    ForEach(model.audioSourceApplications) { application in
                        Text(application.name).tag(application.bundleIdentifier)
                    }
                } label: {
                    settingLabel("Audio to share", help: "Share all system audio or only audio from one currently audible app.")
                }
                .pickerStyle(.menu)
                .disabled(model.isHost)

                if model.isHost {
                    Text("Stop broadcasting to change the shared-audio source.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.audioSourceApplications.isEmpty {
                    Text("Play audio in an app, then refresh the list.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Refresh microphones", action: model.refreshVoiceInputs)
                    Button("Refresh audible apps", action: model.refreshAudioSourceApplications)
                }

                Toggle(isOn: Binding(get: { model.musicDuckingEnabled }, set: model.setMusicDuckingEnabled)) {
                    settingLabel("Lower music during voice",
                                 help: "Reduces incoming room music while someone is speaking.")
                }
                HStack(spacing: 7) {
                    Circle().fill(microphoneStatusColor).frame(width: 7, height: 7)
                    Text(model.microphoneAudienceSummary).foregroundStyle(.secondary)
                }
                .font(.caption)
                DisclosureGroup("Test microphone") {
                    MicrophoneTestPanel(
                        selectedInputUID: model.selectedVoiceInputUID,
                        unavailable: model.walkieTalking || model.walkieStarting || model.openLineState.isSendingMicrophone || model.isHost,
                        showsTitle: false
                    )
                }
                HStack(spacing: 8) {
                    Button("Turn microphone off", action: model.silenceMicrophone)
                    Button(model.incomingCallsMuted ? "Unmute incoming voice" : "Mute incoming voice",
                           action: model.toggleIncomingCallsMute)
                }
                Button(model.incomingMediaMuted ? "Unmute room media" : "Mute room media",
                       action: model.toggleIncomingMediaMute)

                Divider()

                sectionTitle("Interface")
                HStack(spacing: 8) {
                    Button(model.walkieBarHidden ? "Show Talk bar" : "Hide Talk bar") {
                        model.walkieBarHidden ? model.showWalkieBar() : model.hideWalkieBar()
                    }
                    Button(model.floatingBarHidden ? "Show media bar" : "Hide media bar") {
                        model.floatingBarHidden ? model.showFloatingBar() : model.hideFloatingBar()
                    }
                }
                ALONotchSettingsMenu()
                HStack(spacing: 8) {
                    Button("Shortcut Mapper…", action: model.showShortcutMapper)
                    Button("Diagnostics…", action: model.showDiagnostics)
                }
                HStack(spacing: 8) {
                    Button("App settings…", action: model.showAppSettings)
                    Button("About ALO…") { showsAbout = true }
                        .popover(isPresented: $showsAbout, arrowEdge: .trailing) {
                            AboutALOView(model: model)
                        }
                }

                Divider()

                Toggle(isOn: $lyrics.enabled) {
                    settingLabel("Show lyrics below the player", help: LyricsController.privacyNotice)
                }

                Divider()

                HStack(spacing: 7) {
                    Circle().fill(connectionStatusColor).frame(width: 7, height: 7)
                    Text(model.connectionSummary)
                    Spacer(minLength: 8)
                    infoIcon(model.activePrivateInviteKey == nil
                             ? "Public room · discoverable nearby"
                             : "Private room · invite key required")
                }
                .font(.caption)
            }
            .font(.system(size: 12))
            .padding(18)
        }
        .frame(width: 330)
        .frame(maxHeight: 500)
        .onAppear {
            model.refreshVoiceInputs()
            model.refreshAudioSourceApplications()
        }
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
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
