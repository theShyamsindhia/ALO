final class InactiveNowPlayingService: NowPlayingMonitoring {
    // Lifecycle stops explicitly; ARC release must not enter an isolated
    // deinit backdeployment thunk when SwiftUI releases this owner on macOS 15.
    nonisolated deinit {}

    var onSnapshotChange: ((NowPlayingSnapshot?) -> Void)?

    func startMonitoring() {
        onSnapshotChange?(nil)
    }

    func stopMonitoring() {}

    func send(_ command: NowPlayingCommand) {}
}
