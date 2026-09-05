import SwiftUI

struct DJRecordButton: View {
    @ObservedObject var studio: DJStudio
    let label: String
    let stage: DJLiveStage?
    @ObservedObject var bindings: DJKeyBindings
    private var active: Bool { studio.recordingDeck == label }
    var body: some View {
        Button {
            studio.perform { try studio.toggleDeckRecording(label, stage: stage) }
        } label: {
            Label(active ? String(format: "Stop %.1fs", studio.liveSnapshot.recordingDuration) : "REC",
                  systemImage: active ? "stop.fill" : "record.circle")
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(active ? .white : .red)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.red.opacity(active ? 0.8 : 0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.red.opacity(0.5)))
        .disabled((!active && (stage == nil || studio.sharing)) || (studio.recordingDeck != nil && !active))
        .help(active ? "Stop recording and load the take on deck \(label)" : "Record playing broadcast into deck \(label) · up to 32 seconds · \(bindings.label(for: label == "A" ? .deckARecord : .deckBRecord))")
        .accessibilityLabel(active ? "Stop deck \(label) recording" : "Record live broadcast to deck \(label)")
    }
}
