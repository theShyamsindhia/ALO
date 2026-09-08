import Testing
@testable import ALO

struct DevTimingLogChunksTests {
    @Test func transitionEvidenceAlsoFitsNativeLimit() {
        let lines = DevTimingLogChunks.transitionLines(detail: String(repeating: "x", count: 3_000), sampledAtNanos: 100)
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { $0.utf8.count <= 800 && $0.hasPrefix("Playback timing ") })
    }
    @Test func sameTimestampSnapshotsCannotBeMixed() {
        let first = DevTimingLogChunks.make(detail: String(repeating: "a", count: 2_000), sampledAtNanos: 100)
        let second = DevTimingLogChunks.make(detail: String(repeating: "b", count: 2_000), sampledAtNanos: 100)
        var mixed = first
        mixed[1] = second[1]
        #expect(DevTimingLogChunks.reassemble(mixed) == nil)
    }
    @Test(arguments: [0, 1, 2])
    func everyLineFitsNativeLimitAndReassemblesExactly(fixture: Int) throws {
        let detail = ["", String(repeating: "1234567890", count: 1_000),
            String(repeating: "界👩🏽‍💻e\u{301}", count: 1_000)][fixture]
        let parts = DevTimingLogChunks.make(detail: detail, sampledAtNanos: .max)
        #expect(!parts.isEmpty)
        #expect(parts.allSatisfy { $0.line.utf8.count <= 800 })
        #expect(parts.allSatisfy { $0.line.contains("monotonic_ns=18446744073709551615 part=") })
        let joined = try #require(DevTimingLogChunks.reassemble(Array(parts.reversed())))
        #expect(Array(joined.utf8) == Array(detail.utf8))
    }

    @Test func incompleteDuplicateOrMixedSamplesAreNotEvidence() {
        let parts = DevTimingLogChunks.make(detail: String(repeating: "x", count: 2_000), sampledAtNanos: 100)
        #expect(DevTimingLogChunks.reassemble([]) == nil)
        #expect(DevTimingLogChunks.reassemble(Array(parts.dropLast())) == nil)
        var duplicate = parts
        duplicate[1] = duplicate[0]
        #expect(DevTimingLogChunks.reassemble(duplicate) == nil)
        var mixed = parts
        mixed[1] = .init(snapshotID: parts[1].snapshotID, kind: parts[1].kind,
            sampledAtNanos: 101, index: 2, count: parts.count, payload: parts[1].payload)
        #expect(DevTimingLogChunks.reassemble(mixed) == nil)
    }
}
