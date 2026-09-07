import Testing
@testable import ALO

struct DevTimingLogChunksTests {
    @Test(arguments: ["", String(repeating: "1234567890", count: 1_000),
        String(repeating: "界👩🏽‍💻e\u{301}", count: 1_000)])
    func everyLineFitsNativeLimitAndReassemblesExactly(detail: String) throws {
        let parts = DevTimingLogChunks.make(detail: detail, sampledAtNanos: .max)
        #expect(!parts.isEmpty)
        #expect(parts.allSatisfy { $0.line.utf8.count <= 800 })
        #expect(parts.allSatisfy { $0.line.contains("monotonic_ns=18446744073709551615 part=") })
        #expect(DevTimingLogChunks.reassemble(Array(parts.reversed())) == detail)
    }

    @Test func incompleteDuplicateOrMixedSamplesAreNotEvidence() {
        let parts = DevTimingLogChunks.make(detail: String(repeating: "x", count: 2_000), sampledAtNanos: 100)
        #expect(DevTimingLogChunks.reassemble([]) == nil)
        #expect(DevTimingLogChunks.reassemble(Array(parts.dropLast())) == nil)
        var duplicate = parts
        duplicate[1] = duplicate[0]
        #expect(DevTimingLogChunks.reassemble(duplicate) == nil)
        var mixed = parts
        mixed[1] = .init(sampledAtNanos: 101, index: 2, count: parts.count, payload: parts[1].payload)
        #expect(DevTimingLogChunks.reassemble(mixed) == nil)
    }
}
