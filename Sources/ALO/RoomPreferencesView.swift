import SwiftUI

/// Local preferences and diagnostics stay out of the compact playback surface.
struct RoomPreferencesView: View {
    @ObservedObject var model: ALOViewModel
    @ObservedObject private var lyrics: LyricsController

    init(model: ALOViewModel) {
        self.model = model
        lyrics = model.lyrics
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Room settings").font(.headline)

                sectionTitle("This Mac")
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
                    Button(model.incomingMediaMuted && model.incomingCallsMuted ? "Unmute room audio" : "Mute room audio",
                           action: model.toggleAllIncomingAudio)
                }

                Divider()

                Toggle(isOn: $lyrics.enabled) {
                    settingLabel("Show lyrics in chat", help: LyricsController.privacyNotice)
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
