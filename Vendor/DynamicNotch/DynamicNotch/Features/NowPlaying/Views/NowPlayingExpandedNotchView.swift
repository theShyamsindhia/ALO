//
//  NowPlayingExpandedNotchView.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 4/14/26.
//

import SwiftUI

struct NowPlayingExpandedNotchView: View {
    @Environment(\.notchScale) var scale
    @Environment(\.isDynamicIsland) var isDynamicIsland
    
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @ObservedObject var settings: MediaAndFilesSettingsStore
    @ObservedObject var applicationSettings: ApplicationSettingsStore
    
    let onOpenPlaybackSource: @MainActor () -> Void
    
    @State private var scrubProgress: CGFloat?
    @State private var showsLyrics: Bool
    private let detailedPresentationSource = "nowPlaying.notch.expanded"

    init(
        nowPlayingViewModel: NowPlayingViewModel,
        settings: MediaAndFilesSettingsStore,
        applicationSettings: ApplicationSettingsStore,
        onOpenPlaybackSource: @escaping @MainActor () -> Void,
        initiallyShowsLyrics: Bool = false
    ) {
        self.nowPlayingViewModel = nowPlayingViewModel
        self.settings = settings
        self.applicationSettings = applicationSettings
        self.onOpenPlaybackSource = onOpenPlaybackSource
        _showsLyrics = State(initialValue: initiallyShowsLyrics)
    }
    
    private var resolvedSnapshot: NowPlayingSnapshot {
        nowPlayingViewModel.snapshot ?? NowPlayingSnapshot(
            title: "Nothing Playing",
            artist: "Start playback to see live metadata",
            album: "Debug Preview",
            duration: 0,
            elapsedTime: 0,
            playbackRate: 0,
            artworkData: nil,
            refreshedAt: .now
        )
    }
    
    var body: some View {
        let snapshot = resolvedSnapshot

        return TimelineView(.periodic(from: .now, by: progressTick(for: snapshot))) { context in
            timelineContent(snapshot: snapshot, at: context.date)
        }
        .onAppear {
            nowPlayingViewModel.setDetailedPresentationActive(
                true,
                source: detailedPresentationSource
            )
            nowPlayingViewModel.setLyricsPresentationActive(showsLyrics)
        }
        .onDisappear {
            nowPlayingViewModel.setDetailedPresentationActive(
                false,
                source: detailedPresentationSource
            )
            nowPlayingViewModel.setLyricsPresentationActive(false)
        }
        .onChange(of: showsLyrics) { _, isVisible in
            nowPlayingViewModel.setLyricsPresentationActive(isVisible)
        }
    }

