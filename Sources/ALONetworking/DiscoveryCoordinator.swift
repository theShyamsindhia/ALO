import Foundation
import Network

/// Bonjour data is an address hint, never proof of room membership or identity.
public struct NearbyPeerHint: Identifiable, Sendable {
    public let roomID: UUID
    public let peerID: UUID
    public let displayName: String
    public let isPrivate: Bool
    public let endpoint: NWEndpoint
    public var id: String { roomID.uuidString + "/" + peerID.uuidString }
}

public enum NearbyDiscoveryState: Equatable, Sendable {
    case idle, browsing, waiting, permissionRequired, stopped
}

/// A scan has an explicit UI/join/repair owner. Connected peers advertise through
/// their listener but do not need to keep this browser running.
@MainActor public final class DiscoveryCoordinator {
    public static let peerService = "_alo-peer._tcp"
    public static let datagramService = "_alo-data._udp"
    public private(set) var state: NearbyDiscoveryState = .idle
    public var onChange: ((NearbyDiscoveryState, [NearbyPeerHint]) -> Void)?
    private var browser: NWBrowser?
    private var retry: Task<Void, Never>?
    private var expiration: Task<Void, Never>?
    private var lifecycle: UInt64 = 0
    private var attempt = 0
    private var requested = false
    private var hints: [String: NearbyPeerHint] = [:]
    private let ownPeerID: UUID

    public init(ownPeerID: UUID) { self.ownPeerID = ownPeerID }

    public func startScanning(for seconds: TimeInterval = 15) {
        stop()
        guard seconds.isFinite, seconds > 0 else { return }
        requested = true
        attempt = 0
        let token = lifecycle
        let duration = min(120, seconds)
        expiration = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.lifecycle == token else { return }
            self.stop()
        }
        createBrowser(lifecycle: token)
    }

    /// Stops scanning before the caller resolves/connects the selected endpoint.
    public func select(_ id: String) -> NearbyPeerHint? {
        guard let hint = hints[id] else { return nil }
        stop()
        return hint
    }

    public func stop() {
        lifecycle &+= 1
        requested = false
        retry?.cancel(); retry = nil
        expiration?.cancel(); expiration = nil
        browser?.cancel(); browser = nil
        hints.removeAll()
        publish(.stopped)
    }

    private func createBrowser(lifecycle token: UInt64) {
        guard requested, lifecycle == token else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let next = NWBrowser(for: .bonjourWithTXTRecord(type: Self.peerService, domain: nil), using: parameters)
        browser = next
        next.stateUpdateHandler = { [weak self, weak next] state in
            Task { @MainActor in
                guard let self, let next, self.lifecycle == token, self.browser === next else { return }
                switch state {
                case .ready: self.publish(.browsing)
                case .waiting(let error): self.handle(error: error, token: token)
                case .failed(let error): self.handle(error: error, token: token)
                default: break
                }
            }
        }
        next.browseResultsChangedHandler = { [weak self, weak next] results, _ in
            Task { @MainActor in
                guard let self, let next, self.lifecycle == token, self.browser === next else { return }
                var updated: [String: NearbyPeerHint] = [:]
                for result in results.prefix(256) {
                    guard case .bonjour(let record) = result.metadata,
                          let roomText = record["roomID"], let roomID = UUID(uuidString: roomText),
                          let peerText = record["nodeID"], let peerID = UUID(uuidString: peerText),
                          peerID != self.ownPeerID else { continue }
                    let hint = NearbyPeerHint(roomID: roomID, peerID: peerID,
                        displayName: String((record["roomName"] ?? record["name"] ?? "Nearby room").prefix(120)),
                        isPrivate: record["private"] == "1", endpoint: result.endpoint)
                    updated[hint.id] = hint
                }
                self.hints = updated
                self.publish(self.state)
            }
        }
        next.start(queue: .main)
    }

    private func handle(error: NWError, token: UInt64) {
        browser?.cancel(); browser = nil
        hints.removeAll()
        // kDNSServiceErr_PolicyDenied. A denied permission requires a user
        // action; repeatedly constructing browsers cannot grant permission.
        if case .dns(let code) = error, code == -65570 {
            requested = false
            retry?.cancel(); expiration?.cancel()
            publish(.permissionRequired)
            return
        }
        publish(.waiting)
        let delay = ConnectionTimingPolicy().retryDelay(attempt: attempt, jitterUnit: Double.random(in: 0...1))
        attempt = min(5, attempt + 1)
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.lifecycle == token else { return }
            self.createBrowser(lifecycle: token)
        }
    }

    private func publish(_ value: NearbyDiscoveryState) {
        state = value
        onChange?(value, hints.values.sorted { $0.id < $1.id })
    }

    deinit { browser?.cancel(); retry?.cancel(); expiration?.cancel() }
}
