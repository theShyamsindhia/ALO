import Foundation
import CryptoKit
import Testing
@testable import ALONetworking

struct RoomCanvasCoordinatorTests {
    private func stroke(_ id: UUID) -> AnnotationAction {
        .beginDrawing(id: id, tool: .pencil, points: [.init(x: 0.2, y: 0.4)], color: "blue", width: 0.006)
    }

    @Test func joinedPeersFetchOneImageAndConcurrentDrawingsConvergeWithOwnUndo() throws {
        let f = try CanvasSessionFixture()
        let a = try f.join(), b = try f.join()
        try f.pump()
        #expect(a.viewer.state == .ready && b.viewer.state == .ready)
        #expect(a.viewer.imageBytes == f.bytes && b.viewer.imageBytes == f.bytes)
        let first = UUID(), second = UUID()
        a.viewer.submit(stroke(first)); b.viewer.submit(stroke(second)); try f.pump()
        a.viewer.submit(.endDrawing(id: first)); b.viewer.submit(.endDrawing(id: second)); try f.pump()
        #expect(f.host.snapshot(nowNanos: f.now)?.annotations.objects.count == 2)
        #expect(a.viewer.snapshot == b.viewer.snapshot)
        a.viewer.submit(.undo); try f.pump()
        #expect(a.viewer.snapshot?.annotations.objects.map(\.id) == [second])
        #expect(a.viewer.snapshot == b.viewer.snapshot)
        #expect(f.imageSends == 2, "Drawing and presence must not retransmit images")
        #expect(a.rejections.isEmpty && b.rejections.isEmpty)
    }

    @Test func publicCanvasOwnerGrantsEditingAndOtherPeopleCannotGrantThemselvesAccess() throws {
        let f = try CanvasSessionFixture(isPublic: true), a = try f.join()
        try f.pump()
        a.viewer.submit(stroke(UUID())); try f.pump()
        #expect(a.rejections.last == .permissionDenied)
        a.viewer.submit(.setPolicy(.init(permission: .everyone))); try f.pump()
        #expect(a.rejections.last == .permissionDenied)
        f.host.processLocal(.setPolicy(.init(permission: .approved, approvedIDs: [a.id.uuidString])), nowNanos: f.now)
        try f.pump()
        let id = UUID()
        a.viewer.submit(stroke(id)); try f.pump()
        a.viewer.submit(.endDrawing(id: id)); try f.pump()
        #expect(a.viewer.snapshot?.annotations.objects.first?.id == id)
        f.host.processLocal(.deleteObject(id: id), nowNanos: f.now); try f.pump()
        #expect(a.viewer.snapshot?.annotations.objects.isEmpty == true)
    }

    @Test func missingUpdateRequestsOneCheckpointAndBlocksCommandsUntilRecovered() throws {
        let f = try CanvasSessionFixture(), a = try f.join(), b = try f.join()
        try f.pump()
        f.dropNextUpdate.insert(a.id)
        let id = UUID()
        b.viewer.submit(stroke(id)); try f.pump()
        b.viewer.submit(.endDrawing(id: id)); try f.pump()
        #expect(a.viewer.state == .connecting)
        #expect(a.viewer.submit(.undo) == nil)
        #expect(f.checkpointRequests == 1)
        f.now += 1_000_000_000
        f.host.tick(nowNanos: f.now); try f.pump()
        #expect(a.viewer.state == .ready)
        #expect(a.viewer.snapshot?.annotations.objects == b.viewer.snapshot?.annotations.objects)
        #expect(f.imageSends == 2)
    }

