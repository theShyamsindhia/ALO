//
//  WorkspacePlaybackSourceOpener.swift
//  DynamicNotch
//

internal import AppKit
import Foundation

@MainActor
protocol PlaybackSourceOpening: Sendable {
    func openPlaybackSource(_ source: NowPlayingPlaybackSource)
}

@MainActor
final class WorkspacePlaybackSourceOpener: PlaybackSourceOpening {
    // Lifecycle stops explicitly; ARC release must not enter an isolated
    // deinit backdeployment thunk when SwiftUI releases this owner on macOS 15.
    nonisolated deinit {}

    func openPlaybackSource(_ source: NowPlayingPlaybackSource) {
        if let bundleIdentifier = source.preferredBundleIdentifier {
            if ApplicationActivator.shared.openOrActivate(bundleIdentifier: bundleIdentifier) {
                return
            }
        }

        if let processIdentifier = source.validProcessIdentifier,
           let application = NSRunningApplication(processIdentifier: pid_t(processIdentifier)) {
            ApplicationActivator.shared.openOrActivate(application: application)
        }
    }
}
