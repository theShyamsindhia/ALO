import Foundation
import Network
import Testing
@testable import ALO

@Suite("Receiver video connection cleanup", .serialized)
struct ReceiverVideoLifecycleTests {
    @Test(arguments: [false, true])
    func terminalVideoConnectionsAreRetired(cancelAcceptedConnection: Bool) async throws {
        let receiver = try Receiver(requestedRoom: "Lifecycle", capturesSystemMediaCommands: false)
        let queue = DispatchQueue(label: "alo.tests.receiver-video-lifecycle")
        let probe = ReceiverVideoLifecycleProbe()
        let listener = try NWListener(using: LocalNetworkParameters.tcp(), on: .any)
        listener.newConnectionHandler = { connection in
            probe.lock.withLock { probe.accepted.append(connection) }
            receiver.receiveVideoForTesting(from: connection)
        }
        listener.start(queue: queue)
        defer {
            listener.newConnectionHandler = nil; listener.cancel(); receiver.stop()
            probe.lock.withLock {
                probe.senders.forEach { $0.cancel() }; probe.accepted.forEach { $0.cancel() }
                probe.senders.removeAll(); probe.accepted.removeAll()
            }
        }
        #expect(try await wait { if case .ready = listener.state { return true }; return false })
        let port = try #require(listener.port)
        for iteration in 0..<3 {
            let sender = NWConnection(host: "127.0.0.1", port: port, using: LocalNetworkParameters.tcp())
            sender.stateUpdateHandler = { [weak probe] state in
                probe?.lock.withLock { probe?.states.append("iteration \(iteration): \(state)") }
            }
            probe.lock.withLock { probe.senders.append(sender) }; sender.start(queue: queue)
            // Force TCP's initial outbound write; the incomplete header never
            // produces a media frame or starts audio/video playback.
            sender.send(content: Data([0]), completion: .contentProcessed { _ in })
            let connected = try await wait { receiver.videoConnectionCountForTesting == 1 }
            #expect(connected, "Iteration \(iteration), TCP state \(sender.state), accepted \(probe.lock.withLock { probe.accepted.count }), tracked \(receiver.videoConnectionCountForTesting), states \(probe.lock.withLock { probe.states })")
            guard connected else { return }
            let accepted = try #require(probe.lock.withLock { probe.accepted.last })
            if iteration == 1 { receiver.advanceTransportEpochForTesting() }
            if cancelAcceptedConnection { accepted.cancel() }
            else { sender.send(content: nil, contentContext: .finalMessage, isComplete: true,
                               completion: .contentProcessed { _ in }) }
            let retired = try await wait { receiver.videoConnectionCountForTesting == 0 }
            #expect(retired, "A terminated video connection must be removed without a room disconnect")
            guard retired else { return }
            #expect(accepted.stateUpdateHandler == nil)
            sender.cancel()
            // Retirement of the accepted side is not completion of the client
            // cancellation. Finish both before constructing its replacement.
            #expect(try await wait {
                if case .cancelled = sender.state, case .cancelled = accepted.state { return true }
                return false
            }, "Both sides must reach terminal state before the next connection")
            sender.stateUpdateHandler = nil
        }
    }

    private func wait(until condition: () -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private final class ReceiverVideoLifecycleProbe: @unchecked Sendable {
    let lock = NSLock()
    var senders: [NWConnection] = []
    var accepted: [NWConnection] = []
    var states: [String] = []
}
