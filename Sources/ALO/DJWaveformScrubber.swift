import SwiftUI

struct DJWaveformScrubber: View {
    @ObservedObject var deck: DJDeck
    @ObservedObject var studio: DJStudio
    var color: Color
    var label: String
    @State private var preview: Double?
    private var displayedPosition: Double { preview ?? deck.position }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("WAVEFORM / SCRUB").font(.system(size: 9, weight: .bold)).tracking(1)
                Spacer()
                Text(deck.duration == 0 ? "Load or drop an audio file" : "Drag to seek")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.3))
                    Canvas { context, size in
                        let width = size.width, height = size.height
                        if let start = deck.loopStart, let end = deck.loopEnd, deck.duration > 0 {
                            let rect = CGRect(x: start / deck.duration * width, y: 0,
                                              width: (end - start) / deck.duration * width, height: height)
                            context.fill(Path(rect), with: .color(color.opacity(deck.loopEnabled ? 0.25 : 0.1)))
                        }
                        var waveform = Path()
                        for (index, peak) in deck.waveform.enumerated() {
                            let x = (Double(index) + 0.5) / Double(deck.waveform.count) * width
                            let amplitude = max(1, Double(peak) * (height - 8) / 2)
                            waveform.move(to: CGPoint(x: x, y: height / 2 - amplitude))
                            waveform.addLine(to: CGPoint(x: x, y: height / 2 + amplitude))
                        }
                        context.stroke(waveform, with: .color(color.opacity(0.7)), lineWidth: 1)
                        if deck.duration > 0 {
                            let x = min(width, max(0, displayedPosition / deck.duration * width))
                            var cursor = Path()
                            cursor.move(to: CGPoint(x: x, y: 0)); cursor.addLine(to: CGPoint(x: x, y: height))
                            context.stroke(cursor, with: .color(.white), lineWidth: 2)
                        }
                    }
                    if deck.waveformLoading {
                        ProgressView("Loading waveform…").controlSize(.small).font(.caption2)
                    } else if deck.duration == 0 {
                        Label("Your song appears here", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                    } else if deck.waveform.isEmpty {
                        Text("Waveform unavailable · use the slider").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard deck.duration > 0 else { return }
                        preview = min(1, max(0, value.location.x / max(1, geometry.size.width))) * deck.duration
                    }
                    .onEnded { _ in
                        if let preview { studio.perform { try deck.seek(preview) } }
                        preview = nil
                    })
            }.frame(height: 55)
            Slider(value: Binding(get: { deck.position }, set: { value in studio.perform { try deck.seek(value) } }),
                   in: 0...max(1, deck.duration))
                .disabled(deck.duration == 0).tint(color)
                .accessibilityLabel("Deck \(label) scrubber")
                .help("Seek within the loaded song. Seeking outside a loop exits it.")
        }
    }
}
