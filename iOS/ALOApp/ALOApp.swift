import SwiftUI

@main struct ALOMobileApp: App {
    @StateObject private var model = MobileRoomModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { model.activate() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.activate()
                    case .background: model.suspend()
                    // System permission sheets can make the app inactive.
                    // Do not tear down a user-initiated join for that transition.
                    default: break
                    }
                }
        }
    }
}
