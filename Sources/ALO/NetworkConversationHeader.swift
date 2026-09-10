import SwiftUI
import AppKit
import ALONetworkUI

/// Shared by connected chat and the empty/connecting channel states.
struct NetworkConversationHeader<Actions: View>: View {
    @Environment(\.aloCompactNetworkLayout) private var compactLayout
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(ALONetworkTypography.heading).tracking(-0.25)
                    .lineLimit(1).help(title).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(ALONetworkTypography.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            actions()
                .buttonStyle(.plain).labelStyle(.iconOnly)
                .font(.system(size: 16)).foregroundStyle(Color.blue)
        }
        .padding(.horizontal, compactLayout ? 16 : 24).frame(height: compactLayout ? 60 : 68)
        .overlay(alignment: .bottom) { Divider().opacity(0.45).padding(.horizontal, compactLayout ? 16 : 24) }
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
            HStack(spacing: 8) {
                Group {
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                    else {
                        Image(systemName: "music.note").font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.blue.opacity(0.08))
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(ALONetworkTypography.label).lineLimit(1).help(title)
                    if let artist { Text(artist).font(ALONetworkTypography.caption).foregroundStyle(.secondary).lineLimit(1).help(artist) }
                    Text("\(isPlaying ? "Playing" : "Paused") in \(channel)")
                        .font(ALONetworkTypography.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help("\(isPlaying ? "Playing" : "Paused") in \(channel)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isPlaying ? "waveform" : "pause")
                    .font(.system(size: 16)).foregroundStyle(Color.blue)
                    .accessibilityHidden(true)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain).help("Open the playing channel")
        .task(id: artwork) { image = artwork.flatMap(NSImage.init(data:)) }
    }
}
