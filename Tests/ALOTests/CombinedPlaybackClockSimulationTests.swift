import Foundation
import Testing
import ALOCore
import ALOTiming

/// Virtual physical time is the independent oracle. This exercises production
/// timing math, not AVAudioEngine, device latency reporting, or acoustic output.
@Suite("Combined two-output continuous playback timing")
struct CombinedPlaybackClockSimulationTests {
    @Test(arguments: [false, true])
    func independentClocksAndControlQueuePlateaus(asymmetricQueue: Bool) {
        let result = CombinedClockSimulation.run(asymmetricQueue: asymmetricQueue)
        print("Combined playback asymmetric=\(asymmetricQueue): \(result)")
        #expect(result.discontinuities == 0)
        #expect(result.validMeasurements > 20_000)
        #expect(result.maximumRateCorrection <= 0.01)
        if asymmetricQueue {
            // Characterizes an information limit, not a fixable promise that
            // four timestamps reveal the true one-way path delay. The original
            // <20ms assertion failed; its RED log is retained separately.
            #expect(result.finalPhysicalOracleSeparation > 0.020)
            #expect(result.finalWindowMaximumEstimatedError < result.finalPhysicalOracleSeparation / 2,
                "Small inferred residual must not be mistaken for physical alignment confidence")
        } else {
            #expect(result.maximumPhysicalOracleSeparation < 0.020,
                "Bounded small-asymmetry baseline must remain within20ms in the physical oracle")
        }
    }
}

private enum CombinedClockSimulation {
    struct Result: CustomStringConvertible {
        var discontinuities = 0
        var validMeasurements = 0
        var maximumRateCorrection = 0.0
        var maximumPhysicalOracleSeparation = 0.0
        var finalPhysicalOracleSeparation = 0.0
        var finalWindowMaximumEstimatedError = 0.0
        var maximumEstimatedError = 0.0
        var maximumClockBias = 0.0
        var description: String {
            "physicalOracleMax=\(maximumPhysicalOracleSeparation * 1_000)ms finalSeparation=\(finalPhysicalOracleSeparation * 1_000)ms final10sEstimatedMax=\(finalWindowMaximumEstimatedError * 1_000)ms clockBias=\(maximumClockBias * 1_000)ms estimatedMax=\(maximumEstimatedError * 1_000)ms maxRate=\(maximumRateCorrection) measurements=\(validMeasurements) discontinuities=\(discontinuities)"
        }
    }
    struct Oscillator {
        let epoch: Double
        let rate: Double
        func nanos(_ physical: Double) -> UInt64 { UInt64((epoch + physical * rate) * 1e9) }
        func physical(_ nanos: Double) -> Double { (nanos / 1e9 - epoch) / rate }
    }
    struct Reply {
        let arrival: Double
        let probe: ClockSynchronizer.Probe
        let t2: UInt64
        let t3: UInt64
    }
    struct Packet {
        let arrival: Double
        let frame: UInt64
        let capture: UInt64
    }
    final class Output {
        let clock = ClockSynchronizer()
        let monotonic: Oscillator
        let sampleOscillator: Double
        let latency: Double
        let cadence: Double
        var tracker = CaptureTimelineTracker()
        var replies: [Reply] = []
        var packets: [Packet] = []
        var history: [Double] = []
        var nextProbe = 0.0
        var nextPoll = 0.0
        var offset: Int64?
        var renderStart: Double?
        var rendered = 0.0
        var correction = 0.0
        var rate = 1.0
        init(monotonic: Oscillator, sampleOscillator: Double, latency: Double, cadence: Double) {
            self.monotonic = monotonic; self.sampleOscillator = sampleOscillator
            self.latency = latency; self.cadence = cadence
            history.reserveCapacity(360_001)
        }
    }

