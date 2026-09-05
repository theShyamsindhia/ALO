import SwiftUI

/// Deck A's rolling live input. Seeking changes this mix's delay, never the source app's playhead.
struct DJLiveDeckView: View {
    @ObservedObject var studio: DJStudio
    @ObservedObject var deck: DJDeck
    @ObservedObject var bindings: DJKeyBindings
    @State private var scrubDelay: Double = 0
    @State private var scrubbing = false
    private let color = Color.cyan
    private var live: DJLiveSnapshot { studio.liveSnapshot }
    private var waitingForInput: Bool { live.secondsSinceInput.map { $0 > 1 } ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("DECK A · LIVE").font(.caption.weight(.bold)).tracking(2).foregroundStyle(color)
                Spacer()
                Label(live.looping ? "LOOP" : waitingForInput ? "WAITING" : live.delaySeconds > 0.05 ? "REWIND" : "LIVE", systemImage: live.looping ? "repeat" : "dot.radiowaves.left.and.right")
                    .font(.caption2.weight(.bold)).foregroundStyle(live.looping ? color : waitingForInput ? .secondary : .green)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Broadcast input").font(.headline)
                Text(live.stage == .broadcast ? "Your changes are heard by the whole room" : "Your changes are heard only on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
            }
            waveform
            HStack {
                Button { studio.toggleLivePlayback() } label: {
                    Label(live.muted ? "Unmute" : "Mute", systemImage: live.muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }.buttonStyle(.borderedProminent).tint(color)
                    .help("Mute live input · \(bindings.label(for: .deckAPlay))")
                Button("Cue") { action { try DJLiveAudio.shared.returnToCue() } }.disabled(!live.hasCue)
                    .help("Return to live cue · \(bindings.label(for: .deckACue))")
                Button { DJLiveAudio.shared.setCue(); studio.refreshLive() } label: { Image(systemName: "flag.fill") }
                    .help("Set cue in the recent live buffer").accessibilityLabel("Set live cue")
                    .disabled(live.historyDuration == 0)
                Spacer(minLength: 0)
            }
            looper
            HStack {
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                TextField("BPM", value: $deck.bpm, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 55).accessibilityLabel("Live input BPM for beat loops")
                Text("For loop length").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text("Tempo follows the live stream").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                eq("LOW", value: $deck.low)
                eq("MID", value: $deck.mid)
                eq("HIGH", value: $deck.high)
            }
            HStack {
                Text("Gain").font(.caption)
                Slider(value: $deck.gain, in: 0...1).accessibilityLabel("Live input gain")
                Text("\(Int(deck.gain * 100))%").font(.caption.monospacedDigit()).frame(width: 32)
            }
        }.padding(16).frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.22)))
    }

    private var waveform: some View {
        VStack(spacing: 6) {
            HStack {
                Text("WAVEFORM / REWIND").font(.caption2.weight(.bold)).tracking(1)
                Spacer()
                Text("Drag to scrub").font(.caption2).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                let peaks = live.waveform
                guard !peaks.isEmpty else { return }
                let step = size.width / Double(peaks.count)
                var bars = Path()
                for (index, peak) in peaks.enumerated() {
                    let height = max(1, Double(peak) * size.height * 0.9)
                    bars.addRoundedRect(in: CGRect(x: Double(index) * step, y: (size.height - height) / 2,
                                                   width: max(1, step - 1), height: height), cornerSize: CGSize(width: 1, height: 1))
                }
                context.fill(bars, with: .color(color.opacity(0.7)))
                let delay = scrubbing ? scrubDelay : live.delaySeconds
                let x = size.width * (1 - min(1, delay / max(0.001, live.historyDuration)))
                var playhead = Path()
                playhead.move(to: CGPoint(x: x, y: 0)); playhead.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(playhead, with: .color(.white), lineWidth: 2)
            }.frame(height: 63)
                .overlay {
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard live.historyDuration > 0 else { return }
                                    scrubbing = true
                                    let fraction = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                                    scrubDelay = live.historyDuration * (1 - fraction)
                                }
                                .onEnded { _ in
                                    guard scrubbing else { return }
                                    action { try DJLiveAudio.shared.setDelay(seconds: scrubDelay) }
                                    scrubbing = false
                                })
                    }
                }
                .overlay {
                    if waitingForInput && !live.looping {
                        Text("Waiting for broadcast audio…").font(.caption).foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 8)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Recent live audio waveform")
            Slider(value: Binding(get: { max(0, live.historyDuration - (scrubbing ? scrubDelay : live.delaySeconds)) },
                                  set: {
                                      scrubDelay = max(0, live.historyDuration - $0)
                                      if !scrubbing { action { try DJLiveAudio.shared.setDelay(seconds: scrubDelay) } }
                                  }), in: 0...max(0.001, live.historyDuration), onEditingChanged: { editing in
                if editing { scrubDelay = live.delaySeconds; scrubbing = true }
                else { action { try DJLiveAudio.shared.setDelay(seconds: scrubDelay) }; scrubbing = false }
            }).tint(color).disabled(live.historyDuration == 0)
                .accessibilityLabel("Rewind live input, seconds behind live")
            HStack {
                Text(String(format: "−%.1fs / %.1fs buffered", live.delaySeconds, live.historyDuration))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Jump live") { action { try DJLiveAudio.shared.clearLoop(); try DJLiveAudio.shared.setDelay(seconds: 0) } }
                    .controlSize(.mini).disabled(live.historyDuration == 0)
            }
        }
    }

    private var looper: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LOOPER").font(.caption.weight(.bold)).tracking(1)
                Spacer()
                Text(bindings.label(for: .deckALoop)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Button(live.looping ? "Exit loop" : "Loop") { action { try studio.toggleLiveLoop() } }
                    .buttonStyle(.borderedProminent).tint(live.looping ? color : .secondary)
            }
            HStack(spacing: 5) {
                ForEach([1, 2, 4, 8, 16], id: \.self) { beats in
                    Button("\(beats)") {
                        studio.liveLoopBeats = beats
                        if live.looping { action { try DJLiveAudio.shared.clearLoop(); try studio.toggleLiveLoop() } }
                    }
                        .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 5)
                        .foregroundStyle(studio.liveLoopBeats == beats ? color : .primary)
                        .background(studio.liveLoopBeats == beats ? color.opacity(0.22) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(studio.liveLoopBeats == beats ? color.opacity(0.8) : .clear))
                        .accessibilityLabel("Live loop \(beats) beats")
                }
                Text("beats").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("In") { DJLiveAudio.shared.setLoopIn(); studio.refreshLive() }
                Button("Out") { action { try DJLiveAudio.shared.setLoopOut() } }.disabled(!live.hasLoopIn)
                Button("Clear") { action { try DJLiveAudio.shared.clearLoop() } }.disabled(!live.hasLoopIn && !live.looping)
                Spacer(minLength: 0)
                Text(live.looping ? String(format: "%.2fs looping", live.loopDuration) : live.hasLoopIn ? "In marked" : "Last beats")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(live.looping ? color : .secondary)
            }
        }.controlSize(.small).padding(10)
            .background(color.opacity(live.looping ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 9))
            .disabled(live.historyDuration == 0)
    }

    private func eq(_ name: String, value: Binding<Float>) -> some View {
        VStack(spacing: 4) {
            Text(name).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Slider(value: value, in: -24...12).tint(color).accessibilityLabel("Live input \(name) EQ")
            Button(String(format: "%+.0f dB", value.wrappedValue)) { value.wrappedValue = 0 }
                .font(.system(size: 10, design: .monospaced)).buttonStyle(.plain).help("Reset \(name.lowercased()) EQ")
        }
    }
    private func action(_ body: () throws -> Void) { studio.perform(body); studio.refreshLive() }
}
