import Foundation
import Network
import Testing
@testable import ALONetworking

@Suite("Actual receiver-initiated secure UDP", .serialized)
struct SecureMediaDatagramTransportTests {
    @Test func joinLeaveAndFreshSessionRejoinUseTheAcceptedReturnFlow() async throws {
        let harness = try DatagramLoopbackHarness()
        defer { harness.cancel() }
        let payload = Data(repeating: 0xA5, count: SecureDatagram.maximumPayloadSize)
        let first = try await harness.receive(payload: payload)
        #expect(first.payload == payload)
        let second = try await harness.receive(payload: Data([8,9,10]))
        #expect(second.payload == Data([8,9,10]))
        #expect(first.sessionID != second.sessionID)
    }

    @Test func unauthenticatedNoiseDoesNotDisruptHealthyMedia() async throws {
        let harness = try DatagramLoopbackHarness()
        defer { harness.cancel() }
        let result = try await harness.receive(payload: Data(repeating: 7, count: 996), noisyPeer: true)
        #expect(result.payload.count == 996)
    }

    @Test func expiredTicketStopsTheSubscriberWithoutComparingServerClock() async throws {
        let harness = try DatagramLoopbackHarness()
        defer { harness.cancel() }
        let expired = try await harness.waitForExpiry()
        #expect(expired)
    }
}

/// Can also consume credentials from an actual SecurePeerChannel pair for a full TLS+UDP test.
final class DatagramLoopbackHarness: @unchecked Sendable {
    struct Delivery { let sessionID: UUID; let payload: Data }
    private let queue = DispatchQueue(label: "alo.tests.secure-udp")
    private let registry = MediaSubscriptionRegistry()
    private let publisherCredentials: AuthenticatedChannelCredentials
    private let subscriberCredentials: AuthenticatedChannelCredentials
    private var publisher: SecureMediaDatagramPublisher!
    private var subscriber: SecureMediaDatagramSubscriber?
    private var noise: NWConnection?
    private var port: NWEndpoint.Port?
    private var started = false
    private var ticket: MediaSubscriptionTicket?
    private var payload = Data()
    private var noisyPeer = false
    private var expiryMode = false
    private var continuation: CheckedContinuation<Delivery, Error>?
    private var expiryContinuation: CheckedContinuation<Bool, Error>?
    private var operation = UUID()

    init(publisherCredentials: AuthenticatedChannelCredentials? = nil,
         subscriberCredentials: AuthenticatedChannelCredentials? = nil) throws {
        if let publisherCredentials, let subscriberCredentials {
            self.publisherCredentials = publisherCredentials; self.subscriberCredentials = subscriberCredentials
        } else {
            let offer = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop)
            let transcript = try AdmissionTranscript(roomID: NetworkFixture.room, initiatorID: NetworkFixture.receiver,
                responderID: NetworkFixture.sender, connectionID: UUID(), initiatorKeyHash: Data(repeating: 1, count: 32),
                responderKeyHash: Data(repeating: 2, count: 32), initiatorNonce: Data(repeating: 3, count: 32),
                responderNonce: Data(repeating: 4, count: 32), initiatorOffer: offer, responderOffer: offer,
                policy: .secureV2, channelRole: .mediaControl, admissionKind: .publicRoom)
            self.publisherCredentials = AuthenticatedChannelCredentials(transcript: transcript, localRole: .responder,
                                                                        rootSecret: NetworkFixture.key)
            self.subscriberCredentials = AuthenticatedChannelCredentials(transcript: transcript, localRole: .initiator,
                                                                         rootSecret: NetworkFixture.key)
        }
        publisher = try SecureMediaDatagramPublisher(registry: registry, queue: queue)
        publisher.onReady = { [weak self] port in self?.port = port; self?.join() }
        publisher.onSubscriptionValidated = { [weak self] session in
            guard let self, self.ticket?.sessionID == session, !self.expiryMode else { return }
            self.publisher.send(payload: self.payload, sessionID: session, channel: .audio)
        }
    }

    func receive(payload: Data, noisyPeer: Bool = false) async throws -> Delivery {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation; self.payload = payload; self.noisyPeer = noisyPeer; self.expiryMode = false
                self.begin()
            }
        }
    }
    func waitForExpiry() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.expiryContinuation = continuation; self.expiryMode = true; self.begin() }
        }
    }
    private func begin() {
        operation = UUID(); let operation = self.operation
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.operation == operation else { return }
            self.fail(SecureMediaTransportTestError.timeout)
        }
        if let _ = port { join() }
        else if !started { started = true; publisher.start() }
    }
    private func join() {
        guard let port, continuation != nil || expiryContinuation != nil else { return }
        do {
            let ticket = try registry.reserveAdmittedSubscription(credentials: publisherCredentials,
                broadcasterEpoch: 7, generation: 9, channels: [.audio], now: ProcessInfo.processInfo.systemUptime,
                lifetime: expiryMode ? 0.2 : 15)
            self.ticket = ticket
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            if noisyPeer {
                let noise = NWConnection(to: endpoint, using: SecureNetworkParameters.udp())
                self.noise = noise
                noise.stateUpdateHandler = { state in
                    if case .ready = state {
                        for _ in 0..<24 { noise.send(content: Data(repeating: 0, count: 128), completion: .contentProcessed { _ in }) }
                    }
                }
                noise.start(queue: queue)
            }
            let subscriber = try SecureMediaDatagramSubscriber(endpoint: endpoint, credentials: subscriberCredentials,
                                                               ticket: ticket, queue: queue)
            self.subscriber = subscriber
            subscriber.onPayload = { [weak self] channel, payload in
                guard let self, channel == .audio, let continuation = self.continuation else { return }
                self.continuation = nil; self.cleanupJoin()
                continuation.resume(returning: Delivery(sessionID: ticket.sessionID, payload: payload))
            }
            subscriber.onState = { [weak self] state in
                guard let self, state == .failed else { return }
                if let continuation = self.expiryContinuation {
                    self.expiryContinuation = nil; self.cleanupJoin(); continuation.resume(returning: true)
                } else { self.fail(SecureMediaTransportTestError.failed) }
            }
            subscriber.start()
        } catch { fail(error) }
    }
    private func cleanupJoin() {
        operation = UUID(); subscriber?.cancel(); subscriber = nil
        if let ticket { publisher.cancel(sessionID: ticket.sessionID) }; ticket = nil
        noise?.stateUpdateHandler = nil; noise?.cancel(); noise = nil
    }
    private func fail(_ error: Error) {
        let result = continuation, expiry = expiryContinuation
        continuation = nil; expiryContinuation = nil; cleanupJoin()
        result?.resume(throwing: error); expiry?.resume(throwing: error)
    }
    func cancel() { queue.async { self.cleanupJoin(); self.publisher.stop() } }
}

private enum SecureMediaTransportTestError: Error { case failed, timeout }
