import Foundation
import Network
import ALOCore

public struct NearbyRoom: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isPrivate: Bool
    public var peerCount: Int
    public let accessProof: String?
    public let transportPolicy: RoomTransportPolicy
    public var memberNames: [String]
    public var trackTitle: String?
    public var isPlaying: Bool?
    public var icon: RoomIcon?

    public init(id: String, name: String, isPrivate: Bool, peerCount: Int, accessProof: String?,
                transportPolicy: RoomTransportPolicy = .legacyOnly, memberNames: [String] = [],
                trackTitle: String? = nil, isPlaying: Bool? = nil, icon: RoomIcon? = nil) {
        self.id = id; self.name = name; self.isPrivate = isPrivate
        self.peerCount = peerCount; self.accessProof = accessProof
        self.transportPolicy = transportPolicy
        self.memberNames = memberNames
        self.trackTitle = trackTitle
        self.isPlaying = isPlaying
        self.icon = icon
    }

    public var detail: String {
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

    public var activityHelp: String {
        ([detail, "\(peerCount) \(peerCount == 1 ? "person" : "people")"]
            + (isPrivate ? [] : memberNames)).joined(separator: "\n")
    }
}

public enum RoomDiscovery {
    // TXT entries are limited to 255 bytes including the key. Bound by UTF-8,
    // not Character count, so emoji names cannot invalidate the advertisement.
    public static func text(_ value: String) -> String {
        var result = ""
        for character in value where !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            guard result.utf8.count + String(character).utf8.count <= 120 else { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func record(room: RoomConfiguration, nodeID: String, displayName: String,
                       appVersion: String, accessProof: String?, icon: RoomIcon?,
                       media: NowPlayingMedia?) -> [String: String] {
        var record = ["roomID": room.id, "roomName": text(room.name), "nodeID": nodeID,
                       "private": room.isPrivate ? "1" : "0",
                       "version": room.transportPolicy == .secureV2 ? "2" : "1", "appVersion": appVersion]
        if room.transportPolicy == .secureV2 { record["roomGeneration"] = String(ProtocolOffer.currentRoomGeneration) }
        if room.transportPolicy == .legacyOnly, let accessProof { record["accessProof"] = accessProof }
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

    public static func rooms(from records: [NWTXTRecord], transportPolicy: RoomTransportPolicy = .legacyOnly) -> [NearbyRoom] {
        var rooms = [String: NearbyRoom]()
        var members = [String: Set<String>]()
        for record in records.prefix(256).sorted(by: { ($0["nodeID"] ?? "") < ($1["nodeID"] ?? "") }) {
            if transportPolicy == .secureV2,
               record["roomGeneration"] != String(ProtocolOffer.currentRoomGeneration) { continue }
            guard let id = record["roomID"], let name = record["roomName"] else { continue }
            let isPrivate = record["private"] == "1"
            let proof = transportPolicy == .secureV2 ? nil : record["accessProof"]
            if let existing = rooms[id], existing.isPrivate != isPrivate || existing.accessProof != proof { continue }
            let memberID = record["nodeID"] ?? UUID().uuidString
            guard members[id, default: []].insert(memberID).inserted else { continue }
            var room = rooms[id] ?? NearbyRoom(id: id, name: text(name), isPrivate: isPrivate, peerCount: 0,
                                             accessProof: proof, transportPolicy: transportPolicy)
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

public final class MeshRoomBrowser {
    public static let serviceType = "_werai-mesh._tcp"
    public static let secureServiceType = "_alo-peer._tcp"

    private let queue = DispatchQueue(label: "in.werai.mesh.browser", qos: .userInitiated)
    private let updateHandler: ([NearbyRoom]) -> Void
    private let errorHandler: (String) -> Void
    private let readyHandler: () -> Void
    private let scanFinishedHandler: () -> Void
    private var browser: NWBrowser?
    private let transportPolicy: RoomTransportPolicy
    private var scanGeneration: UInt64 = 0
    private var expiration: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var retryAttempt = 0

    public init(
        updateHandler: @escaping ([NearbyRoom]) -> Void,
        errorHandler: @escaping (String) -> Void = { _ in },
        transportPolicy: RoomTransportPolicy = .legacyOnly,
        readyHandler: @escaping () -> Void = {},
        scanFinishedHandler: @escaping () -> Void = {}
    ) {
        self.updateHandler = updateHandler
        self.errorHandler = errorHandler
        self.transportPolicy = transportPolicy
        self.readyHandler = readyHandler
        self.scanFinishedHandler = scanFinishedHandler
    }

    public func start() {
        queue.async { [weak self] in self?.beginScan() }
    }

    private func beginScan() {
        guard browser == nil else { return }
        guard transportPolicy != .migrationRequired else { errorHandler("This room requires an explicit transport migration."); return }
        scanGeneration &+= 1
        retryAttempt = 0
        let generation = scanGeneration
        let expiration = DispatchWorkItem { [weak self] in
            guard let self, self.scanGeneration == generation else { return }
            self.stopOnQueue()
            self.scanFinishedHandler()
        }
        self.expiration = expiration
        queue.asyncAfter(deadline: .now() + 15, execute: expiration)
        createBrowser(generation: generation)
    }

    private func createBrowser(generation: UInt64) {
        guard generation == scanGeneration else { return }
        let parameters = NWParameters(); parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: transportPolicy == .secureV2 ? Self.secureServiceType : Self.serviceType, domain: nil),
            using: transportPolicy == .secureV2 ? parameters : LocalNetworkParameters.tcp()
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.scanGeneration == generation, self.browser === browser else { return }
            self.updateHandler(RoomDiscovery.rooms(from: results.prefix(256).compactMap {
                guard case .bonjour(let record) = $0.metadata else { return nil }
                return record
            }, transportPolicy: self.transportPolicy))
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.scanGeneration == generation, self.browser === browser else { return }
            switch state {
            case .ready: self.readyHandler()
            case .failed(let error), .waiting(let error):
                self.errorHandler(error.localizedDescription)
                // Denied consent is a user state, not an automatic retry loop.
                if case .dns(let code) = error, code == -65570 {
                    self.stopOnQueue()
                    return
                }
                browser.cancel(); self.browser = nil
                let delay = ConnectionTimingPolicy().retryDelay(attempt: self.retryAttempt,
                                                               jitterUnit: Double.random(in: 0...1))
                self.retryAttempt += 1
                self.retry?.cancel()
                let retry = DispatchWorkItem { [weak self] in self?.createBrowser(generation: generation) }
                self.retry = retry
                self.queue.asyncAfter(deadline: .now() + delay, execute: retry)
            default: break
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func restart() {
        queue.async { [weak self] in
            self?.stopOnQueue()
            self?.beginScan()
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func stopOnQueue() {
        scanGeneration &+= 1
        expiration?.cancel(); expiration = nil
        retry?.cancel(); retry = nil
        browser?.cancel()
        browser = nil
    }
}
