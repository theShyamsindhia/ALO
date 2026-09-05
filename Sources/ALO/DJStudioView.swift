import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DJStudioWindowController: NSObject, NSWindowDelegate {
    static let shared = DJStudioWindowController()
    private var window: NSWindow?
    private let keyMonitor = DJKeyMonitor()
    private var stopBroadcast: (() -> Void)?
    func show(model: ALOViewModel) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: min(940, (NSScreen.main?.visibleFrame.height ?? 1010) - 70)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ALO · DJ Studio"
        window.minSize = NSSize(width: 960, height: 740)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: DJStudioView(model: model, studio: .shared))
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        keyMonitor.start(window: window, bindings: .shared) { action in
            let studio = DJStudio.shared
            if let pad = action.padIndex { studio.trigger(pad); return }
            studio.perform {
                switch action {
                case .deckAPlay:
                    if studio.liveEnabled { studio.toggleLivePlayback() } else { try studio.a.toggle() }
                case .deckBPlay: try studio.b.toggle()
                case .deckACue:
                    if studio.liveEnabled { try DJLiveAudio.shared.returnToCue(); studio.refreshLive() } else { try studio.a.returnToCue() }
                case .deckBCue: try studio.b.returnToCue()
                case .deckALoop:
                    if studio.liveEnabled { try studio.toggleLiveLoop() } else { try studio.a.toggleBeatLoop() }
                case .deckBLoop: try studio.b.toggleBeatLoop()
                case .stopAll: studio.stopAll()
                case .crossfadeLeft: studio.crossfade = 0
                case .crossfadeCenter: studio.crossfade = 0.5
                case .crossfadeRight: studio.crossfade = 1
                default: break
                }
            }
        }
        stopBroadcast = { [weak model] in model?.stopDJBroadcast() }
        DJStudio.shared.startUpdates()
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        keyMonitor.stop()
        stopBroadcast?()
        stopBroadcast = nil
        DJStudio.shared.setLiveStage(nil)
        DJStudio.shared.stopAll()
        DJStudio.shared.stopUpdates()
        window = nil
    }
}

