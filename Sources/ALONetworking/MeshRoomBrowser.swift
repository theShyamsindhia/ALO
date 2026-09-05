import Foundation
import Network
import ALOCore

public struct NearbyRoom: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isPrivate: Bool
    public let peerCount: Int
    public let accessProof: String?
    public let transportPolicy: RoomTransportPolicy

    public init(id: String, name: String, isPrivate: Bool, peerCount: Int, accessProof: String?, transportPolicy: RoomTransportPolicy = .legacyOnly) {
        self.id = id; self.name = name; self.isPrivate = isPrivate
        self.peerCount = peerCount; self.accessProof = accessProof
        self.transportPolicy = transportPolicy
    }
}

public final class MeshRoomBrowser {
    public static let serviceType = "_werai-mesh._tcp"
    public static let secureServiceType = "_alo-peer._tcp"

    private let queue = DispatchQueue(label: "in.werai.mesh.browser", qos: .userInitiated)
    private let updateHandler: ([NearbyRoom]) -> Void
    private let errorHandler: (String) -> Void
    private var browser: NWBrowser?
    private let transportPolicy: RoomTransportPolicy

    public init(
        updateHandler: @escaping ([NearbyRoom]) -> Void,
        errorHandler: @escaping (String) -> Void = { _ in },
        transportPolicy: RoomTransportPolicy = .legacyOnly
    ) {
        self.updateHandler = updateHandler
        self.errorHandler = errorHandler
        self.transportPolicy = transportPolicy
    }

    public func start() {
        guard browser == nil else { return }
        guard transportPolicy != .migrationRequired else { errorHandler("This room requires an explicit transport migration."); return }
        let parameters = NWParameters(); parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: transportPolicy == .secureV2 ? Self.secureServiceType : Self.serviceType, domain: nil),
            using: transportPolicy == .secureV2 ? parameters : LocalNetworkParameters.tcp()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var rooms = [String: (name: String, isPrivate: Bool, peers: Int, accessProof: String?)]()
            for result in results.prefix(256) {
                guard case .bonjour(let record) = result.metadata,
                      let id = record["roomID"],
                      let name = record["roomName"]
                else { continue }
                let existing = rooms[id]
                let isPrivate = record["private"] == "1"
                let proof = self?.transportPolicy == .secureV2 ? nil : record["accessProof"]
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
                    accessProof: $0.value.accessProof,
                    transportPolicy: self?.transportPolicy ?? .legacyOnly
                )
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.errorHandler(error.localizedDescription) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func restart() {
        stop()
        start()
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
