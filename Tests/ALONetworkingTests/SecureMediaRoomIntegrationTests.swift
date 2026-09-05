import Foundation
import Network
import Testing
import ALOCore
@testable import ALONetworking

/// Real TLS admission, clock probes and authenticated UDP, with synthetic capture.
/// This checks lifecycle continuity, not speaker/Bluetooth or acoustic accuracy.
@Suite("Secure room live media lifecycle", .serialized)
struct SecureMediaRoomIntegrationTests {
    @Test func lateJoinAndRepeatedRejoinDoNotRequireRebroadcastOrRestartHealthyPeer() async throws {
        let room = RoomConfiguration.secure(name: "Live media lifecycle")
        let admission = LiveMediaBox<MediaHostSession?>(nil)
        let source = try LiveMediaNode(room: room, incoming: { channel, _ in
            channel.withAuthenticatedCredentials { result in
                do {
                    guard let host = admission.read({ $0 }) else { channel.cancel(); return }
                    try host.attach(channel: channel, credentials: result.get())
                } catch { channel.cancel() }
            }
        })
        let healthy = try LiveMediaNode(room: room)
        defer { source.stop(); healthy.stop(); admission.read { $0 }?.stop() }
        try source.start(); try healthy.start()
        let sourcePort = try await source.port()
        let timeline = CapturedMediaTimeline()
        source.mesh.publishBroadcaster(active: true, mediaServiceName: "Live capture")
        try await liveMediaEventually { source.epoch != nil }
        let epoch = try #require(source.epoch)
        let broadcaster = MediaHostSession.Broadcaster(peerID: source.id, epoch: epoch)
        let host: MediaHostSession = try await withCheckedThrowingContinuation { continuation in
            source.mesh.makeMediaHost(callbacks: .init(currentBroadcaster: { broadcaster },
                currentAnchor: { _, stream, now in timeline.anchor(for: stream, issuedAtHostNanos: now) })) {
                continuation.resume(with: $0)
            }
        }
        admission.update { $0 = host }
        let capture = LiveMediaCapture(host: host, timeline: timeline)
        capture.start()
        defer { capture.stop() }
        // Capture has started before any receiver exists: the reported regression.
        try await liveMediaEventually { capture.packetCount > 30 }
        healthy.connect(port: sourcePort, source: source.id)
        try await liveMediaEventually { healthy.hasPeer(source.id) }
        let healthySink = LiveMediaSink()
        defer { healthySink.stop() }
        healthySink.open(node: healthy, room: room, source: source.id, epoch: epoch)
        try await liveMediaEventually { healthySink.count > 30 }

        let returningIdentity = try InstallationIdentity.ephemeral()
        for _ in 0..<2 {
            let before = healthySink.count
            let newcomer = LiveMediaNode(room: room, identity: returningIdentity)
            let sink = LiveMediaSink()
            defer { sink.stop(); newcomer.stop() }
            try newcomer.start()
            newcomer.connect(port: sourcePort, source: source.id)
            try await liveMediaEventually { newcomer.hasPeer(source.id) }
            sink.open(node: newcomer, room: room, source: source.id, epoch: epoch)
            try await liveMediaEventually { sink.count > 30 && healthySink.count > before + 30 }
            #expect(sink.errors.isEmpty)
            #expect(sink.uniqueFrames == sink.count)
            #expect(sink.delays.allSatisfy { $0 == RoomTiming.defaultPlayoutDelayNanos })
            sink.stop()
            await newcomer.stopAndWait()
            try await liveMediaEventually { !source.hasPeer(newcomer.id) }
            let afterLeave = healthySink.count
            try await liveMediaEventually { healthySink.count > afterLeave + 30 }
        }
        #expect(healthySink.errors.isEmpty)
        #expect(healthySink.uniqueFrames == healthySink.count)
        // Another receiver's arrival/departure must not renew a healthy lease.
        #expect(healthySink.commits == 1)
        #expect(healthySink.delays == [RoomTiming.defaultPlayoutDelayNanos])
    }
}

