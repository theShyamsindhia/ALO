import Foundation
import Testing
@testable import ALOCore

@Suite struct ClockProtocolResilienceTests {
    @Test func unansweredProbesEvictOldestWithoutCreatingClockSamples() {
        let clock = ClockSynchronizer()
        let first = clock.makePing(at: 0)
        for time in 1...128 { _ = clock.makePing(at: UInt64(time)) }
        let accepted = clock.acceptPong(.init(type: "pong", id: first.id,
            clientNanos: 0, hostNanos: 100), receivedAt: 200)
        #expect(!accepted)
        #expect(clock.sampleCount == 0)
        #expect(!clock.isReady)
    }

    @Test func expiredProbeCannotPrimeAClockAfterAStall() {
        let clock = ClockSynchronizer()
        let ping = clock.makePing(at: 1_000)
        let accepted = clock.acceptPong(.init(type: "pong", id: ping.id,
            clientNanos: 1_000, hostNanos: 2_000), receivedAt: 31_000_001_000)
        #expect(!accepted)
        #expect(clock.offsetNanos == nil)
    }

    @Test func extremeAuthenticatedHostClockCannotTrapEstimatorArithmetic() {
        let clock = ClockSynchronizer()
        let first = clock.makePing(at: 0)
        _ = clock.acceptPong(.init(type: "pong", id: first.id,
            clientNanos: 0, hostNanos: UInt64(Int64.max)), receivedAt: 0)
        let second = clock.makePing(at: 10_000)
        _ = clock.acceptPong(.init(type: "pong", id: second.id,
            clientNanos: 10_000, hostNanos: 0), receivedAt: 10_000)
        #expect(clock.offsetNanos != nil)
        #expect(clock.offsetNanos(at: UInt64.max) != nil)
    }
}
