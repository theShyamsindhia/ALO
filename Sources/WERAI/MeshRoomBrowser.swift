import Foundation
import Network

struct NearbyRoom: Identifiable, Equatable {
    let id: String
    let name: String
    let isPrivate: Bool
    let peerCount: Int
    let accessProof: String?
}

final class MeshRoomBrowser {
    static let serviceType = "_werai-mesh._tcp"

    private let queue = DispatchQueue(label: "in.werai.mesh.browser", qos: .userInitiated)
    private let updateHandler: ([NearbyRoom]) -> Void
    private let errorHandler: (String) -> Void
    private var browser: NWBrowser?

    init(
        updateHandler: @escaping ([NearbyRoom]) -> Void,
        errorHandler: @escaping (String) -> Void = { _ in }
    ) {
        self.updateHandler = updateHandler
        self.errorHandler = errorHandler
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var rooms = [String: (name: String, isPrivate: Bool, peers: Int, accessProof: String?)]()
            for result in results {
                guard case .bonjour(let record) = result.metadata,
                      let id = record["roomID"],
                      let name = record["roomName"]
                else { continue }
                let existing = rooms[id]
                let isPrivate = record["private"] == "1"
                let proof = record["accessProof"]
                if let existing,
                   existing.isPrivate != isPrivate || existing.accessProof != proof {
                    continue
                }
                rooms[id] = (
                    name: name,
                    isPrivate: isPrivate,
                    peers: (existing?.peers ?? 0) + 1,
                    accessProof: proof
                )
            }
            self?.updateHandler(rooms.map {
                NearbyRoom(
                    id: $0.key,
                    name: $0.value.name,
                    isPrivate: $0.value.isPrivate,
                    peerCount: $0.value.peers,
                    accessProof: $0.value.accessProof
                )
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.errorHandler(error.localizedDescription) }
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
