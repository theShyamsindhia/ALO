import Foundation
import Testing
import ALOCore
@testable import ALONetworking

@Suite struct AnnotationCoordinatorTests {
    @Test(arguments: [false, true])
    func sourceChangeDuringPublicationDoesNotDeliverRetiredEvents(restart: Bool) throws {
        let pair = try AnnotationCoordinatorFixture()
        let source = try #require(pair.snapshot?.sessionID)
        var changed = false
        pair.host.onEvent = { [weak pair] _ in
            guard let pair, !changed else { return }
            changed = true
            // Queue another event while the old source is still current, then
            // retire it before the outer event reaches the wire.
            pair.host.processLocal(.init(sessionID: source, sequence: 2,
                action: .setDefaultStickerTTL(.threeHundred)), nowNanos: 1_000_000_000)
            if restart { pair.host.beginSource(nowNanos: 2_000_000_000) }
            else { pair.host.endSource() }
        }
        pair.host.processLocal(.init(sessionID: source, sequence: 1,
            action: .setDefaultStickerTTL(.thirty)), nowNanos: 1_000_000_000)
        #expect(pair.wireRevisions.isEmpty)
        #expect(pair.events.isEmpty)
        #expect(pair.errors.isEmpty)
        if restart {
            #expect(pair.snapshot?.sessionID != source)
            #expect(pair.snapshot?.revision == 0)
            let next = try #require(pair.snapshot?.sessionID)
            pair.host.processLocal(.init(sessionID: next, sequence: 1,
                action: .setDefaultStickerTTL(.thirty)), nowNanos: 3_000_000_000)
            #expect(pair.wireRevisions == [1])
            #expect(pair.events.count == 1)
        } else { #expect(pair.snapshot == nil) }
    }

    @Test func sourceRestartDuringPeerDeliveryStopsRemainingRetiredFanout() throws {
        let first = try AnnotationCoordinatorFixture()
        let second = try AnnotationCoordinatorFixture(existingHost: first.host, receiverID: UUID())
        let previous = try #require(first.snapshot?.sessionID)
        var changed = false
        // Dictionary iteration order must not affect this regression. Whichever
        // peer receives first restarts capture synchronously during delivery.
        let restart: (AnnotationEvent) -> Void = { [weak first] _ in
            guard !changed else { return }
            changed = true
            first?.host.beginSource(nowNanos: 2_000_000_000)
        }
        first.onWireEvent = restart; second.onWireEvent = restart
        first.host.processLocal(.init(sessionID: previous, sequence: 1,
            action: .setDefaultStickerTTL(.thirty)), nowNanos: 1_000_000_000)
        #expect(changed)
        #expect(first.wireRevisions.count + second.wireRevisions.count == 1)
        #expect(first.snapshot?.sessionID != previous)
        #expect(first.snapshot?.sessionID == second.snapshot?.sessionID)
        #expect(first.errors.isEmpty && second.errors.isEmpty)
        let next = try #require(first.snapshot?.sessionID)
        first.host.processLocal(.init(sessionID: next, sequence: 1,
            action: .setDefaultStickerTTL(.threeHundred)), nowNanos: 3_000_000_000)
        #expect(first.wireRevisions.count + second.wireRevisions.count == 3)
    }

    @Test func repeatedSnapshotRequestsAreCoalescedWithoutDisconnectingMedia() throws {
        let pair = try AnnotationCoordinatorFixture()
        let initial = pair.snapshotCount
        pair.viewer.requestSnapshot()
        pair.viewer.requestSnapshot()
        #expect(pair.errors.isEmpty)
        pair.host.tick(nowNanos: 2_000_000_000)
        #expect(pair.snapshotCount == initial + 2)
    }

    @Test func reentrantPublicationKeepsEveryViewerInHostRevisionOrder() throws {
        let pair = try AnnotationCoordinatorFixture()
        let source = try #require(pair.snapshot?.sessionID)
        var nested = false
        pair.host.onEvent = { [weak pair] _ in
            guard !nested else { return }
            nested = true
            pair?.host.processLocal(.init(sessionID: source, sequence: 2, action: .setDefaultStickerTTL(.threeHundred)), nowNanos: 1_000_000_000)
        }
        pair.host.processLocal(.init(sessionID: source, sequence: 1, action: .setDefaultStickerTTL(.thirty)), nowNanos: 1_000_000_000)
        #expect(pair.wireRevisions == [1, 2])
        #expect(pair.errors.isEmpty)
    }

    @Test func admittedActorOwnsCommandsAndSourceRestartClearsReplicas() throws {
        let pair = try AnnotationCoordinatorFixture()
        let first = try #require(pair.snapshot)
        let sticker = UUID()
        pair.viewer.send(AnnotationCommand(sessionID: first.sessionID, sequence: 1,
            action: .placeSticker(id: sticker, stickerID: .heart, position: .init(x: 0.5, y: 0.5))))
        let event = try #require(pair.events.last)
        #expect(event.actorID == NetworkFixture.receiver.uuidString)
        guard case .upsert(let object) = event.change else { Issue.record("Missing accepted sticker"); return }
        #expect(object.authorID == NetworkFixture.receiver.uuidString)
        pair.host.beginSource(nowNanos: 3_000_000_000)
        #expect(pair.snapshot?.sessionID != first.sessionID)
        #expect(pair.snapshot?.objects.isEmpty == true)
        pair.viewer.send(AnnotationCommand(sessionID: first.sessionID, sequence: 2, action: .clear))
        #expect(pair.rejections.last == .wrongSession)
        #expect(pair.errors.isEmpty)
    }

    @Test func publicRoomIsPresenterOnlyAndRevocationClearsViewer() throws {
        let pair = try AnnotationCoordinatorFixture(isPublic: true)
        let snapshot = try #require(pair.snapshot)
        pair.viewer.send(AnnotationCommand(sessionID: snapshot.sessionID, sequence: 1,
            action: .placeSticker(id: UUID(), stickerID: .star, position: .init(x: 0.5, y: 0.5))))
        #expect(pair.rejections == [.permissionDenied])
        #expect(pair.events.isEmpty)
        pair.clientCredentials.invalidate()
        pair.viewer.receive(try AnnotationWireMessage.requestSnapshot.encoded(), nowNanos: 2_000_000_000)
        #expect(pair.snapshot == nil)
    }

    @Test func fullCriticalQueueFailsExplicitlyAndDoesNotAffectOtherPeer() {
        var failures = 0, healthySends = 0
        let stalled = AnnotationReliableOutput(send: { _, _ in }, close: { _ in failures += 1 })
        let healthy = AnnotationReliableOutput(send: { _, done in healthySends += 1; done(.success(())) }, close: { _ in Issue.record("Healthy output failed") })
        for _ in 0..<140 {
            stalled.enqueue(.ended(sessionID: UUID()))
            healthy.enqueue(.ended(sessionID: UUID()))
        }
        #expect(failures == 1)
        #expect(healthySends == 140)
    }
}

/// Codec/coordinator unit harness. Actual TLS credential derivation is covered
/// separately by SecurePeerChannelTests; only tests can construct credentials.
private final class AnnotationCoordinatorFixture {
    let host: AnnotationHostCoordinator
    var viewer: AnnotationViewerCoordinator!
    let clientCredentials: AuthenticatedChannelCredentials
    var snapshot: AnnotationSnapshot?
    var events: [AnnotationEvent] = []
    var rejections: [AnnotationRejection] = []
    var errors: [Error] = []
    var wireRevisions: [UInt64] = []
    var snapshotCount = 0
    var onWireEvent: ((AnnotationEvent) -> Void)?
    init(isPublic: Bool = false, existingHost: AnnotationHostCoordinator? = nil,
         receiverID: UUID = NetworkFixture.receiver) throws {
        let offer = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop)
        let transcript = try AdmissionTranscript(roomID: NetworkFixture.room, initiatorID: receiverID,
            responderID: NetworkFixture.sender, connectionID: UUID(), initiatorKeyHash: Data(repeating: 1, count: 32),
            responderKeyHash: Data(repeating: 2, count: 32), initiatorNonce: Data(repeating: 3, count: 32),
            responderNonce: Data(repeating: 4, count: 32), initiatorOffer: offer, responderOffer: offer,
            policy: .secureV2, channelRole: .mediaControl)
        clientCredentials = AuthenticatedChannelCredentials(transcript: transcript, localRole: .initiator, rootSecret: NetworkFixture.key)
        let server = AuthenticatedChannelCredentials(transcript: transcript, localRole: .responder, rootSecret: NetworkFixture.key)
        host = existingHost ?? AnnotationHostCoordinator(roomID: NetworkFixture.room, presenterID: NetworkFixture.sender, isPublicRoom: isPublic)
        if existingHost == nil { host.beginSource(nowNanos: 1_000_000_000) }
        viewer = try AnnotationViewerCoordinator(credentials: clientCredentials, send: { [weak self] data, done in
            self?.host.receive(data, connectionID: transcript.connectionID, nowNanos: 1_000_000_000)
            done(.success(()))
        }, close: { [weak self] error in self?.errors.append(error) })
        viewer.onSnapshot = { [weak self] in self?.snapshot = $0; self?.snapshotCount += 1 }
        viewer.onEvent = { [weak self] in self?.events.append($0) }
        viewer.onRejection = { [weak self] _, reason in self?.rejections.append(reason) }
        try host.addPeer(credentials: server, send: { [weak self] data, done in
            if case .event(let event) = try? AnnotationWireMessage(encoded: data) { self?.wireRevisions.append(event.revision) }
            self?.viewer.receive(data, nowNanos: 1_000_000_000)
            if case .event(let event) = try? AnnotationWireMessage(encoded: data) { self?.onWireEvent?(event) }
            done(.success(()))
        }, close: { [weak self] error in self?.errors.append(error) })
        viewer.start()
    }
}
