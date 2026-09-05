import Foundation
import Network
import Testing
import ALOCore
@testable import ALO

@Suite("Bounded audio sender bursts", .serialized)
struct AudioSenderBurstTests {
    @Test func expiredPendingDoesNotMakeFreshCaptureCongested() throws {
        let fixture = try AudioBurstFixture()
        defer { fixture.stop() }
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 12 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos - 60_000_000)
        fixture.barrier()
        fixture.advanceAudioClock(by: 120_000_000)
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 4 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos)
        fixture.barrier()
        fixture.drain()
        #expect(fixture.probe.sequences == Array(0..<8) + Array(12..<16))
        let snapshot = try #require(fixture.host.audioSenderSnapshot().first)
        #expect(snapshot.enqueued == 16 && snapshot.sent == 12)
        #expect(snapshot.expiredWait == 4 && snapshot.replaced == 0)
    }

    @Test func idleCapturePastPlayoutDeadlineHasAnExplicitDropReason() throws {
        let fixture = try AudioBurstFixture()
        defer { fixture.stop() }
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 4 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos - 300_000_000)
        fixture.barrier()
        let snapshot = try #require(fixture.host.audioSenderSnapshot().first)
        #expect(snapshot.enqueued == 4 && snapshot.sent == 0)
        #expect(snapshot.expiredAge == 4 && snapshot.expiredWait == 0)
        #expect(snapshot.pending == 0 && fixture.probe.sequences.isEmpty)
        let diagnostics = try #require(fixture.host.diagnosticsSnapshot().listeners.first)
        #expect(diagnostics.audioExpiredAge == 4)
    }

    @Test(arguments: [UInt64(60_000_000), 120_000_000])
    func briefCompletionBurstPreservesEveryPacketInOrder(acquisitionAgeNanos: UInt64) throws {
        let fixture = try AudioBurstFixture()
        defer { fixture.stop() }
        let start = fixture.audioNowNanos - acquisitionAgeNanos
        // Three callbacks arrive before their completions are dispatched, as
        // happens after a brief scheduler stall even on an uncongested link.
        // Acquisition can already be delayed while still fitting the room's
        // 250ms playout budget; that is not time spent in the sender queue.
        for index in 0..<3 {
            fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 4 * 240 * 2),
                captureTimeNanos: start + UInt64(index) * 20_000_000)
        }
        fixture.barrier()
        #expect(fixture.probe.sequences == Array(0..<8))
        fixture.drain()
        #expect(fixture.probe.sequences == Array(0..<12),
            "A brief completion burst must not collapse four fresh pending packets into one")
    }

    @Test func sixtyMillisecondCompletionDelayPreservesFreshBurst() throws {
        let fixture = try AudioBurstFixture()
        defer { fixture.stop() }
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 12 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos - 60_000_000)
        fixture.barrier()
        #expect(fixture.probe.sequences == Array(0..<8))
        // Delivery can be fast even when callback dispatch is delayed. Advance
        // only the sender's clock; no wall-clock sleeps or scheduling assumptions.
        fixture.advanceAudioClock(by: 60_000_000)
        fixture.drain()
        #expect(fixture.probe.sequences == Array(0..<12))
    }

    @Test func stalledSenderDoesNotFlushExpiredAudioAfterCaptureStops() throws {
        let fixture = try AudioBurstFixture()
        defer { fixture.stop() }
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 12 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos - 60_000_000)
        fixture.barrier()
        fixture.advanceAudioClock(by: 120_000_000)
        fixture.drain()
        #expect(fixture.probe.sequences == Array(0..<8),
            "Completion after a stall must discard expired pending audio even without a new capture")
    }

    @Test func pendingStorageRemainsBoundedDuringAnOversizedBurst() throws {
        let fixture = try AudioBurstFixture()
        defer { fixture.stop() }
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 200 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos)
        fixture.barrier()
        fixture.drain()
        #expect(fixture.probe.sequences == Array(0..<8) + [199],
            "An oversized backlog enters bounded latest-only mode")
    }

    @Test func congestionPersistsUntilInflightActuallyDrainsThenFIFORecovers() throws {
        let fixture = try AudioBurstFixture()
        defer { fixture.stop() }
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 25 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos)
        fixture.barrier()
        fixture.completeOne()
        #expect(fixture.probe.sequences == Array(0..<8) + [24])
        // Pending is now empty, but eight sends remain outstanding. This is
        // still congestion, not permission to rebuild another FIFO backlog.
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 12 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos)
        fixture.barrier()
        fixture.completeOne()
        #expect(fixture.probe.sequences == Array(0..<8) + [24, 36])
        fixture.drain()
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 12 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos)
        fixture.barrier()
        fixture.drain()
        #expect(fixture.probe.sequences == Array(0..<8) + [24, 36] + Array(37..<49))
    }

    @Test func aRecoveredSteadyLinkRestoresFIFOWithoutReachingZeroInflight() throws {
        let fixture = try AudioBurstFixture()
        defer { fixture.stop() }
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 25 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos)
        fixture.barrier()
        // First completion sends the latest pending packet, maintaining eight
        // in flight. Four more demonstrate recovery to half capacity without
        // requiring the steady stream to become completely idle.
        for _ in 0..<5 { fixture.completeOne() }
        #expect(fixture.probe.sequences == Array(0..<8) + [24])
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 12 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos)
        fixture.barrier()
        fixture.drain()
        #expect(fixture.probe.sequences == Array(0..<8) + [24] + Array(25..<37),
            "A recovered link must preserve a fresh burst while four earlier sends remain in flight")
    }

    @Test(arguments: ["pause", "resync", "stop"])
    func pendingAudioCannotCrossATimelineOrConnectionBoundary(boundary: String) throws {
        let fixture = try AudioBurstFixture()
        defer { fixture.stop() }
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 12 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos - 60_000_000)
        fixture.barrier()
        switch boundary {
        case "pause": fixture.host.setNowPlaying(NowPlayingMedia(isPlaying: false))
        case "resync": _ = fixture.host.requestResync()
        default: fixture.host.stop()
        }
        fixture.barrier()
        fixture.drain()
        #expect(fixture.probe.sequences == Array(0..<8))
    }

    @Test func replacedPeersCompletionsCannotDrainTheOldQueue() throws {
        let fixture = try AudioBurstFixture()
        defer { fixture.stop() }
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 12 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos - 60_000_000)
        fixture.barrier()
        let replacement = try fixture.replacePeer()
        defer { replacement.cancel() }
        fixture.drain()
        #expect(fixture.probe.sequences == Array(0..<8))
        fixture.host.acceptAudio(samples: [Int16](repeating: 1, count: 4 * 240 * 2),
            captureTimeNanos: fixture.audioNowNanos)
        fixture.barrier()
        fixture.drain()
        #expect(fixture.probe.sequences == Array(0..<8) + Array(12..<16))
    }
}

