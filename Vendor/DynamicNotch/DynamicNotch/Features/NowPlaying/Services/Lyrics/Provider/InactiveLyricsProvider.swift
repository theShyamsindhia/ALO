//
//  InactiveLyricsProvider.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 5/13/26.
//

import Foundation

@MainActor
final class InactiveLyricsProvider: LyricsProviding {
    // Lifecycle stops explicitly; ARC release must not enter an isolated
    // deinit backdeployment thunk when SwiftUI releases this owner on macOS 15.
    nonisolated deinit {}

    func lyrics(for snapshot: NowPlayingSnapshot) async throws -> TrackLyrics? {
        nil
    }
}
