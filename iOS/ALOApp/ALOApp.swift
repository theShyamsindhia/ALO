import SwiftUI
import ALOAppModel
import ALOIdentity
import ALORooms

@main struct ALOMobileApp: App {
    @StateObject private var account: NetworkAccountModel
    @StateObject private var model: MobileRoomModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let account: NetworkAccountModel
        #if DEBUG && targetEnvironment(simulator)
        if MobileRoomStore.usesTemporarySimulatorIdentity {
            let sessionID = UUID().uuidString
            let defaults = UserDefaults(suiteName: "in.werai.ios.network-test.\(sessionID)")!
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ALO-Network-Test-\(sessionID)", isDirectory: true)
            account = NetworkAccountModel(defaults: defaults,
                repository: NetworkRepository(directoryURL: directory),
                identityStore: UserIdentityStore(storage: MobileTemporaryIdentityStorage()))
        } else {
            account = NetworkAccountModel()
        }
        #else
        account = NetworkAccountModel()
        #endif
        _account = StateObject(wrappedValue: account)
        _model = StateObject(wrappedValue: MobileRoomModel(account: account))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, account: account)
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