private final class AudioBurstFixture {
    let probe = AudioBurstProbe()
    let host: HostServer
    let control: NWConnection
    private let queue = DispatchQueue(label: "alo.tests.audio-burst-control")
    private let joined = DispatchSemaphore(value: 0)
    private let participantID = UUID().uuidString

    init() throws {
        let probe = self.probe
        let ready = DispatchSemaphore(value: 0)
        let joined = self.joined
        host = HostServer(roomName: "Audio burst regression", receiverCountHandler: {
            if $0 == 1 { joined.signal() }
        }, advertise: false, listenerReadyHandler: { port in
            probe.lock.withLock { probe.port = port }; ready.signal()
        }, outboundSend: { connection, bytes, complete, completion in
            if let packet = AudioPacket(data: bytes) {
                probe.lock.withLock {
                    probe.sent.append(packet.sequence)
                    probe.completions.append(completion)
                }
            } else {
                connection.send(content: bytes, isComplete: complete,
                    completion: .contentProcessed(completion))
            }
        }, audioSendNowNanos: { probe.lock.withLock { probe.audioNowNanos } })
        try host.start()
        guard ready.wait(timeout: .now() + 3) == .success,
              let port = probe.lock.withLock({ probe.port }) else {
            host.stop(); throw AudioBurstError.listenerNotReady
        }
        control = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        control.start(queue: queue)
        let join = try ControlMessage(type: "join", udpPort: 9, videoPort: 9,
            displayName: "Burst receiver", participantID: participantID).encodedLine()
        control.send(content: join, completion: .contentProcessed { _ in })
        guard joined.wait(timeout: .now() + 3) == .success else {
            control.cancel(); host.stop(); throw AudioBurstError.joinFailed
        }
    }

    func barrier() { _ = host.diagnosticsSnapshot() }
    var audioNowNanos: UInt64 { probe.lock.withLock { probe.audioNowNanos } }
    func advanceAudioClock(by nanos: UInt64) { probe.lock.withLock { probe.audioNowNanos += nanos } }
    func replacePeer() throws -> NWConnection {
        let port = try #require(probe.lock.withLock { probe.port })
        let replacement = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        replacement.start(queue: queue)
        let join = try ControlMessage(type: "join", udpPort: 9, videoPort: 9,
            displayName: "Replacement", participantID: participantID).encodedLine()
        replacement.send(content: join, completion: .contentProcessed { _ in })
        guard joined.wait(timeout: .now() + 3) == .success else {
            replacement.cancel(); throw AudioBurstError.joinFailed
        }
        return replacement
    }
    func drain() {
        for _ in 0..<32 {
            let callbacks = probe.lock.withLock {
                let callbacks = probe.completions
                probe.completions.removeAll()
                return callbacks
            }
            if callbacks.isEmpty { return }
            callbacks.forEach { $0(nil) }
            barrier()
        }
    }
    func completeOne() {
        let callback = probe.lock.withLock { probe.completions.removeFirst() }
        callback(nil)
        barrier()
    }
    func stop() { control.cancel(); host.stop() }
}

private enum AudioBurstError: Error { case listenerNotReady, joinFailed }
private final class AudioBurstProbe: @unchecked Sendable {
    let lock = NSLock()
    var port: NWEndpoint.Port?
    var audioNowNanos = MonotonicClock.nowNanos()
    var sent: [UInt32] = []
    var completions: [(NWError?) -> Void] = []
    var sequences: [UInt32] { lock.withLock { sent } }
}
