import Foundation
import Testing
import ALOCore
@testable import ALONetworking

@Suite struct AnnotationWireTests {
    @Test func snapshotCannotPoisonTheNextEventRevisionOrRendererGeometry() throws {
        let source = AnnotationAuthority(presenterID: "presenter")
        let maximumRevision = AnnotationSnapshot(sessionID: source.sessionID, revision: .max,
            presenterID: "presenter", hostTimeNanos: 1, policy: source.policy, objects: [], leases: [])
        let invalidGeometry = AnnotationSnapshot(sessionID: source.sessionID, revision: 1,
            presenterID: "presenter", hostTimeNanos: 1, policy: source.policy,
            objects: [.init(authorID: "presenter", tool: .pencil, points: [.init(x: 1e100, y: -1)])], leases: [])
        for snapshot in [maximumRevision, invalidGeometry] {
            let chunks = try AnnotationSnapshotChunk.split(snapshot)
            #expect(throws: (any Error).self) {
                var assembler = AnnotationSnapshotAssembler()
                for chunk in chunks { _ = try assembler.append(chunk, nowNanos: 1) }
            }
        }
    }

    @Test func snapshotRetainsHostTTLAndSessionAcrossChunks() throws {
        var authority = AnnotationAuthority(presenterID: "presenter")
        let command = AnnotationCommand(sessionID: authority.sessionID, sequence: 1,
            action: .placeSticker(id: UUID(), stickerID: .heart, position: .init(x: 0.5, y: 0.5), ttl: .sixty))
        let result = authority.process(command, actorID: "viewer", nowNanos: 1_000_000_000)
        #expect(result.accepted)
        let snapshot = authority.snapshot(nowNanos: 21_000_000_000)
        var assembler = AnnotationSnapshotAssembler()
        var assembled: AnnotationSnapshot?
        for chunk in try AnnotationSnapshotChunk.split(snapshot) {
            let wire = try AnnotationWireMessage.snapshotChunk(chunk).encoded()
            guard case .snapshotChunk(let decoded) = try AnnotationWireMessage(encoded: wire) else {
                Issue.record("Wrong wire message"); return
            }
            assembled = try assembler.append(decoded, nowNanos: 5_000_000_000)
        }
        #expect(assembled == snapshot)
        let object = try #require(assembled?.objects.first)
        #expect(assembled?.remainingTTL(for: object) == 40)
        #expect(assembler.bufferedByteCount == 0)
    }

    @Test func reorderedSplicedOrExpiredSnapshotCannotRetainMemory() throws {
        let transfer = UUID(), session = UUID()
        let first = try AnnotationSnapshotChunk(transferID: transfer, sessionID: session, index: 0, count: 2,
            bytes: Data(repeating: 1, count: AnnotationSnapshotChunk.chunkBytes))
        let last = try AnnotationSnapshotChunk(transferID: transfer, sessionID: session, index: 1, count: 2, bytes: Data([1]))
        var assembler = AnnotationSnapshotAssembler()
        do { _ = try assembler.append(last, nowNanos: 0); Issue.record("Accepted out-of-order chunk") } catch {}
        #expect(assembler.bufferedByteCount == 0)
        _ = try assembler.append(first, nowNanos: 0)
        do { _ = try assembler.append(last, nowNanos: 10_000_000_000); Issue.record("Accepted expired transfer") } catch {}
        #expect(assembler.bufferedByteCount == 0)
        _ = try assembler.append(first, nowNanos: 20_000_000_000)
        let spliced = try AnnotationSnapshotChunk(transferID: UUID(), sessionID: session, index: 1, count: 2, bytes: Data([1]))
        do { _ = try assembler.append(spliced, nowNanos: 20_000_000_001); Issue.record("Accepted spliced transfer") } catch {}
        #expect(assembler.bufferedByteCount == 0)
    }

    @Test func boundedWireRejectsUnknownProtocolAndOversizedCommands() throws {
        #expect(throws: (any Error).self) {
            _ = try AnnotationWireMessage(encoded: Data(repeating: 1, count: AnnotationWireMessage.maximumWireBytes + 1))
        }
        #expect(throws: (any Error).self) {
            _ = try AnnotationWireMessage.hello(capabilities: Array(repeating: "annotations.v1", count: 17)).encoded()
        }
        let valid = try AnnotationWireMessage.requestSnapshot.encoded()
        let other = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "annotations.v1", with: "annotations.v9").utf8)
        #expect(throws: (any Error).self) { _ = try AnnotationWireMessage(encoded: other) }
    }
}
