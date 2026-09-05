import SwiftUI

/// No local clock is inferred from song metadata. Pass position only when the
/// caller has a trustworthy playhead that accounts for pauses, seeks and latency.
struct LyricsPanel: View {
    @ObservedObject var controller: LyricsController
    var accent: Color = Color(red: 0.55, green: 0.59, blue: 0.75)
    var position: Double? = nil
    @State private var expanded = false

    var body: some View {
        if controller.enabled {
            VStack(alignment: .leading, spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                        Text("Lyrics")
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse lyrics" : "Show lyrics")
                if expanded {
                    content.padding(.horizontal, 14).padding(.bottom, 10)
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
                        }.frame(maxHeight: 150)
                            .onChange(of: active(result)) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
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
