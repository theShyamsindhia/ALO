//
//  HomePageViewModel.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 5/18/26.
//

import Combine
import Foundation

@MainActor
final class HomePageViewModel: ObservableObject {
    // Lifecycle stops explicitly; ARC release must not enter an isolated
    // deinit backdeployment thunk when SwiftUI releases this owner on macOS 15.
    nonisolated deinit {}

    @Published var event: HomePageEvent?
}
