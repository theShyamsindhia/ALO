import Foundation
import Network

/// Untrusted endpoint candidates only. Neither TXT nor a display name grants
/// membership/task permission; actual TLS/purpose proof must precede consent UI.
public final class NetworkDeviceMessagingDiscovery: @unchecked Sendable {
    public static let serviceType = "_alo-codex._tcp"
    public struct Candidate: Identifiable {
        public let id: UUID
        public let networkHint: UUID
        public let endpoint: NWEndpoint
    }
    public enum Event { case candidates([Candidate]), unavailable }
    private let queue: DispatchQueue
    private let event: (Event) -> Void
    private var browser: NWBrowser?
    private var candidates: [NWEndpoint: Candidate] = [:]
    private var stopped = false
    public init(queue target: DispatchQueue, event: @escaping (Event) -> Void) {
        queue = DispatchQueue(label: "alo.device-message-discovery", target: target); self.event = event
    }
    deinit { browser?.browseResultsChangedHandler = nil; browser?.stateUpdateHandler = nil; browser?.cancel() }
    public func start(networks: Set<UUID>) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.browser == nil, !networks.isEmpty else { return }
            let parameters = NWParameters(); parameters.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                guard let self, let browser, !self.stopped, self.browser === browser else { return }
                var next: [NWEndpoint: Candidate] = [:]
                for result in results.prefix(128) {
                    guard next.count < 32, case .bonjour(let txt) = result.metadata,
                          txt["v"] == "1", let raw = txt["id"], raw.utf8.count == 36,
                          let network = UUID(uuidString: raw), networks.contains(network),
                          result.endpoint.debugDescription.utf8.count <= 512 else { continue }
                    let id = self.candidates[result.endpoint]?.id ?? UUID()
                    next[result.endpoint] = Candidate(id: id, networkHint: network, endpoint: result.endpoint)
                }
                self.candidates = next
                self.event(.candidates(next.values.sorted { $0.id.uuidString < $1.id.uuidString }))
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, let browser, !self.stopped, self.browser === browser else { return }
                if case .failed = state {
                    browser.cancel(); self.browser = nil; self.candidates.removeAll()
                    self.event(.candidates([])); self.event(.unavailable)
                }
            }
            browser.start(queue: self.queue)
        }
    }
    /// Terminal instance. Explicit local retry creates a new generation/instance;
    /// there is no automatic reconnect or text resend loop.
    public func stop() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true; self.browser?.cancel(); self.browser = nil; self.candidates.removeAll()
        }
    }
}
