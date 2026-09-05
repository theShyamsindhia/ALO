//
//  CompositeLyricsProvider.swift
//  DynamicNotch
//

import Foundation

@MainActor
final class CompositeLyricsProvider: LyricsProviding {
    // Lifecycle stops explicitly; ARC release must not enter an isolated
    // deinit backdeployment thunk when SwiftUI releases this owner on macOS 15.
    nonisolated deinit {}

    private let providers: [any LyricsProviding]

    init(providers: [any LyricsProviding]) {
        self.providers = providers
    }

    func lyrics(for snapshot: NowPlayingSnapshot) async throws -> TrackLyrics? {
        for provider in providers {
            if let lyrics = try? await provider.lyrics(for: snapshot) {
                return lyrics
            }
        }
        return nil
    }
}
