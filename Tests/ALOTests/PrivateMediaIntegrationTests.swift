import Foundation
import Network
import Testing
import ALOCore
import ALONetworking
@testable import ALO

@Suite("Private desktop media integration", .serialized)
struct PrivateMediaIntegrationTests {
    @Test(arguments: [false, true])
    func realHostJoinEncryptsAudioAndRejectsUninvitedClients(wrongKeyAfterAuthorized: Bool) async throws {
        let room = RoomConfiguration(name: "Private media", isPrivate: true, accessKey: UUID().uuidString)
        let security = try #require(try RoomMediaSecurity.forRoom(room, serviceName: "source"))
        let wrongRoom = RoomConfiguration(id: room.id, name: room.name, isPrivate: true, accessKey: UUID().uuidString)
        let wrong = try #require(try RoomMediaSecurity.forRoom(wrongRoom, serviceName: "source"))
        let probe = PrivateHostProbe()
        let queue = DispatchQueue(label: "review.private-host.test")
        let audio = try NWListener(using: .udp, on: .any)
        let video = try NWListener(using: security.tcp(video: true), on: .any)
        for listener in [audio, video] {
            listener.newConnectionHandler = { connection in
                probe.registerConnection(connection) { connection.start(queue: queue) }
            }
            listener.start(queue: queue)
        }
        let host = HostServer(roomName: "source", mediaSecurity: security, advertise: false,
            listenerReadyHandler: { port in probe.lock.withLock { probe.port = port } },
            outboundSend: { connection, data, isComplete, completion in
                probe.lock.withLock {
                    if let message = try? JSONDecoder().decode(ControlMessage.self, from: data) {
                        if message.type == "welcome", let session = message.mediaSessionID {
                            probe.sessions.append(session)
                            probe.welcomedParticipants.append(message.participantID ?? "missing")
                            probe.diagnostics.append("welcome to \(message.participantID ?? "missing") at \(connection.endpoint)")
                        }
                    } else { probe.audioPackets.append(data) }
                }
                connection.send(content: data, isComplete: isComplete, completion: .contentProcessed { error in completion(error) })
            })
        try host.start()
        defer {
            host.stop()
            let connections = probe.stopConnections()
            #expect(PrivateNativeRetirement.cancelAndWait(connections: connections, listeners: [audio, video], queue: queue),
                "Private fixture must observe native cancellation before releasing its started resources")
        }
        for _ in 0..<200 {
            if audio.port != nil, video.port != nil, probe.lock.withLock({ probe.port != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try #require(probe.lock.withLock { probe.port })
        let audioPort = try #require(audio.port), videoPort = try #require(video.port)
        for (label, parameters) in [("authorized", security.tcp()), ("wrong-key", wrong.tcp()), ("plaintext", LocalNetworkParameters.tcp())] {
            let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
            connection.stateUpdateHandler = { [weak connection] state in
                probe.lock.withLock {
                    probe.diagnostics.append("\(label): \(state); local=\(String(describing: connection?.currentPath?.localEndpoint))")
                    if case .ready = state { probe.readyClients.insert(label) }
                    // Network.framework can report a rejected PSK handshake as
                    // waiting(.tls), rather than a terminal failed state.
                    switch state {
                    case .waiting(let error), .failed(let error):
                        if case .tls = error { probe.tlsRejectedClients.insert(label) }
                    default: break
                    }
                }
            }
            probe.registerConnection(connection) { connection.start(queue: queue) }
            let join = try ControlMessage(type: "join", udpPort: audioPort.rawValue, videoPort: videoPort.rawValue,
                                          displayName: label, participantID: label).encodedLine()
            connection.send(content: join, completion: .contentProcessed { error in
                probe.lock.withLock { probe.diagnostics.append("\(label) join send: \(String(describing: error))") }
            })
            // Exercise both the original concurrent handshake and an uninvited
            // client arriving after a successful handshake could warm TLS state.
            if label == "authorized", wrongKeyAfterAuthorized {
                for _ in 0..<200 {
                    if probe.lock.withLock({ !probe.sessions.isEmpty }) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        for _ in 0..<200 {
            if probe.lock.withLock({
                !probe.sessions.isEmpty && (probe.tlsRejectedClients.contains("wrong-key") || probe.readyClients.contains("wrong-key"))
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let session = try #require(probe.lock.withLock { probe.sessions.first })
        try await Task.sleep(for: .milliseconds(200))
        let samples = [Int16](repeating: 42, count: 480)
        host.acceptAudio(samples: samples, captureTimeNanos: MonotonicClock.nowNanos())
        for _ in 0..<200 {
            if probe.lock.withLock({ !probe.audioPackets.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let encrypted = try #require(probe.lock.withLock { probe.audioPackets.first })
        let diagnostics = probe.lock.withLock { probe.diagnostics.joined(separator: "\n") }
        #expect(probe.lock.withLock { probe.tlsRejectedClients.contains("wrong-key") }, "\(diagnostics)")
        #expect(!probe.lock.withLock { probe.readyClients.contains("wrong-key") }, "\(diagnostics)")
        #expect(probe.lock.withLock { probe.welcomedParticipants } == ["authorized"], "\(diagnostics)")
        #expect(probe.lock.withLock { probe.sessions.count } == 1, "\(diagnostics)")
        #expect(probe.lock.withLock { probe.audioPackets.count } == 1, "\(diagnostics)")
        #expect(AudioPacket(data: encrypted) == nil)
        let opener = try security.audioOpener(sessionID: session)
        let packet = try #require(AudioPacket(data: try opener.open(encrypted)))
        #expect(packet.samples == samples)
        #expect(throws: SecureTransportError.replay) { try opener.open(encrypted) }
    }

    @Test
    func probeRegistrationAfterTeardownDoesNotStartOrRetainConnection() {
        let probe = PrivateHostProbe()
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        // Invoke the same registration path as a queued listener callback after
        // teardown. No connection is started and no network I/O is needed.
        #expect(probe.stopConnections().isEmpty)
        var starts = 0
        probe.registerConnection(connection) { starts += 1 }
        defer { connection.cancel() }
        #expect(starts == 0)
        #expect(probe.stopConnections().isEmpty)
    }

    @Test func nativeFixtureWaitsForStartedConnectionAndListenerCancellation() throws {
        let probe = PrivateHostProbe(), queue = DispatchQueue(label: "private-fixture.native-cancellation")
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0), accepted = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { connection in
            probe.registerConnection(connection) { connection.start(queue: queue) }
            accepted.signal()
        }
        listener.start(queue: queue)
        defer { _ = PrivateNativeRetirement.cancelAndWait(connections: probe.stopConnections(), listeners: [listener], queue: queue) }
        try #require(ready.wait(timeout: .now() + 3) == .success)
        let client = NWConnection(host: "127.0.0.1", port: try #require(listener.port), using: .tcp)
        probe.registerConnection(client) { client.start(queue: queue) }
        try #require(accepted.wait(timeout: .now() + 3) == .success, "Require a real accepted native connection")
        let retired = probe.stopConnections()
        try #require(retired.count == 2)
        #expect(PrivateNativeRetirement.cancelAndWait(connections: retired, listeners: [listener], queue: queue))
        #expect(retired.allSatisfy { if case .cancelled = $0.state { return true }; return false })
        if case .cancelled = listener.state {} else { Issue.record("Listener did not reach native cancelled state") }
    }
}

private enum PrivateNativeRetirement {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private let group: DispatchGroup
        init(_ group: DispatchGroup) { self.group = group; group.enter() }
        func finish() {
            lock.withLock {
                guard !completed else { return }
                completed = true; group.leave()
            }
        }
    }
    /// Retain exact started resources until their native callbacks arrive. The
    /// wait is never on the queue delivering those callbacks. A rejected late
    /// registration did not start and is deliberately outside this snapshot.
    static func cancelAndWait(connections: [NWConnection], listeners: [NWListener], queue: DispatchQueue) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let group = DispatchGroup()
        var completions: [Completion] = []
        queue.sync {
            for connection in connections {
                if case .cancelled = connection.state { continue }
                let completion = Completion(group)
                completions.append(completion)
                connection.stateUpdateHandler = { state in if case .cancelled = state { completion.finish() } }
                connection.cancel()
            }
            for listener in listeners {
                listener.newConnectionHandler = nil
                if case .cancelled = listener.state { continue }
                let completion = Completion(group)
                completions.append(completion)
                listener.stateUpdateHandler = { state in if case .cancelled = state { completion.finish() } }
                listener.cancel()
            }
        }
        let observed = group.wait(timeout: .now() + 3) == .success
        queue.sync {
            connections.forEach { $0.stateUpdateHandler = nil }
            listeners.forEach { $0.stateUpdateHandler = nil }
        }
        // Balance bookkeeping after abandoning observation, without pretending
        // native cancellation happened. The returned failure remains unchanged.
        if !observed { completions.forEach { $0.finish() } }
        return observed
    }
}

private final class PrivateHostProbe: @unchecked Sendable {
    let lock = NSLock()
    private var stopped = false
    var port: NWEndpoint.Port?
    var connections = [NWConnection]()
    var sessions = [UUID]()
    var welcomedParticipants = [String]()
    var readyClients = Set<String>()
    var tlsRejectedClients = Set<String>()
    var diagnostics = [String]()
    var audioPackets = [Data]()

    // The fixture's start closure only starts this connection asynchronously;
    // it must not re-enter the probe. Serialize it with the teardown snapshot.
    func registerConnection(_ connection: NWConnection, start: () -> Void) {
        let accepted = lock.withLock {
            guard !stopped else { return false }
            connections.append(connection)
            start()
            return true
        }
        if !accepted { connection.cancel() }
    }

    func stopConnections() -> [NWConnection] {
        lock.withLock {
            stopped = true
            let snapshot = connections
            connections.removeAll()
            return snapshot
        }
    }
}