private final class LiveMediaBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read<T>(_ body: (Value) -> T) -> T { lock.withLock { body(value) } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private final class LiveMediaNode {
    struct State { var port: NWEndpoint.Port?; var peers: Set<String> = []; var epoch: UInt64? }
    let id: UUID
    let mesh: MeshControlPlane
    private let state = LiveMediaBox(State())
    convenience init(room: RoomConfiguration, incoming: ((SecurePeerChannel, AuthenticatedPeer) -> Void)? = nil) throws {
        self.init(room: room, identity: try .ephemeral(), incoming: incoming)
    }
    init(room: RoomConfiguration, identity: InstallationIdentity,
         incoming: ((SecurePeerChannel, AuthenticatedPeer) -> Void)? = nil) {
        id = identity.publicIdentity.nodeID
        let state = self.state
        mesh = MeshControlPlane(room: room, nodeID: id.uuidString, displayName: "Test peer",
            listenerReadyHandler: { port in state.update { $0.port = port } },
            replicaHandler: { replica in state.update { $0.epoch = replica.broadcaster?.epoch } },
            participantsHandler: { peers in state.update { $0.peers = Set(peers.map(\.id)) } },
            installationIdentity: identity, peerPins: MemoryPeerPinStore(), incomingMediaChannelHandler: incoming)
    }
    func start() throws { try mesh.start(advertise: false) }
    func stop() { mesh.stop() }
    func stopAndWait() async { await withCheckedContinuation { c in mesh.stop { c.resume() } } }
    func hasPeer(_ id: UUID) -> Bool { state.read { $0.peers.contains(id.uuidString) } }
    var epoch: UInt64? { state.read { $0.epoch } }
    func port() async throws -> NWEndpoint.Port {
        try await liveMediaEventually { self.state.read { $0.port != nil } }
        return try #require(state.read { $0.port })
    }
    func connect(port: NWEndpoint.Port, source: UUID) {
        mesh.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port), expectedNodeID: source.uuidString)
    }
}

private final class LiveMediaSink: @unchecked Sendable {
    struct State {
        var receiver: MediaReceiverSession?
        var frames = Set<UInt64>()
        var count = 0
        var delays: [UInt64] = []
        var errors: [String] = []
    }
    private let state = LiveMediaBox(State())
    var count: Int { state.read { $0.count } }
    var uniqueFrames: Int { state.read { $0.frames.count } }
    var commits: Int { state.read { $0.delays.count } }
    var delays: [UInt64] { state.read { $0.delays } }
    var errors: [String] { state.read { $0.errors } }
    func stop() { state.read { $0.receiver }?.stop() }
    func open(node: LiveMediaNode, room: RoomConfiguration, source: UUID, epoch: UInt64) {
        node.mesh.openMediaChannel(to: source, role: .mediaControl) { [self] result in
            do {
                let channel = try result.get().0
                let selection = MediaReceiverSession.Selection(roomID: UUID(uuidString: room.id)!,
                    localPeerID: node.id, broadcasterPeerID: source, broadcasterEpoch: epoch)
                MediaReceiverSession.attach(channel: channel, expected: selection, callbacks: .init(
                    prepareAnchor: { [self] preparation in
                        state.read { $0.receiver }?.completePreparation(id: preparation.id, ready: true)
                    }, anchorCommitted: { [self] preparation in
                        state.update { $0.delays.append(preparation.anchor.hostPlaybackTimeNanos - preparation.anchor.captureTimeNanos) }
                    }, audio: { [self] packet, _, _ in
                        state.update { $0.count += 1; $0.frames.insert(packet.frameIndex) }
                    }, state: { [self] value in
                        if value == .failed { state.update { $0.errors.append("Media receiver failed") } }
                    })) { [self] result in
                        switch result {
                        case .success(let receiver): state.update { $0.receiver = receiver }
                        case .failure(let error): state.update { $0.errors.append(String(describing: error)) }
                        }
                    }
            } catch { state.update { $0.errors.append(String(describing: error)) } }
        }
    }
}

private final class LiveMediaCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "alo.test.live-capture", qos: .userInteractive)
    private let count = LiveMediaBox<UInt32>(0)
    private let host: MediaHostSession
    private let timeline: CapturedMediaTimeline
    private var timer: DispatchSourceTimer?
    var packetCount: UInt32 { count.read { $0 } }
    init(host: MediaHostSession, timeline: CapturedMediaTimeline) { self.host = host; self.timeline = timeline }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [self] in
            let sequence = count.read { $0 }
            let packet = AudioPacket(sequence: sequence, frameIndex: UInt64(sequence) * 240,
                captureTimeNanos: MonotonicClock.nowNanos(), samples: Array(repeating: 2_000, count: 480))
            timeline.observe([packet]); host.submitAudio([packet])
            count.update { $0 += 1 }
        }
        self.timer = timer; timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
}

private func liveMediaEventually(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(condition(), "Real TLS/UDP room did not reach expected media state within 10 seconds")
}
