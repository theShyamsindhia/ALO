import SwiftUI

struct DJGuideView: View {
    @ObservedObject var bindings: DJKeyBindings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("DJ Studio guide", systemImage: "questionmark.circle").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    step("1 · Load and scrub", "Click Load song on a deck, or drop an audio file onto it. Its waveform loads below the song title. Drag across the waveform or use the slider to seek. The white line is your playhead; the colored region is your loop.")
                    step("2 · Set your loop", "Enter the song’s original BPM, choose 1, 2, 4, 8, or 16 beats, then press Loop at your desired starting point. Press Play if paused. For a custom region, press In, move or play forward, then press Out. Loops can be up to 32 seconds. Exit loop resumes the song from the current position; Clear also removes the markers. Seeking outside the region exits the loop.")
                    step("3 · Perform from the keyboard", "Keys work while DJ Studio is the active window. They pause while you type or use a dialog. Open Keys to change them; duplicate assignments are rejected and changes are saved.")
                    Grid(alignment: .leading, horizontalSpacing: 25, verticalSpacing: 7) {
                        keyRow("Deck A / B play", .deckAPlay, .deckBPlay)
                        keyRow("Deck A / B cue", .deckACue, .deckBCue)
                        keyRow("Deck A / B loop", .deckALoop, .deckBLoop)
                        GridRow { Text("Crossfader A / center / B"); Text([DJAction.crossfadeLeft, .crossfadeCenter, .crossfadeRight].map { bindings.label(for: $0) }.joined(separator: " / ")).monospaced() }
                        GridRow { Text("Stop all"); Text(bindings.label(for: .stopAll)).monospaced() }
                    }.font(.callout).padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    step("4 · Play the launchpad", "Click a pad or press its displayed key. Right-click to load a sample up to 10 seconds long or restore its built-in sound. Pad gain controls new hits. Pads are one-shots; the deck Looper repeats song regions.")
                    step("5 · Mix and share", "Use channel gain and EQ to balance the decks, then blend with the crossfader. Match tempo uses your entered BPMs; it does not detect beats or align their phase. Watch the master meter and lower gain at peaks. Share DJ mix sends both decks and pads to the room. Stop the current broadcast first.")
                    step("Live broadcast on Deck A", "Select Live broadcast above A to process room audio directly. The waveform and rewind slider use the last 32 seconds in memory. Jump live returns to incoming audio. Set BPM and loop the last selected beats, or use In/Out. A’s play key mutes/unmutes the input. EQ, gain and crossfader affect it; B and pads mix alongside it. At the broadcaster this changes the room audio; at a listener it changes only this Mac. Voice chat bypasses these effects. Live tempo follows the stream. Room Song retains the source’s supported previous/play/next controls.")
                    step("Stopping", "Stop all silences the decks and pads, including live input. Closing DJ Studio discards live history and restores normal room audio; it also ends a dedicated DJ mix broadcast. Changing audio output stops playback; press Play again after the change. This version uses your Mac’s current output, without a separate headphone cue output.")
                }
            }
        }.padding(24).frame(width: 650, height: 700).preferredColorScheme(.dark)
    }
    private func step(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func keyRow(_ title: String, _ a: DJAction, _ b: DJAction) -> some View {
        GridRow { Text(title); Text("\(bindings.label(for: a)) / \(bindings.label(for: b))").monospaced() }
    }
}
