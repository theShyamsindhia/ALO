import Foundation
import Network

final class RoomBrowser {
    private let queue = DispatchQueue(label: "in.werai.rooms", qos: .userInitiated)
    private let updateHandler: ([String]) -> Void
    private let errorHandler: (String) -> Void
    private var browser: NWBrowser?

    init(
        updateHandler: @escaping ([String]) -> Void,
        errorHandler: @escaping (String) -> Void = { _ in }
    ) {
        self.updateHandler = updateHandler
        self.errorHandler = errorHandler
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: HostServer.serviceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = Set(results.compactMap { result -> String? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return name
            }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            self?.updateHandler(names)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.errorHandler(error.localizedDescription)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
