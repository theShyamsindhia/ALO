import Testing
import ALOTiming

@Suite("Independent two-device clock simulation")
struct ClockSimulationTests {
    @Test func hourOfOscillatorSkewJitterAndDroppedProbesStaysBounded() {
        let clock = ClockSynchronizer()
        var worstError = 0.0
        var checks = 0
        for second in UInt64(0)..<3_600 {
            // Two distinct monotonic epochs, 80 ppm oscillator disagreement,
            // variable Wi-Fi latency, bounded one-way asymmetry and lost probes.
            let t1 = 100_000_000_000 + second * 1_000_000_000
            let probe = clock.makeProbe(at: t1)
            if second % 23 == 0 { continue }
            let outward = 1_000_000 + (second * 31_337) % 4_000_000
            let returning = outward + (second % 3) * 300_000
            let hostAtReceipt = t1 + outward + 3_000_000_000 + (t1 + outward) / 12_500
            #expect(clock.acceptReply(id: probe.id, echoedSendNanos: t1,
                hostNanos: hostAtReceipt, receivedAt: t1 + outward + returning))
            if second > 30, let estimated = clock.offsetNanos(at: t1 + 500_000_000) {
                let actual = 3_000_000_000 + (t1 + 500_000_000) / 12_500
                worstError = max(worstError, abs(Double(estimated) - Double(actual)))
                checks += 1
            }
        }
        #expect(checks > 3_000)
        #expect(worstError < 2_000_000, "worst offset error: \(worstError / 1_000_000) ms")
    }

    @Test func hostProcessingDelayMustNotBecomeClockOffset() {
        let clock = ClockSynchronizer()
        for second in UInt64(1)...30 {
            let sent = second * 1_000_000_000
            let probe = clock.makeProbe(at: sent)
            let serverReceived = sent + 2_000_000 + 100_000_000
            let serverSent = serverReceived + 120_000_000
            #expect(clock.acceptReply(id: probe.id, echoedSendNanos: sent,
                hostNanos: serverSent, receivedAt: sent + 124_000_000,
                hostReceivedNanos: serverReceived))
        }
        #expect(abs((clock.offsetNanos(at: 30_124_000_000) ?? 0) - 100_000_000) < 1_000_000)
    }

    @Test func uninterruptedPlaybackWithChangingHostLoadDoesNotDrift() {
        let clock = ClockSynchronizer()
        var largestError = 0.0
        for second in UInt64(1)...3_600 {
            let t1 = 100_000_000_000 + second * 1_000_000_000
            let probe = clock.makeProbe(at: t1)
            let transit: UInt64 = 2_000_000
            // Long low-load/high-load plateaus reproduce the original filter's
            // failure after old low-latency samples leave its 120-sample window.
            let residence: UInt64 = (second / 180).isMultiple(of: 2) ? 500_000 : 120_000_000
            let t2 = t1 + transit + 600_000_000
            let t3 = t2 + residence
            let t4 = t1 + transit * 2 + residence
            #expect(clock.acceptReply(id: probe.id, echoedSendNanos: t1,
                hostNanos: t3, receivedAt: t4, hostReceivedNanos: t2))
            if clock.isReady {
                largestError = max(largestError, abs(Double(clock.offsetNanos(at: t4) ?? 0) - 600_000_000))
            }
        }
        #expect(largestError < 1_000_000, "Clock load-induced error: \(largestError / 1_000_000) ms")
        #expect(clock.bestRoundTripNanos == 4_000_000)
    }

    @Test func invalidResidenceAndReplayedRepliesCannotTrainTheClock() {
        let clock = ClockSynchronizer()
        for (received, sent) in [(UInt64(200), UInt64(199)), (200, 2_000)] {
            let probe = clock.makeProbe(at: 100)
            #expect(!clock.acceptReply(id: probe.id, echoedSendNanos: 100,
                hostNanos: sent, receivedAt: 110, hostReceivedNanos: received))
        }
        #expect(clock.sampleCount == 0)
        let good = clock.makeProbe(at: 1_000)
        #expect(clock.acceptReply(id: good.id, echoedSendNanos: 1_000,
            hostNanos: 2_006, receivedAt: 1_010, hostReceivedNanos: 2_004))
        #expect(!clock.acceptReply(id: good.id, echoedSendNanos: 1_000,
            hostNanos: 2_006, receivedAt: 1_010, hostReceivedNanos: 2_004))
        #expect(clock.sampleCount == 1)
    }
}