    @Test func reconnectKeepsCanvasFinishesInterruptedGestureAndIgnoresRetiredConnection() throws {
        let f = try CanvasSessionFixture(), a = try f.join()
        try f.pump()
        let id = UUID()
        a.viewer.submit(stroke(id)); try f.pump()
        let retired = a.connectionID
        f.host.removePeer(connectionID: retired, nowNanos: f.now); try f.pump()
        if case .interrupted = a.viewer.state {} else { Issue.record("Link loss must not end the canvas") }
        #expect(a.viewer.snapshot != nil)
        #expect(f.host.snapshot(nowNanos: f.now)?.annotations.objects.first?.isComplete == true)
        try f.reconnect(a); try f.pump()
        #expect(a.viewer.state == .ready)
        a.viewer.receive(.ended, connectionID: retired, nowNanos: f.now)
        #expect(a.viewer.state == .ready)
        a.viewer.submit(.undo); try f.pump()
        #expect(a.viewer.snapshot?.annotations.objects.isEmpty == true)
        #expect(a.rejections.isEmpty, "Reconnect must not restart the command sequence")
        #expect(f.imageSends == 1, "A verified unchanged image can stay cached across reconnect")
    }

    @Test func replacingImageResetsCommandsAndOwnerEndCannotBeResurrected() throws {
        let f = try CanvasSessionFixture(), a = try f.join()
        try f.pump()
        let oldEpoch = a.viewer.snapshot?.annotations.sessionID
        a.viewer.submit(stroke(UUID())); try f.pump()
        let bytes = Data(repeating: 9, count: 55)
        try f.host.replaceImage(CanvasSessionFixture.descriptor(bytes), bytes: bytes, nowNanos: f.now)
        try f.pump()
        #expect(a.viewer.snapshot?.annotations.sessionID != oldEpoch)
        #expect(a.viewer.imageBytes == bytes)
        #expect(a.viewer.snapshot?.annotations.objects.isEmpty == true)
        let id = UUID()
        a.viewer.submit(stroke(id)); try f.pump()
        a.viewer.submit(.endDrawing(id: id)); try f.pump()
        #expect(a.rejections.isEmpty)
        f.host.end(); try f.pump()
        #expect(a.viewer.state == .ended && a.viewer.snapshot == nil && a.viewer.imageBytes == nil)
        #expect(f.host.snapshot(nowNanos: f.now) == nil)
        #expect(throws: RoomCanvasError.ended) { try f.reconnect(a) }
    }

    @Test func silenceAndMissingImagesTimeOutWhileLeavingNeverEndsOtherViewers() throws {
        let f = try CanvasSessionFixture(), a = try f.join()
        f.holdImages.insert(a.id)
        try f.pump()
        #expect(a.viewer.state == .loadingImage(0))
        f.now += 10_000_000_000
        a.viewer.tick(nowNanos: f.now); try f.pump()
        if case .interrupted = a.viewer.state {} else { Issue.record("A silent image response needs a visible recovery state") }
        f.holdImages.remove(a.id)
        try f.reconnect(a); try f.pump()
        let b = try f.join(); try f.pump()
        a.viewer.leave(); try f.pump()
        #expect(a.viewer.state == .left && a.viewer.imageBytes == nil)
        #expect(b.viewer.state == .ready && !f.host.ended)
        #expect(b.viewer.snapshot?.participants.contains(a.id) == false)
    }

    @Test func revocationAndWrongDirectionCloseOnlyThatCanvasPeer() throws {
        let f = try CanvasSessionFixture(), a = try f.join(), b = try f.join()
        try f.pump()
        a.serverCredentials.invalidate()
        f.host.tick(nowNanos: f.now); try f.pump()
        if case .interrupted = a.viewer.state {} else { Issue.record("Revoked peer stayed active") }
        #expect(b.viewer.state == .ready && !f.host.ended)
        f.host.receive(.ended, connectionID: b.connectionID, nowNanos: f.now); try f.pump()
        #expect(!f.host.ended, "A viewer cannot end the owner's canvas")
        if case .interrupted = b.viewer.state {} else { Issue.record("Invalid client message was accepted") }
    }