    private func timelineContent(snapshot: NowPlayingSnapshot, at date: Date) -> some View {
        let elapsedTime = nowPlayingViewModel.snapshot != nil ?
        nowPlayingViewModel.elapsedTime(at: date) :
        snapshot.elapsedTime
        let progress = progressValue(elapsedTime: elapsedTime, duration: snapshot.duration)
        let displayedProgress = min(max(scrubProgress ?? progress, 0), 1)
        let displayedElapsedTime = snapshot.duration > 0 ?
        TimeInterval(displayedProgress) * snapshot.duration :
        elapsedTime
        let appearance = settings.resolvedNowPlayingAppearanceOptions(
            isDefaultActivityStrokeEnabled: applicationSettings.isDefaultActivityStrokeEnabled
        )

        return VStack {
            Spacer()

            Group {
                if showsLyrics {
                    lyricsSection(elapsedTime: displayedElapsedTime)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    headerSection(snapshot: snapshot, appearance: appearance)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .frame(height: 78)
            .animation(.easeInOut(duration: 0.2), value: showsLyrics)

            Spacer()

            PlayerProgressBar(
                progress: displayedProgress,
                displayedElapsedTime: displayedElapsedTime,
                duration: snapshot.duration,
                isInteractive: snapshot.duration > 0 && nowPlayingViewModel.canSend(.seek(0)),
                tintGradient: {
                    switch appearance.progressTintStyle {
                    case .default:
                        return nil
                    case .artwork:
                        return nowPlayingViewModel.artworkPalette.equalizerGradient
                    case .systemAccent:
                        return LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                }(),
                primaryColor: progressTimeColor(isPrimary: true, appearance: appearance),
                secondaryColor: progressTimeColor(isPrimary: false, appearance: appearance),
                onScrubChanged: { newProgress in
                    scrubProgress = newProgress
                },
                onScrubEnded: { newProgress in
                    nowPlayingViewModel.seek(to: snapshot.duration * TimeInterval(newProgress))
                    scrubProgress = nil
                }
            )

            Spacer()

            controlsSection(snapshot: snapshot, appearance: appearance)
        }
        .padding(.horizontal, isDynamicIsland ? 50 : 70)
        .padding(.top, isDynamicIsland ? 15 : 25)
        .padding(.bottom, 15)
    }

    @ViewBuilder
    private func lyricsSection(elapsedTime: TimeInterval) -> some View {
        if nowPlayingViewModel.snapshot == nil {
            Color.clear
                .accessibilityHidden(true)
        } else {
            switch nowPlayingViewModel.lyricsState {
            case .idle:
                Color.clear
                    .accessibilityHidden(true)

            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Finding lyrics…")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityElement(children: .combine)

            case .loaded(let lyrics):
                lyricLines(lyrics, elapsedTime: elapsedTime)

            case .notFound:
                lyricsStatus("Lyrics unavailable", systemImage: "quote.bubble")

            case .failed:
                lyricsStatus("Lyrics didn't load", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            }
        }
    }

    private func lyricLines(_ lyrics: TrackLyrics, elapsedTime: TimeInterval) -> some View {
        let activeIndex = lyrics.activeLineIndex(at: elapsedTime) ?? 0
        let activeLine = lyrics.lines.indices.contains(activeIndex) ? lyrics.lines[activeIndex] : nil
        let previousIndex = activeIndex - 1
        let nextIndex = activeIndex + 1
        let previousLine = lyrics.isSynced && lyrics.lines.indices.contains(previousIndex) ? lyrics.lines[previousIndex] : nil
        let nextLine = lyrics.isSynced && lyrics.lines.indices.contains(nextIndex) ? lyrics.lines[nextIndex] : nil

        return VStack(spacing: 3) {
            if let previousLine {
                Text(previousLine.text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.24))
                    .lineLimit(1)
            }

            Text(activeLine?.text ?? "Lyrics unavailable")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(activeLine == nil ? 0.4 : 0.92))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)

            if let nextLine {
                Text(nextLine.text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.22), value: activeIndex)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activeLine.map { "Lyrics: \($0.text)" } ?? "Lyrics unavailable")
    }

    private func lyricsStatus(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.38))
            .lineLimit(1)
    }

    @ViewBuilder
    private func headerSection(snapshot: NowPlayingSnapshot, appearance: NowPlayingAppearanceOptions) -> some View {
        HStack(spacing: 15) {
            Button(action: {
                openPlaybackSource()
            }) {
                ArtworkView(
                    nowPlayingViewModel: nowPlayingViewModel,
                    width: 60,
                    height: 60,
                    cornerRadius: 10,
                    usesFlipAnimation: appearance.usesArtwork3DEffect
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(PlaybackSourceButtonStyle())
            .disabled(!nowPlayingViewModel.canOpenPlaybackSource)

            HStack(alignment: .top, spacing: 10) {
                Button(action: {
                    openPlaybackSource()
                }) {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(
                            .constant(displayTitle(for: snapshot)),
                            font: .system(size: 16, weight: .medium),
                            nsFont: .headline,
                            textColor: .white.opacity(0.8),
                            backgroundColor: .clear,
                            minDuration: 2.0,
                            frameWidth: 170
                        )

                        MarqueeText(
                            .constant(displayArtist(for: snapshot)),
                            font: .system(size: 14),
                            nsFont: .headline,
                            textColor: .white.opacity(0.5),
                            backgroundColor: .clear,
                            minDuration: 3.0,
                            frameWidth: 170
                        )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlaybackSourceButtonStyle())
                .disabled(!nowPlayingViewModel.canOpenPlaybackSource)

                Spacer()

                LightweightNowPlayingEqualizerView(
                    isPlaying: snapshot.isPlaying,
                    colors: [
                        nowPlayingViewModel.artworkPalette.equalizerHighlightColor,
                        nowPlayingViewModel.artworkPalette.equalizerBaseColor
                    ],
                    barHeight: 23,
                    barWidth: 2.7
                )
                .frame(width: 23, height: 18)
            }
        }
    }

    @ViewBuilder
    private func controlsSection(snapshot: NowPlayingSnapshot, appearance: NowPlayingAppearanceOptions) -> some View {
        ZStack {
            HStack(spacing: 18) {
                PlayerControlButton(
                    systemImage: "backward.fill",
                    fontSize: 20,
                    width: 38,
                    height: 38,
                    feedbackStyle: .backward
                ) {
                    nowPlayingViewModel.previousTrack()
                }
                .disabled(!nowPlayingViewModel.canSend(.previousTrack))

                PlayerControlButton(
                    systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill",
                    fontSize: 30,
                    width: 38,
                    height: 38,
                    feedbackStyle: .playPause
                ) {
                    nowPlayingViewModel.togglePlayPause()
                }
                .disabled(!nowPlayingViewModel.canSend(.togglePlayPause))

                PlayerControlButton(
                    systemImage: "forward.fill",
                    fontSize: 20,
                    width: 38,
                    height: 38,
                    feedbackStyle: .forward
                ) {
                    nowPlayingViewModel.nextTrack()
                }
                .disabled(!nowPlayingViewModel.canSend(.nextTrack))
            }

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsLyrics.toggle()
                    }
                } label: {
                    Image(systemName: showsLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(showsLyrics ? 0.9 : 0.52))
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(showsLyrics ? 0.12 : 0))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(showsLyrics ? "Hide lyrics" : "Show lyrics")
                .accessibilityLabel(showsLyrics ? "Hide lyrics" : "Show lyrics")

                Spacer()

                if appearance.showsOutputDeviceButton {
                    AudioOutputRoutePickerButton(
                        nowPlayingViewModel: nowPlayingViewModel,
                        width: 38,
                        height: 38,
                        fontSize: 19
                    )
                }
            }
            .padding(.horizontal, 8)
        }
    }
    
    private func displayTitle(for snapshot: NowPlayingSnapshot) -> String {
        snapshot.title.trimmed.isEmpty ? "Unknown Track" : snapshot.title
    }
    
    private func displayArtist(for snapshot: NowPlayingSnapshot) -> String {
        snapshot.artist.trimmed.isEmpty ? "Unknown Artist" : snapshot.artist
    }
    
    private func displayAlbum(for snapshot: NowPlayingSnapshot) -> String {
        snapshot.album.trimmed.isEmpty ? "Unknown Album" : snapshot.album
    }
    
    private func progressValue(elapsedTime: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(CGFloat(elapsedTime / duration), 0), 1)
    }
    
    private func formattedTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "--:--" }
        
        let totalSeconds = max(0, Int(time.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func progressTimeColor(isPrimary: Bool, appearance: NowPlayingAppearanceOptions) -> Color {
        switch appearance.progressTintStyle {
        case .default:
            return .white.opacity(0.4)
        case .artwork:
            let nsColor = isPrimary ?
            nowPlayingViewModel.artworkPalette.equalizerHighlightColor :
            nowPlayingViewModel.artworkPalette.equalizerBaseColor
            return Color(nsColor: nsColor)
        case .systemAccent:
            return isPrimary ? .accentColor : .accentColor.opacity(0.7)
        }
    }
    
    private func playbackStatusColor(for snapshot: NowPlayingSnapshot) -> Color {
        if nowPlayingViewModel.snapshot == nil {
            return .white.opacity(0.48)
        }
        
        return snapshot.isPlaying ?
        Color(red: 0.97, green: 0.73, blue: 0.32) :
            .white.opacity(0.48)
    }

    private func progressTick(for snapshot: NowPlayingSnapshot) -> TimeInterval {
        snapshot.isPlaying ? 1.0 : 30.0
    }

    private func openPlaybackSource() {
        guard nowPlayingViewModel.canOpenPlaybackSource else { return }
        nowPlayingViewModel.openPlaybackSource()
        if !applicationSettings.isCloseAtFocusLiveActivityEnabled {
            onOpenPlaybackSource()
        }
    }
}
