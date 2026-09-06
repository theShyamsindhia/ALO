import Testing
import ALOCore

@Suite("Clock reacquisition after interrupted two-device playback")
struct ClockReacquisitionTests {
    private func probe(_ clock: ClockSynchronizer, at time: UInt64,
                       offset: UInt64, rtt: UInt64 = 2_000_000) {
        let ping = clock.makePing(at: time)
        #expect(clock.acceptPong(.init(type: "pong", id: ping.id,
            clientNanos: time, hostNanos: time + rtt / 2 + offset), receivedAt: time + rtt))
    }

    @Test func resumedLinkMustNotReusePreInterruptionLowLatencySamples() {
        let clock = ClockSynchronizer()
        for second in UInt64(1)...120 {
            probe(clock, at: second * 1_000_000_000, offset: 100_000_000)
        }
        // One Mac slept, or its monotonic epoch advanced differently while the
        // connection was stalled. The resumed Wi-Fi path has a higher RTT.
        // The old minimum-RTT window must not outvote ALL fresh observations.
        for step in UInt64(0)..<4 {
            probe(clock, at: 130_000_000_000 + step * 250_000_000,
                  offset: 600_000_000, rtt: 8_000_000)
            if step == 0 { #expect(!clock.isReady) }
        }
        #expect(clock.isReady)
        #expect(abs((clock.offsetNanos(at: 131_000_000_000) ?? 0) - 600_000_000) < 1_000_000)
    }

    @Test func resetDoesNotAllowAnOldPongToAuthenticateANewProbe() {
        let clock = ClockSynchronizer()
        let old = clock.makePing(at: 1_000_000_000)
        clock.reset()
        let new = clock.makePing(at: 2_000_000_000)
        #expect(old.id != new.id)
        #expect(!clock.acceptPong(.init(type: "pong", id: old.id,
            clientNanos: old.clientNanos, hostNanos: 900_000_000_000), receivedAt: 2_002_000_000))
        #expect(clock.sampleCount == 0)
    }

    @Test func echoedTimestampMustMatchOutstandingProbe() {
        let clock = ClockSynchronizer()
        let ping = clock.makePing(at: 1_000_000_000)
        #expect(!clock.acceptPong(.init(type: "pong", id: ping.id,
            clientNanos: 999, hostNanos: 900_000_000_000), receivedAt: 1_002_000_000))
        #expect(clock.sampleCount == 0)
    }
}
