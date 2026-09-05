//
//  InactiveAudioOutputRoutingService.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 4/8/26.
//

import CoreAudio

final class InactiveAudioOutputRoutingService: AudioOutputRouting {
    // Lifecycle stops explicitly; ARC release must not enter an isolated
    // deinit backdeployment thunk when SwiftUI releases this owner on macOS 15.
    nonisolated deinit {}

    func availableRoutes() -> [AudioOutputRoute] { [] }

    func currentRoute() -> AudioOutputRoute? { nil }

    @discardableResult
    func setCurrentRoute(_ id: AudioDeviceID) -> Bool { false }
}
