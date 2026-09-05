import Foundation
import Network
import Testing
import ALOCore
import ALONetworking
@testable import ALO

@Suite("Private desktop media integration", .serialized)
struct PrivateMediaIntegrationTests {
    @Test func realHostJoinEncryptsAudioAndRejectsUninvitedClients() async throws {
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
                probe.lock.withLock { probe.connections.append(connection) }
                connection.start(queue: queue)
            }
            listener.start(queue: queue)
        }
        let host = HostServer(roomName: "source", mediaSecurity: security, advertise: false,
            listenerReadyHandler: { port in probe.lock.withLock { probe.port = port } },
            outboundSend: { connection, data, isComplete, completion in
                probe.lock.withLock {
                    if let message = try? JSONDecoder().decode(ControlMessage.self, from: data) {
                        if message.type == "welcome", let session = message.mediaSessionID { probe.sessions.append(session) }
                    } else { probe.audioPackets.append(data) }
                }
                connection.send(content: data, isComplete: isComplete, completion: .contentProcessed { error in completion(error) })
            })
        try host.start()
        defer {
            host.stop()
            audio.newConnectionHandler = nil; video.newConnectionHandler = nil
            audio.cancel(); video.cancel()
            probe.lock.withLock { probe.connections.forEach { $0.cancel() }; probe.connections.removeAll() }
        }
        for _ in 0..<200 {
            if audio.port != nil, video.port != nil, probe.lock.withLock({ probe.port != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try #require(probe.lock.withLock { probe.port })
        let audioPort = try #require(audio.port), videoPort = try #require(video.port)
        for parameters in [security.tcp(), wrong.tcp(), LocalNetworkParameters.tcp()] {
            let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
            probe.lock.withLock { probe.connections.append(connection) }
            connection.start(queue: queue)
            let join = try ControlMessage(type: "join", udpPort: audioPort.rawValue, videoPort: videoPort.rawValue,
                                          displayName: "Receiver", participantID: UUID().uuidString).encodedLine()
            connection.send(content: join, completion: .contentProcessed { _ in })
        }
        for _ in 0..<200 {
            if probe.lock.withLock({ !probe.sessions.isEmpty }) { break }
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
        #expect(probe.lock.withLock { probe.sessions.count == 1 && probe.audioPackets.count == 1 })
        #expect(AudioPacket(data: encrypted) == nil)
        let opener = try security.audioOpener(sessionID: session)
        let packet = try #require(AudioPacket(data: try opener.open(encrypted)))
        #expect(packet.samples == samples)
        #expect(throws: SecureTransportError.replay) { try opener.open(encrypted) }
    }
}

private final class PrivateHostProbe: @unchecked Sendable {
    let lock = NSLock()
    var port: NWEndpoint.Port?
    var connections = [NWConnection]()
    var sessions = [UUID]()
    var audioPackets = [Data]()
}