    static func run(asymmetricQueue: Bool) -> Result {
        let host = Oscillator(epoch: 900, rate: 1.000030)
        let captureRate = 0.999880
        let outputs = [
            Output(monotonic: .init(epoch: 120, rate: 0.999960), sampleOscillator: 1.000150, latency: 0.020, cadence: 0.005),
            Output(monotonic: .init(epoch: 450, rate: 1.000080), sampleOscillator: 0.999800, latency: 0.110, cadence: 0.020)
        ]
        // Sample rate and monotonic clocks are distinct. Content frame zero
        // was captured at physical5s, after clock-estimator warmup.
        let captureStart = 5.0
        let captureAnchor = host.nanos(captureStart)
        let delay: UInt64 = 250_000_000
        let step = 0.001
        var nextPacket = 0
        var result = Result()
        for tick in 0...360_000 {
            let now = Double(tick) * step
            while captureStart + Double(nextPacket) * 0.005 / captureRate <= now {
                let physicalCapture = captureStart + Double(nextPacket) * 0.005 / captureRate
                for (index, output) in outputs.enumerated() {
                    // Independent bounded media jitter/loss, with frame indices
                    // retained through loss. No packet-arrival time is a clock.
                    if (nextPacket + index * 13) % 137 != 0 {
                        output.packets.append(.init(arrival: physicalCapture + 0.002
                            + Double((nextPacket * 17 + index * 7) % 7) * 0.001,
                            frame: UInt64(nextPacket * 240), capture: host.nanos(physicalCapture)))
                    }
                }
                nextPacket += 1
            }
            for (index, output) in outputs.enumerated() {
                if now >= output.nextProbe {
                    let number = Int(output.nextProbe)
                    output.nextProbe += 1
                    let probe = output.clock.makeProbe(at: output.monotonic.nanos(now))
                    if (number + index * 5) % 23 != 0 {
                        let transit = 0.002 + Double((number * 17 + index * 3) % 5) * 0.0004
                        // Server residence is observed with all four timestamps.
                        // Only receiver1 gets an unobservable one-way queue in
                        // the adversarial case; do not conflate it with residence.
                        let outward = transit + (asymmetricQueue && index == 1 && number >= 180 ? 0.080 : 0)
                        let returning = transit + Double((number + index) % 3) * 0.0002
                        let residence = (number / 90).isMultiple(of: 2) ? 0.0005 : 0.120
                        output.replies.append(.init(arrival: now + outward + residence + returning,
                            probe: probe, t2: host.nanos(now + outward), t3: host.nanos(now + outward + residence)))
                    }
                }
                let readyReplies = output.replies.filter { $0.arrival <= now }.sorted { $0.arrival < $1.arrival }
                output.replies.removeAll { $0.arrival <= now }
                for reply in readyReplies {
                    let received = output.monotonic.nanos(reply.arrival)
                    if output.clock.acceptReply(id: reply.probe.id, echoedSendNanos: reply.probe.sentAtNanos,
                        hostNanos: reply.t3, receivedAt: received, hostReceivedNanos: reply.t2) {
                        // Secure playback receives a new estimate at pong time;
                        // it does not continuously extrapolate on every poll.
                        output.offset = output.clock.offsetNanos(at: received)
                    }
                }
                let readyPackets = output.packets.filter { $0.arrival <= now }.sorted { $0.arrival < $1.arrival }
                output.packets.removeAll { $0.arrival <= now }
                for packet in readyPackets {
                    if output.tracker.observe(frameIndex: packet.frame, captureNanos: packet.capture,
                        anchorFrameIndex: 0, anchorCaptureNanos: captureAnchor) == .discontinuous {
                        result.discontinuities += 1
                    }
                }
                if output.renderStart == nil, now >= captureStart + 0.015, let offset = output.offset {
                    let localStart = Double(captureAnchor + delay) - output.latency * 1e9 - Double(offset)
                    output.renderStart = output.monotonic.physical(localStart)
                }
                if let start = output.renderStart, now > start {
                    let elapsed = max(0, now - max(now - step, start))
                    output.rendered += elapsed * output.sampleOscillator * output.rate
                }
                output.history.append(output.rendered)
                if now >= output.nextPoll {
                    // Independent5ms and20ms polling plus bounded executor jitter.
                    output.nextPoll = now + output.cadence + Double((tick + index) % 3) * 0.001
                    if now >= 200 && now < 200.250 {
                        output.nextPoll = 200.250
                        continue
                    }
                    guard let start = output.renderStart, now >= start + 0.004,
                          let offset = output.offset else { continue }
                    let renderLocal = output.monotonic.nanos(now)
                    let renderHost = UInt64(Int64(renderLocal) + offset)
                    if let estimate = RenderDriftEstimate(nowNanos: renderLocal, renderLocalNanos: renderLocal,
                        renderHostNanos: renderHost, outputLatencyNanos: UInt64(output.latency * 1e9),
                        captureAnchorNanos: captureAnchor, playoutDelayNanos: delay,
                        sampleTime: Int64(output.rendered * 48_000), sampleRate: 48_000,
                        captureOffsetNanos: output.tracker.offsetNanos) {
                        output.correction = PlaybackRateCorrection.next(previous: output.correction,
                            errorSeconds: estimate.errorSeconds)
                        let nextRate = Float(1 + output.correction)
                        if abs(Float(output.rate) - nextRate) > 0.000_005 { output.rate = Double(nextRate) }
                        result.validMeasurements += 1
                        result.maximumEstimatedError = max(result.maximumEstimatedError, abs(estimate.errorSeconds))
                        if now >= 350 {
                            result.finalWindowMaximumEstimatedError = max(result.finalWindowMaximumEstimatedError,
                                abs(estimate.errorSeconds))
                        }
                        result.maximumRateCorrection = max(result.maximumRateCorrection, abs(output.correction))
                        result.maximumClockBias = max(result.maximumClockBias,
                            abs(Double(renderHost) - Double(host.nanos(now))) / 1e9)
                    }
                }
            }
            if now > 30 {
                // Compare the same physical audible instant, not simultaneous
                // render callbacks (the two route latencies differ by90ms).
                let content = outputs.map { output in
                    output.history[max(0, tick - Int((output.latency / step).rounded()))]
                }
                result.finalPhysicalOracleSeparation = abs(content[0] - content[1]) / captureRate
                result.maximumPhysicalOracleSeparation = max(result.maximumPhysicalOracleSeparation,
                    result.finalPhysicalOracleSeparation)
            }
        }
        return result
    }
}
