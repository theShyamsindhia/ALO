import Foundation
import Network
import ALOCore

struct NearbyRoom: Identifiable, Equatable {
    let id: String
    let name: String
    let isPrivate: Bool
    var peerCount: Int
    let accessProof: String?
    var memberNames: [String] = []
    var trackTitle: String? = nil
    var isPlaying: Bool? = nil
    var icon: RoomIcon? = nil

    var detail: String {
        let count = "\(peerCount) \(peerCount == 1 ? "person" : "people")"
        if isPrivate { return "Private · \(count)" }
        if let trackTitle {
            let who = memberNames.first.map { peerCount > 1 ? "\($0) + \(peerCount - 1)" : $0 } ?? count
            return "\(who) · \(isPlaying == false ? "Paused: " : "")\(trackTitle)"
        }
        if let first = memberNames.first {
            return peerCount > 1 ? "\(first) + \(peerCount - 1) nearby" : "\(first) is here"
        }
        return "Nearby · \(count)"
    }

    var activityHelp: String {
        ([detail, "\(peerCount) \(peerCount == 1 ? "person" : "people")"]
            + (isPrivate ? [] : memberNames)).joined(separator: "\n")
    }
}

enum RoomDiscovery {
    // TXT entries are limited to 255 bytes including the key. Bound by UTF-8,
    // not Character count, so emoji names cannot invalidate the advertisement.
    static func text(_ value: String) -> String {
        var result = ""
        for character in value where !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            guard result.utf8.count + String(character).utf8.count <= 120 else { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func record(room: RoomConfiguration, nodeID: String, displayName: String,
                       appVersion: String, accessProof: String?, icon: RoomIcon?,
                       media: NowPlayingMedia?) -> [String: String] {
        var record = ["roomID": room.id, "roomName": text(room.name), "nodeID": nodeID,
                      "private": room.isPrivate ? "1" : "0", "version": "1", "appVersion": appVersion]
        if let accessProof { record["accessProof"] = accessProof }
        guard !room.isPrivate else { return record }
        record["memberName"] = text(displayName)
        if let media, let title = media.title, !text(title).isEmpty {
            record["trackTitle"] = text(title)
            record["playing"] = media.isPlaying.map { $0 ? "1" : "0" }
        }
        if let icon, icon.isValid {
            record["roomIcon"] = icon.symbol
            record["iconCounter"] = String(icon.version.counter)
            record["iconAuthor"] = icon.version.nodeID
        }
        return record
    }

    static func rooms(from records: [NWTXTRecord]) -> [NearbyRoom] {
        var rooms = [String: NearbyRoom]()
        var members = [String: Set<String>]()
        for record in records.sorted(by: { ($0["nodeID"] ?? "") < ($1["nodeID"] ?? "") }) {
            guard let id = record["roomID"], let name = record["roomName"] else { continue }
            let isPrivate = record["private"] == "1"
            let proof = record["accessProof"]
            if let existing = rooms[id], existing.isPrivate != isPrivate || existing.accessProof != proof { continue }
            let memberID = record["nodeID"] ?? UUID().uuidString
            guard members[id, default: []].insert(memberID).inserted else { continue }
            var room = rooms[id] ?? NearbyRoom(id: id, name: text(name), isPrivate: isPrivate, peerCount: 0, accessProof: proof)
            if !isPrivate {
                if let member = record["memberName"], !text(member).isEmpty { room.memberNames.append(text(member)) }
                if let title = record["trackTitle"], !text(title).isEmpty {
                    room.trackTitle = text(title)
                    room.isPlaying = record["playing"].map { $0 == "1" }
                }
                if let symbol = record["roomIcon"], let author = record["iconAuthor"],
                   let counter = record["iconCounter"].flatMap(UInt64.init) {
                    let icon = RoomIcon(symbol: symbol, version: MeshVersion(counter: counter, nodeID: author))
                    if icon.supersedes(room.icon) { room.icon = icon }
                }
            }
            room.peerCount += 1
            rooms[id] = room
        }
        return rooms.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

final class MeshRoomBrowser {
    static let serviceType = "_werai-mesh._tcp"

    private let queue = DispatchQueue(label: "in.werai.mesh.browser", qos: .userInitiated)
    private let updateHandler: ([NearbyRoom]) -> Void
    private let errorHandler: (String) -> Void
    private let readyHandler: () -> Void
    private var browser: NWBrowser?

    init(
        updateHandler: @escaping ([NearbyRoom]) -> Void,
        errorHandler: @escaping (String) -> Void = { _ in },
        readyHandler: @escaping () -> Void = {}
    ) {
        self.updateHandler = updateHandler
        self.errorHandler = errorHandler
        self.readyHandler = readyHandler
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: LocalNetworkParameters.tcp()
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            self.updateHandler(RoomDiscovery.rooms(from: results.compactMap {
                guard case .bonjour(let record) = $0.metadata else { return nil }
                return record
            }))
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            switch state {
            case .ready: self.readyHandler()
            case .failed(let error), .waiting(let error): self.errorHandler(error.localizedDescription)
            default: break
            }
        }
        self.browser = browser
        browser.start(queue: queue)
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
