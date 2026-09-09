import SwiftUI
import AppKit

/// Shared by connected chat and the empty/connecting channel states.
struct NetworkConversationHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .bold)).tracking(-0.35)
                    .lineLimit(1).help(title).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            actions()
                .buttonStyle(.plain).labelStyle(.iconOnly)
                .font(.system(size: 20)).foregroundStyle(Color.blue)
        }
        .padding(.horizontal, 28).frame(height: 74)
        .overlay(alignment: .bottom) { Divider().opacity(0.45).padding(.horizontal, 24) }
    }
}

struct NetworkNowPlayingCard: View {
    let title: String
    let artist: String?
    let channel: String
    let artwork: Data?
    let isPlaying: Bool
    let openChannel: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: openChannel) {
            HStack(spacing: 12) {
                Group {
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                    else {
                        Image(systemName: "music.note").font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.blue.opacity(0.08))
                    }
                }
                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(isPlaying ? "Playing" : "Paused") in \(channel)")
                        .textCase(.uppercase).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let artist { Text(artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Image(systemName: isPlaying ? "waveform" : "pause")
                    .font(.system(size: 18)).foregroundStyle(Color.blue)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain).help("Open the playing channel")
        .task(id: artwork) { image = artwork.flatMap(NSImage.init(data:)) }
    }
}
