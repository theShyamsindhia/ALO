import Testing
@testable import ALOCore
@testable import ALO

@Suite struct ClockConsumerBoundaryTests {
    @Test func minimumOffsetFromAcceptedClockSamplesDoesNotTrapJitter() throws {
        let clock = ClockSynchronizer()
        let clientEpoch = UInt64(Int64.max) + 1
        for step in UInt64(0)..<4 {
            let time = clientEpoch + step
            let ping = clock.makePing(at: time)
            #expect(clock.acceptPong(.init(type: "pong", id: ping.id,
                clientNanos: time, hostNanos: 0), receivedAt: time))
        }
        #expect(clock.isReady)
        let offset = try #require(clock.offsetNanos(at: clientEpoch + 3))
        #expect(offset == Int64.min)
        let jitter = NetworkJitterEstimator()
        jitter.observe(captureTimeNanos: 3, receivedAt: clientEpoch + 3, clockOffsetNanos: offset)
        #expect(jitter.sampleCount == 1)
    }

    @Test func overflowingHostArrivalDoesNotCreateWrappedTransitSample() throws {
        let clock = ClockSynchronizer()
        for step in UInt64(0)..<4 {
            let ping = clock.makePing(at: step)
            #expect(clock.acceptPong(.init(type: "pong", id: ping.id,
                clientNanos: step, hostNanos: UInt64.max), receivedAt: step))
        }
        let offset = try #require(clock.offsetNanos(at: 3))
        #expect(offset == Int64.max)
        let jitter = NetworkJitterEstimator()
        jitter.observe(captureTimeNanos: 0, receivedAt: UInt64.max, clockOffsetNanos: offset)
        #expect(jitter.sampleCount == 0)
    }

    @Test func minimumClockOffsetDoesNotTrapAudioPacketAdmission() throws {
        let clock = ClockSynchronizer()
        let clientEpoch = UInt64(Int64.max) + 1
        for step in UInt64(0)..<4 {
            let ping = clock.makePing(at: clientEpoch + step)
            #expect(clock.acceptPong(.init(type: "pong", id: ping.id,
                clientNanos: clientEpoch + step, hostNanos: 0), receivedAt: clientEpoch + step))
        }
        let offset = try #require(clock.offsetNanos(at: clientEpoch + 3))
        #expect(offset == Int64.min)
        let player = try SynchronizedPlayer()
        defer { player.stop() }
        player.clockOffsetNanos = offset
        player.accept(AudioPacket(sequence: 0, frameIndex: 0, captureTimeNanos: UInt64.max,
            samples: Array(repeating: 0, count: 480)))
        #expect(player.expectedSequenceForTesting == 1)
    }
}
