import AVFoundation
import Testing
import ALOCore
@testable import ALO

/// Offline graph probe only. It does not measure hardware or acoustic latency.
@Suite(.serialized)
struct ManualRenderTimingProbeTests {
    @Test(arguments: [Float(0.99), 1, 1.01], [Double(48_000), 44_100])
    func varispeedImpulseTimeline(rate: Float, outputRate: Double) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let outputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2))
        engine.attach(player)
        engine.attach(varispeed)
        engine.connect(player, to: varispeed, format: inputFormat)
        engine.connect(varispeed, to: engine.mainMixerNode, format: inputFormat)
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 256)
        defer { player.stop(); engine.stop() }

        let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 24_000))
        input.frameLength = input.frameCapacity
        let channels = try #require(input.floatChannelData)
        for channel in 0..<2 {
            channels[channel].initialize(repeating: 0, count: Int(input.frameLength))
            channels[channel][4_800] = 1
            channels[channel][14_400] = 1
        }
        varispeed.rate = rate
        player.scheduleBuffer(input)
        try engine.start()
        player.play()

        let output = try #require(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 256))
        var rendered: [Float] = []
        var lastPlayerSeconds: Double?
        var lastOutputSeconds: Double?
        for _ in 0..<Int(outputRate * 0.45 / 256) + 2 {
            let status = try engine.renderOffline(256, to: output)
            try #require(status == .success, "Offline graph failed to render: \(status.rawValue)")
            let channel = try #require(output.floatChannelData)[0]
            rendered.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            if let nodeTime = player.lastRenderTime,
               let time = player.playerTime(forNodeTime: nodeTime), time.isSampleTimeValid {
                lastPlayerSeconds = Double(time.sampleTime) / time.sampleRate
                lastOutputSeconds = Double(engine.manualRenderingSampleTime) / outputRate
            }
        }
        func peak(near seconds: Double) throws -> Int {
            let first = max(0, Int((seconds - 0.025) * outputRate))
            let end = min(rendered.count, Int((seconds + 0.025) * outputRate))
            let index = try #require((first..<end).max { abs(rendered[$0]) < abs(rendered[$1]) })
            #expect(abs(rendered[index]) > 0.1, "Expected impulse was not rendered")
            return index
        }
        let first = try peak(near: 0.1 / Double(rate))
        let second = try peak(near: 0.3 / Double(rate))
        let firstError = Double(first) / outputRate - 0.1 / Double(rate)
        let secondError = Double(second) / outputRate - 0.3 / Double(rate)
        let intervalError = Double(second - first) / outputRate - 0.2 / Double(rate)
        print("OFFLINE_TIMING rate=\(rate) outputHz=\(outputRate) firstErrorMs=\(firstError * 1000) secondErrorMs=\(secondError * 1000) intervalErrorMs=\(intervalError * 1000) playerSeconds=\(lastPlayerSeconds ?? -1) outputSeconds=\(lastOutputSeconds ?? -1) playerDownstreamMs=\(player.outputPresentationLatency * 1000) unitLatencyMs=\(varispeed.latency * 1000) outputHardwareMs=\(engine.outputNode.presentationLatency * 1000)")
        // The initial zero-delay hypothesis was falsified: this offline graph
        // adds ~1ms, plus resampling delay at 44.1kHz. Characterize its stable
        // phase separately from rate accuracy; this is not acoustic evidence.
        #expect(abs(intervalError) <= 2 / outputRate, "Rendered content must follow the requested rate")
        #expect(abs(firstError - player.outputPresentationLatency) < 0.001,
                "Offline phase should remain close to the measured downstream graph delay")
        #expect(abs(secondError - firstError) <= 2 / outputRate,
                "A fixed graph delay must not masquerade as accumulating drift")
    }

    @Test @MainActor
    func missingRenderHostTimeDoesNotLatchPriorRate() async throws {
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 960)
        let player = try SynchronizedPlayer(audioOutput: output, liveDJAudio: DJLiveAudio())
        defer { player.stop(); output.engine.stop() }
        let node = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        let unit = try #require(output.engine.attachedNodes.compactMap { $0 as? AVAudioUnitVarispeed }.first)
        player.clockOffsetNanos = 0
        let capture = MonotonicClock.nowNanos() + 2_000_000_000
        func packet(_ sequence: UInt32) -> AudioPacket {
            AudioPacket(sequence: sequence, frameIndex: UInt64(sequence) * 240,
                captureTimeNanos: capture + UInt64(sequence) * 5_000_000,
                samples: [Int16](repeating: 500, count: 480))
        }
        player.accept(packet(0))
        // Offline mode has no meaningful future host-time start. Keep the
        // production wrapper/anchor live, but start its real node in sample
        // time and seed a prior correction through the attached audio unit.
        node.stop()
        let seed = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        seed.frameLength = seed.frameCapacity
        for channel in 0..<2 {
            try #require(seed.floatChannelData)[channel].initialize(repeating: 0.01, count: 960)
        }
        node.scheduleBuffer(seed, completionHandler: nil)
        node.play()
        unit.rate = 1.01
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        var previousSample: Int64 = -1
        let began = MonotonicClock.nowNanos()
        for step in 0..<60 {
            for offset in 1...4 { player.accept(packet(UInt32(step * 4 + offset))) }
            try #require(try output.engine.renderOffline(960, to: buffer) == .success)
            let render = try #require(node.lastRenderTime)
            let time = try #require(node.playerTime(forNodeTime: render))
            let now = MonotonicClock.nowNanos()
            let host = MonotonicClock.ticksToNanos(render.hostTime)
            let unavailableHost = !render.isHostTimeValid || now < host || now - host > RenderDriftEstimate.maximumAgeNanos
            try #require(unavailableHost, "Offline mode did not produce the target missing/stale host timestamp condition")
            try #require(time.isSampleTimeValid && time.sampleTime > previousSample,
                         "Test requires advancing playback, not a watchdog-detectable stall")
            previousSample = time.sampleTime
            player.maintainSync()
            if step == 0 { #expect(unit.rate == 1.01, "A brief missing sample should preserve the prior rate") }
            #expect(player.syncReport().driftNanos == nil)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        print("MISSING_RENDER_HOST elapsedMs=\(Double(MonotonicClock.nowNanos() - began) / 1_000_000) finalRate=\(unit.rate) sampleTime=\(previousSample) resyncs=\(player.syncReport().resyncCount)")
        #expect(abs(unit.rate - 1) < 0.000_005,
                "Production player retained a prior rate correction for over a second without a usable render host clock")
        unit.rate = 1.01
        player.resetStream()
        #expect(unit.rate == 1, "Stream reset must discard the previous rate")
        unit.rate = 0.99
        player.stop()
        #expect(unit.rate == 1, "Stop must discard the previous rate")
    }

    @Test func holdoverPreservesBriefGapsThenFreshTimingResumesWithoutStaleCorrection() {
        var controller = PlaybackRateController()
        let sample: UInt64 = 1_000_000_000
        for _ in 0..<100 { _ = controller.updateFresh(errorSeconds: 0.04, sampledAtNanos: sample) }
        let learned = controller.rate
        #expect(learned > 1.009)
        let shortGapExpired = controller.handleMissing(at: sample + PlaybackRateController.maximumHoldoverNanos - 1)
        #expect(!shortGapExpired)
        #expect(controller.rate == learned)
        let longGapExpired = controller.handleMissing(at: sample + PlaybackRateController.maximumHoldoverNanos)
        #expect(longGapExpired)
        #expect(controller.rate == 1)
        // Recovery starts from neutral, without replaying the old smoothed 1%.
        #expect(controller.updateFresh(errorSeconds: 0, sampledAtNanos: 2_000_000_000) == 1)
        #expect(controller.updateFresh(errorSeconds: -0.004, sampledAtNanos: 2_020_000_000) < 1)
        let resumedGapExpired = controller.handleMissing(at: 2_100_000_000)
        #expect(!resumedGapExpired)
        #expect(controller.rate < 1)
        controller.reset()
        #expect(controller.rate == 1)
        let resetGapExpired = controller.handleMissing(at: 10_000_000_000)
        #expect(!resetGapExpired, "Reset must clear old clock-age evidence")
        let resetLongGapExpired = controller.handleMissing(at: 10_000_000_000 + PlaybackRateController.maximumHoldoverNanos)
        #expect(resetLongGapExpired)
    }

    @Test func staleOrRegressedSampleClockCannotExtendHoldover() {
        var controller = PlaybackRateController()
        _ = controller.updateFresh(errorSeconds: 0.04, sampledAtNanos: 1_000_000_000)
        // Budget starts at the actual render sample, not the later poll.
        let staleExpired = controller.handleMissing(at: 1_500_000_000)
        #expect(staleExpired)
        #expect(controller.rate == 1)
        _ = controller.updateFresh(errorSeconds: 0.04, sampledAtNanos: 2_000_000_000)
        let regressedExpired = controller.handleMissing(at: 1_999_999_999)
        #expect(regressedExpired)
        #expect(controller.rate == 1)
        _ = controller.updateFresh(errorSeconds: 0.04, sampledAtNanos: 3_000_000_000)
        #expect(controller.rate > 1)
        #expect(controller.updateFresh(errorSeconds: 0, sampledAtNanos: 4_000_000_000) == 1,
                "A blocked maintenance queue must not replay correction on its first fresh sample")
    }
}
