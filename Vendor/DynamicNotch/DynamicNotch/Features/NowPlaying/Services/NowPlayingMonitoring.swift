protocol NowPlayingMonitoring: AnyObject {
    var onSnapshotChange: ((NowPlayingSnapshot?) -> Void)? { get set }

    func startMonitoring()
    func stopMonitoring()
    func send(_ command: NowPlayingCommand)
}

protocol NowPlayingDetailPollingConfigurable: AnyObject {
    func setDetailPollingEnabled(_ isEnabled: Bool)
}

/// Optional command capabilities for embedded sources; system services preserve
/// their original behavior when this protocol is not implemented.
protocol NowPlayingCommandAvailabilityProviding: AnyObject {
    func canSend(_ command: NowPlayingCommand) -> Bool
}
