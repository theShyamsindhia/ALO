import SwiftUI

/// No local clock is inferred from song metadata. Pass position only when the
/// caller has a trustworthy playhead that accounts for pauses, seeks and latency.
struct LyricsPanel: View {
    @ObservedObject var controller: LyricsController
    var accent: Color = Color(red: 0.55, green: 0.59, blue: 0.75)
    var position: Double? = nil
    var expandedPresentation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        if controller.enabled {
            VStack(alignment: .leading, spacing: 0) {
                if expandedPresentation {
                    HStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                        Text("Lyrics")
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 9)
                    content.padding(.horizontal, 14).padding(.bottom, 10)
                } else {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "text.alignleft")
                            Text("Lyrics")
                            Spacer()
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse lyrics" : "Show lyrics")
                    if expanded { content.padding(.horizontal, 14).padding(.bottom, 10) }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.state {
        case .disabled: EmptyView()
        case .missingTrack: status("Lyrics need a track title and artist.")
        case .loading:
            HStack(spacing: 7) { ProgressView().controlSize(.small); status("Finding lyrics…") }
        case .unavailable(let message): status(message)
        case .failed(let message):
            HStack(alignment: .top) {
                status(message)
                Spacer(minLength: 6)
                Button("Retry") { controller.retry() }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 11))
            }
        case .ready(let result):
            if result.instrumental { status("Instrumental · no lyrics") }
            else {
                VStack(alignment: .leading, spacing: 7) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            if !result.lines.isEmpty, position != nil {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(result.lines) { line in
                                        Text(line.text.isEmpty ? "♪" : line.text)
                                            .font(.system(size: 13, weight: active(result) == line.id ? .semibold : .regular))
                                            .foregroundStyle(active(result) == line.id ? accent : .secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                                    }
                                }
                            } else {
                                Text(result.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }
                        .frame(maxHeight: 150)
                        .onAppear {
                            guard let id = active(result) else { return }
                            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                        }
                        .onChange(of: active(result)) { _, id in
                            guard let id else { return }
                            if reduceMotion {
                                proxy.scrollTo(id, anchor: .center)
                            } else {
                                withAnimation(.easeInOut(duration: 0.24)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                        }
                    }
                    HStack {
                        if position == nil { Text("Timing unavailable").font(.system(size: 9)).foregroundStyle(.tertiary) }
                        Spacer()
                        Link("LRCLIB", destination: URL(string: "https://lrclib.net")!)
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func active(_ result: LyricsResult) -> Int? { LyricsProvider.activeLine(in: result.lines, seconds: position) }
    private func status(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct LyricsPlayerLine: View {
    @ObservedObject var controller: LyricsController
    let position: Double?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 8, weight: .medium))
            Text(presentation.label)
                .lineLimit(1)
                .allowsTightening(true)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .help(presentation.detail ?? presentation.label)
        .accessibilityLabel("Lyrics: \(presentation.detail ?? presentation.label)")
    }

    struct Presentation: Equatable {
        let label: String
        let detail: String?
    }

    static func presentation(for state: LyricsController.State, position: Double?) -> Presentation {
        switch state {
        case .disabled: return Presentation(label: "Lyrics off", detail: nil)
        case .missingTrack:
            return Presentation(label: "Lyrics unavailable", detail: "Lyrics need a track title and artist.")
        case .loading: return Presentation(label: "Finding lyrics…", detail: nil)
        case .unavailable(let message), .failed(let message):
            return Presentation(label: "Lyrics unavailable", detail: message)
        case .ready(let result):
            if result.instrumental { return Presentation(label: "Instrumental · no lyrics", detail: nil) }
            if let index = LyricsProvider.activeLine(in: result.lines, seconds: position),
               let line = result.lines.first(where: { $0.id == index }), !line.text.isEmpty {
                return Presentation(label: line.text, detail: nil)
            }
            let line = result.lines.first(where: { !$0.text.isEmpty })?.text
                ?? result.plain.split(separator: "\n").first.map(String.init)
                ?? "Lyrics available"
            return Presentation(label: line, detail: nil)
        }
    }

    private var presentation: Presentation {
        Self.presentation(for: controller.state, position: position)
    }
}