    @Test func largePauseUpdateFallsBackToCheckpointsWithoutRetransmittingImages() throws {
        let f = try CanvasSessionFixture()
        let peers = try (0..<8).map { _ in try f.join() }
        try f.pump()
        let points = (0..<1_000).map { AnnotationPoint(x: Double($0) / 1_001, y: Double($0) / 1_003) }
        for peer in peers {
            peer.viewer.submit(.beginDrawing(id: UUID(), tool: .pencil, points: points, color: "blue", width: 0.006))
        }
        try f.pump()
        let before = f.checkpointSends
        f.host.processLocal(.setPolicy(.init(permission: .everyone, paused: true)), nowNanos: f.now)
        try f.pump()
        #expect(f.checkpointSends == before + peers.count)
        #expect(f.imageSends == peers.count)
        for peer in peers {
            #expect(peer.viewer.state == .ready && peer.rejections.isEmpty)
            #expect(peer.viewer.snapshot?.annotations.policy.paused == true)
            #expect(peer.viewer.snapshot?.annotations.objects.count == peers.count)
            #expect(peer.viewer.snapshot?.annotations.objects.allSatisfy(\.isComplete) == true)
        }
    }

    @Test func uncompletedJoinExpiresAndSnapshotRequestsAreCoalesced() throws {
        let f = try CanvasSessionFixture(), a = try f.join()
        f.pending.removeAll() // No join reaches the host.
        f.now += 5_000_000_000
        f.host.tick(nowNanos: f.now); try f.pump()
        #expect(f.host.snapshot(nowNanos: f.now)?.participants == [f.owner])
        if case .interrupted = a.viewer.state {} else { Issue.record("An unused admitted connection remained open") }
        try f.reconnect(a); try f.pump()
        let initial = f.checkpointSends
        for _ in 0..<100 {
            f.host.receive(.requestImage(sha256: Data(repeating: 0, count: 32)), connectionID: a.connectionID, nowNanos: f.now)
        }
        #expect(f.checkpointSends == initial)
        f.now += 1_000_000_000
        f.host.tick(nowNanos: f.now); try f.pump()
        #expect(f.checkpointSends == initial + 1)
        #expect(a.viewer.state == .ready && f.imageSends == 1)
    }

    @Test func replacingWithSameImageResetsDrawingEpochWithoutAnotherDownload() throws {
        let f = try CanvasSessionFixture(), a = try f.join()
        try f.pump()
        let id = UUID()
        a.viewer.submit(stroke(id)); try f.pump()
        a.viewer.submit(.endDrawing(id: id)); try f.pump()
        let oldEpoch = a.viewer.snapshot?.annotations.sessionID
        try f.host.replaceImage(CanvasSessionFixture.descriptor(f.bytes), bytes: f.bytes, nowNanos: f.now)
        try f.pump()
        #expect(a.viewer.snapshot?.annotations.sessionID != oldEpoch)
        a.viewer.submit(stroke(UUID())); try f.pump()
        #expect(a.viewer.snapshot?.annotations.commandSequences[a.id.uuidString] == 1)
        #expect(f.imageSends == 1 && a.rejections.isEmpty)
    }
}

/// Queued typed messages pass through the real canvas codec. No synchronous
/// re-entry, sleeps, sockets or UI: the test chooses drops and advances time.
private final class CanvasSessionFixture {
    final class Peer {
        let id: UUID
        let viewer: RoomCanvasViewerCoordinator
        var connectionID = UUID()
        var serverCredentials: AuthenticatedChannelCredentials!
        var rejections: [AnnotationRejection] = []
        init(id: UUID, viewer: RoomCanvasViewerCoordinator) { self.id = id; self.viewer = viewer }
    }
    let room = UUID(), owner = UUID(), canvas = UUID()
    let bytes = Data(repeating: 4, count: RoomCanvasChunk.chunkBytes + 19)
    var host: RoomCanvasHostCoordinator!
    var now: UInt64 = 1_000_000_000
    var pending: [() throws -> Void] = []
    var dropNextUpdate: Set<UUID> = [], holdImages: Set<UUID> = []
    var imageSends = 0, checkpointRequests = 0, checkpointSends = 0

