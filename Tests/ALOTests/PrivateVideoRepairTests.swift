import Foundation
import Network
import Testing
import ALOCore
@testable import ALO

@Suite("Private video repair preserves TLS", .serialized)
struct PrivateVideoRepairTests {
    @Test(arguments: [false, true])
    func replacementDeliversThroughThePSKListener(stallFirstSend: Bool) async throws {
        try await exercisePrivateVideoSend(stallFirstSend: stallFirstSend, delayFirstSend: false)
    }

    @Test func healthyBackpressureKeepsTheOriginalTLSConnection() async throws {
        try await exercisePrivateVideoSend(stallFirstSend: false, delayFirstSend: true)
    }

    private func exercisePrivateVideoSend(stallFirstSend: Bool, delayFirstSend: Bool) async throws {
        let room = RoomConfiguration(name: "Private repair", isPrivate: true, accessKey: UUID().uuidString)
        let security = try #require(try RoomMediaSecurity.forRoom(room, serviceName: "repair-source"))
        let queue = DispatchQueue(label: "alo.tests.private-video-repair")
        let probe = PrivateVideoRepairProbe()
        let audio = try NWListener(using: .udp, on: .any)
        let video = try NWListener(using: security.tcp(video: true), on: .any)
        audio.newConnectionHandler = { connection in
            probe.lock.withLock { probe.connections.append(connection) }
            connection.start(queue: queue)
        }
        video.newConnectionHandler = { connection in
            probe.lock.withLock { probe.connections.append(connection) }
            connection.stateUpdateHandler = { state in
                if case .ready = state { _ = probe.lock.withLock { probe.ready.insert(ObjectIdentifier(connection)) } }
            }
            connection.start(queue: queue)
            probe.receiveVideo(connection, decoder: VideoFrameStreamDecoder())
        }
        audio.start(queue: queue); video.start(queue: queue)
        let host = HostServer(roomName: "repair-source", mediaSecurity: security, advertise: false,
            listenerReadyHandler: { port in probe.lock.withLock { probe.port = port } },
            outboundSend: { connection, bytes, isComplete, completion in
                // Fail only the first video write; control and replacement writes
                // remain actual Network.framework traffic, not a mocked delivery.
                let isVideo = bytes.prefix(4) == Data([0x57, 0x45, 0x52, 0x56])
                let inject = probe.lock.withLock {
                    guard isVideo, !probe.injected else { return false }
                    probe.injected = true
                    return true
                }
                if inject {
                    if delayFirstSend {
                        // A healthy but backpressured write completes after the old
                        // one-second watchdog. Delivery still uses actual PSK TLS.
                        queue.asyncAfter(deadline: .now() + 1.5) {
                            connection.send(content: bytes, isComplete: isComplete,
                                completion: .contentProcessed { error in
                                    probe.lock.withLock { probe.delayedSendCompleted = true }
                                    completion(error)
                                })
                        }
                        return
                    }
                    if !stallFirstSend { completion(.posix(.ECONNRESET)) }
                    return // The stall case exercises HostServer's send watchdog.
                }
                connection.send(content: bytes, isComplete: isComplete, completion: .contentProcessed { completion($0) })
            })
        host.setVideoKeyframeHandler { [weak host] in
            probe.lock.withLock {
                if delayFirstSend && !probe.delayedSendCompleted { probe.blockedKeyframeRequests += 1 }
            }
            host?.acceptVideo(Self.frame(marker: 2))
        }
        try host.start()
        defer {
            host.setVideoKeyframeHandler(nil); host.stop()
            audio.newConnectionHandler = nil; video.newConnectionHandler = nil
            audio.cancel(); video.cancel()
            probe.lock.withLock { probe.connections.forEach { $0.stateUpdateHandler = nil; $0.cancel() }; probe.connections.removeAll() }
        }
        let listenersReady = try await wait { audio.port != nil && video.port != nil && probe.lock.withLock { probe.port != nil } }
        #expect(listenersReady)
        let port = try #require(probe.lock.withLock { probe.port })
        let audioPort = try #require(audio.port), videoPort = try #require(video.port)
        let control = NWConnection(host: "127.0.0.1", port: port, using: security.tcp())
        probe.lock.withLock { probe.connections.append(control) }
        control.start(queue: queue)
        let join = try ControlMessage(type: "join", udpPort: audioPort.rawValue, videoPort: videoPort.rawValue,
            displayName: "Repair receiver", participantID: UUID().uuidString).encodedLine()
        control.send(content: join, completion: .contentProcessed { _ in })
        let firstConnected = try await wait { probe.lock.withLock { !probe.ready.isEmpty } }
        #expect(firstConnected, "Initial private video TLS connection must work before testing repair")
        let original = try #require(probe.lock.withLock { probe.ready.first })
        host.acceptVideo(Self.frame(marker: 1))
        if delayFirstSend {
            // Keep capturing while TCP is backpressured. A blocked listener
            // must not request more expensive room-wide keyframes it cannot send.
            for _ in 0..<25 {
                host.acceptVideo(VideoFrame(captureTimeNanos: MonotonicClock.nowNanos(), width: 16, height: 16,
                    isKeyframe: false, payload: Data([3, 42, 77])))
                try await Task.sleep(for: .milliseconds(40))
            }
            let delivered = try await wait { probe.lock.withLock {
                probe.deliveries.contains { $0.connection == original && $0.payload == Data([1, 42, 77]) }
            } }
            #expect(delivered, "A successful 1.5-second send must deliver over the original TLS connection")
            #expect(probe.lock.withLock { probe.ready.count == 1 }, "Healthy backpressure must not trigger reconnect/IDR churn")
            #expect(probe.lock.withLock { probe.blockedKeyframeRequests == 0 }, "Do not increase encoder load for a still-blocked video sender")
            return
        }
        let repaired = try await wait(attempts: stallFirstSend ? 800 : 400) { probe.lock.withLock { probe.deliveries.contains { $0.connection != original && $0.payload == Data([2, 42, 77]) } } }
        #expect(probe.lock.withLock { probe.injected })
        #expect(repaired, "Replacement video must complete PSK TLS and deliver the fresh keyframe after a failed or stalled send")
        #expect(probe.lock.withLock { probe.deliveries.allSatisfy { $0.payload != Data([1, 42, 77]) } })
    }

    private static func frame(marker: UInt8) -> VideoFrame {
        VideoFrame(captureTimeNanos: MonotonicClock.nowNanos(), width: 16, height: 16,
                   isKeyframe: true, parameterSet1: Data([0x67]), parameterSet2: Data([0x68]),
                   payload: Data([marker, 42, 77]))
    }
    private func wait(attempts: Int = 400, until condition: () -> Bool) async throws -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private final class PrivateVideoRepairProbe: @unchecked Sendable {
    struct Delivery { let connection: ObjectIdentifier; let payload: Data }
    let lock = NSLock()
    var port: NWEndpoint.Port?
    var connections: [NWConnection] = []
    var ready: Set<ObjectIdentifier> = []
    var injected = false
    var delayedSendCompleted = false
    var blockedKeyframeRequests = 0
    var deliveries: [Delivery] = []

    func receiveVideo(_ connection: NWConnection, decoder: VideoFrameStreamDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            if let bytes {
                let frames = decoder.append(bytes)
                self.lock.withLock {
                    self.deliveries += frames.map { Delivery(connection: ObjectIdentifier(connection), payload: $0.payload) }
                }
            }
            if !complete && error == nil { self.receiveVideo(connection, decoder: decoder) }
        }
    }
}