struct DJStudioView: View {
    @ObservedObject var model: ALOViewModel
    @ObservedObject var studio: DJStudio
    @ObservedObject var bindings: DJKeyBindings = .shared
    @State private var showsKeys = false
    @State private var showsGuide = false
    private let colors: [Color] = [.orange, .pink, .cyan, .purple]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 10) {
                        Picker("Deck A source", selection: Binding(get: { studio.liveEnabled }, set: { live in
                            guard !live || (model.hasBroadcaster && !studio.sharing) else { return }
                            studio.setLiveStage(live ? (model.isHost ? .broadcast : .listening) : nil)
                        })) {
                            Text("Live broadcast").tag(true).disabled(!model.hasBroadcaster || studio.sharing)
                            Text("Audio file").tag(false)
                        }.pickerStyle(.segmented).accessibilityLabel("Deck A source")
                        if studio.liveEnabled {
                            DJLiveDeckView(studio: studio, deck: studio.a, bindings: bindings)
                        } else {
                            DJDeckView(deck: studio.a, studio: studio, other: studio.b, bindings: bindings, label: "A", color: .cyan)
                        }
                    }.frame(maxWidth: .infinity)
                    mixer.frame(width: 172)
                    DJDeckView(deck: studio.b, studio: studio, other: studio.a, bindings: bindings, label: "B", color: .purple)
                }
                HStack(alignment: .top, spacing: 20) {
                    launchpad
                    session.frame(width: 275)
                }
            }.padding(24)
        }
        .background(Color(red: 0.055, green: 0.06, blue: 0.075))
        .preferredColorScheme(.dark)
        .onAppear {
            if model.hasBroadcaster && !studio.sharing && !studio.liveEnabled {
                studio.setLiveStage(model.isHost ? .broadcast : .listening)
            }
        }
        .onChange(of: model.hasBroadcaster) { _, _ in studio.setLiveStage(nil) }
        .onChange(of: model.isHost) { _, _ in studio.setLiveStage(nil) }
        .sheet(isPresented: $showsKeys) { DJKeyEditorView(bindings: bindings) }
        .sheet(isPresented: $showsGuide) { DJGuideView(bindings: bindings) }
        .alert("DJ Studio", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
            Button("OK") { studio.error = nil }
        } message: { Text(studio.error ?? "") }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.grid.3x3.fill").font(.system(size: 26)).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text("DJ STUDIO").font(.system(size: 23, weight: .bold, design: .rounded))
                Text("Two decks. Sixteen pads. Your room.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Label(studio.sharing || studio.liveSnapshot.stage == .broadcast ? "Sharing with room" : "Local listening mix", systemImage: studio.sharing || studio.liveSnapshot.stage == .broadcast ? "dot.radiowaves.left.and.right" : "headphones")
                .font(.caption.weight(.semibold)).foregroundStyle(studio.sharing ? .green : .secondary)
            Button { showsKeys = true } label: { Label("Keys", systemImage: "keyboard") }
                .help("Edit and save DJ key bindings")
            Button { showsGuide = true } label: { Label("Guide", systemImage: "questionmark.circle") }
            Button(role: .destructive) { studio.stopAll() } label: { Label("Stop all", systemImage: "stop.fill") }
                .help("Stop both decks and all pads · \(bindings.label(for: .stopAll))")
        }
    }

    private var mixer: some View {
        VStack(spacing: 17) {
            Text("MIXER").font(.caption.weight(.bold)).tracking(2)
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("DJ MASTER"); Spacer(); Text("\(Int(studio.master * 100))%") }.font(.caption.monospacedDigit())
                Slider(value: $studio.master, in: 0...1).accessibilityLabel("Master volume")
                ProgressView(value: Double(min(1, studio.level))).tint(studio.level >= 0.98 ? .red : .green)
                    .accessibilityLabel("Master output level")
                Text(studio.level >= 0.98 ? "Peak — reduce gain" : "Output level").font(.caption2).foregroundStyle(studio.level >= 0.98 ? .red : .secondary)
            }
            Divider()
            VStack(spacing: 8) {
                Text("CROSSFADER").font(.caption.weight(.medium))
                HStack { Text("A").foregroundStyle(.cyan); Slider(value: $studio.crossfade, in: 0...1).accessibilityLabel("Crossfader, deck A to deck B"); Text("B").foregroundStyle(.purple) }
                Button("Center") { studio.crossfade = 0.5 }.controlSize(.small)
            }
            Divider()
            Text(studio.liveEnabled ? "Live input follows the stream. Enter its BPM to set beat loop length." : "Tempo match uses the BPM you enter on each deck.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Close this window to stop playback.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(16).djCard()
    }

    private var launchpad: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LAUNCHPAD").font(.caption.weight(.bold)).tracking(2)
                Spacer()
                Text("Pad gain").font(.caption).foregroundStyle(.secondary)
                Slider(value: $studio.padGain, in: 0...1).frame(width: 100).accessibilityLabel("Launchpad volume")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(0..<16, id: \.self) { index in
                    pad(index)
                }
            }
            Text("Use the keys shown · Right-click a pad to load a sample (up to 10 seconds)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func pad(_ index: Int) -> some View {
        let color = colors[index / 4]
        let active = studio.activePads.contains(index)
        return Button { studio.trigger(index) } label: {
            VStack(alignment: .leading, spacing: 9) {
                Text(bindings.label(for: .pad(index))).font(.system(size: 10, weight: .bold, design: .monospaced)).opacity(0.65)
                Text(studio.padNames[index]).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                .background(color.opacity(active ? 0.7 : 0.14), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(active ? 1 : 0.4), lineWidth: 1))
                .foregroundStyle(active ? .white : color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(studio.padNames[index]), key \(bindings.label(for: .pad(index)))")
        .contextMenu {
            Button("Load sample…") {
                DJFilePicker.choose { url in studio.perform { try studio.loadPad(index, url: url) } }
            }
            Button("Restore built-in sound") { studio.restorePad(index) }
        }
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ROOM SONG").font(.caption.weight(.bold)).tracking(2)
            HStack(spacing: 10) {
                Group {
                    if let data = model.nowPlaying.artworkData, let artwork = NSImage(data: data) {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note").font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.06))
                    }
                }.frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.hasBroadcaster || studio.liveEnabled ? (model.nowPlaying.title ?? "Live room audio") : "No song broadcasting")
                        .font(.headline).lineLimit(2)
                    Text(model.hasBroadcaster || studio.liveEnabled ? (model.nowPlaying.artist ?? "Shared with the room") : "Start a room broadcast to listen")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if model.hasBroadcaster {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let progress = model.roomPlaybackProgress(at: context.date) {
                        ProgressView(value: progress).tint(.cyan).accessibilityLabel("Current room song progress")
                    }
                }
                HStack(spacing: 18) {
                    Button { model.sendRoomMediaCommand(.previousTrack) } label: { Image(systemName: "backward.end.fill") }
                        .help("Previous room song").accessibilityLabel("Previous room song")
                    Button { model.toggleRoomPlayback() } label: { Image(systemName: model.roomIsPlaying ? "pause.fill" : "play.fill") }
                        .help(model.roomIsPlaying ? "Pause room song" : "Play room song")
                        .accessibilityLabel(model.roomIsPlaying ? "Pause room song" : "Play room song")
                    Button { model.playNextRoomTrack() } label: { Image(systemName: "forward.end.fill") }
                        .help("Next room song").accessibilityLabel("Next room song")
                    Spacer()
                }.disabled(!model.canControlRoomPlayback)
                if !model.canControlRoomPlayback {
                    Text(studio.sharing ? "Use the deck controls for your live mix." : "Playback controls aren’t available for this broadcast source.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Divider()
            if studio.sharing {
                Label("DJ mix is live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                Button("Stop sharing") { model.toggleBroadcasting() }.disabled(!model.isHost || model.mediaSwitchBusy)
            } else {
                Button { model.startDJBroadcast() } label: { Label("Share DJ mix", systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(.borderedProminent).tint(.cyan)
                    .disabled(model.phase != .live || model.hasBroadcaster || model.mediaSwitchBusy)
                Text(studio.liveEnabled ? (model.isHost ? "Live input, deck B and pads feed your room broadcast." : "Live input, deck B and pads blend in your listening mix on this Mac.") : model.hasBroadcaster ? "Select Live broadcast on deck A to mix the current room audio." : model.phase != .live ? "Join a room to share your mix." : "Share both decks and pads with the room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(studio.liveEnabled ? "Scrub and loop the recent live buffer on deck A. Room song controls above operate the original source." : "Load songs on the decks, or select the current live broadcast on deck A.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).djCard()
    }

}

private struct DJDeckView: View {
    @ObservedObject var deck: DJDeck
    @ObservedObject var studio: DJStudio
    var other: DJDeck
    @ObservedObject var bindings: DJKeyBindings
    var label: String
    var color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("DECK \(label)").font(.caption.weight(.bold)).tracking(2).foregroundStyle(color)
                Spacer()
                Button { DJFilePicker.choose { url in studio.perform { try deck.load(url) } } } label: { Label("Load song", systemImage: "folder") }
                    .controlSize(.small)
            }
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.black.opacity(0.45))
                    Circle().stroke(color.opacity(0.2), lineWidth: 6).padding(4)
                    Circle().trim(from: 0, to: deck.duration > 0 ? deck.position / deck.duration : 0)
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round)).padding(4).rotationEffect(.degrees(-90))
                    Image(systemName: "music.note").foregroundStyle(color).font(.title2)
                }.frame(width: 65, height: 65)
                VStack(alignment: .leading, spacing: 7) {
                    Text(deck.title).font(.headline).lineLimit(2).help(deck.title)
                    Text("\(clock(deck.position)) / \(clock(deck.duration))").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            DJWaveformScrubber(deck: deck, studio: studio, color: color, label: label)
            HStack(spacing: 8) {
                Button { studio.perform { try deck.toggle() } } label: {
                    Label(deck.isPlaying ? "Pause" : "Play", systemImage: deck.isPlaying ? "pause.fill" : "play.fill")
                }.buttonStyle(.borderedProminent).tint(color)
                Button("Cue") { studio.perform { try deck.returnToCue() } }.help("Return to cue at \(clock(deck.cue))")
                Button { deck.setCue() } label: { Image(systemName: "flag.fill") }.help("Set cue at current position").accessibilityLabel("Set deck \(label) cue")
                Spacer(minLength: 0)
                Text(bindings.label(for: label == "A" ? .deckAPlay : .deckBPlay)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.disabled(deck.duration == 0)
            looper
            HStack(spacing: 8) {
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                TextField("BPM", value: $deck.bpm, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 55).accessibilityLabel("Deck \(label) original BPM")
                Spacer()
                Button("Match tempo") { studio.sync(deck, to: other) }.controlSize(.small).disabled(deck.duration == 0 || other.duration == 0)
            }
            HStack {
                Text("Tempo").font(.caption)
                Slider(value: $deck.rate, in: 0.75...1.25).accessibilityLabel("Deck \(label) tempo")
                Button(String(format: "%+.0f%%", (deck.rate - 1) * 100)) { deck.rate = 1 }.font(.caption.monospacedDigit()).buttonStyle(.plain).help("Reset tempo")
            }
            HStack(spacing: 12) {
                eqControl("LOW", value: $deck.low)
                eqControl("MID", value: $deck.mid)
                eqControl("HIGH", value: $deck.high)
            }
            HStack {
                Text("Gain").font(.caption)
                Slider(value: $deck.gain, in: 0...1).accessibilityLabel("Deck \(label) volume")
                Text("\(Int(deck.gain * 100))%").font(.caption.monospacedDigit()).frame(width: 32)
            }
        }.padding(16).frame(maxWidth: .infinity).djCard()
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, url.isFileURL else { return false }
                studio.perform { try deck.load(url) }
                return true
            }
    }
    private var looper: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LOOPER").font(.caption.weight(.bold)).tracking(1)
                Spacer()
                Text(bindings.label(for: label == "A" ? .deckALoop : .deckBLoop))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Button(deck.loopEnabled ? "Exit loop" : "Loop") { studio.perform { try deck.toggleBeatLoop() } }
                    .tint(deck.loopEnabled ? color : .secondary)
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 5) {
                ForEach([1, 2, 4, 8, 16], id: \.self) { beats in
                    Button("\(beats)") { studio.perform { try deck.setLoopBeats(beats) } }
                        .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 5)
                        .foregroundStyle(deck.loopBeats == beats ? color : .primary)
                        .background(deck.loopBeats == beats ? color.opacity(0.22) : Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(deck.loopBeats == beats ? color.opacity(0.8) : .clear))
                        .accessibilityLabel("Deck \(label) loop \(beats) beats")
                }
                Text("beats").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("In") { studio.perform { try deck.setLoopIn() } }.help("Set loop start at the playhead")
                Button("Out") { studio.perform { try deck.setLoopOut() } }.disabled(deck.loopStart == nil)
                    .help("Set loop end and enable the loop")
                Button("Clear") { studio.perform { try deck.clearLoop() } }.disabled(deck.loopStart == nil)
                Spacer(minLength: 0)
                Text(loopRange).font(.system(size: 10, design: .monospaced)).foregroundStyle(deck.loopEnabled ? color : .secondary)
            }
        }.controlSize(.small).padding(10)
            .background(color.opacity(deck.loopEnabled ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 9))
            .disabled(deck.duration == 0)
    }
    private var loopRange: String {
        guard let start = deck.loopStart else { return "Set BPM first" }
        guard let end = deck.loopEnd else { return "In \(clock(start))" }
        return "\(clock(start))–\(clock(end))"
    }
    private func eqControl(_ name: String, value: Binding<Float>) -> some View {
        VStack(spacing: 4) {
            Text(name).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Slider(value: value, in: -24...12).tint(color).accessibilityLabel("Deck \(label) \(name) EQ")
            Button(String(format: "%+.0f dB", value.wrappedValue)) { value.wrappedValue = 0 }
                .font(.system(size: 10, design: .monospaced)).buttonStyle(.plain).help("Reset \(name.lowercased()) EQ")
        }
    }
    private func clock(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

@MainActor
private enum DJFilePicker {
    static func choose(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Load"
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { result in
                if result == .OK, let url = panel.url { completion(url) }
            }
        } else {
            panel.begin { result in if result == .OK, let url = panel.url { completion(url) } }
        }
    }
}

private extension View {
    func djCard() -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.09), lineWidth: 1))
    }
}
