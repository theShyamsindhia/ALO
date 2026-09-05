import SwiftUI

/// Local preferences and diagnostics stay out of the compact playback surface.
struct RoomPreferencesView: View {
    @ObservedObject var model: ALOViewModel
    @ObservedObject private var lyrics: LyricsController
    init(model: ALOViewModel) { self.model = model; lyrics = model.lyrics }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Room settings").font(.headline)
                Text("This Mac").font(.caption).foregroundStyle(.secondary)
                Toggle("Automatically keep this Mac in sync", isOn: Binding(get: { model.automaticAudioSync }, set: model.setAutomaticAudioSync))
                Text("Corrects drift above 40 ms after one second, with eight seconds between corrections. Other Macs keep their own settings. Device and playback recovery remain active.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Audio timing") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let timing = model.localAudioTiming {
                            metric("Network round trip", timing.roundTripMilliseconds)
                            metric("Room playback delay", timing.activePlayoutBufferMilliseconds)
                            metric("Output delay", timing.outputLatencyMilliseconds)
                            if let age = timing.driftMeasurementAgeMilliseconds, age <= 1500 {
                                metric("Current drift", timing.currentDriftMilliseconds)
                            } else { Text("Current drift · awaiting a fresh sample") }
                            Text("Automatic sync · \(timing.automaticSyncState ?? "waiting")")
                        } else { Text("Timing appears while this Mac is receiving audio.") }
                        Text("Network delay and playback drift are different. Resync corrects alignment; it cannot make a slow connection faster.")
                            .foregroundStyle(.secondary)
                        Button("Sync this Mac now", action: model.syncThisMac)
                            .disabled(!model.hasBroadcaster || model.currentParticipantID == nil || model.mediaSwitchBusy)
                    }.font(.caption).padding(.top, 8)
                }
                Divider()
                Toggle("Lower music during voice", isOn: Binding(get: { model.musicDuckingEnabled }, set: model.setMusicDuckingEnabled))
                Text(model.microphoneAudienceSummary).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Test microphone") {
                    MicrophoneTestPanel(selectedInputUID: model.selectedVoiceInputUID,
                        unavailable: model.walkieTalking || model.walkieStarting || model.openLineState.isSendingMicrophone || model.isHost,
                        showsTitle: false)
                }
                Button("Turn microphone off", action: model.silenceMicrophone)
                Button(model.incomingMediaMuted && model.incomingCallsMuted ? "Unmute room audio" : "Mute room audio", action: model.toggleAllIncomingAudio)
                Divider()
                Toggle("Show lyrics in chat", isOn: $lyrics.enabled)
                Text(LyricsController.privacyNotice).font(.caption).foregroundStyle(.secondary)
                Divider()
                Text(model.connectionSummary).font(.caption)
                Text(model.activePrivateInviteKey == nil ? "Public room · discoverable nearby" : "Private room · invite key required")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(18)
        }.frame(width: 330).frame(maxHeight: 540)
    }
    private func metric(_ title: String, _ value: Double?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.map { String(format: "%.0f ms", $0) } ?? "Measuring…").monospacedDigit()
        }
    }
}
