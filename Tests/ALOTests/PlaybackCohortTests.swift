import Foundation
import Testing
import ALOCore
@testable import ALO

struct PlaybackCohortTests {
    @Test func weightedCompletionIsOncePerTicketAndGeneration() {
        let credits = PlaybackBufferCompletions()
        let first = credits.scheduled(packetCount: 4)
        let second = credits.scheduled(packetCount: 3)
        #expect(credits.count == 7)
        credits.completed(generation: first)
        #expect(credits.count == 3)
        credits.completed(generation: first)
        #expect(credits.count == 3)
        credits.invalidate()
        let fresh = credits.scheduled(packetCount: 2)
        credits.completed(generation: second)
        #expect(credits.count == 2)
        credits.completed(generation: fresh)
        #expect(credits.count == 0)
    }
    @Test(arguments: [1, 2, 3, 4])
    func exactTailFramesAndFrozenDeadline(packets: Int) throws {
        let context = PlaybackPCMCohort.Context(offset: 0, targetLatency: 250_000_000, outputLatency: 0)
        var cohort = try #require(PlaybackPCMCohort(samples: [Int16](repeating: 1, count: 480),
            sourceFrame: 0, renderNanos: 250_000_000, heldAtNanos: 1_000_000, context: context))
        for index in 1..<packets {
            let next = try #require(PlaybackPCMCohort(samples: [Int16](repeating: Int16(index+1), count: 480),
                sourceFrame: UInt64(index*240), renderNanos: 250_000_000 + UInt64(index)*5_000_000 + 100_000,
                heldAtNanos: UInt64(index)*5_000_000, context: context))
            let appended = cohort.append(next)
            #expect(appended)
        }
        #expect(cohort.packetCount == packets && cohort.frameCount == packets*240)
        #expect(cohort.endRenderNanos == 250_000_000 + UInt64(packets)*5_000_000)
        #expect(cohort.flushDeadline(headroomNanos: 25_000_000) == 21_000_000)
        #expect(cohort.flushDeadline(headroomNanos: 240_000_000) == 10_000_000)
        #expect(cohort.samples.count == packets*480)
        for index in 0..<packets { #expect(cohort.samples[index*480] == Int16(index+1)) }
    }
}