    init(isPublic: Bool = false) throws {
        host = try RoomCanvasHostCoordinator(roomID: room, canvasID: canvas, ownerID: owner,
            image: Self.descriptor(bytes), bytes: bytes, isPublicRoom: isPublic)
    }
    static func descriptor(_ bytes: Data) -> RoomCanvasImage {
        .init(name: "shared.png", byteCount: bytes.count, sha256: Data(SHA256.hash(data: bytes)), pixelWidth: 800, pixelHeight: 600)
    }
    func join() throws -> Peer {
        let id = UUID()
        let peer = Peer(id: id, viewer: .init(roomID: room, canvasID: canvas, localID: id, ownerID: owner))
        peer.viewer.onRejection = { [weak peer] _, reason in peer?.rejections.append(reason) }
        try reconnect(peer)
        return peer
    }
    func reconnect(_ peer: Peer) throws {
        let offer = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: [.desktop, .roomCanvas])
        let id = UUID()
        let transcript = try AdmissionTranscript(roomID: room, initiatorID: peer.id, responderID: owner,
            connectionID: id, initiatorKeyHash: Data(repeating: 1, count: 32), responderKeyHash: Data(repeating: 2, count: 32),
            initiatorNonce: Data(repeating: 3, count: 32), responderNonce: Data(repeating: 4, count: 32),
            initiatorOffer: offer, responderOffer: offer, policy: .secureV2, channelRole: .roomCanvas)
        let client = AuthenticatedChannelCredentials(transcript: transcript, localRole: .initiator, rootSecret: NetworkFixture.key)
        let server = AuthenticatedChannelCredentials(transcript: transcript, localRole: .responder, rootSecret: NetworkFixture.key)
        try host.addPeer(credentials: server, nowNanos: now, send: { [unowned self, weak peer] output in
            guard let peer else { return }
            switch output {
            case .message(let message):
                if case .update = message, self.dropNextUpdate.remove(peer.id) != nil { return }
                self.deliver(message, to: peer, connection: id)
            case .checkpoint(let snapshot):
                self.checkpointSends += 1
                do { for chunk in try RoomCanvasChunk.checkpoint(snapshot) { self.deliver(.checkpointChunk(chunk), to: peer, connection: id) } }
                catch { Issue.record(error) }
            case .image(let bytes, _):
                guard !self.holdImages.contains(peer.id) else { return }
                self.imageSends += 1
                do { for chunk in try RoomCanvasChunk.split(bytes) { self.deliver(.imageChunk(chunk), to: peer, connection: id) } }
                catch { Issue.record(error) }
            case .end: self.deliver(.ended, to: peer, connection: id)
            }
        }, close: { [unowned self, weak peer] in
            self.pending.append { peer?.viewer.disconnected(connectionID: id, reason: "Test link interrupted") }
        })
        peer.connectionID = id; peer.serverCredentials = server
        try peer.viewer.connect(credentials: client, nowNanos: now, send: { [unowned self] message in
            if case .requestCheckpoint = message { self.checkpointRequests += 1 }
            self.pending.append {
                let data = try message.encoded(roomID: self.room, canvasID: self.canvas)
                self.host.receive(try RoomCanvasMessage(encoded: data, roomID: self.room, canvasID: self.canvas), connectionID: id, nowNanos: self.now)
            }
        }, close: { [unowned self] in self.pending.append { self.host.removePeer(connectionID: id, nowNanos: self.now) } })
    }
    private func deliver(_ message: RoomCanvasMessage, to peer: Peer, connection: UUID) {
        pending.append { [weak peer] in
            let bytes = try message.encoded(roomID: self.room, canvasID: self.canvas)
            peer?.viewer.receive(try RoomCanvasMessage(encoded: bytes, roomID: self.room, canvasID: self.canvas), connectionID: connection, nowNanos: self.now)
        }
    }
    func pump() throws {
        var count = 0
        while !pending.isEmpty {
            count += 1
            try #require(count < 10_000, "Coordinator sent an unbounded response loop")
            try pending.removeFirst()()
        }
        now += 20_000_000
    }
}
