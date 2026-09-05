import Foundation
import CryptoKit
import Network
import Testing
import ALOCore
@testable import ALO

@Suite("Private media security", .serialized)
struct PrivateMediaSecurityTests {
    @Test func privateMediaRequiresRoomKeyAndRejectsAudioReplays() async throws {
        let room = RoomConfiguration(name: "Private", isPrivate: true, accessKey: UUID().uuidString)
        let security = try #require(try RoomMediaSecurity.forRoom(room, serviceName: "source"))
        let wrongRoom = RoomConfiguration(id: room.id, name: room.name, isPrivate: true, accessKey: UUID().uuidString)
        let wrong = try #require(try RoomMediaSecurity.forRoom(wrongRoom, serviceName: "source"))
        let otherSource = try #require(try RoomMediaSecurity.forRoom(room, serviceName: "another-source"))
        let session = UUID()
        let packet = try security.audioSealer(sessionID: session).seal(Data([42]))
        let opener = try security.audioOpener(sessionID: session)
        #expect(try opener.open(packet) == Data([42]))
        #expect(throws: SecureTransportError.replay) { try opener.open(packet) }
        #expect(throws: (any Error).self) { try wrong.audioOpener(sessionID: session).open(packet) }
        #expect(throws: (any Error).self) { try otherSource.audioOpener(sessionID: session).open(packet) }
        #expect(throws: (any Error).self) { try security.audioOpener(sessionID: UUID()).open(packet) }
        for video in [false, true] {
            try await assertTLS(security: security, candidates: [security.tcp(video: video), wrong.tcp(video: video), LocalNetworkParameters.tcp()], video: video)
        }
    }

    private func assertTLS(security: RoomMediaSecurity, candidates: [NWParameters], video: Bool) async throws {
        let queue = DispatchQueue(label: "review.private-media.test")
        let probe = MediaProbe()
        let listener = try NWListener(using: security.tcp(video: video), on: .any)
        listener.stateUpdateHandler = { state in if case .ready = state { probe.lock.withLock { probe.port = listener.port } } }
        listener.newConnectionHandler = { connection in
            probe.lock.withLock { probe.connections.append(connection) }
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state { probe.lock.withLock { probe.failures.append("server: \(error)") } }
            }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { data, _, _, _ in
                if let data, !data.isEmpty { probe.lock.withLock { probe.received.append(data) } }
            }
        }
        listener.start(queue: queue)
        defer {
            listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
            probe.lock.withLock { probe.connections.forEach { $0.cancel() }; probe.connections.removeAll() }
        }
        for _ in 0..<200 {
            if probe.lock.withLock({ probe.port != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try #require(probe.lock.withLock { probe.port })
        for (index, parameters) in candidates.enumerated() {
            let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
            probe.lock.withLock { probe.connections.append(connection) }
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state { probe.lock.withLock { probe.failures.append("client \(index): \(error)") } }
            }
            connection.start(queue: queue)
            connection.send(content: Data([UInt8(index + 1)]), completion: .contentProcessed { _ in })
        }
        for _ in 0..<200 {
            if probe.lock.withLock({ !probe.received.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(probe.lock.withLock { probe.received } == [Data([1])], "TLS failures: \(probe.lock.withLock { probe.failures })")
    }

}

private final class MediaProbe: @unchecked Sendable {
    let lock = NSLock()
    var port: NWEndpoint.Port?
    var connections = [NWConnection]()
    var received = [Data]()
    var failures = [String]()
}
